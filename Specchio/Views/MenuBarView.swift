import SwiftUI
import os.log

private let log = SpecchioLogger.menuBar

struct MenuBarPopoverView: View {
    @ObservedObject var appState: AppState

    @State private var thumbnailImage: CGImage?
    @State private var isVisible = false
    @State private var lastThumbnailSourceID: String?
    @AppStorage("menuBarThumbnailWidth") private var thumbnailWidth: Int = 480

    private let thumbnailTimer = Timer.publish(every: 1.0 / 8.0, on: .main, in: .common).autoconnect()

    private var thumbWidth: CGFloat { CGFloat(thumbnailWidth) }

    var body: some View {
        VStack(spacing: 0) {
            if hasActivePreviewSession {
                connectedView
            } else {
                disconnectedView
                    .padding()
            }

            Divider()

            HStack(spacing: 6) {
                if hasActivePreviewSession {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)

                    Text(connectionLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(fpsLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Spacer()
                }

                Button("Show Specchio") {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if let window = NSApplication.shared.windows.first(where: {
                        $0.contentView?.ancestorOrSelf(ofType: NSHostingView<MainWindow>.self) != nil
                            || $0.title.contains("Specchio")
                            || (!$0.title.isEmpty && $0.level == .normal)
                    }) {
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        NSApplication.shared.windows
                            .first { $0.level == .normal && !$0.title.isEmpty }?
                            .makeKeyAndOrderFront(nil)
                    }
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: thumbWidth)
        .onAppear {
            isVisible = true
            log.info("MenuBar: popover appeared")
        }
        .onDisappear {
            isVisible = false
            thumbnailImage = nil
            log.info("MenuBar: popover disappeared")
        }
        .onReceive(thumbnailTimer) { _ in
            guard isVisible else { return }
            updateThumbnail()
        }
    }

    // MARK: - Connected

    private var connectedView: some View {
        Group {
            if let cgImage = thumbnailImage {
                Image(decorative: cgImage, scale: 1.0)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbWidth)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: thumbWidth, height: thumbWidth * phoneAspectRatio)
                    .overlay {
                        ProgressView()
                    }
            }
        }
    }

    private var phoneAspectRatio: CGFloat {
        guard appState.phoneScreenSize.width > 0 else { return 844.0 / 390.0 }
        return appState.phoneScreenSize.height / appState.phoneScreenSize.width
    }

    private var hasActivePreviewSession: Bool {
        if let iosScreenCapture = appState.iosScreenCaptureStream,
           iosScreenCapture.currentFrame != nil || iosScreenCapture.isCapturing {
            return true
        }

        if appState.connectionState.isConnected {
            return true
        }

        if let airPlay = appState.airPlayStream {
            return airPlay.currentFrame != nil || airPlay.isClientConnected || airPlay.isAdvertising
        }

        guard let replayKit = appState.replayKitStream else {
            return false
        }

        return replayKit.currentFrame != nil || replayKit.isClientConnected || replayKit.isListening
    }

    private var connectionLabel: String {
        if let source = currentPreviewSource {
            return source.label
        }

        if let iosScreenCapture = appState.iosScreenCaptureStream,
           iosScreenCapture.isCapturing {
            return "USB Native"
        }

        if let replayKit = appState.replayKitStream,
           replayKit.isListening || replayKit.isClientConnected {
            return "Easy"
        }

        if let airPlay = appState.airPlayStream,
           airPlay.isAdvertising || airPlay.isClientConnected {
            return "AirPlay"
        }

        switch appState.connectionState {
        case .usb: return "USB"
        case .wifi: return "WiFi"
        default: return "Connected"
        }
    }

    private var fpsLabel: String {
        if let iosScreenCapture = appState.iosScreenCaptureStream,
           iosScreenCapture.currentFrame != nil || iosScreenCapture.isCapturing {
            return "\(Int(iosScreenCapture.currentFPS)) fps"
        } else if let replayKit = appState.replayKitStream,
           replayKit.currentFrame != nil || replayKit.isClientConnected || replayKit.isListening {
            return "\(Int(replayKit.currentFPS)) fps"
        } else if let airPlay = appState.airPlayStream,
                  airPlay.currentFrame != nil || airPlay.isClientConnected || airPlay.isAdvertising {
            return "\(Int(airPlay.currentFPS)) fps"
        } else if let h264 = appState.h264Stream, h264.isStreaming {
            return "\(Int(h264.currentFPS)) fps"
        } else if let mjpeg = appState.mjpegStream, mjpeg.isStreaming {
            return "\(Int(mjpeg.currentFPS)) fps"
        } else if let ss = appState.screenshotStream, ss.isStreaming {
            return "\(Int(ss.currentFPS)) fps"
        }
        return ""
    }

    // MARK: - Disconnected

    private var disconnectedView: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Not Connected")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 100)
    }

