import SwiftUI
import AVKit
import AppKit

struct SpecchioVideoLink: Identifiable, Equatable {
    let id: String
    let title: String
    let remoteURL: URL?

    static func cdn(id: String, title: String, url: URL) -> SpecchioVideoLink {
        SpecchioVideoLink(id: id, title: title, remoteURL: url)
    }

    static func placeholder(id: String, title: String) -> SpecchioVideoLink {
        SpecchioVideoLink(id: id, title: title, remoteURL: nil)
    }
}

enum SpecchioVideoLinks {
    static let bluetoothConnectionExample = SpecchioVideoLink.cdn(
        id: "bluetooth-connection-example",
        title: "Bluetooth connection guide",
        url: URL(string: "https://pub-97ba386621da499e92282258f46d7e74.r2.dev/tutorial.mp4")!
    )

    static let iphoneSetupPlaceholder = SpecchioVideoLink.placeholder(
        id: "iphone-setup-placeholder",
        title: "iPhone setup guide placeholder"
    )
}

struct SpecchioVideoTutorialButton: View {
    let link: SpecchioVideoLink

    @StateObject private var floatingPlayer = SpecchioFloatingVideoPlayerController()

    var body: some View {
        SWPlasmaActionButton(
            title: "Video tutorial",
            systemImage: "play.rectangle",
            foregroundColor: .white,
            style: .prism,
            scale: 1.25,
            intensity: 1.1,
            distortion: 1.0,
            accessibilityLabel: "Video tutorial",
            debugName: "video-tutorial-button"
        ) {
            SpecchioLogger.video.info("[VideoTutorialButton] tapped branch=open-floating-window linkID=\(link.id, privacy: .public)")
            floatingPlayer.show(link: link)
        }
        .onAppear {
            SpecchioLogger.video.info("[VideoTutorialButton] appeared linkID=\(link.id, privacy: .public) hasRemoteURL=\(link.remoteURL != nil)")
        }
    }
}

final class SpecchioFloatingVideoPlayerController: NSObject, ObservableObject, NSWindowDelegate {
    private var window: NSPanel?
    private var currentLink: SpecchioVideoLink?

    func show(link: SpecchioVideoLink) {
        SpecchioLogger.video.info("[FloatingVideoPlayer] show requested linkID=\(link.id, privacy: .public) hasExistingWindow=\(self.window != nil) hasRemoteURL=\(link.remoteURL != nil)")

        if let window {
            if currentLink == link {
                SpecchioLogger.video.info("[FloatingVideoPlayer] branch=reuse-existing-window linkID=\(link.id, privacy: .public)")
            } else {
                SpecchioLogger.video.info("[FloatingVideoPlayer] branch=replace-content existingLinkID=\(self.currentLink?.id ?? "none", privacy: .public) nextLinkID=\(link.id, privacy: .public)")
                window.contentView = makeHostingView(for: link)
                currentLink = link
            }

            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        SpecchioLogger.video.info("[FloatingVideoPlayer] branch=create-floating-panel linkID=\(link.id, privacy: .public) width=\(SpecchioInternalVideoMetrics.floatingPlayerWidth) height=\(SpecchioInternalVideoMetrics.floatingPlayerHeight)")
        let panel = NSPanel(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(
                    width: SpecchioInternalVideoMetrics.floatingPlayerWidth,
                    height: SpecchioInternalVideoMetrics.floatingPlayerHeight
                )
            ),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = link.title
        panel.contentView = makeHostingView(for: link)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        window = panel
        currentLink = link
        SpecchioLogger.video.info("[FloatingVideoPlayer] floating panel shown linkID=\(link.id, privacy: .public) title=\(link.title, privacy: .public)")
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else {
            SpecchioLogger.video.info("[FloatingVideoPlayer] windowWillClose branch=untracked-window")
            return
        }

        SpecchioLogger.video.info("[FloatingVideoPlayer] windowWillClose branch=release-window linkID=\(self.currentLink?.id ?? "none", privacy: .public)")
        window = nil
        currentLink = nil
    }

    private func makeHostingView(for link: SpecchioVideoLink) -> NSHostingView<SpecchioInternalVideoPlayerView> {
        SpecchioLogger.video.info("[FloatingVideoPlayer] makeHostingView linkID=\(link.id, privacy: .public)")
        let view = SpecchioInternalVideoPlayerView(link: link)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: SpecchioInternalVideoMetrics.floatingPlayerWidth,
                height: SpecchioInternalVideoMetrics.floatingPlayerHeight
            )
        )
        return hostingView
    }
}

