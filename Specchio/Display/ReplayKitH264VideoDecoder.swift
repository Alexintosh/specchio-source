import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

private let replayKitH264Log = SpecchioLogger.replayKit

enum ReplayKitVideoDecoderCodec: Equatable {
    case h264
    case hevc

    var name: String {
        switch self {
        case .h264:
            return "H.264"
        case .hevc:
            return "HEVC"
        }
    }

    var logToken: String {
        switch self {
        case .h264:
            return "H264"
        case .hevc:
            return "HEVC"
        }
    }

    func nalUnitType(_ nalUnit: Data) -> UInt8? {
        switch self {
        case .h264:
            return ReplayKitAnnexBParser.nalUnitType(nalUnit)
        case .hevc:
            return ReplayKitAnnexBParser.hevcNALUnitType(nalUnit)
        }
    }

    func isParameterSetNALType(_ type: UInt8) -> Bool {
        switch self {
        case .h264:
            return type == 7 || type == 8
        case .hevc:
            return type == 32 || type == 33 || type == 34
        }
    }

    func containsRandomAccessFrame(in annexBData: Data) -> Bool {
        switch self {
        case .h264:
            return ReplayKitAnnexBParser.containsIDR(in: annexBData)
        case .hevc:
            return ReplayKitAnnexBParser.containsHEVCRandomAccessPicture(in: annexBData)
        }
    }
}

final class ReplayKitH264VideoDecoder {
    enum KeyframeRecoveryPolicy {
        case requireKeyframeAfterDecodeFailure
        case allowDeltaFramesAfterDecodedFrame

        var diagnosticDescription: String {
            switch self {
            case .requireKeyframeAfterDecodeFailure:
                return "requireKeyframeAfterDecodeFailure"
            case .allowDeltaFramesAfterDecodedFrame:
                return "allowDeltaFramesAfterDecodedFrame"
            }
        }

        func shouldWaitForKeyframeAfterDecodeFailure(hasDecodedFrame: Bool) -> Bool {
            switch self {
            case .requireKeyframeAfterDecodeFailure:
                return true
            case .allowDeltaFramesAfterDecodedFrame:
                return !hasDecodedFrame
            }
        }

        func shouldKeepSessionOnUnchangedConfigRefresh(
            hasDecodedFrame: Bool,
            sessionActive: Bool
        ) -> Bool {
            switch self {
            case .requireKeyframeAfterDecodeFailure:
                return false
            case .allowDeltaFramesAfterDecodedFrame:
                return hasDecodedFrame && sessionActive
            }
        }
    }

    enum DecodeSubmission {
        case submitted
        case dropped(String)
    }

    enum DecodeResult {
        case decoded(DecodedFrame)
        case failed(String)
    }

    struct DecodedFrame {
        let image: CGImage
        let header: ReplayKitH264AccessUnitHeader
        let bufferSize: CGSize
        let displaySize: CGSize
        let displayCropSource: String
        let decodeMilliseconds: Double
        let receiveToDecodeMilliseconds: Double
        let decodedAt: CFTimeInterval
    }

    fileprivate final class FrameMetadata {
        let header: ReplayKitH264AccessUnitHeader
        let decodeStartedAt: CFTimeInterval
        let receivedAt: CFTimeInterval
        let completion: (DecodeResult) -> Void

        init(
            header: ReplayKitH264AccessUnitHeader,
            decodeStartedAt: CFTimeInterval,
            receivedAt: CFTimeInterval,
            completion: @escaping (DecodeResult) -> Void
        ) {
            self.header = header
            self.decodeStartedAt = decodeStartedAt
            self.receivedAt = receivedAt
            self.completion = completion
        }
    }

    private let callbackQueue: DispatchQueue
    private let keyframeRecoveryPolicy: KeyframeRecoveryPolicy
    private let codec: ReplayKitVideoDecoderCodec
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var vpsData: Data?
    private var spsData: Data?
    private var ppsData: Data?
    private var waitingForKeyframe = true
    private var hasDecodedFrame = false

    private(set) var statusDescription: String

