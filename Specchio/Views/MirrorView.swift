import SwiftUI

struct MirrorView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var deviceManager: DeviceManager

    @State private var accessibilityPollTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                displayView(size: geo.size)

                if let client = appState.wdaClient {
                    InputOverlay(
                        phoneScreenSize: appState.phoneScreenSize,
                        viewSize: geo.size,
                        wdaClient: client,
                        inputSocket: appState.inputSocket,
                        keyboardExtSocket: appState.keyboardExtSocket
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            LiveStatusBarView(
                iosScreenCaptureStream: appState.iosScreenCaptureStream,
                h264Stream: appState.h264Stream,
                mjpegStream: appState.mjpegStream,
                screenshotStream: appState.screenshotStream,
                mode: resolvedDisplayMode,
                activeVideoSource: appState.activeVideoSource,
                inputWSConnected: appState.inputWSConnected,
                keyboardExtConnected: appState.keyboardExtConnected
            )
        }
        .onChange(of: resolvedDisplayMode) { newMode in
            if newMode == .accessibility {
                startAccessibilityPolling()
            } else {
                stopAccessibilityPolling()
            }
        }
        .onAppear {
            if resolvedDisplayMode == .accessibility {
                startAccessibilityPolling()
            }
        }
        .onDisappear {
            stopAccessibilityPolling()
            appState.iosScreenCaptureStream?.stopCapture(reason: "MirrorView disappeared", clearFrame: true)
            appState.h264Stream?.stop()
            appState.mjpegStream?.stop()
            appState.screenshotStream?.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveScreenshot)) { _ in
            let cgImage = appState.iosScreenCaptureStream?.currentFrame ?? appState.h264Stream?.currentFrame ?? appState.mjpegStream?.currentFrame ?? appState.screenshotStream?.currentFrame
            let image: NSImage?
            if let cg = cgImage {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            } else {
                image = appState.lastScreenshot
            }
            if let image {
                _ = try? ScreenshotSaver.saveCurrentFrame(image)
            }
        }
    }

    private var resolvedDisplayMode: DisplayMode {
        if appState.displayMode != .auto { return appState.displayMode }
        return .screenshot
    }

    @ViewBuilder
    private func displayView(size: CGSize) -> some View {
        switch resolvedDisplayMode {
        case .screenshot, .auto:
            if let iosScreenCapture = appState.iosScreenCaptureStream,
                      appState.activeVideoSource == .iosScreenCaptureUSB {
                IOSScreenCaptureStreamView(stream: iosScreenCapture)
            } else if let h264 = appState.h264Stream, h264.isStreaming {
                H264StreamView(stream: h264)
            } else if let h264 = appState.h264Stream, h264.currentFrame != nil {
                H264StreamView(stream: h264)
            } else if let mjpeg = appState.mjpegStream, mjpeg.isStreaming {
                MJPEGStreamView(stream: mjpeg)
            } else if let mjpeg = appState.mjpegStream, mjpeg.currentFrame != nil {
                MJPEGStreamView(stream: mjpeg)
            } else if let stream = appState.screenshotStream, stream.isStreaming {
                ScreenshotStreamView(stream: stream)
            } else {
                ProgressView("Loading...")
            }
        case .accessibility:
            if let tree = appState.accessibilityTree {
                let scale = min(
                    size.width / appState.phoneScreenSize.width,
                    size.height / appState.phoneScreenSize.height
                )
                AccessibilityDisplay(
                    rootElement: tree,
                    screenSize: appState.phoneScreenSize,
                    scale: scale
                )
            } else {
                ProgressView("Loading accessibility tree...")
            }
        }
    }

    // MARK: - Accessibility Tree Polling

    private func startAccessibilityPolling() {
        stopAccessibilityPolling()
        accessibilityPollTask = Task {
            let parser = AccessibilityTreeParser()
            while !Task.isCancelled {
                guard let client = appState.wdaClient else { break }
                do {
                    let xml = try await client.accessibilityTree()
                    if let tree = parser.parse(xml: xml) {
                        appState.accessibilityTree = tree
                    }
                } catch {
                    // Transient error — retry on next cycle
                }
                try? await Task.sleep(nanoseconds: 500_000_000) // 2 fps
            }
        }
    }

    private func stopAccessibilityPolling() {
        accessibilityPollTask?.cancel()
        accessibilityPollTask = nil
    }
}

/// Observes the stream directly so FPS counter updates live.
private struct LiveStatusBarView: View {
    var iosScreenCaptureStream: IOSScreenCaptureManager?
    var h264Stream: H264StreamManager?
    var mjpegStream: MJPEGStreamManager?
    var screenshotStream: ScreenshotStreamManager?
    let mode: DisplayMode
    let activeVideoSource: SpecchioVideoSourceKind
    var inputWSConnected: Bool = false
    var keyboardExtConnected: Bool = false

