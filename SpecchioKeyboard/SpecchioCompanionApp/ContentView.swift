import SwiftUI
import ReplayKit
import AVKit
import os.log
import Network

private let keyboardCompanionLog = Logger(subsystem: "com.alexintosh.SpecchioKeyboard", category: "CompanionUI")

private enum CompanionTab: String, CaseIterable, Identifiable {
    case screenStreaming
    case keyboard
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenStreaming:
            return "Screen Streaming"
        case .keyboard:
            return "Keyboard"
        case .logs:
            return "Logs"
        }
    }

    var headerSubtitle: String {
        switch self {
        case .screenStreaming:
            return "Screen Streaming"
        case .keyboard:
            return "Keyboard"
        case .logs:
            return "Logs"
        }
    }

    var systemImage: String {
        switch self {
        case .screenStreaming:
            return "iphone.radiowaves.left.and.right"
        case .keyboard:
            return "keyboard"
        case .logs:
            return "list.bullet.rectangle"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .screenStreaming:
            return .blue
        case .keyboard:
            return .green
        case .logs:
            return .orange
        }
    }
}

struct ContentView: View {
    private static let SHOW = false

    @ObservedObject var discovery: MacDiscovery
    @ObservedObject var broadcastDiagnostics: BroadcastDiagnostics
    @ObservedObject var idleTimerController: IdleTimerController
    @AppStorage("easyKeepScreenAwake", store: specchioCompanionSharedDefaults) private var keepScreenAwake = false
    @AppStorage("hasSeenSpecchioWelcomeSlides", store: specchioCompanionSharedDefaults) private var hasSeenWelcomeSlides = false
    @AppStorage(ReplayKitVideoCodecPreference.storageKey, store: specchioCompanionSharedDefaults) private var replayKitVideoCodecPreference = ReplayKitVideoCodecPreference.defaultValue.rawValue
    @State private var selectedTab: CompanionTab = .screenStreaming
    @State private var isShowingWelcomeSlides = false

    var body: some View {
        TabView(selection: $selectedTab) {
            screenStreamingTab
                .tabItem {
                    Label(CompanionTab.screenStreaming.title, systemImage: CompanionTab.screenStreaming.systemImage)
                }
                .tag(CompanionTab.screenStreaming)

            keyboardTab
                .tabItem {
                    Label(CompanionTab.keyboard.title, systemImage: CompanionTab.keyboard.systemImage)
                }
                .tag(CompanionTab.keyboard)

            logsTab
                .tabItem {
                    Label(CompanionTab.logs.title, systemImage: CompanionTab.logs.systemImage)
                }
                .tag(CompanionTab.logs)
        }
        .onAppear {
            keyboardCompanionLog.info("[CompanionUI] ContentView appeared selectedTab=\(self.selectedTab.rawValue) keepScreenAwake=\(self.keepScreenAwake) awakeGuardActive=\(self.idleTimerController.isAwakeGuardActive) hasSeenWelcomeSlides=\(self.hasSeenWelcomeSlides)")
            idleTimerController.updatePreference(keepScreenAwake, trigger: "content-appear")
            presentWelcomeSlidesIfNeeded(trigger: "content-appear")
        }
        .onChange(of: selectedTab) { newValue in
            keyboardCompanionLog.info("[CompanionUI] selected tab changed tab=\(newValue.rawValue)")
        }
        .onChange(of: keepScreenAwake) { newValue in
            keyboardCompanionLog.info("[CompanionUI] keepScreenAwake changed enabled=\(newValue)")
            idleTimerController.updatePreference(newValue, trigger: "toggle-change")
        }
        .onChange(of: idleTimerController.isAwakeGuardActive) { newValue in
            keyboardCompanionLog.info("[CompanionUI] awake guard active changed active=\(newValue) scenePhase=\(self.idleTimerController.currentScenePhaseLabel)")
        }
        .onChange(of: replayKitVideoCodecPreference) { newValue in
            keyboardCompanionLog.info("[CompanionUI] ReplayKit video codec preference changed value=\(newValue, privacy: .public)")
        }
        .fullScreenCover(isPresented: $isShowingWelcomeSlides) {
            SpecchioWelcomeSlidesView {
                completeWelcomeSlides(reason: "done")
            } onSkip: {
                completeWelcomeSlides(reason: "skip")
            }
        }
    }