struct SpecchioInternalVideoPlayerView: View {
    let link: SpecchioVideoLink

    @State private var player: AVPlayer?
    @State private var loadedURL: URL?
    @State private var status: SpecchioInternalVideoStatus

    init(link: SpecchioVideoLink) {
        self.link = link
        _status = State(initialValue: link.remoteURL == nil ? .placeholder : .loading)
    }

    var body: some View {
        NativeAVPlayerView(player: player, linkID: link.id)
            .aspectRatio(SpecchioInternalVideoMetrics.defaultAspectRatio, contentMode: .fit)
            .accessibilityLabel(accessibilityLabel)
            .onAppear {
                SpecchioLogger.video.info("[InternalVideoPlayer] appeared linkID=\(link.id, privacy: .public) title=\(link.title, privacy: .public)")
                configurePlayer(reason: "appear")
            }
            .onChange(of: link) { _, _ in
                SpecchioLogger.video.info("[InternalVideoPlayer] link changed linkID=\(link.id, privacy: .public)")
                configurePlayer(reason: "link-change")
            }
            .onDisappear {
                if let player {
                    SpecchioLogger.video.info("[InternalVideoPlayer] disappear branch=pause linkID=\(link.id, privacy: .public)")
                    player.pause()
                } else {
                    SpecchioLogger.video.info("[InternalVideoPlayer] disappear branch=no-player linkID=\(link.id, privacy: .public)")
                }
            }
    }

    private var accessibilityLabel: String {
        "\(link.title): \(status.accessibilityLabel)"
    }

    private func configurePlayer(reason: String) {
        SpecchioLogger.video.info("[InternalVideoPlayer] configure start reason=\(reason, privacy: .public) linkID=\(link.id, privacy: .public) hasRemoteURL=\(link.remoteURL != nil)")

        guard let remoteURL = link.remoteURL else {
            SpecchioLogger.video.info("[InternalVideoPlayer] configure branch=placeholder reason=\(reason, privacy: .public) linkID=\(link.id, privacy: .public)")
            player?.pause()
            player = nil
            loadedURL = nil
            status = .placeholder
            return
        }

        if loadedURL == remoteURL, player != nil {
            SpecchioLogger.video.info("[InternalVideoPlayer] configure branch=reuse-player reason=\(reason, privacy: .public) linkID=\(link.id, privacy: .public) url=\(remoteURL.absoluteString, privacy: .public)")
            status = .ready
            return
        }

        SpecchioLogger.video.info("[InternalVideoPlayer] configure branch=create-player reason=\(reason, privacy: .public) linkID=\(link.id, privacy: .public) scheme=\(remoteURL.scheme ?? "none", privacy: .public) url=\(remoteURL.absoluteString, privacy: .public)")
        let nextPlayer = AVPlayer(url: remoteURL)
        player?.pause()
        player = nextPlayer
        loadedURL = remoteURL
        status = .ready
    }
}

private enum SpecchioInternalVideoStatus: Equatable {
    case loading
    case ready
    case placeholder

    var label: String {
        switch self {
        case .loading:
            return "Video loading"
        case .ready:
            return "Native video"
        case .placeholder:
            return "Video not linked"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .loading:
            return "video loading"
        case .ready:
            return "native video player ready"
        case .placeholder:
            return "video link is not configured"
        }
    }