    init(
        callbackQueue: DispatchQueue,
        codec: ReplayKitVideoDecoderCodec = .h264,
        keyframeRecoveryPolicy: KeyframeRecoveryPolicy = .requireKeyframeAfterDecodeFailure
    ) {
        self.callbackQueue = callbackQueue
        self.codec = codec
        self.keyframeRecoveryPolicy = keyframeRecoveryPolicy
        self.statusDescription = "waiting for \(codec.name) config"
    }

    private var logPrefix: String {
        "[Receiver\(codec.logToken)]"
    }

    private var hasRequiredParameterSets: Bool {
        switch codec {
        case .h264:
            return spsData != nil && ppsData != nil
        case .hevc:
            return vpsData != nil && spsData != nil && ppsData != nil
        }
    }

    func reset(reason: String) {
        replayKitH264Log.info("\(self.logPrefix, privacy: .public) reset reason=\(reason, privacy: .public)")
        destroyDecompressionSession(reason: reason)
        formatDescription = nil
        vpsData = nil
        spsData = nil
        ppsData = nil
        waitingForKeyframe = true
        hasDecodedFrame = false
        statusDescription = "waiting for \(codec.name) config"
    }

    func apply(config: ReplayKitH264ConfigPayload) -> Bool {
        guard codec == .h264 else {
            statusDescription = "rejected H.264 config on \(codec.name) decoder"
            replayKitH264Log.warning("\(self.logPrefix, privacy: .public) config rejected sequence=\(config.sequence) reason=wrong decoder codec")
            return false
        }
        replayKitH264Log.info("[ReceiverVideo] packet h264Config sequence=\(config.sequence) width=\(config.width) height=\(config.height) targetFPS=\(config.targetFPS)")
        guard config.isUsableForDecoding,
              let sps = config.spsData,
              let pps = config.ppsData else {
            statusDescription = "invalid \(codec.name) config"
            replayKitH264Log.warning("\(self.logPrefix, privacy: .public) config rejected sequence=\(config.sequence) reason=invalid sps/pps")
            return false
        }

        let parameterSetsChanged = spsData != sps || ppsData != pps
        let sessionActive = decompressionSession != nil
        if !parameterSetsChanged,
           keyframeRecoveryPolicy.shouldKeepSessionOnUnchangedConfigRefresh(
            hasDecodedFrame: hasDecodedFrame,
            sessionActive: sessionActive
           ) {
            statusDescription = "\(codec.name) config refresh kept decoder session"
            replayKitH264Log.info("\(self.logPrefix, privacy: .public) config refresh branch=UNCHANGED_KEEP_SESSION sequence=\(config.sequence) policy=\(self.keyframeRecoveryPolicy.diagnosticDescription, privacy: .public) hasDecodedFrame=\(self.hasDecodedFrame) waitingForKeyframe=\(self.waitingForKeyframe) sessionActive=\(sessionActive)")
            return true
        }

        vpsData = nil
        spsData = sps
        ppsData = pps
        waitingForKeyframe = true
        hasDecodedFrame = false
        replayKitH264Log.info("\(self.logPrefix, privacy: .public) sps/pps accepted source=config branch=REBUILD_SESSION sequence=\(config.sequence) policy=\(self.keyframeRecoveryPolicy.diagnosticDescription, privacy: .public) parameterSetsChanged=\(parameterSetsChanged) previousSessionActive=\(sessionActive) spsBytes=\(sps.count) ppsBytes=\(pps.count)")
        return createFormatDescriptionAndSession(reason: "config sequence \(config.sequence)")
    }