    private var screenStreamingTab: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    companionHeader(for: .screenStreaming)
                    connectionStatusCard
                    screenStreamingCard
                    onboardingButton
                    if Self.SHOW {
                        PointerCalibrationCard(discovery: discovery)
                    }
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("Screen Streaming")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            keyboardCompanionLog.info("[CompanionUI] screen streaming tab appeared default=\(self.selectedTab == .screenStreaming) macConnected=\(self.discovery.macIP != nil) showCalibrationButton=\(Self.SHOW)")
        }
    }

    private var keyboardTab: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    companionHeader(for: .keyboard)
                    connectionStatusCard
                    keyboardSetupSection

                    Divider()
                        .padding(.horizontal)

                    aboutKeyboardSection
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("Keyboard")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            keyboardCompanionLog.info("[CompanionUI] keyboard tab appeared macConnected=\(self.discovery.macIP != nil)")
        }
    }

    private var logsTab: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    companionHeader(for: .logs)
                    logsCard
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            keyboardCompanionLog.info("[CompanionUI] logs tab appeared broadcast=\(self.broadcastDiagnostics.broadcastStatus) sender=\(self.broadcastDiagnostics.senderStatus)")
        }
    }

    private func companionHeader(for tab: CompanionTab) -> some View {
        VStack(spacing: 12) {
            Text("\u{1FA9E}")
                .font(.system(size: 80))
                .padding(.top, 16)

            Text("Specchio")
                .font(.largeTitle.weight(.bold))

            Text(tab.headerSubtitle)
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            CompanionTabIndicator(tab: tab)
                .padding(.top, 16)
                .padding(.trailing, 16)
        }
        .padding(.bottom, 8)
    }

    private var connectionStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: discovery.macIP != nil ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                    .foregroundColor(discovery.macIP != nil ? .green : .orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(discovery.macIP != nil ? "Mac Connected" : "Searching...")
                        .font(.headline)
                    Text(discovery.status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if discovery.macIP != nil {
                    Text(discovery.macIP!)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
            }

            if discovery.macIP == nil {
                Button(action: { discovery.start() }) {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private var screenStreamingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .foregroundColor(discovery.macIP != nil ? .blue : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Streaming")
                        .font(.headline)
                    Text(discovery.macIP != nil ? "Ready for Specchio Easy" : "Find your Mac before starting")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            ReplayKitStartButton(isEnabled: discovery.macIP != nil)

            if let ip = discovery.macIP {
                Text("Target: \(discovery.replayKitServiceName ?? "Specchio Easy") · \(Self.formatTarget(ip: ip, port: discovery.replayKitPort ?? 9500))")
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(broadcastDiagnostics.lastAudioSampleAgeText)
                Text(broadcastDiagnostics.audioSenderStatus)
                Text(broadcastDiagnostics.audioFormatText)
            }
            .font(.caption.monospaced())
            .foregroundColor(.secondary)

            Picker("Video Codec", selection: $replayKitVideoCodecPreference) {
                Text("H.264 Preferred").tag(ReplayKitVideoCodecPreference.h264Preferred.rawValue)
                Text("JPEG Only").tag(ReplayKitVideoCodecPreference.jpegOnly.rawValue)
            }
            .pickerStyle(.segmented)

        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Broadcast: \(broadcastDiagnostics.broadcastStatus)")
            Text("Sender: \(broadcastDiagnostics.senderStatus)")
            Text("Lifecycle: \(broadcastDiagnostics.lifecycleEvent)")
            Text(broadcastDiagnostics.statusAgeText)
            Text("Heartbeat: \(broadcastDiagnostics.heartbeatAgeText)")
            Text("Video: \(broadcastDiagnostics.lastVideoSampleAgeText)")
            Text(broadcastDiagnostics.videoCodecText)
            Text(broadcastDiagnostics.videoEncoderStatus)
            Text(broadcastDiagnostics.videoKeyframesText)
            Text(broadcastDiagnostics.videoEncodeText)
            Text(broadcastDiagnostics.lastAudioSampleAgeText)
            Text(broadcastDiagnostics.audioSenderStatus)
            Text(broadcastDiagnostics.audioFormatText)
            Text(broadcastDiagnostics.audioPacketText)
            Text("Keep-awake: \(broadcastDiagnostics.keepAwakeStatusText)")
                .foregroundColor(.secondary)
        }
        .font(.caption.monospaced())
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
        .onAppear {
            keyboardCompanionLog.info("[CompanionUI] logs card visible statusAge=\(self.broadcastDiagnostics.statusAgeText) heartbeat=\(self.broadcastDiagnostics.heartbeatAgeText) video=\(self.broadcastDiagnostics.lastVideoSampleAgeText) audio=\(self.broadcastDiagnostics.lastAudioSampleAgeText) codec=\(self.broadcastDiagnostics.videoCodecText)")
        }
    }

    private var keyboardSetupSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Setup")
                .font(.headline)
                .padding(.horizontal)

            SetupStep(
                number: 1,
                title: "Add the keyboard",
                description: "Settings \u{2192} General \u{2192} Keyboard \u{2192} Keyboards \u{2192} Add New Keyboard"
            )

            SetupStep(
                number: 2,
                title: "Select Specchio Keyboard",
                description: "Find \"Specchio Keyboard\" in the list and tap it."
            )

            SetupStep(
                number: 3,
                title: "Allow Full Access",
                description: "Tap \"Specchio Keyboard\" in your keyboard list, then enable \"Allow Full Access\"."
            )

            SetupStep(
                number: 4,
                title: "Switch to Specchio Keyboard",
                description: "In any app, long-press the globe icon and select Specchio."
            )
        }
    }

    private var aboutKeyboardSection: some View {
        VStack(spacing: 12) {
            Text("About")
                .font(.headline)

            Text("This is the companion app for **Specchio** on Mac. The Keyboard tab helps enable the custom keyboard that receives text directly from the Mac app for near-instant typing (~5ms vs ~310ms through the standard path).")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text("This app does not work on its own. You need the Specchio Mac app running and connected to your device.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Link(destination: URL(string: "https://specchio.space")!) {
                Label("Get Specchio for Mac", systemImage: "macwindow")
                    .font(.footnote.weight(.medium))
            }

            Text("specchio.space")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.6))
                .padding(.bottom, 16)
        }
        .padding(.horizontal)
    }

    private var onboardingButton: some View {
        Button {
            presentWelcomeSlidesAgain(trigger: "screen-streaming-button")
        } label: {
            Label("Show Onboarding", systemImage: "questionmark.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
    }

    private static func formatTarget(ip: String, port: Int) -> String {
        let host = ip.contains(":") ? "[\(ip)]" : ip
        return "\(host):\(String(port))"
    }

    private func presentWelcomeSlidesIfNeeded(trigger: String) {
        guard !hasSeenWelcomeSlides else {
            keyboardCompanionLog.info("[CompanionUI] welcome slides skipped trigger=\(trigger) reason=already-seen")
            return
        }
        guard !isShowingWelcomeSlides else {
            keyboardCompanionLog.info("[CompanionUI] welcome slides skipped trigger=\(trigger) reason=already-presenting")
            return
        }
        keyboardCompanionLog.info("[CompanionUI] welcome slides presenting trigger=\(trigger)")
        isShowingWelcomeSlides = true
    }

    private func presentWelcomeSlidesAgain(trigger: String) {
        guard !isShowingWelcomeSlides else {
            keyboardCompanionLog.info("[CompanionUI] welcome slides manual request skipped trigger=\(trigger) reason=already-presenting")
            return
        }
        keyboardCompanionLog.info("[CompanionUI] welcome slides manual request presenting trigger=\(trigger)")
        isShowingWelcomeSlides = true
    }

    private func completeWelcomeSlides(reason: String) {
        keyboardCompanionLog.info("[CompanionUI] welcome slides completed reason=\(reason)")
        hasSeenWelcomeSlides = true
        isShowingWelcomeSlides = false
    }
}

private struct SpecchioWelcomeSlidesView: View {
    let onDone: () -> Void
    let onSkip: () -> Void

    @StateObject private var videoPreloader = SpecchioTutorialVideoPreloader()
    @State private var selectedSlideID = 0

    private let slides = SpecchioWelcomeSlide.slides

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $selectedSlideID) {
                    ForEach(slides) { slide in
                        SpecchioWelcomeSlidePage(slide: slide)
                            .tag(slide.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .onAppear {
                    keyboardCompanionLog.info("[CompanionUI] welcome slides view appeared slide=\(self.selectedSlideID)")
                    videoPreloader.preload(
                        videos: slides.compactMap(\.tutorialVideo),
                        trigger: "welcome-slides-appear"
                    )
                }
                .onChange(of: selectedSlideID) { newValue in
                    keyboardCompanionLog.info("[CompanionUI] welcome slide changed slide=\(newValue)")
                }

                Divider()

                HStack(spacing: 12) {
                    Button {
                        keyboardCompanionLog.info("[CompanionUI] welcome slides skip tapped slide=\(self.selectedSlideID)")
                        onSkip()
                    } label: {
                        Label("Skip", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button {
                        keyboardCompanionLog.info("[CompanionUI] welcome slides primary tapped slide=\(self.selectedSlideID)")
                        advanceOrFinish()
                    } label: {
                        Label(primaryButtonTitle, systemImage: isLastSlide ? "checkmark" : "arrow.right")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
        }
        .environmentObject(videoPreloader)
    }

    private var isLastSlide: Bool {
        selectedSlideID == slides.last?.id
    }

    private var primaryButtonTitle: String {
        isLastSlide ? "Start" : "Next"
    }

    private func advanceOrFinish() {
        guard !isLastSlide else {
            onDone()
            return
        }
        selectedSlideID = min(selectedSlideID + 1, slides.count - 1)
    }
}

private struct SpecchioWelcomeSlidePage: View {
    let slide: SpecchioWelcomeSlide

    @State private var fullScreenVideo: SpecchioTutorialVideo?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    SpecchioWelcomeSlideIcon(icon: slide.icon, tint: slide.tint)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(slide.title)
                            .font(.largeTitle.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)

                        Text(slide.subtitle)
                            .font(.title3)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let video = slide.tutorialVideo {
                    SpecchioTutorialVideoPreview(video: video) {
                        keyboardCompanionLog.info("[CompanionUI] welcome tutorial video fullscreen requested video=\(video.id)")
                        fullScreenVideo = video
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(slide.details, id: \.self) { detail in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(slide.tint)
                                .font(.subheadline)
                                .accessibilityHidden(true)
                            Text(detail)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !slide.links.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(slide.links) { link in
                            if let url = link.url {
                                Link(destination: url) {
                                    SpecchioWelcomeLinkLabel(link: link)
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                Button {
                                    keyboardCompanionLog.info("[CompanionUI] welcome shortcut link tapped without url link=\(link.id)")
                                } label: {
                                    SpecchioWelcomeLinkLabel(link: link)
                                }
                                .buttonStyle(.bordered)
                                .disabled(true)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical)
            .padding(.horizontal, 20)
        }
        .fullScreenCover(item: $fullScreenVideo) { video in
            SpecchioTutorialFullscreenVideo(video: video)
        }
    }
}

private struct SpecchioWelcomeSlide: Identifiable {
    let id: Int
    let title: String
    let subtitle: String
    let details: [String]
    let icon: SpecchioSlideIcon
    let tint: Color
    let tutorialVideo: SpecchioTutorialVideo?
    let links: [SpecchioWelcomeSlideLink]

    private static let mouseOnShortcutURL = URL(string: "https://www.icloud.com/shortcuts/6b4d0f5109914768863d5ff4ef32cd58")!
    private static let mouseOffShortcutURL = URL(string: "https://www.icloud.com/shortcuts/2cfa8b6f553b465aa5e337cf3e0c6d86")!
    private static let shortcutsIconURL = URL(string: "https://help.apple.com/assets/6781C3C67B7D74FBA40A8869/6781C3D2FBC8FC20260A5112/en_GB/e5b2bdfad57b2e0b806c0f65d8d1db72.png")!

    static let slides: [SpecchioWelcomeSlide] = [
        SpecchioWelcomeSlide(
            id: 0,
            title: "Welcome to Specchio",
            subtitle: "This iPhone app works with Specchio on your Mac.",
            details: [
                "Stream your iPhone or iPad screen to your Mac.",
                "Use the Mac app as the main control center.",
                "This companion app does not do much on its own."
            ],
            icon: .mirror,
            tint: .blue,
            tutorialVideo: nil,
            links: []
        ),
        SpecchioWelcomeSlide(
            id: 1,
            title: "Install the Mac app",
            subtitle: "Specchio needs the Mac application before streaming can work.",
            details: [
                "Download Specchio for Mac from specchio.space.",
                "Open the Mac app and keep it running on the same network.",
                "This app will search for your Mac automatically."
            ],
            icon: .system("macwindow"),
            tint: .purple,
            tutorialVideo: nil,
            links: [
                SpecchioWelcomeSlideLink(
                    id: "download-mac",
                    title: "Download for Mac",
                    icon: .system("arrow.down.circle"),
                    url: URL(string: "https://specchio.space/")!
                )
            ]
        ),
        SpecchioWelcomeSlide(
            id: 2,
            title: "Install the Shortcuts",
            subtitle: "Optional: use Shortcuts to quickly switch Specchio mouse mode.",
            details: [
                "This step is optional.",
                "Install both Shortcuts once from the links below.",
                "Use Mouse On before starting a Specchio session.",
                "Use Mouse Off when you are done."
            ],
            icon: .remoteImage(shortcutsIconURL),
            tint: .indigo,
            tutorialVideo: nil,
            links: [
                SpecchioWelcomeSlideLink(
                    id: "mouse-on-shortcut",
                    title: "Install Mouse On Shortcut",
                    icon: .remoteImage(shortcutsIconURL),
                    url: mouseOnShortcutURL
                ),
                SpecchioWelcomeSlideLink(
                    id: "mouse-off-shortcut",
                    title: "Install Mouse Off Shortcut",
                    icon: .remoteImage(shortcutsIconURL),
                    url: mouseOffShortcutURL
                )
            ]
        ),
        SpecchioWelcomeSlide(
            id: 3,
            title: "Enable AssistiveTouch",
            subtitle: "This helps Specchio line up touch and pointer behavior.",
            details: [
                "Open Settings -> Accessibility -> Touch -> AssistiveTouch.",
                "Turn AssistiveTouch on.",
                "Turn Perform Touch Gestures off."
            ],
            icon: .system("hand.tap"),
            tint: .green,
            tutorialVideo: SpecchioTutorialVideo(
                id: "assistive-touch-settings",
                title: "AssistiveTouch setup preview",
                url: URL(string: "https://pub-97ba386621da499e92282258f46d7e74.r2.dev/enable-assistive-touch.mp4")!
            ),
            links: []
        ),
        SpecchioWelcomeSlide(
            id: 4,
            title: "Keep the iPhone awake",
            subtitle: "Streaming stops when iPhone sleeps.",
            details: [
                "Open Settings -> Display & Brightness -> Auto-Lock.",
                "Choose Never while using Specchio.",
                "You can turn Auto-Lock back on after your session."
            ],
            icon: .system("moon.zzz"),
            tint: .orange,
            tutorialVideo: SpecchioTutorialVideo(
                id: "auto-lock-settings",
                title: "Auto-Lock setup preview",
                url: URL(string: "https://pub-97ba386621da499e92282258f46d7e74.r2.dev/auto-lock.mp4")!
            ),
            links: []
        ),
        SpecchioWelcomeSlide(
            id: 5,
            title: "Start the broadcast",
            subtitle: "Use the Screen Streaming tab when your Mac is connected.",
            details: [
                "Wait until the status says Mac Connected.",
                "Tap Start Screen.",
                "Choose Specchio Broadcast and start the stream."
            ],
            icon: .system("record.circle"),
            tint: .red,
            tutorialVideo: nil,
            links: []
        )
    ]
}

private enum SpecchioSlideIcon {
    case system(String)
    case mirror
    case remoteImage(URL)
}

private struct SpecchioWelcomeSlideIcon: View {
    let icon: SpecchioSlideIcon
    let tint: Color

    var body: some View {
        Group {
            switch icon {
            case .system(let systemName):
                Image(systemName: systemName)
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundColor(tint)
            case .mirror:
                Text("🪞")
                    .font(.system(size: 52))
            case .remoteImage(let url):
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        Image(systemName: "app.dashed")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundColor(tint)
                    case .empty:
                        ProgressView()
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct MirrorGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let lineWidth = side / 16
            ZStack {
                RoundedRectangle(cornerRadius: side / 5, style: .continuous)
                    .stroke(lineWidth: lineWidth)
                RoundedRectangle(cornerRadius: side / 7, style: .continuous)
                    .fill(.primary.opacity(0.12))
                    .padding(side / 8)
                Path { path in
                    path.move(to: CGPoint(x: side * 0.25, y: side * 0.7))
                    path.addLine(to: CGPoint(x: side * 0.7, y: side * 0.25))
                }
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .opacity(0.55)
            }
            .frame(width: side, height: side)
        }
    }
}

private struct SpecchioWelcomeLinkLabel: View {
    let link: SpecchioWelcomeSlideLink

    var body: some View {
        HStack(spacing: 8) {
            SpecchioWelcomeInlineIcon(icon: link.icon)
            Text(link.title)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SpecchioWelcomeInlineIcon: View {
    let icon: SpecchioSlideIcon

    var body: some View {
        Group {
            switch icon {
            case .system(let systemName):
                Image(systemName: systemName)
                    .font(.headline)
            case .mirror:
                Text("🪞")
                    .font(.system(size: 18))
            case .remoteImage(let url):
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        Image(systemName: "app.dashed")
                    case .empty:
                        ProgressView()
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SpecchioWelcomeSlideLink: Identifiable {
    let id: String
    let title: String
    let icon: SpecchioSlideIcon
    let url: URL?
}

private struct SpecchioTutorialVideo: Identifiable {
    let id: String
    let title: String
    let url: URL
}

@MainActor
private final class SpecchioTutorialVideoPreloader: ObservableObject {
    @Published private var assetsByVideoID: [String: AVURLAsset] = [:]
    private var preloadTasksByVideoID: [String: Task<Void, Never>] = [:]

    func asset(for video: SpecchioTutorialVideo) -> AVURLAsset? {
        assetsByVideoID[video.id]
    }

    func preload(videos: [SpecchioTutorialVideo], trigger: String) {
        for video in videos {
            guard preloadTasksByVideoID[video.id] == nil else {
                keyboardCompanionLog.info("[CompanionUI] tutorial video preload skipped video=\(video.id) trigger=\(trigger) reason=already-started")
                continue
            }

            let asset = AVURLAsset(url: video.url)
            assetsByVideoID[video.id] = asset
            keyboardCompanionLog.info("[CompanionUI] tutorial video preload started video=\(video.id) trigger=\(trigger) url=\(video.url.absoluteString)")

            preloadTasksByVideoID[video.id] = Task { [video, asset] in
                do {
                    let isPlayable = try await asset.load(.isPlayable)
                    let duration = try await asset.load(.duration)
                    keyboardCompanionLog.info("[CompanionUI] tutorial video preload finished video=\(video.id) playable=\(isPlayable) duration=\(duration.seconds, privacy: .public)")
                } catch {
                    keyboardCompanionLog.error("[CompanionUI] tutorial video preload failed video=\(video.id) error=\(error.localizedDescription)")
                }
            }
        }
    }

    deinit {
        for task in preloadTasksByVideoID.values {
            task.cancel()
        }
    }
}

private struct SpecchioTutorialVideoPreview: View {
    let video: SpecchioTutorialVideo
    let onOpenFullscreen: () -> Void

    @EnvironmentObject private var videoPreloader: SpecchioTutorialVideoPreloader
    @ScaledMetric(relativeTo: .body) private var previewSide = 168

    var body: some View {
        HStack {
            Spacer()

            Button {
                onOpenFullscreen()
            } label: {
                LoopingTutorialVideoView(url: video.url, preloadedAsset: videoPreloader.asset(for: video), isMuted: true, showsControls: false, videoGravity: .resizeAspectFill)
                    .frame(width: previewSide, height: previewSide)
                    .clipped()
                    .onAppear {
                        keyboardCompanionLog.info("[CompanionUI] tutorial video preview loading video=\(video.id) url=\(video.url.absoluteString)")
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.2))
                    }
                    .overlay(alignment: .bottomLeading) {
                        Label(video.title, systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(8)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(video.title). Opens fullscreen video.")

            Spacer()
        }
    }
}

private struct SpecchioTutorialFullscreenVideo: View {
    let video: SpecchioTutorialVideo
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var videoPreloader: SpecchioTutorialVideoPreloader

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                LoopingTutorialVideoView(url: video.url, preloadedAsset: videoPreloader.asset(for: video), isMuted: false, showsControls: true, videoGravity: .resizeAspect)
                    .ignoresSafeArea()
                    .onAppear {
                        keyboardCompanionLog.info("[CompanionUI] tutorial video fullscreen loading video=\(video.id) url=\(video.url.absoluteString)")
                    }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        keyboardCompanionLog.info("[CompanionUI] tutorial video fullscreen dismissed video=\(video.id)")
                        dismiss()
                    } label: {
                        Label("Done", systemImage: "xmark")
                    }
                }
            }
        }
    }
}

private struct LoopingTutorialVideoView: UIViewControllerRepresentable {
    let url: URL
    let preloadedAsset: AVURLAsset?
    let isMuted: Bool
    let showsControls: Bool
    let videoGravity: AVLayerVideoGravity

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.videoGravity = videoGravity
        configure(controller, coordinator: context.coordinator)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.showsPlaybackControls = showsControls
        controller.videoGravity = videoGravity
        if context.coordinator.url != url || context.coordinator.isUsingPreloadedAsset != (preloadedAsset != nil) {
            configure(controller, coordinator: context.coordinator)
        } else {
            context.coordinator.player?.isMuted = isMuted
        }
    }

    private func configure(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        let item = AVPlayerItem(asset: preloadedAsset ?? AVURLAsset(url: url))
        let player = AVQueuePlayer(playerItem: item)
        player.isMuted = isMuted
        controller.showsPlaybackControls = showsControls
        controller.player = player
        coordinator.url = url
        coordinator.isUsingPreloadedAsset = preloadedAsset != nil
        coordinator.player = player
        coordinator.looper = AVPlayerLooper(player: player, templateItem: item)
        player.play()
    }

    final class Coordinator {
        var url: URL?
        var isUsingPreloadedAsset = false
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
    }
}

private struct CompanionTabIndicator: View {
    let tab: CompanionTab

    var body: some View {
        Circle()
            .fill(tab.indicatorColor)
            .frame(width: 8, height: 8)
            .accessibilityLabel("\(tab.headerSubtitle) tab active")
            .onAppear {
                keyboardCompanionLog.info("[CompanionUI] tab indicator visible tab=\(tab.rawValue)")
            }
    }
}

private struct ReplayKitBroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = "com.alexintosh.SpecchioKeyboard.broadcast"
        picker.showsMicrophoneButton = false
        picker.backgroundColor = .clear
        picker.tintColor = .clear
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = "com.alexintosh.SpecchioKeyboard.broadcast"
        uiView.showsMicrophoneButton = false
        uiView.backgroundColor = .clear
        uiView.tintColor = .clear
    }
}

private struct ReplayKitStartButton: View {
    let isEnabled: Bool

    var body: some View {
        ReplayKitStartButtonView(isEnabled: isEnabled)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
    }
}

private struct PointerCalibrationCard: View {
    @ObservedObject var discovery: MacDiscovery
    @State private var isPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .foregroundColor(discovery.macIP != nil ? .purple : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pointer Calibration")
                        .font(.headline)
                    Text(discovery.macIP != nil ? "Measure the Bluetooth pointer offset" : "Find your Mac before calibrating")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Button {
                isPresented = true
            } label: {
                Label("Start Calibration", systemImage: "target")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(discovery.macIP == nil)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
        .fullScreenCover(isPresented: $isPresented) {
            PointerCalibrationView(macHost: discovery.macIP)
        }
    }
}

private struct PointerCalibrationView: View {
    let macHost: String?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sender = PointerCalibrationSender()
    @State private var targetIndex = 0

    private let targets: [CGPoint] = [
        CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.18, y: 0.2),
        CGPoint(x: 0.82, y: 0.2),
        CGPoint(x: 0.82, y: 0.78),
        CGPoint(x: 0.18, y: 0.78),
        CGPoint(x: 0.5, y: 0.5),
    ]

    var body: some View {
        GeometryReader { geo in
            let expected = expectedPoint(in: geo.size)

            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pointer Calibration")
                                .font(.headline)
                            Text("Target \(min(targetIndex + 1, targets.count)) of \(targets.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(currentTargetID)
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Done") {
                            sender.stop()
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                    .background(.ultraThinMaterial)

                    Spacer()
                }

                CalibrationTarget()
                    .position(expected)

                VStack(spacing: 6) {
                    Spacer()
                    Text("Expected \(Int(expected.x)), \(Int(expected.y))")
                        .font(.caption2.monospaced())
                        .foregroundColor(.white.opacity(0.75))
                    Text(sender.status)
                        .font(.caption.monospaced())
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .padding(.bottom, 24)
                }
            }
            .coordinateSpace(name: "calibration")
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("calibration"))
                    .onEnded { value in
                        handleTap(actual: value.location, expected: expected, surface: geo.size)
                    }
            )
            .onAppear {
                os_log("[PointerCalibration] screen appeared targetID=%{public}@", log: .default, type: .info, currentTargetID)
                sender.start(host: macHost)
            }
            .onDisappear {
                sender.stop()
            }
        }
    }

    private var currentTargetID: String {
        "tap-\(min(targetIndex + 1, targets.count))"
    }

    private func expectedPoint(in size: CGSize) -> CGPoint {
        guard !targets.isEmpty else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        let normalized = targets[min(targetIndex, targets.count - 1)]
        return CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
    }

    private func handleTap(actual: CGPoint, expected: CGPoint, surface: CGSize) {
        os_log(
            "[PointerCalibration] tapped targetID=%{public}@ coordinateOrigin=topLeft expected=(%.1f,%.1f) actual=(%.1f,%.1f)",
            log: .default,
            type: .info,
            currentTargetID,
            expected.x,
            expected.y,
            actual.x,
            actual.y
        )
        sender.send(
            index: targetIndex,
            expected: expected,
            actual: actual,
            surface: surface
        )
        if targetIndex < targets.count - 1 {
            targetIndex += 1
        }
    }
}

private struct CalibrationTarget: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.95), lineWidth: 3)
                .frame(width: 72, height: 72)
            Circle()
                .stroke(Color.blue, lineWidth: 3)
                .frame(width: 44, height: 44)
            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 96, height: 2)
            Rectangle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 2, height: 96)
        }
        .shadow(color: .blue.opacity(0.6), radius: 12)
    }
}