    var color: Color {
        switch self {
        case .loading:
            return .orange
        case .ready:
            return .green
        case .placeholder:
            return .secondary
        }
    }
}

private enum SpecchioInternalVideoMetrics {
    static let defaultAspectRatio: CGFloat = 16.0 / 9.0
    static let floatingPlayerWidth: CGFloat = SpecchioPhoneWindowMetrics.defaultPhoneScreenSize.width
    static let floatingPlayerHeight: CGFloat = floatingPlayerWidth / defaultAspectRatio
}

struct SpecchioSetupTutorialButton: View {
    @StateObject private var tutorial = SpecchioSetupTutorialWindowController()
    private let providedTutorial: SpecchioSetupTutorialWindowController?
    private let title: String
    private let systemImage: String
    private let accessibilityLabel: String
    private let debugName: String
    private let customAction: (() -> Void)?

    init(
        tutorial: SpecchioSetupTutorialWindowController? = nil,
        title: String = "Setup tutorial",
        systemImage: String = "play.rectangle",
        accessibilityLabel: String = "Setup tutorial",
        debugName: String = "setup-tutorial-button",
        action: (() -> Void)? = nil
    ) {
        self.providedTutorial = tutorial
        self.title = title
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.debugName = debugName
        self.customAction = action
    }

    private var activeTutorial: SpecchioSetupTutorialWindowController {
        providedTutorial ?? tutorial
    }

    var body: some View {
        SWPlasmaActionButton(
            title: title,
            systemImage: systemImage,
            foregroundColor: .white,
            style: .prism,
            scale: 1.25,
            intensity: 1.1,
            distortion: 1.0,
            accessibilityLabel: accessibilityLabel,
            debugName: debugName
        ) {
            if let customAction {
                SpecchioLogger.easyMode.info("[SetupTutorialButton] tapped branch=custom-action title=\(title, privacy: .public) systemImage=\(systemImage, privacy: .public)")
                customAction()
            } else {
                SpecchioLogger.easyMode.info("[SetupTutorialButton] tapped branch=open-floating-window title=\(title, privacy: .public) systemImage=\(systemImage, privacy: .public)")
                activeTutorial.show()
            }
        }
        .onAppear {
            SpecchioLogger.easyMode.info("[SetupTutorialButton] appeared branch=ready title=\(title, privacy: .public) systemImage=\(systemImage, privacy: .public) hasCustomAction=\(customAction != nil)")
        }
    }
}

final class SpecchioSetupTutorialWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private var window: NSPanel?

    func show() {
        SpecchioLogger.easyMode.info("[SetupTutorialWindow] show requested hasExistingWindow=\(self.window != nil)")

        if let window {
            SpecchioLogger.easyMode.info("[SetupTutorialWindow] branch=reuse-existing-window")
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let contentSize = SpecchioSetupTutorialMetrics.windowContentSize
        SpecchioLogger.easyMode.info("[SetupTutorialWindow] branch=create-floating-panel width=\(contentSize.width) height=\(contentSize.height)")
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Specchio Setup"
        panel.contentMinSize = SpecchioSetupTutorialMetrics.windowMinimumContentSize
        panel.contentView = makeHostingView(size: contentSize)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        window = panel
        SpecchioLogger.easyMode.info("[SetupTutorialWindow] floating panel shown")
    }

    func close(reason: String) {
        guard let window else {
            SpecchioLogger.easyMode.info("[SetupTutorialWindow] close skipped reason=\(reason, privacy: .public) branch=no-window")
            return
        }

        SpecchioLogger.easyMode.info("[SetupTutorialWindow] close requested reason=\(reason, privacy: .public) branch=close-window")
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else {
            SpecchioLogger.easyMode.info("[SetupTutorialWindow] windowWillClose branch=untracked-window")
            return
        }

        SpecchioLogger.easyMode.info("[SetupTutorialWindow] windowWillClose branch=release-window")
        window = nil
    }

    private func makeHostingView(size: CGSize) -> NSHostingView<SpecchioSetupTutorialView> {
        SpecchioLogger.easyMode.info("[SetupTutorialWindow] makeHostingView width=\(size.width) height=\(size.height)")
        let view = SpecchioSetupTutorialView { [weak self] reason in
            self?.close(reason: reason)
        }
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        return hostingView
    }
}

