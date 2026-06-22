import Foundation
import CoreGraphics
import ImageIO
import Combine

class ScreenshotStreamManager: ObservableObject {
    @Published var currentFrame: CGImage?
    @Published var isStreaming = false
    @Published var currentFPS: Double = 0
    @Published var latencyMs: Double = 0

    private let screenshotURL: URL
    private let session: URLSession
    private var pendingFrame: CGImage?
    private var fetchTask: Task<Void, Never>?
    private var publishTimer: Timer?
    private var fpsTimer: Timer?
    private var targetFPS: Double = 10
    private var frameCount = 0

    init(baseURL: URL) {
        self.screenshotURL = baseURL.appendingPathComponent("/screenshot")
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    func start(fps: Double = 10) {
        targetFPS = max(1, min(30, fps))
        isStreaming = true
        startFPSCounter()
        startPublishTimer()

        fetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let interval = 1.0 / self.targetFPS

            while !Task.isCancelled {
                let start = CFAbsoluteTimeGetCurrent()
                do {
                    let imageData = try await self.fetchScreenshot()
                    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

                    if let cgImage = Self.decodeJPEG(imageData) {
                        self.pendingFrame = cgImage
                        await MainActor.run {
                            self.latencyMs = elapsed
                        }
                    }
                } catch {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    continue
                }

                let elapsed = CFAbsoluteTimeGetCurrent() - start
                let sleepTime = max(0, interval - elapsed)
                if sleepTime > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
                }
            }
        }
    }

    func stop() {
        isStreaming = false
        fetchTask?.cancel()
        fetchTask = nil
        publishTimer?.invalidate()
        publishTimer = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        session.invalidateAndCancel()
    }

    func setFPS(_ fps: Double) {
        targetFPS = max(1, min(30, fps))
    }

    // MARK: - Fetch (bypasses WDAClient actor)

    private func fetchScreenshot() async throws -> Data {
        let (data, response) = try await session.data(from: screenshotURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ScreenshotError.httpError(http.statusCode)
        }
        // WDA returns {"value": "<base64 string>", ...}
        let json = try JSONDecoder().decode(WDAScreenshotResponse.self, from: data)
        guard let imageData = Data(base64Encoded: json.value) else {
            throw ScreenshotError.invalidData
        }
        return imageData
    }

    // MARK: - Fast JPEG Decode (same as MJPEGStreamManager)

    private static func decodeJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldAllowFloat: false,
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Publish Timer (decoupled from fetch)

    private func startPublishTimer() {
        publishTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.publishPendingFrame()
        }
    }

    private func publishPendingFrame() {
        guard let frame = pendingFrame else { return }
        pendingFrame = nil
        currentFrame = frame
        frameCount += 1
    }

    // MARK: - FPS Counter

    private func startFPSCounter() {
        frameCount = 0
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.currentFPS = Double(self.frameCount)
            self.frameCount = 0
        }
    }
}

private enum ScreenshotError: Error {
    case httpError(Int)
    case invalidData
}