private final class PointerCalibrationSender: ObservableObject {
    @Published var status = "Calibration link idle"

    private let log = OSLog(subsystem: "com.alexintosh.SpecchioKeyboard", category: "PointerCalibration")
    private let port: NWEndpoint.Port = 9600
    private let queue = DispatchQueue(label: "com.alexintosh.SpecchioKeyboard.pointer-calibration")
    private var connection: NWConnection?
    private var nextSequence = 1

    func start(host: String?) {
        guard let host, !host.isEmpty else {
            status = "No Mac host"
            os_log("[PointerCalibration] start failed: no host", log: log, type: .error)
            return
        }

        stop()
        status = "Connecting to \(host):\(port.rawValue)"
        os_log("[PointerCalibration] connecting to %{public}@:%d", log: log, type: .info, host, port.rawValue)

        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connection else { return }
            DispatchQueue.main.async {
                self.handle(state)
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        connection?.cancel()
        connection = nil
    }

    func send(index: Int, expected: CGPoint, actual: CGPoint, surface: CGSize) {
        let sequence = nextSequence
        nextSequence += 1
        let payload: [String: Any] = [
            "type": "pointerCalibrationMeasurement",
            "sequence": sequence,
            "kind": "tap",
            "targetID": "tap-\(index + 1)",
            "coordinateOrigin": "topLeft",
            "index": index,
            "expectedX": expected.x,
            "expectedY": expected.y,
            "actualX": actual.x,
            "actualY": actual.y,
            "width": surface.width,
            "height": surface.height,
            "timestamp": Date().timeIntervalSince1970,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8) else {
            status = "Failed to encode sample \(index + 1)"
            os_log("[PointerCalibration] encode failed index=%d", log: log, type: .error, index)
            return
        }
        line.append("\n")

        guard let connection else {
            status = "Calibration link not connected"
            os_log("[PointerCalibration] send dropped: no connection", log: log, type: .error)
            return
        }

        let sample = line.data(using: .utf8) ?? Data()
        status = "Sending sample \(index + 1)…"
        connection.send(content: sample, completion: .contentProcessed { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.status = "Send failed: \(error.localizedDescription)"
                    os_log("[PointerCalibration] send failed: %{public}@", log: self?.log ?? .default, type: .error, error.localizedDescription)
                } else {
                    self?.status = "Sample \(index + 1) sent"
                    os_log(
                        "[PointerCalibration] sent sample sequence=%d index=%d coordinateOrigin=topLeft expected=(%.1f,%.1f) actual=(%.1f,%.1f)",
                        log: self?.log ?? .default,
                        type: .info,
                        sequence,
                        index,
                        expected.x,
                        expected.y,
                        actual.x,
                        actual.y
                    )
                }
            }
        })
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .setup, .preparing:
            status = "Preparing calibration link…"
        case .ready:
            status = "Calibration link ready"
            os_log("[PointerCalibration] connection ready", log: log, type: .info)
        case .waiting(let error):
            status = "Waiting: \(error.localizedDescription)"
            os_log("[PointerCalibration] waiting: %{public}@", log: log, type: .error, error.localizedDescription)
        case .failed(let error):
            status = "Failed: \(error.localizedDescription)"
            os_log("[PointerCalibration] failed: %{public}@", log: log, type: .error, error.localizedDescription)
        case .cancelled:
            status = "Calibration link stopped"
            os_log("[PointerCalibration] cancelled", log: log, type: .info)
        @unknown default:
            status = "Unknown calibration link state"
            os_log("[PointerCalibration] unknown state", log: log, type: .error)
        }
    }
}