    // MARK: - Thumbnail

    private func updateThumbnail() {
        guard let source = currentPreviewSource else {
            if lastThumbnailSourceID != nil {
                log.info("MenuBar: thumbnail source cleared")
                lastThumbnailSourceID = nil
            } else {
                log.debug("MenuBar: thumbnail skipped because no preview frame source is available")
            }
            return
        }

        if lastThumbnailSourceID != source.id {
            log.info("MenuBar: thumbnail source selected source=\(source.id, privacy: .public) label=\(source.label, privacy: .public) width=\(source.frame.width) height=\(source.frame.height)")
            lastThumbnailSourceID = source.id
        }

        thumbnailImage = downsample(source.frame, toWidth: thumbWidth * 2) // @2x
        log.debug("MenuBar: thumbnail updated source=\(source.id, privacy: .public)")
    }

    private var currentPreviewSource: MenuBarPreviewSource? {
        if appState.activeVideoSource == .iosScreenCaptureUSB,
           let frame = appState.iosScreenCaptureStream?.currentFrame {
            return MenuBarPreviewSource(id: "ios-screen-capture-usb", label: "USB Native", frame: frame)
        }

        if appState.activeVideoSource == .airPlay,
           let frame = appState.airPlayStream?.currentFrame {
            return MenuBarPreviewSource(id: "easy-airplay", label: "AirPlay", frame: frame)
        }

        if let frame = appState.replayKitStream?.currentFrame {
            return MenuBarPreviewSource(id: "easy-replaykit", label: "Easy", frame: frame)
        }

        if let frame = appState.h264Stream?.currentFrame {
            return MenuBarPreviewSource(id: "dev-h264", label: "USB/WiFi", frame: frame)
        }

        if let frame = appState.mjpegStream?.currentFrame {
            return MenuBarPreviewSource(id: "dev-mjpeg", label: "USB/WiFi", frame: frame)
        }

        if let frame = appState.screenshotStream?.currentFrame {
            return MenuBarPreviewSource(id: "dev-screenshot", label: connectionLabelForDevState, frame: frame)
        }

        return nil
    }

    private var connectionLabelForDevState: String {
        switch appState.connectionState {
        case .usb: return "USB"
        case .wifi: return "WiFi"
        default: return "Connected"
        }
    }

    private func downsample(_ source: CGImage, toWidth targetWidth: CGFloat) -> CGImage? {
        let scale = targetWidth / CGFloat(source.width)
        guard scale < 1.0 else { return source }

        let targetW = Int(targetWidth)
        let targetH = Int(CGFloat(source.height) * scale)

        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return source }

        ctx.interpolationQuality = .medium
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        return ctx.makeImage() ?? source
    }
}

private struct MenuBarPreviewSource {
    let id: String
    let label: String
    let frame: CGImage
}

// MARK: - NSView helper

private extension NSView {
    func ancestorOrSelf<T: NSView>(ofType type: T.Type) -> T? {
        if let typed = self as? T { return typed }
        return superview?.ancestorOrSelf(ofType: type)
    }
}