struct SpecchioSetupTutorialView: View {
    let onDismiss: (String) -> Void

    @State private var selectedSlide: SpecchioSetupTutorialSlide = .welcome
    @State private var completedChecklistIDs: Set<SpecchioSetupChecklistItem.ID> = []

    private var canFinish: Bool {
        completedChecklistIDs.count == SpecchioSetupChecklistItem.allCases.count
    }

    var body: some View {
        VStack(spacing: 0) {
            tutorialMedia
                .frame(maxWidth: .infinity)
                .frame(height: SpecchioSetupTutorialMetrics.mediaHeight)
                .background(Color.black.opacity(0.78))

            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(selectedSlide.title)
                            .font(.system(size: 34, weight: .bold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)

                        Text(selectedSlide.subtitle)
                            .font(.title3)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 16)

                    SpecchioSetupTutorialDebugBadge(slide: selectedSlide)
                }

                tutorialDetails
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    ForEach(SpecchioSetupTutorialSlide.allCases) { slide in
                        Circle()
                            .fill(slide == selectedSlide ? Color.accentColor : Color.secondary.opacity(0.35))
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("Tutorial step \(slide.stepNumber) of \(SpecchioSetupTutorialSlide.allCases.count)")
                    }

                    Spacer()

                    Button("Not Now") {
                        SpecchioLogger.easyMode.info("[SetupTutorial] not-now tapped slide=\(selectedSlide.logName, privacy: .public)")
                        onDismiss("not-now")
                    }
                    .keyboardShortcut(.cancelAction)

                    if selectedSlide != .welcome {
                        Button("Back") {
                            moveBackward()
                        }
                    }

                    Button(primaryButtonTitle) {
                        handlePrimaryAction()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedSlide == .verification && !canFinish)
                    .help(primaryButtonHelp)
                }
            }
            .padding(.horizontal, 48)
            .padding(.top, 34)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .preferredColorScheme(.dark)
        .frame(
            minWidth: SpecchioSetupTutorialMetrics.windowMinimumContentSize.width,
            idealWidth: SpecchioSetupTutorialMetrics.windowContentSize.width,
            minHeight: SpecchioSetupTutorialMetrics.windowMinimumContentSize.height,
            idealHeight: SpecchioSetupTutorialMetrics.windowContentSize.height
        )
        .onAppear {
            SpecchioLogger.easyMode.info("[SetupTutorial] appeared slide=\(selectedSlide.logName, privacy: .public) checklistCompleted=\(completedChecklistIDs.count)")
        }
        .onChange(of: selectedSlide) { oldValue, newValue in
            SpecchioLogger.easyMode.info("[SetupTutorial] slide changed from=\(oldValue.logName, privacy: .public) to=\(newValue.logName, privacy: .public)")
        }
        .onChange(of: completedChecklistIDs) { _, newValue in
            SpecchioLogger.easyMode.info("[SetupTutorial] checklist state changed completed=\(newValue.count) total=\(SpecchioSetupChecklistItem.allCases.count) canFinish=\(canFinish)")
        }
    }

    @ViewBuilder
    private var tutorialMedia: some View {
        switch selectedSlide {
        case .welcome:
            SpecchioSetupTutorialHeroIllustration()
                .onAppear {
                    SpecchioLogger.easyMode.info("[SetupTutorial] media appeared slide=welcome branch=hero-illustration")
                }
        case .bluetooth:
            SpecchioSetupTutorialVideoPane(
                link: SpecchioVideoLinks.bluetoothConnectionExample,
                placeholderTitle: "Bluetooth connection video"
            )
            .onAppear {
                SpecchioLogger.easyMode.info("[SetupTutorial] media appeared slide=bluetooth branch=video hasRemoteURL=\(SpecchioVideoLinks.bluetoothConnectionExample.remoteURL != nil)")
            }
        case .iphone:
            SpecchioSetupTutorialVideoPane(
                link: SpecchioVideoLinks.iphoneSetupPlaceholder,
                placeholderTitle: "iPhone steps video placeholder"
            )
            .onAppear {
                SpecchioLogger.easyMode.info("[SetupTutorial] media appeared slide=iphone branch=placeholder hasRemoteURL=\(SpecchioVideoLinks.iphoneSetupPlaceholder.remoteURL != nil)")
            }
        case .verification:
            SpecchioSetupTutorialVerificationHero(isReady: canFinish)
                .onAppear {
                    SpecchioLogger.easyMode.info("[SetupTutorial] media appeared slide=verification branch=checklist-hero ready=\(canFinish)")
                }
        }
    }

    @ViewBuilder
    private var tutorialDetails: some View {
        switch selectedSlide {
        case .welcome:
            VStack(alignment: .leading, spacing: 14) {
                SpecchioSetupTutorialInfoRow(
                    icon: "iphone",
                    title: "Mirror your iPhone on your Mac",
                    text: "Specchio brings your iPhone screen into a Mac window for quick access."
                )
                SpecchioSetupTutorialInfoRow(
                    icon: "keyboard",
                    title: "Use Mac input through Bluetooth",
                    text: "Bluetooth lets Specchio forward keyboard and pointer actions to the iPhone."
                )
                SpecchioSetupTutorialInfoRow(
                    icon: "checkmark.seal",
                    title: "Finish with a short readiness check",
                    text: "Confirm the basic setup items before starting your first session."
                )
            }
        case .bluetooth:
            VStack(alignment: .leading, spacing: 14) {
                SpecchioSetupTutorialInfoRow(
                    icon: "1.circle",
                    title: "Open the Bluetooth setup",
                    text: "Specchio prepares a Bluetooth HID connection for the iPhone."
                )
                SpecchioSetupTutorialInfoRow(
                    icon: "2.circle",
                    title: "Pair from iPhone settings",
                    text: "On iPhone, open Settings, then Bluetooth, and select Specchio when it appears."
                )
                SpecchioSetupTutorialInfoRow(
                    icon: "3.circle",
                    title: "Return to Specchio",
                    text: "Once paired, come back to the Mac and finish connecting."
                )
            }
        case .iphone:
            VStack(alignment: .leading, spacing: 14) {
                SpecchioSetupTutorialInfoRow(
                    icon: "hand.tap",
                    title: "Follow the iPhone prompts",
                    text: "This slide is reserved for the phone-side walkthrough video."
                )
                SpecchioSetupTutorialInfoRow(
                    icon: "lock.open",
                    title: "Keep the iPhone unlocked",
                    text: "The first setup is easiest when the iPhone stays awake and near the Mac."
                )
                SpecchioSetupTutorialInfoRow(
                    icon: "arrowshape.turn.up.left",
                    title: "Come back to the Mac",
                    text: "After the iPhone steps are done, continue to the final checks."
                )
            }
        case .verification:
            VStack(alignment: .leading, spacing: 12) {
                ForEach(SpecchioSetupChecklistItem.allCases) { item in
                    SpecchioSetupChecklistRow(
                        item: item,
                        isOn: Binding(
                            get: { completedChecklistIDs.contains(item.id) },
                            set: { isOn in
                                setChecklistItem(item, isOn: isOn)
                            }
                        )
                    )
                }

                if !canFinish {
                    Text("Complete all checks to enable Ready to Go.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                        .onAppear {
                            SpecchioLogger.easyMode.info("[SetupTutorial] verification helper visible branch=checks-incomplete completed=\(completedChecklistIDs.count)")
                        }
                }
            }
        }
    }

    private var primaryButtonTitle: String {
        selectedSlide == .verification ? "Ready to Go" : "Continue"
    }

    private var primaryButtonHelp: String {
        if selectedSlide == .verification && !canFinish {
            return "Complete all setup checks first"
        }
        return primaryButtonTitle
    }

    private func handlePrimaryAction() {
        SpecchioLogger.easyMode.info("[SetupTutorial] primary tapped slide=\(selectedSlide.logName, privacy: .public) canFinish=\(canFinish)")

        guard selectedSlide != .verification else {
            guard canFinish else {
                SpecchioLogger.easyMode.info("[SetupTutorial] primary blocked branch=verification-incomplete completed=\(completedChecklistIDs.count)")
                return
            }

            SpecchioLogger.easyMode.info("[SetupTutorial] primary completed branch=ready-to-go")
            onDismiss("ready-to-go")
            return
        }

        moveForward()
    }

    private func moveForward() {
        guard let nextSlide = selectedSlide.next else {
            SpecchioLogger.easyMode.info("[SetupTutorial] next skipped slide=\(selectedSlide.logName, privacy: .public) branch=no-next-slide")
            return
        }

        SpecchioLogger.easyMode.info("[SetupTutorial] next applied from=\(selectedSlide.logName, privacy: .public) to=\(nextSlide.logName, privacy: .public)")
        selectedSlide = nextSlide
    }

    private func moveBackward() {
        guard let previousSlide = selectedSlide.previous else {
            SpecchioLogger.easyMode.info("[SetupTutorial] back skipped slide=\(selectedSlide.logName, privacy: .public) branch=no-previous-slide")
            return
        }

        SpecchioLogger.easyMode.info("[SetupTutorial] back applied from=\(selectedSlide.logName, privacy: .public) to=\(previousSlide.logName, privacy: .public)")
        selectedSlide = previousSlide
    }

    private func setChecklistItem(_ item: SpecchioSetupChecklistItem, isOn: Bool) {
        let alreadyCompleted = completedChecklistIDs.contains(item.id)
        SpecchioLogger.easyMode.info("[SetupTutorial] checklist toggle requested item=\(item.logName, privacy: .public) isOn=\(isOn) alreadyCompleted=\(alreadyCompleted)")

        if isOn {
            let inserted = completedChecklistIDs.insert(item.id).inserted
            SpecchioLogger.easyMode.info("[SetupTutorial] checklist branch=mark-complete item=\(item.logName, privacy: .public) inserted=\(inserted)")
        } else {
            let removed = completedChecklistIDs.remove(item.id) != nil
            SpecchioLogger.easyMode.info("[SetupTutorial] checklist branch=mark-incomplete item=\(item.logName, privacy: .public) removed=\(removed)")
        }
    }
}

