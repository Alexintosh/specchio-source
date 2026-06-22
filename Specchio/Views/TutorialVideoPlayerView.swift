import SwiftUI
import AppKit
import AVKit

struct TutorialVideoAsset: Equatable {
    let resourceName: String
    let fileExtension: String
    let resourceSubdirectory: String?
    let title: String
    let accessibilityLabel: String
    let preferredDisplayHeight: CGFloat
    let aspectRatio: CGFloat?

    init(
        resourceName: String,
        fileExtension: String,
        resourceSubdirectory: String? = nil,
        title: String,
        accessibilityLabel: String,
        preferredDisplayHeight: CGFloat = 360,
        aspectRatio: CGFloat? = nil
    ) {
        self.resourceName = resourceName
        self.fileExtension = fileExtension
        self.resourceSubdirectory = resourceSubdirectory
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.preferredDisplayHeight = preferredDisplayHeight
        self.aspectRatio = aspectRatio
    }

    var diagnosticName: String {
        "\(resourceName).\(fileExtension)"
    }

    func bundleURL() -> URL? {
        if let resourceSubdirectory,
           let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: fileExtension,
            subdirectory: resourceSubdirectory
           ) {
            SpecchioLogger.easyMode.debug("[TutorialVideoAsset] resolved branch=subdirectory asset=\(diagnosticName, privacy: .public) subdirectory=\(resourceSubdirectory, privacy: .public)")
            return url
        }

        let url = Bundle.main.url(forResource: resourceName, withExtension: fileExtension)
        SpecchioLogger.easyMode.debug("[TutorialVideoAsset] resolved branch=main-bundle asset=\(diagnosticName, privacy: .public) found=\(url != nil)")
        return url
    }
}

struct TutorialVideoPlayerView: View {
    let asset: TutorialVideoAsset
    let displayHeight: CGFloat
    let source: String
    var showsLargePreviewButton = true

    @StateObject private var largePreview = TutorialVideoLargePreviewController()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TutorialVideoContentView(asset: asset)

            if showsLargePreviewButton, asset.bundleURL() != nil {
                Button {
                    SpecchioLogger.easyMode.info("[TutorialVideoPlayer] large preview tapped source=\(source, privacy: .public) asset=\(asset.diagnosticName, privacy: .public)")
                    largePreview.show(asset: asset, source: source)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Open large preview")
                .accessibilityLabel("Open large preview for \(asset.title)")
                .padding(8)
            }
        }
        .frame(height: displayHeight)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .onAppear {
            SpecchioLogger.easyMode.info("[TutorialVideoPlayer] appeared source=\(source, privacy: .public) asset=\(asset.diagnosticName, privacy: .public) height=\(displayHeight) hasLargePreview=\(showsLargePreviewButton)")
        }
    }
}

struct TutorialVideoContentView: View {
    let asset: TutorialVideoAsset
    var controlsStyle: AVPlayerViewControlsStyle = .none
    var showsFullScreenToggleButton = false

    var body: some View {
        Group {
            if let url = asset.bundleURL() {
                TutorialLoopingVideoPlayer(
                    url: url,
                    controlsStyle: controlsStyle,
                    showsFullScreenToggleButton: showsFullScreenToggleButton,
                    diagnosticName: asset.diagnosticName
                )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.title2)
                    Text("Tutorial video missing")
                        .font(.caption.weight(.semibold))
                    Text(asset.diagnosticName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.9))
            }
        }
        .accessibilityLabel(asset.accessibilityLabel)
        .onAppear {
            SpecchioLogger.easyMode.info("[TutorialVideoContent] displayed asset=\(asset.diagnosticName, privacy: .public) controls=\(String(describing: controlsStyle), privacy: .public) fullScreenToggle=\(showsFullScreenToggleButton)")
        }
    }
}

private struct TutorialLoopingVideoPlayer: NSViewRepresentable {
    let url: URL
    let controlsStyle: AVPlayerViewControlsStyle
    let showsFullScreenToggleButton: Bool
    let diagnosticName: String

    func makeCoordinator() -> Coordinator {
        Coordinator(diagnosticName: diagnosticName)
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = controlsStyle
        playerView.showsFullScreenToggleButton = showsFullScreenToggleButton
        playerView.videoGravity = .resizeAspect
        context.coordinator.configure(url: url, playerView: playerView, reason: "makeNSView")
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.controlsStyle = controlsStyle
        nsView.showsFullScreenToggleButton = showsFullScreenToggleButton
        nsView.videoGravity = .resizeAspect
        context.coordinator.configure(url: url, playerView: nsView, reason: "updateNSView")
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.stop(reason: "dismantleNSView")
        nsView.player = nil
    }

    final class Coordinator {
        private let diagnosticName: String
        private var player: AVPlayer?
        private var currentURL: URL?
        private var endObserver: NSObjectProtocol?

        init(diagnosticName: String) {
            self.diagnosticName = diagnosticName
        }

        deinit {
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
        }

        func configure(url: URL, playerView: AVPlayerView, reason: String) {
            guard currentURL != url else {
                SpecchioLogger.easyMode.debug("[TutorialVideoPlayer] configure skipped reason=\(reason, privacy: .public) branch=same-url asset=\(self.diagnosticName, privacy: .public)")
                return
            }

            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }

            let player = AVPlayer(url: url)
            player.actionAtItemEnd = .none
            player.isMuted = true
            player.volume = 0
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak player] _ in
                SpecchioLogger.easyMode.info("[TutorialVideoPlayer] loop restart asset=\(self.diagnosticName, privacy: .public)")
                player?.seek(to: .zero)
                player?.play()
            }

            self.player = player
            currentURL = url
            playerView.player = player
            player.play()
            SpecchioLogger.easyMode.info("[TutorialVideoPlayer] configured reason=\(reason, privacy: .public) asset=\(self.diagnosticName, privacy: .public) muted=\(player.isMuted) volume=\(player.volume)")
        }

        func stop(reason: String) {
            guard let player else {
                SpecchioLogger.easyMode.debug("[TutorialVideoPlayer] stop skipped reason=\(reason, privacy: .public) branch=no-player asset=\(self.diagnosticName, privacy: .public)")
                return
            }

            player.pause()
            SpecchioLogger.easyMode.info("[TutorialVideoPlayer] stopped reason=\(reason, privacy: .public) asset=\(self.diagnosticName, privacy: .public)")
        }
    }
}

final class TutorialVideoLargePreviewController: NSObject, ObservableObject, NSWindowDelegate {
    private var panel: NSPanel?

    func show(asset: TutorialVideoAsset, source: String) {
        guard asset.bundleURL() != nil else {
            SpecchioLogger.easyMode.error("[TutorialVideoLargePreview] show skipped source=\(source, privacy: .public) reason=missing-resource asset=\(asset.diagnosticName, privacy: .public)")
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        let screenFrame = NSApp.keyWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let contentSize = resolvedContentSize(for: asset, screenFrame: screenFrame)
        panel.title = asset.title
        panel.setContentSize(contentSize)
        panel.contentView = NSHostingView(rootView: TutorialVideoLargePreviewView(asset: asset))
        position(panel, in: screenFrame)
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        SpecchioLogger.easyMode.info("[TutorialVideoLargePreview] shown source=\(source, privacy: .public) title=\(asset.title, privacy: .public) asset=\(asset.diagnosticName, privacy: .public) width=\(contentSize.width) height=\(contentSize.height) aspectRatio=\(asset.aspectRatio ?? 0)")
    }

    func windowWillClose(_ notification: Notification) {
        SpecchioLogger.easyMode.info("[TutorialVideoLargePreview] closed")
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: TutorialVideoLargePreviewMetrics.fallbackSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        return panel
    }

    private func resolvedContentSize(for asset: TutorialVideoAsset, screenFrame: CGRect) -> CGSize {
        guard !screenFrame.isEmpty else {
            SpecchioLogger.easyMode.info("[TutorialVideoLargePreview] size resolved branch=no-screen asset=\(asset.diagnosticName, privacy: .public)")
            return TutorialVideoLargePreviewMetrics.fallbackSize
        }

        let maximumSize = CGSize(
            width: screenFrame.width * TutorialVideoLargePreviewMetrics.screenCoverage,
            height: screenFrame.height * TutorialVideoLargePreviewMetrics.screenCoverage
        )

        guard let aspectRatio = asset.aspectRatio, aspectRatio > 0 else {
            SpecchioLogger.easyMode.info("[TutorialVideoLargePreview] size resolved branch=no-aspect asset=\(asset.diagnosticName, privacy: .public) width=\(maximumSize.width) height=\(maximumSize.height)")
            return maximumSize
        }

        let size: CGSize
        if aspectRatio < 1 {
            let height = maximumSize.height
            let naturalWidth = height * aspectRatio
            size = CGSize(
                width: clamp(naturalWidth, lower: TutorialVideoLargePreviewMetrics.minimumWidth, upper: maximumSize.width),
                height: height
            )
        } else {
            let widthFromMaximumHeight = maximumSize.height * aspectRatio
            let width = min(maximumSize.width, widthFromMaximumHeight)
            let naturalHeight = width / aspectRatio
            size = CGSize(
                width: width,
                height: clamp(naturalHeight, lower: TutorialVideoLargePreviewMetrics.minimumHeight, upper: maximumSize.height)
            )
        }

        SpecchioLogger.easyMode.info("[TutorialVideoLargePreview] size resolved branch=aspect asset=\(asset.diagnosticName, privacy: .public) aspectRatio=\(aspectRatio) width=\(size.width) height=\(size.height) maxWidth=\(maximumSize.width) maxHeight=\(maximumSize.height)")
        return size
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, min(lower, upper)), upper)
    }

    private func position(_ panel: NSPanel, in screenFrame: CGRect) {
        guard !screenFrame.isEmpty else {
            panel.center()
            return
        }

        let frameSize = panel.frame.size
        panel.setFrameOrigin(CGPoint(
            x: screenFrame.midX - frameSize.width / 2,
            y: screenFrame.midY - frameSize.height / 2
        ))
    }
}

private enum TutorialVideoLargePreviewMetrics {
    static let screenCoverage: CGFloat = 0.82
    static let minimumWidth: CGFloat = 420
    static let minimumHeight: CGFloat = 320
    static let fallbackSize = CGSize(width: 720, height: 620)
}

private struct TutorialVideoLargePreviewView: View {
    let asset: TutorialVideoAsset

    var body: some View {
        ZStack {
            Color.black
            TutorialVideoContentView(
                asset: asset,
                controlsStyle: .floating,
                showsFullScreenToggleButton: true
            )
        }
        .accessibilityLabel("Large tutorial video preview for \(asset.title)")
        .onAppear {
            SpecchioLogger.easyMode.info("[TutorialVideoLargePreview] content appeared title=\(asset.title, privacy: .public) asset=\(asset.diagnosticName, privacy: .public)")
        }
    }
}