    func apply(config: AirPlayHEVCConfigPayload) -> Bool {
        guard codec == .hevc else {
            statusDescription = "rejected HEVC config on \(codec.name) decoder"
            replayKitH264Log.warning("\(self.logPrefix, privacy: .public) config rejected sequence=\(config.sequence) reason=wrong decoder codec")
            return false
        }
        replayKitH264Log.info("[ReceiverVideo] packet hevcConfig sequence=\(config.sequence) width=\(config.width) height=\(config.height) targetFPS=\(config.targetFPS) nalLengthBytes=\(config.nalLengthByteCount)")
        guard config.isUsableForDecoding else {
            statusDescription = "invalid \(codec.name) config"
            replayKitH264Log.warning("\(self.logPrefix, privacy: .public) config rejected sequence=\(config.sequence) reason=invalid vps/sps/pps")
            return false
        }

        let parameterSetsChanged = vpsData != config.vps || spsData != config.sps || ppsData != config.pps
        let sessionActive = decompressionSession != nil
        if !parameterSetsChanged,
           keyframeRecoveryPolicy.shouldKeepSessionOnUnchangedConfigRefresh(
            hasDecodedFrame: hasDecodedFrame,
            sessionActive: sessionActive
           ) {
            statusDescription = "\(codec.name) config refresh kept decoder session"
            replayKitH264Log.info("\(self.logPrefix, privacy: .public) config refresh branch=UNCHANGED_KEEP_SESSION sequence=\(config.sequence) policy=\(self.keyframeRecoveryPolicy.diagnosticDescription, privacy: .public) hasDecodedFrame=\(self.hasDecodedFrame) waitingForKeyframe=\(self.waitingForKeyframe) sessionActive=\(sessionActive)")
            return true
        }

        vpsData = config.vps
        spsData = config.sps
        ppsData = config.pps
        waitingForKeyframe = true
        hasDecodedFrame = false
        replayKitH264Log.info("\(self.logPrefix, privacy: .public) vps/sps/pps accepted source=config branch=REBUILD_SESSION sequence=\(config.sequence) policy=\(self.keyframeRecoveryPolicy.diagnosticDescription, privacy: .public) parameterSetsChanged=\(parameterSetsChanged) previousSessionActive=\(sessionActive) vpsBytes=\(config.vps.count) spsBytes=\(config.sps.count) ppsBytes=\(config.pps.count)")
        return createFormatDescriptionAndSession(reason: "config sequence \(config.sequence)")
    }