private struct ReplayKitStartButtonView: UIViewRepresentable {
    let isEnabled: Bool

    func makeUIView(context: Context) -> ReplayKitStartButtonContainer {
        let view = ReplayKitStartButtonContainer()
        view.configure(isEnabled: isEnabled)
        return view
    }

    func updateUIView(_ uiView: ReplayKitStartButtonContainer, context: Context) {
        uiView.configure(isEnabled: isEnabled)
    }
}

private final class ReplayKitStartButtonContainer: UIControl {
    private let log = OSLog(subsystem: "com.alexintosh.SpecchioKeyboard", category: "ReplayKitPicker")
    private let picker = RPSystemBroadcastPickerView(frame: .zero)
    private let iconView = UIImageView(image: UIImage(systemName: "record.circle"))
    private let label = UILabel()
    private var pickerButton: UIButton?
    private var hasLoggedMissingPickerButton = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        os_log("[ReplayKitPicker] init visible picker button", log: log, type: .info)

        backgroundColor = tintColor
        layer.cornerRadius = 12

        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.isUserInteractionEnabled = false

        label.text = "Start Screen"
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .white
        label.textAlignment = .center
        label.isUserInteractionEnabled = false

        picker.preferredExtension = "com.alexintosh.SpecchioKeyboard.broadcast"
        picker.showsMicrophoneButton = false
        picker.backgroundColor = .clear
        picker.tintColor = .clear
        picker.isOpaque = false

