import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import Network
import VideoToolbox

class H264StreamManager: NSObject, ObservableObject {
    @Published var currentFrame: CGImage?
    @Published var isStreaming = false
    @Published var currentFPS: Double = 0

    /// Called when the stream ends unexpectedly (USB unplug, network error, etc.)
    var onStreamFailed: ((Error?) -> Void)?

    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    fileprivate var pendingFrame: CGImage?
    private var displayLink: CVDisplayLink?
    private var displayLinkActive = false
    private var frameCount = 0
    private var fpsTimer: Timer?

    // Cached CIContext for CVPixelBuffer → CGImage conversion
    fileprivate let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // NAL unit parsing state
    private var buffer = Data()
    private var spsData: Data?
    private var ppsData: Data?

    init(host: String, port: UInt16 = 9200) {
        self.host = host
        self.port = port
        super.init()
    }

    func start() {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)

        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self?.isStreaming = true
                    self?.startFPSCounter()
                    self?.startDisplayLink()
                }
                self?.readLengthPrefix()
            case .failed(let error):
                DispatchQueue.main.async {
                    self?.isStreaming = false
                    self?.onStreamFailed?(error)
                }
            case .cancelled:
                DispatchQueue.main.async {
                    self?.isStreaming = false
                }
            default:
                break
            }
        }

        connection?.start(queue: DispatchQueue(label: "h264.network", qos: .userInteractive))
    }

    func stop() {
        connection?.cancel()
        connection = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        stopDisplayLink()
        destroyDecompressionSession()
        DispatchQueue.main.async { [weak self] in
            self?.isStreaming = false
        }
    }

    // MARK: - Network Reading (length-prefixed NAL units)

    private func readLengthPrefix() {
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async { [weak self] in
                    self?.isStreaming = false
                    self?.onStreamFailed?(error)
                }
                return
            }

            if isComplete {
                DispatchQueue.main.async { [weak self] in
                    self?.isStreaming = false
                    self?.onStreamFailed?(nil)
                }
                return
            }

            guard let data = data, data.count == 4 else {
                self.readLengthPrefix()
                return
            }

            let length = data.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(as: UInt32.self).bigEndian
            }

            self.readNALUnit(length: Int(length))
        }
    }

    private func readNALUnit(length: Int) {
        guard length > 0, length < 10_000_000 else {
            // Sanity check — skip corrupted frames
            readLengthPrefix()
            return
        }

        connection?.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async { [weak self] in
                    self?.isStreaming = false
                    self?.onStreamFailed?(error)
                }
                return
            }

            if isComplete {
                DispatchQueue.main.async { [weak self] in
                    self?.isStreaming = false
                    self?.onStreamFailed?(nil)
                }
                return
            }

            if let data = data {
                self.processNALData(data)
            }

            self.readLengthPrefix()
        }
    }

    // MARK: - NAL Unit Processing

    private func processNALData(_ data: Data) {
        // The data contains one or more NAL units in Annex B format (00 00 00 01 prefix).
        // We need to find SPS/PPS to create the format description,
        // then wrap video NAL units into CMSampleBuffers for decoding.

        let nalUnits = extractNALUnits(from: data)

        for nalUnit in nalUnits {
            guard !nalUnit.isEmpty else { continue }

            let nalType = nalUnit[0] & 0x1F

            switch nalType {
            case 7: // SPS
                spsData = nalUnit
                tryCreateFormatDescription()
            case 8: // PPS
                ppsData = nalUnit
                tryCreateFormatDescription()
            case 1, 5: // Coded slice (non-IDR / IDR)
                decodeNALUnit(nalUnit)
            default:
                break
            }
        }
    }

    private func extractNALUnits(from data: Data) -> [Data] {
        var units: [Data] = []
        var i = 0
        let count = data.count
        var startPositions: [Int] = []

        // Find all Annex B start codes (00 00 00 01)
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while i < count - 3 {
                if base[i] == 0x00 && base[i + 1] == 0x00 && base[i + 2] == 0x00 && base[i + 3] == 0x01 {
                    startPositions.append(i)
                    i += 4
                } else {
                    i += 1
                }
            }
        }

        for (idx, start) in startPositions.enumerated() {
            let nalStart = start + 4
            let nalEnd = idx + 1 < startPositions.count ? startPositions[idx + 1] : count
            if nalStart < nalEnd {
                units.append(data.subdata(in: nalStart..<nalEnd))
            }
        }

        return units
    }

    private func tryCreateFormatDescription() {
        guard let sps = spsData, let pps = ppsData else { return }

        // Destroy old session if format changes
        destroyDecompressionSession()
        formatDescription = nil

        sps.withUnsafeBytes { (spsRaw: UnsafeRawBufferPointer) in
            pps.withUnsafeBytes { (ppsRaw: UnsafeRawBufferPointer) in
                let spsPtr = spsRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let ppsPtr = ppsRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                var pointers = [spsPtr, ppsPtr]
                var sizes = [sps.count, pps.count]

                var desc: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )

                if status == noErr, let desc = desc {
                    self.formatDescription = desc
                    self.createDecompressionSession(formatDescription: desc)
                }
            }
        }
    }

    // MARK: - VTDecompressionSession

    private func createDecompressionSession(formatDescription: CMVideoFormatDescription) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )

        if status == noErr {
            decompressionSession = session
        }
    }

    private func destroyDecompressionSession() {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
    }

    private func decodeNALUnit(_ nalUnit: Data) {
        guard let formatDescription = formatDescription,
              let session = decompressionSession else { return }

        // Convert from Annex B to AVCC (4-byte length prefix)
        var nalLength = UInt32(nalUnit.count).bigEndian
        var avccData = Data(bytes: &nalLength, count: 4)
        avccData.append(nalUnit)

        let dataLength = avccData.count

        // Create CMBlockBuffer with a copy of the data
        var blockBuffer: CMBlockBuffer?
        let status = avccData.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) -> OSStatus in
            guard let baseAddress = rawPtr.baseAddress else { return -1 }
            var localBlock: CMBlockBuffer?
            let s = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: dataLength,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataLength,
                flags: 0,
                blockBufferOut: &localBlock
            )
            guard s == noErr, let block = localBlock else { return s }
            let copyStatus = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataLength
            )
            if copyStatus == noErr {
                blockBuffer = block
            }
            return copyStatus
        }

        guard status == noErr, let block = blockBuffer else { return }

        // Create CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataLength
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard let sample = sampleBuffer else { return }

        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._1xRealTimePlayback],
            frameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let dl = displayLink else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            let mgr = Unmanaged<H264StreamManager>.fromOpaque(userInfo!).takeUnretainedValue()
            mgr.publishPendingFrame()
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(dl, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(dl)
        displayLinkActive = true
    }

    private func stopDisplayLink() {
        if let dl = displayLink {
            CVDisplayLinkStop(dl)
        }
        displayLink = nil
        displayLinkActive = false
    }

    private func publishPendingFrame() {
        guard let frame = pendingFrame else { return }
        pendingFrame = nil

        DispatchQueue.main.async { [weak self] in
            self?.currentFrame = frame
            self?.frameCount += 1
        }
    }

    private func startFPSCounter() {
        frameCount = 0
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let sample = Double(self.frameCount) * 2.0
            self.frameCount = 0
            if self.currentFPS == 0 {
                self.currentFPS = sample
            } else {
                self.currentFPS = self.currentFPS * 0.7 + sample * 0.3
            }
        }
    }
}

// MARK: - VTDecompressionSession callback

private func decompressionOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard status == noErr,
          let refCon = decompressionOutputRefCon,
          let pixelBuffer = imageBuffer else { return }

    let mgr = Unmanaged<H264StreamManager>.fromOpaque(refCon).takeUnretainedValue()

    // Convert CVPixelBuffer to CGImage using cached CIContext
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    if let cgImage = mgr.ciContext.createCGImage(ciImage, from: ciImage.extent) {
        mgr.pendingFrame = cgImage
    }
}