private enum SpecchioSetupTutorialSlide: Int, CaseIterable, Identifiable {
    case welcome
    case bluetooth
    case iphone
    case verification

    var id: Int { rawValue }

    var stepNumber: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .welcome:
            return "Welcome to Specchio"
        case .bluetooth:
            return "Connect Bluetooth"
        case .iphone:
            return "Finish on iPhone"
        case .verification:
            return "Ready checks"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            return "A quick guide before you mirror and control your iPhone from your Mac."
        case .bluetooth:
            return "Bluetooth carries keyboard and pointer input from your Mac to your iPhone."
        case .iphone:
            return "Follow the phone-side steps, then return here to continue."
        case .verification:
            return "Tick each item when it is done, then start using Specchio."
        }
    }

    var logName: String {
        switch self {
        case .welcome: return "welcome"
        case .bluetooth: return "bluetooth"
        case .iphone: return "iphone"
        case .verification: return "verification"
        }
    }

    var next: SpecchioSetupTutorialSlide? {
        Self(rawValue: rawValue + 1)
    }

    var previous: SpecchioSetupTutorialSlide? {
        Self(rawValue: rawValue - 1)
    }
}

private enum SpecchioSetupChecklistItem: String, CaseIterable, Identifiable {
    case bluetoothOn
    case iphoneNearby
    case iphoneUnlocked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bluetoothOn:
            return "Bluetooth is on"
        case .iphoneNearby:
            return "iPhone is nearby"
        case .iphoneUnlocked:
            return "iPhone is unlocked"
        }
    }

    var detail: String {
        switch self {
        case .bluetoothOn:
            return "Bluetooth is enabled on both the Mac and the iPhone."
        case .iphoneNearby:
            return "The iPhone is close enough to pair and stay connected."
        case .iphoneUnlocked:
            return "The iPhone is awake so prompts and broadcasts are visible."
        }
    }

    var logName: String { rawValue }
}

private struct SpecchioSetupTutorialInfoRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SpecchioSetupChecklistRow: View {
    let item: SpecchioSetupChecklistItem
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline)
                Text(item.detail)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }
}

private struct SpecchioSetupTutorialDebugBadge: View {
    let slide: SpecchioSetupTutorialSlide

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
            Text("TUT \(slide.stepNumber)/\(SpecchioSetupTutorialSlide.allCases.count)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.07), in: Capsule())
        .accessibilityLabel("Setup tutorial diagnostic indicator step \(slide.stepNumber)")
        .onAppear {
            SpecchioLogger.easyMode.info("[SetupTutorial] debug badge visible slide=\(slide.logName, privacy: .public)")
        }
    }
}

private struct SpecchioSetupTutorialVideoPane: View {
    let link: SpecchioVideoLink
    let placeholderTitle: String

    var body: some View {
        Group {
            if link.remoteURL == nil {
                VStack(spacing: 12) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 62, weight: .regular))
                        .foregroundColor(.white.opacity(0.86))
                    Text(placeholderTitle)
                        .font(.headline)
                    Text("Video asset not linked yet")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.32))
                .onAppear {
                    SpecchioLogger.easyMode.info("[SetupTutorialVideoPane] placeholder appeared linkID=\(link.id, privacy: .public)")
                }
            } else {
                SpecchioInternalVideoPlayerView(link: link)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 22)
                    .onAppear {
                        SpecchioLogger.easyMode.info("[SetupTutorialVideoPane] native player appeared linkID=\(link.id, privacy: .public)")
                    }
            }
        }
    }
}

private struct SpecchioSetupTutorialHeroIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let laptopWidth = size.width * 0.58
            let laptopHeight = size.height * 0.62
            let phoneWidth = size.width * 0.16
            let phoneHeight = size.height * 0.62
            let iconSize = min(phoneWidth * 0.18, 12)

            ZStack {
                LinearGradient(
                    colors: [
                        Color.specchioPlasmaRGB(0x2A0A4A),
                        Color.specchioPlasmaRGB(0x6B4FA0),
                        Color.specchioPlasmaRGB(0x0288FF)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(0.78)

                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black.opacity(0.34))
                    .frame(width: laptopWidth, height: laptopHeight)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.white.opacity(0.45))
                            .frame(height: max(8, laptopHeight * 0.06))
                            .offset(y: laptopHeight * 0.08)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.specchioPlasmaRGB(0x2A0A4A),
                                        Color.specchioPlasmaRGB(0x6B4FA0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .padding(laptopWidth * 0.08)
                    }
                    .offset(x: -size.width * 0.12)

                RoundedRectangle(cornerRadius: phoneWidth * 0.14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.specchioPlasmaRGB(0xFFB86C),
                                Color.specchioPlasmaRGB(0xEA4C89)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: phoneWidth, height: phoneHeight)
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(Color.black.opacity(0.85))
                            .frame(width: phoneWidth * 0.34, height: phoneHeight * 0.045)
                            .padding(.top, phoneHeight * 0.04)
                    }
                    .overlay {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.fixed(iconSize), spacing: iconSize * 0.55), count: 4),
                            spacing: iconSize * 0.55
                        ) {
                            ForEach(0..<20, id: \.self) { index in
                                RoundedRectangle(cornerRadius: iconSize * 0.28, style: .continuous)
                                    .fill(iconColor(index: index))
                                    .frame(width: iconSize, height: iconSize)
                            }
                        }
                        .padding(.top, phoneHeight * 0.14)
                    }
                    .offset(x: size.width * 0.18, y: size.height * 0.02)
            }
        }
        .clipped()
        .accessibilityLabel("Specchio setup illustration")
    }

    private func iconColor(index: Int) -> Color {
        let colors: [Color] = [
            .green, .white, .yellow, .cyan,
            .blue, .gray, .mint, .indigo,
            .orange, .white, .red, .blue
        ]
        return colors[index % colors.count].opacity(0.92)
    }
}