        addSubview(iconView)
        addSubview(label)
        addSubview(picker)
        addTarget(self, action: #selector(containerTapped), for: .touchUpInside)
        accessibilityLabel = "Start Specchio Screen"
        accessibilityTraits = [.button]
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(isEnabled: Bool) {
        self.isEnabled = isEnabled
        picker.isUserInteractionEnabled = isEnabled
        backgroundColor = isEnabled ? tintColor : .tertiarySystemBackground
        iconView.tintColor = isEnabled ? .white : .secondaryLabel
        label.textColor = isEnabled ? .white : .secondaryLabel
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        picker.frame = bounds

        let iconSize: CGFloat = 22
        let spacing: CGFloat = 8
        let labelSize = label.sizeThatFits(CGSize(width: bounds.width, height: bounds.height))
        let totalWidth = iconSize + spacing + labelSize.width
        let startX = max(0, (bounds.width - totalWidth) / 2)
        iconView.frame = CGRect(
            x: startX,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        label.frame = CGRect(
            x: iconView.frame.maxX + spacing,
            y: 0,
            width: min(labelSize.width, max(0, bounds.width - iconView.frame.maxX - spacing)),
            height: bounds.height
        )

        wirePickerButtonIfNeeded()
        if let pickerButton {
            pickerButton.frame = picker.bounds
            pickerButton.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            pickerButton.tintColor = .clear
            pickerButton.backgroundColor = .clear
            pickerButton.alpha = 0.02
        } else if !hasLoggedMissingPickerButton {
            hasLoggedMissingPickerButton = true
            os_log("[ReplayKitPicker] picker UIButton not found in RPSystemBroadcastPickerView hierarchy", log: log, type: .error)
        }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        os_log("[ReplayKitPicker] touch began inside visible button enabled=%{public}@", log: log, type: .info, String(isEnabled))
        return super.beginTracking(touch, with: event)
    }

    @objc private func containerTapped() {
        os_log("[ReplayKitPicker] container touchUpInside fired enabled=%{public}@", log: log, type: .info, String(isEnabled))
        guard isEnabled else {
            os_log("[ReplayKitPicker] tap ignored because Mac target is not ready", log: log, type: .info)
            return
        }

        guard let pickerButton else {
            os_log("[ReplayKitPicker] cannot forward tap because picker UIButton is missing", log: log, type: .error)
            return
        }

        os_log("[ReplayKitPicker] forwarding tap to RPSystemBroadcastPickerView UIButton", log: log, type: .info)
        pickerButton.sendActions(for: .touchUpInside)
    }

    @objc private func pickerButtonTapped() {
        os_log("[ReplayKitPicker] native picker UIButton touchUpInside fired", log: log, type: .info)
    }

    private func wirePickerButtonIfNeeded() {
        guard pickerButton == nil else { return }
        guard let button = firstButton(in: picker) else { return }
        os_log("[ReplayKitPicker] found native picker UIButton", log: log, type: .info)
        button.addTarget(self, action: #selector(pickerButtonTapped), for: .touchUpInside)
        button.addTarget(self, action: #selector(pickerButtonTouchDown), for: .touchDown)
        button.addTarget(self, action: #selector(pickerButtonTouchCancelled), for: [.touchCancel, .touchDragExit])
        pickerButton = button
    }

    @objc private func pickerButtonTouchDown() {
        os_log("[ReplayKitPicker] native picker UIButton touchDown fired", log: log, type: .info)
    }

    @objc private func pickerButtonTouchCancelled() {
        os_log("[ReplayKitPicker] native picker UIButton touch cancelled/exited", log: log, type: .info)
    }

    private func firstButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton {
            return button
        }

        for subview in view.subviews {
            if let button = firstButton(in: subview) {
                return button
            }
        }

        return nil
    }
}

private struct SetupStep: View {
    let number: Int
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 28, height: 28)
                Text("\(number)")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal)
    }
}

#Preview {
    ContentView(
        discovery: MacDiscovery(),
        broadcastDiagnostics: BroadcastDiagnostics(),
        idleTimerController: IdleTimerController()
    )
}
