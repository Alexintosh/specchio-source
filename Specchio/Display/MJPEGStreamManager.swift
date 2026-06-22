import AppKit
import CoreGraphics
import Foundation
import ImageIO

class MJPEGStreamManager: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var currentFrame: CGImage?
    @Published var isStreaming = false
    @Published var currentFPS: Double = 0

    /// Called when the stream ends unexpectedly (USB unplug, network error, etc.)
    var onStreamFailed: ((Error?) -> Void)?

    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var buffer = Data()
    private var frameCount = 0
    private var fpsTimer: Timer?
    private let streamURL: URL

    // Frame dropping: only publish the latest frame
    private let processingQueue = DispatchQueue(label: "mjpeg.processing", qos: .userInteractive)
    private var pendingFrame: CGImage?
    private var displayLinkActive = false

    init(url: URL) {
        self.streamURL = url
        super.init()
    }

    func start() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = .infinity
        // Larger buffer for high-throughput streaming
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        let delegateQueue = OperationQueue()
        delegateQueue.name = "mjpeg.network"
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInteractive

        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        dataTask = session?.dataTask(with: streamURL)
        dataTask?.resume()

        DispatchQueue.main.async { [weak self] in
            self?.isStreaming = true
            self?.startFPSCounter()
            self?.startDisplayLink()
        }
    }

    func stop() {
        dataTask?.cancel()
        dataTask = nil
        session?.invalidateAndCancel()
        session = nil
        fpsTimer?.invalidate()
        stopDisplayLink()
        isStreaming = false
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        extractFrames()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.isStreaming = false
            self?.onStreamFailed?(error)
        }
    }

    // MARK: - MJPEG Frame Extraction

    private let jpegStart = Data([0xFF, 0xD8])
    private let jpegEnd = Data([0xFF, 0xD9])

    private func extractFrames() {
        // Extract all complete frames, keep only the latest
        var latestFrame: CGImage?

        while let startRange = buffer.range(of: jpegStart),
              let endRange = buffer.range(of: jpegEnd, in: startRange.lowerBound..<buffer.endIndex) {
            let frameData = buffer.subdata(in: startRange.lowerBound..<endRange.upperBound)
            buffer.removeSubrange(buffer.startIndex..<endRange.upperBound)

            // Fast JPEG decode via ImageIO (much faster than NSImage)
            if let image = decodeJPEG(frameData) {
                latestFrame = image
            }
        }

        // Only publish the most recent frame (drop intermediates)
        if let frame = latestFrame {
            pendingFrame = frame
        }

        // Prevent unbounded buffer growth
        if buffer.count > 2_000_000 {
            // Keep only from the last JPEG start marker
            if let lastStart = buffer.range(of: jpegStart) {
                buffer.removeSubrange(buffer.startIndex..<lastStart.lowerBound)
            } else {
                buffer.removeAll()
            }
        }
    }

    private func decodeJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldAllowFloat: false
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Display Link (vsync-driven frame publishing)

    private var displayLink: CVDisplayLink?

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let dl = displayLink else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            let mgr = Unmanaged<MJPEGStreamManager>.fromOpaque(userInfo!).takeUnretainedValue()
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
        // Use 0.5s sample with exponential moving average for smoother display
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let sample = Double(self.frameCount) * 2.0 // scale 0.5s sample to per-second
            self.frameCount = 0
            // Smooth: 70% old value, 30% new sample
            if self.currentFPS == 0 {
                self.currentFPS = sample
            } else {
                self.currentFPS = self.currentFPS * 0.7 + sample * 0.3
            }
        }
    }
}