private struct SpecchioSetupTutorialVerificationHero: View {
    let isReady: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.specchioPlasmaRGB(0x2A0A4A),
                    Color.specchioPlasmaRGB(0x0288FF)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(0.78)

            VStack(spacing: 14) {
                Image(systemName: isReady ? "checkmark.circle.fill" : "checklist")
                    .font(.system(size: 78, weight: .semibold))
                    .foregroundColor(isReady ? .green : .white.opacity(0.88))
                Text(isReady ? "Ready to Go" : "Final Checks")
                    .font(.title.weight(.bold))
            }
        }
        .accessibilityLabel(isReady ? "Setup checks complete" : "Setup checks incomplete")
    }
}

private enum SpecchioSetupTutorialMetrics {
    private static let referenceImageSize = CGSize(width: 1846, height: 1890)
    private static let referenceAspectRatio = referenceImageSize.width / referenceImageSize.height

    static let windowContentSize = CGSize(
        width: SpecchioPhoneWindowMetrics.defaultPhoneScreenSize.width * 1.76,
        height: (SpecchioPhoneWindowMetrics.defaultPhoneScreenSize.width * 1.76) / referenceAspectRatio
    )

    static let windowMinimumContentSize = windowContentSize

    static let mediaHeight = windowContentSize.height * 0.43
}

private struct NativeAVPlayerView: NSViewRepresentable {
    let player: AVPlayer?
    let linkID: String

    func makeCoordinator() -> Coordinator {
        Coordinator(linkID: linkID)
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .default
        playerView.videoGravity = .resizeAspect
        playerView.player = player
        context.coordinator.logPlayerUpdate(player: player, reason: "makeNSView")
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player === player {
            context.coordinator.logPlayerUpdate(player: player, reason: "updateNSView-reuse")
            return
        }

        nsView.player = player
        context.coordinator.logPlayerUpdate(player: player, reason: "updateNSView-replace")
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        if let player = nsView.player {
            SpecchioLogger.video.info("[NativeAVPlayerView] dismantle branch=pause linkID=\(coordinator.linkID, privacy: .public)")
            player.pause()
        } else {
            SpecchioLogger.video.info("[NativeAVPlayerView] dismantle branch=no-player linkID=\(coordinator.linkID, privacy: .public)")
        }
        nsView.player = nil
    }

    final class Coordinator {
        let linkID: String
        private var lastLoggedHasPlayer: Bool?
        private var lastLoggedReason: String?

        init(linkID: String) {
            self.linkID = linkID
            SpecchioLogger.video.info("[NativeAVPlayerView] coordinator init linkID=\(linkID, privacy: .public)")
        }

        func logPlayerUpdate(player: AVPlayer?, reason: String) {
            let hasPlayer = player != nil
            guard lastLoggedHasPlayer != hasPlayer || lastLoggedReason != reason else { return }
            lastLoggedHasPlayer = hasPlayer
            lastLoggedReason = reason
            SpecchioLogger.video.info("[NativeAVPlayerView] player update reason=\(reason, privacy: .public) linkID=\(self.linkID, privacy: .public) hasPlayer=\(hasPlayer)")
        }
    }
}