    var body: some View {
        if let iosScreenCapture = iosScreenCaptureStream, activeVideoSource == .iosScreenCaptureUSB {
            ObservedIOSScreenCaptureStatusBar(stream: iosScreenCapture, mode: mode, inputWSConnected: inputWSConnected, keyboardExtConnected: keyboardExtConnected)
        } else if let h264 = h264Stream, h264.isStreaming {
            ObservedH264StatusBar(stream: h264, mode: mode, source: activeVideoSource, inputWSConnected: inputWSConnected, keyboardExtConnected: keyboardExtConnected)
        } else if let mjpeg = mjpegStream {
            ObservedMJPEGStatusBar(stream: mjpeg, mode: mode, source: activeVideoSource, inputWSConnected: inputWSConnected, keyboardExtConnected: keyboardExtConnected)
        } else if let screenshot = screenshotStream {
            ObservedScreenshotStatusBar(stream: screenshot, mode: mode, source: activeVideoSource, inputWSConnected: inputWSConnected, keyboardExtConnected: keyboardExtConnected)
        } else {
            StatusBarView(fps: 0, latency: 0, mode: mode, source: activeVideoSource, inputWSConnected: inputWSConnected, keyboardExtConnected: keyboardExtConnected)
        }
    }
}

private struct ObservedIOSScreenCaptureStatusBar: View {
    @ObservedObject var stream: IOSScreenCaptureManager
    let mode: DisplayMode
    var inputWSConnected: Bool = false
    var keyboardExtConnected: Bool = false

    var body: some View {
        StatusBarView(fps: stream.currentFPS, latency: 0, mode: mode, source: .iosScreenCaptureUSB, inputWSConnected: inputWSConnected, keyboardExtConnected: keyboardExtConnected)
    }
}

private struct ObservedH264StatusBar: View {
    @ObservedObject var stream: H264StreamManager
    let mode: DisplayMode
    let source: SpecchioVideoSourceKind
    var inputWSConnected: Bool = false
    var keyboardExtConnected: Bool = false

    var body: some View {
        StatusBarView(fps: stream.currentFPS, latency: 0, mode: mode, source: source == .none ? .h264 : source, inputWSConnected: inputWSConnected, keyboardExtConnected: keyboardExtConnected)
    }
}

private struct ObservedMJPEGStatusBar: View {
    @ObservedObject var stream: MJPEGStreamManager
    let mode: DisplayMode
    let source: SpecchioVideoSourceKind
    var inputWSConnected: Bool = false
    var keyboardExtConnected: Bool = false

    var body: some View {
        StatusBarView(fps: stream.currentFPS, latency: 0, mode: mode, source: source == .none ? .mjpeg : source, inputWSConnected: inputWSConnected, keyboardExtConnected: keyboardExtConnected)
    }
}

private struct ObservedScreenshotStatusBar: View {
    @ObservedObject var stream: ScreenshotStreamManager
    let mode: DisplayMode
    let source: SpecchioVideoSourceKind
    var inputWSConnected: Bool = false
    var keyboardExtConnected: Bool = false

    var body: some View {
        StatusBarView(fps: stream.currentFPS, latency: stream.latencyMs, mode: mode, source: source == .none ? .screenshot : source, inputWSConnected: inputWSConnected, keyboardExtConnected: keyboardExtConnected)
    }
}

private struct IOSScreenCaptureStreamView: View {
    @ObservedObject var stream: IOSScreenCaptureManager

    var body: some View {
        if let cgImage = stream.currentFrame {
            Image(decorative: cgImage, scale: 1.0)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
        } else {
            ProgressView(stream.statusMessage)
        }
    }
}

/// Observes H.264 stream — uses CGImage + no interpolation for speed.
private struct H264StreamView: View {
    @ObservedObject var stream: H264StreamManager

    var body: some View {
        if let cgImage = stream.currentFrame {
            Image(decorative: cgImage, scale: 1.0)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
        } else {
            ProgressView("Connecting to H.264 stream...")
        }
    }
}

/// Observes MJPEG stream — uses CGImage + no interpolation for speed.
private struct MJPEGStreamView: View {
    @ObservedObject var stream: MJPEGStreamManager

    var body: some View {
        if let cgImage = stream.currentFrame {
            Image(decorative: cgImage, scale: 1.0)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
        } else {
            ProgressView("Connecting to stream...")
        }
    }
}

/// Fallback: observes screenshot polling stream (CGImage, same as MJPEG path).
private struct ScreenshotStreamView: View {
    @ObservedObject var stream: ScreenshotStreamManager

    var body: some View {
        if let cgImage = stream.currentFrame {
            Image(decorative: cgImage, scale: 1.0)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
        } else {
            ProgressView("Loading...")
        }
    }
}