    func decode(
        packet: ReplayKitH264AccessUnitPacket,
        receivedAt: CFTimeInterval,
        completion: @escaping (DecodeResult) -> Void
    ) -> DecodeSubmission {
        let header = packet.header
        replayKitH264Log.info("[ReceiverVideo] packet codec=\(self.codec.name, privacy: .public) accessUnit seq=\(header.sequenceNumber) bytes=\(packet.annexBBytes.count) flags=\(header.flags.rawValue) width=\(header.width) height=\(header.height)")

        let nalUnits = ReplayKitAnnexBParser.extractNALUnits(from: packet.annexBBytes)
        guard !nalUnits.isEmpty else {
            statusDescription = "malformed Annex B access unit"
            replayKitH264Log.warning("\(self.logPrefix, privacy: .public) access unit dropped seq=\(header.sequenceNumber) reason=no Annex B NAL units")
            return .dropped(statusDescription)
        }

        acceptParameterSetsIfPresent(nalUnits: nalUnits, sequenceNumber: header.sequenceNumber)

        if formatDescription == nil || decompressionSession == nil {
            guard hasRequiredParameterSets else {
                statusDescription = "waiting for \(codec.name) config"
                replayKitH264Log.info("\(self.logPrefix, privacy: .public) waitingForKeyframe seq=\(header.sequenceNumber) reason=missing parameter sets")
                return .dropped(statusDescription)
            }

            guard createFormatDescriptionAndSession(reason: "access unit \(header.sequenceNumber)") else {
                replayKitH264Log.warning("\(self.logPrefix, privacy: .public) access unit dropped seq=\(header.sequenceNumber) reason=session create failed")
                return .dropped(statusDescription)
            }
        }

        let containsIDR = header.flags.contains(.keyframe) || codec.containsRandomAccessFrame(in: packet.annexBBytes)
        guard !waitingForKeyframe || containsIDR else {
            statusDescription = "waiting for \(codec.name) keyframe"
            replayKitH264Log.info("\(self.logPrefix, privacy: .public) waitingForKeyframe seq=\(header.sequenceNumber) reason=non-keyframe before decoder recovery policy=\(self.keyframeRecoveryPolicy.diagnosticDescription, privacy: .public) hasDecodedFrame=\(self.hasDecodedFrame)")
            return .dropped(statusDescription)
        }

        if containsIDR {
            replayKitH264Log.info("\(self.logPrefix, privacy: .public) keyframe accepted seq=\(header.sequenceNumber)")
            waitingForKeyframe = false
        }

        guard let avccData = Self.lengthPrefixedSampleData(from: nalUnits, codec: codec) else {
            statusDescription = "malformed \(codec.name) access unit"
            replayKitH264Log.warning("\(self.logPrefix, privacy: .public) access unit dropped seq=\(header.sequenceNumber) reason=empty coded NAL payload")
            return .dropped(statusDescription)
        }

        guard let sampleBuffer = makeSampleBuffer(avccData: avccData, header: header),
              let session = decompressionSession else {
            updateKeyframeWaitAfterDecodeFailure(
                sequenceNumber: header.sequenceNumber,
                failureDescription: "failed to build \(codec.name) sample"
            )
            statusDescription = "failed to build \(codec.name) sample"
            replayKitH264Log.warning("\(self.logPrefix, privacy: .public) decoder failed seq=\(header.sequenceNumber) reason=sample buffer create failed")
            return .dropped(statusDescription)
        }

        let metadata = FrameMetadata(
            header: header,
            decodeStartedAt: CACurrentMediaTime(),
            receivedAt: receivedAt,
            completion: completion
        )
        let metadataRef = Unmanaged.passRetained(metadata).toOpaque()
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._1xRealTimePlayback],
            frameRefcon: metadataRef,
            infoFlagsOut: &infoFlags
        )

        guard status == noErr else {
            _ = Unmanaged<FrameMetadata>.fromOpaque(metadataRef).takeRetainedValue()
            updateKeyframeWaitAfterDecodeFailure(
                sequenceNumber: header.sequenceNumber,
                failureDescription: "decoder failed \(status)"
            )
            statusDescription = "decoder failed \(status)"
            replayKitH264Log.warning("\(self.logPrefix, privacy: .public) decoder failed seq=\(header.sequenceNumber) status=\(status) infoFlags=\(infoFlags.rawValue)")
            return .dropped(statusDescription)
        }

        statusDescription = "decoding \(codec.name)"
        replayKitH264Log.debug("\(self.logPrefix, privacy: .public) decode submitted seq=\(header.sequenceNumber) infoFlags=\(infoFlags.rawValue)")
        return .submitted
    }

    private func acceptParameterSetsIfPresent(nalUnits: [Data], sequenceNumber: UInt64) {
        var acceptedVPS = false
        var acceptedSPS = false
        var acceptedPPS = false

        for nalUnit in nalUnits {
            switch codec.nalUnitType(nalUnit) {
            case 32 where codec == .hevc:
                if vpsData != nalUnit {
                    vpsData = nalUnit
                    acceptedVPS = true
                }
            case 7:
                guard codec == .h264 else { continue }
                if spsData != nalUnit {
                    spsData = nalUnit
                    acceptedSPS = true
                }
            case 33:
                guard codec == .hevc else { continue }
                if spsData != nalUnit {
                    spsData = nalUnit
                    acceptedSPS = true
                }
            case 8:
                guard codec == .h264 else { continue }
                if ppsData != nalUnit {
                    ppsData = nalUnit
                    acceptedPPS = true
                }
            case 34:
                guard codec == .hevc else { continue }
                if ppsData != nalUnit {
                    ppsData = nalUnit
                    acceptedPPS = true
                }
            default:
                continue
            }
        }

        guard acceptedVPS || acceptedSPS || acceptedPPS else { return }
        waitingForKeyframe = true
        hasDecodedFrame = false
        replayKitH264Log.info("\(self.logPrefix, privacy: .public) parameter sets accepted source=accessUnit seq=\(sequenceNumber) vpsChanged=\(acceptedVPS) spsChanged=\(acceptedSPS) ppsChanged=\(acceptedPPS)")
        _ = createFormatDescriptionAndSession(reason: "parameter set update seq \(sequenceNumber)")
    }

    private func updateKeyframeWaitAfterDecodeFailure(
        sequenceNumber: UInt64,
        failureDescription: String
    ) {
        let shouldWait = keyframeRecoveryPolicy.shouldWaitForKeyframeAfterDecodeFailure(
            hasDecodedFrame: hasDecodedFrame
        )
        waitingForKeyframe = shouldWait
        let branch = shouldWait ? "WAIT_FOR_KEYFRAME" : "CONTINUE_DELTA_RECOVERY"
        replayKitH264Log.warning("\(self.logPrefix, privacy: .public) recovery decision seq=\(sequenceNumber) branch=\(branch, privacy: .public) policy=\(self.keyframeRecoveryPolicy.diagnosticDescription, privacy: .public) hasDecodedFrame=\(self.hasDecodedFrame) reason=\(failureDescription, privacy: .public)")
    }

    private func createFormatDescriptionAndSession(reason: String) -> Bool {
        guard hasRequiredParameterSets else {
            statusDescription = "waiting for \(codec.name) config"
            replayKitH264Log.info("\(self.logPrefix, privacy: .public) format create skipped reason=\(reason, privacy: .public) branch=missing parameter sets")
            return false
        }

        destroyDecompressionSession(reason: "format rebuild \(reason)")
        formatDescription = nil

        let status: OSStatus
        switch codec {
        case .h264:
            status = createH264FormatDescription()
        case .hevc:
            status = createHEVCFormatDescription()
        }

        guard status == noErr, let formatDescription else {
            statusDescription = "format description failed \(status)"
            replayKitH264Log.warning("\(self.logPrefix, privacy: .public) decoder failed reason=format description status=\(status)")
            return false
        }

        return createDecompressionSession(formatDescription: formatDescription, reason: reason)
    }

    private func createH264FormatDescription() -> OSStatus {
        guard let sps = spsData, let pps = ppsData else {
            return -1
        }

        let status = sps.withUnsafeBytes { spsRaw -> OSStatus in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                guard let spsBase = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return -1
                }

                var parameterSetPointers = [spsBase, ppsBase]
                var parameterSetSizes = [sps.count, pps.count]
                var description: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSetPointers.count,
                    parameterSetPointers: &parameterSetPointers,
                    parameterSetSizes: &parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )

                guard status == noErr, let description else {
                    return status
                }

                formatDescription = description
                return noErr
            }
        }

        return status
    }

    private func createHEVCFormatDescription() -> OSStatus {
        guard let vps = vpsData, let sps = spsData, let pps = ppsData else {
            return -1
        }

        return vps.withUnsafeBytes { vpsRaw -> OSStatus in
            sps.withUnsafeBytes { spsRaw -> OSStatus in
                pps.withUnsafeBytes { ppsRaw -> OSStatus in
                    guard let vpsBase = vpsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let spsBase = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let ppsBase = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return -1
                    }

                    var parameterSetPointers = [vpsBase, spsBase, ppsBase]
                    var parameterSetSizes = [vps.count, sps.count, pps.count]
                    var description: CMVideoFormatDescription?
                    let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: parameterSetPointers.count,
                        parameterSetPointers: &parameterSetPointers,
                        parameterSetSizes: &parameterSetSizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &description
                    )

                    guard status == noErr, let description else {
                        return status
                    }

                    formatDescription = description
                    return noErr
                }
            }
        }
    }

    private func createDecompressionSession(formatDescription: CMVideoFormatDescription, reason: String) -> Bool {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: replayKitH264DecompressionOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session else {
            statusDescription = "decoder create failed \(status)"
            replayKitH264Log.warning("\(self.logPrefix, privacy: .public) decoder failed reason=session create status=\(status)")
            return false
        }

        decompressionSession = session
        statusDescription = "waiting for \(codec.name) keyframe"
        replayKitH264Log.info("\(self.logPrefix, privacy: .public) decoder created reason=\(reason, privacy: .public)")
        return true
    }

    private func destroyDecompressionSession(reason: String) {
        guard let decompressionSession else {
            replayKitH264Log.debug("\(self.logPrefix, privacy: .public) decoder destroy skipped reason=\(reason, privacy: .public) sessionPresent=false")
            return
        }

        replayKitH264Log.info("\(self.logPrefix, privacy: .public) decoder destroy reason=\(reason, privacy: .public)")
        VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
        VTDecompressionSessionInvalidate(decompressionSession)
        self.decompressionSession = nil
    }

    private func makeSampleBuffer(avccData: Data, header: ReplayKitH264AccessUnitHeader) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let blockStatus = avccData.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            var localBlock: CMBlockBuffer?
            let createStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avccData.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avccData.count,
                flags: 0,
                blockBufferOut: &localBlock
            )
            guard createStatus == noErr, let localBlock else { return createStatus }
            let copyStatus = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: localBlock,
                offsetIntoDestination: 0,
                dataLength: avccData.count
            )
            if copyStatus == noErr {
                blockBuffer = localBlock
            }
            return copyStatus
        }

        guard blockStatus == noErr, let blockBuffer, let formatDescription else {
            replayKitH264Log.warning("\(self.logPrefix, privacy: .public) sample buffer block create failed seq=\(header.sequenceNumber) status=\(blockStatus)")
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(
                value: CMTimeValue(header.presentationTimestampMilliseconds),
                timescale: CMTimeScale(ReplayKitH264Constants.timescale)
            ),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avccData.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer else {
            replayKitH264Log.warning("\(self.logPrefix, privacy: .public) sample buffer create failed seq=\(header.sequenceNumber) status=\(sampleStatus)")
            return nil
        }

        return sampleBuffer
    }

    private static func lengthPrefixedSampleData(from nalUnits: [Data], codec: ReplayKitVideoDecoderCodec) -> Data? {
        var avccData = Data()
        for nalUnit in nalUnits {
            guard !nalUnit.isEmpty else { continue }
            guard let nalType = codec.nalUnitType(nalUnit) else {
                continue
            }
            if codec.isParameterSetNALType(nalType) {
                continue
            }
            guard let nalLength = UInt32(exactly: nalUnit.count) else {
                return nil
            }
            avccData.appendUInt32BE(nalLength)
            avccData.append(nalUnit)
        }

        return avccData.isEmpty ? nil : avccData
    }

    fileprivate func handleDecodedFrame(
        status: OSStatus,
        imageBuffer: CVImageBuffer?,
        metadata: FrameMetadata
    ) {
        guard status == noErr, let imageBuffer else {
            callbackQueue.async { [weak self] in
                self?.updateKeyframeWaitAfterDecodeFailure(
                    sequenceNumber: metadata.header.sequenceNumber,
                    failureDescription: "decoder callback failed \(status)"
                )
                self?.statusDescription = "decoder failed \(status)"
                replayKitH264Log.warning("\(self?.logPrefix ?? "[ReceiverVideo]", privacy: .public) decoder failed seq=\(metadata.header.sequenceNumber) status=\(status)")
                metadata.completion(.failed("decoder failed \(status)"))
            }
            return
        }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let displayGeometry = Self.displayGeometry(
            for: imageBuffer,
            ciExtent: ciImage.extent,
            header: metadata.header
        )
        guard let image = ciContext.createCGImage(ciImage, from: displayGeometry.cropRect) else {
            callbackQueue.async { [weak self] in
                self?.updateKeyframeWaitAfterDecodeFailure(
                    sequenceNumber: metadata.header.sequenceNumber,
                    failureDescription: "CGImage conversion failed"
                )
                self?.statusDescription = "CGImage conversion failed"
                replayKitH264Log.warning("\(self?.logPrefix ?? "[ReceiverVideo]", privacy: .public) decoder failed seq=\(metadata.header.sequenceNumber) reason=CGImage conversion")
                metadata.completion(.failed("CGImage conversion failed"))
            }
            return
        }

        let decodedAt = CACurrentMediaTime()
        let decodeMilliseconds = (decodedAt - metadata.decodeStartedAt) * 1000
        let receiveToDecodeMilliseconds = (decodedAt - metadata.receivedAt) * 1000
        callbackQueue.async { [weak self] in
            self?.hasDecodedFrame = true
            let codecName = self?.codec.name ?? "video"
            self?.statusDescription = "decoded \(codecName) frame"
            replayKitH264Log.info("\(self?.logPrefix ?? "[ReceiverVideo]", privacy: .public) frame decoded seq=\(metadata.header.sequenceNumber) headerWidth=\(metadata.header.width) headerHeight=\(metadata.header.height) bufferWidth=\(displayGeometry.bufferSize.width) bufferHeight=\(displayGeometry.bufferSize.height) cleanX=\(displayGeometry.cleanRect.origin.x) cleanY=\(displayGeometry.cleanRect.origin.y) cleanWidth=\(displayGeometry.cleanRect.width) cleanHeight=\(displayGeometry.cleanRect.height) displayWidth=\(image.width) displayHeight=\(image.height) cropSource=\(displayGeometry.cropSource, privacy: .public) decodeMs=\(String(format: "%.1f", decodeMilliseconds), privacy: .public)")
            metadata.completion(.decoded(DecodedFrame(
                image: image,
                header: metadata.header,
                bufferSize: displayGeometry.bufferSize,
                displaySize: CGSize(width: CGFloat(image.width), height: CGFloat(image.height)),
                displayCropSource: displayGeometry.cropSource,
                decodeMilliseconds: decodeMilliseconds,
                receiveToDecodeMilliseconds: receiveToDecodeMilliseconds,
                decodedAt: decodedAt
            )))
        }
    }

    private static func displayGeometry(
        for imageBuffer: CVImageBuffer,
        ciExtent: CGRect,
        header: ReplayKitH264AccessUnitHeader
    ) -> (cropRect: CGRect, cleanRect: CGRect, bufferSize: CGSize, cropSource: String) {
        let bufferSize = CGSize(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        )
        let fallbackRect = ciExtent.integral
        let cleanRect = CVImageBufferGetCleanRect(imageBuffer)
        if isValidCropRect(cleanRect, inside: ciExtent),
           !sameDisplaySize(cleanRect.size, ciExtent.size) {
            return (cleanRect.integral, cleanRect, bufferSize, "clean-aperture")
        }

        let headerSize = CGSize(width: CGFloat(header.width), height: CGFloat(header.height))
        if headerSize.width > 0,
           headerSize.height > 0,
           headerSize.width <= ciExtent.width + 0.5,
           headerSize.height <= ciExtent.height + 0.5,
           !sameDisplaySize(headerSize, ciExtent.size) {
            let headerRect = CGRect(
                x: ciExtent.minX,
                y: ciExtent.minY,
                width: headerSize.width,
                height: headerSize.height
            )
            return (headerRect.integral, cleanRect, bufferSize, "protocol-header")
        }

        return (fallbackRect, cleanRect, bufferSize, "full-extent")
    }

    private static func isValidCropRect(_ rect: CGRect, inside extent: CGRect) -> Bool {
        guard rect.width.isFinite,
              rect.height.isFinite,
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width > 0,
              rect.height > 0 else {
            return false
        }

        return extent.insetBy(dx: -0.5, dy: -0.5).contains(rect)
    }

    private static func sameDisplaySize(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= 0.5 && abs(lhs.height - rhs.height) <= 0.5
    }
}

private func replayKitH264DecompressionOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard let decompressionOutputRefCon else {
        if let sourceFrameRefCon {
            _ = Unmanaged<ReplayKitH264VideoDecoder.FrameMetadata>.fromOpaque(sourceFrameRefCon).takeRetainedValue()
        }
        return
    }

    guard let sourceFrameRefCon else {
        return
    }

    let decoder = Unmanaged<ReplayKitH264VideoDecoder>.fromOpaque(decompressionOutputRefCon).takeUnretainedValue()
    let metadata = Unmanaged<ReplayKitH264VideoDecoder.FrameMetadata>.fromOpaque(sourceFrameRefCon).takeRetainedValue()
    decoder.handleDecodedFrame(
        status: status,
        imageBuffer: imageBuffer,
        metadata: metadata
    )
}
