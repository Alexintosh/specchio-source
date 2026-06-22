import SwiftUI
import Network
import os.log
import UIKit

let specchioCompanionAppGroupIdentifier = "group.com.alexintosh.SpecchioKeyboard"
let specchioCompanionSharedDefaults = UserDefaults(suiteName: specchioCompanionAppGroupIdentifier)

private let companionAppLog = Logger(subsystem: "com.alexintosh.SpecchioKeyboard", category: "CompanionApp")

@main
struct SpecchioCompanionApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var discovery = MacDiscovery()
    @StateObject private var broadcastDiagnostics = BroadcastDiagnostics()
    @StateObject private var idleTimerController = IdleTimerController()

    var body: some Scene {
        WindowGroup {
            ContentView(
                discovery: discovery,
                broadcastDiagnostics: broadcastDiagnostics,
                idleTimerController: idleTimerController
            )
            .onAppear {
                companionAppLog.info("[CompanionApp] window appeared; starting discovery")
                discovery.start()
                idleTimerController.updateScenePhase(scenePhase, trigger: "window-appear")
            }
            .onChange(of: scenePhase) { newValue in
                companionAppLog.info("[CompanionApp] scenePhase changed phase=\(IdleTimerController.scenePhaseLabel(for: newValue))")
                idleTimerController.updateScenePhase(newValue, trigger: "scene-phase-change")
            }
        }
    }
}

final class BroadcastDiagnostics: ObservableObject {
    @Published var broadcastStatus = "Not started"
    @Published var senderStatus = "Idle"
    @Published var statusAgeText = ""
    @Published var lifecycleEvent = "unknown"
    @Published var heartbeatAgeText = "no heartbeat"
    @Published var lastVideoSampleAgeText = "no video sample"
    @Published var keepAwakeStatusText = "Off"
    @Published var videoCodecText = "Video codec: waiting"
    @Published var videoEncoderStatus = "Encoder: waiting"
    @Published var videoKeyframesText = "Keyframes: 0"
    @Published var videoEncodeText = "Encode: n/a"
    @Published var audioSenderStatus = "Audio sender: Idle"
    @Published var lastAudioSampleAgeText = "Audio: no audio sample"
    @Published var audioPacketText = "Audio packets: 0 sent / 0 dropped"
    @Published var audioFormatText = "Audio format: waiting"

    private let sharedDefaults = specchioCompanionSharedDefaults
    private var timer: Timer?
    private var lastRefreshSignature = ""

    init() {
        companionAppLog.info("[BroadcastDiagnostics] init sharedDefaultsAvailable=\(self.sharedDefaults != nil)")
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        guard let sharedDefaults else {
            companionAppLog.error("[BroadcastDiagnostics] refresh branch=missing-defaults")
            broadcastStatus = "App Group unavailable"
            senderStatus = "Idle"
            lifecycleEvent = "unknown"
            statusAgeText = "no extension update"
            heartbeatAgeText = "no heartbeat"
            lastVideoSampleAgeText = "no video sample"
            keepAwakeStatusText = "Unavailable"
            videoCodecText = "Video codec: unavailable"
            videoEncoderStatus = "Encoder: unavailable"
            videoKeyframesText = "Keyframes: 0"
            videoEncodeText = "Encode: n/a"
            audioSenderStatus = "Audio sender: unavailable"
            lastAudioSampleAgeText = "Audio: no audio sample"
            audioPacketText = "Audio packets: 0 sent / 0 dropped"
            audioFormatText = "Audio format: unavailable"
            return
        }

        broadcastStatus = sharedDefaults.string(forKey: "broadcastLastStatus") ?? "Not started"
        senderStatus = sharedDefaults.string(forKey: "broadcastSenderStatus") ?? "Idle"
        lifecycleEvent = sharedDefaults.string(forKey: "broadcastLastLifecycleEvent") ?? "unknown"

        let broadcastTime = sharedDefaults.double(forKey: "broadcastLastStatusTime")
        let senderTime = sharedDefaults.double(forKey: "broadcastSenderStatusTime")
        let latestTime = max(broadcastTime, senderTime)
        if latestTime > 0 {
            let age = max(0, Int(Date().timeIntervalSince1970 - latestTime))
            statusAgeText = "\(age)s ago"
        } else {
            statusAgeText = "no extension update"
        }

        heartbeatAgeText = Self.relativeAgeText(
            for: sharedDefaults.double(forKey: "broadcastLastHeartbeatTime"),
            missing: "no heartbeat"
        )
        lastVideoSampleAgeText = Self.relativeAgeText(
            for: max(
                sharedDefaults.double(forKey: "broadcastVideoLastSampleTime"),
                sharedDefaults.double(forKey: "broadcastLastVideoSampleTime")
            ),
            missing: "no video sample"
        )

        let codec = sharedDefaults.string(forKey: "broadcastVideoCodec") ?? "unavailable"
        switch codec {
        case ReplayKitBroadcastVideoCodecStatus.h264.rawValue:
            videoCodecText = "Video codec: H.264"
        case ReplayKitBroadcastVideoCodecStatus.jpegFallback.rawValue:
            videoCodecText = "Video codec: JPEG fallback"
        default:
            videoCodecText = "Video codec: waiting"
        }
        videoEncoderStatus = "Encoder: \(sharedDefaults.string(forKey: "broadcastVideoEncoderStatus") ?? "waiting")"
        videoKeyframesText = "Keyframes: \(sharedDefaults.integer(forKey: "broadcastVideoKeyframesSent"))"
        let encodeMilliseconds = sharedDefaults.integer(forKey: "broadcastVideoLastEncodeMilliseconds")
        videoEncodeText = encodeMilliseconds > 0 ? "Encode: \(encodeMilliseconds) ms" : "Encode: n/a"

        audioSenderStatus = "Audio sender: \(sharedDefaults.string(forKey: "broadcastAudioSenderStatus") ?? "Idle")"
        let audioSampleAge = Self.relativeAgeText(
            for: max(
                sharedDefaults.double(forKey: "broadcastAudioLastSampleTime"),
                sharedDefaults.double(forKey: "broadcastLastAudioSampleTime")
            ),
            missing: "no audio sample"
        )
        lastAudioSampleAgeText = "Audio: \(audioSampleAge)"
        audioPacketText = "Audio packets: \(sharedDefaults.integer(forKey: "broadcastAudioPacketsSent")) sent / \(sharedDefaults.integer(forKey: "broadcastAudioPacketsDropped")) dropped"
        audioFormatText = "Audio format: \(sharedDefaults.string(forKey: "broadcastAudioFormatSummary") ?? "waiting")"

        let keepPreference = sharedDefaults.object(forKey: "easyKeepScreenAwake") as? Bool
        let keepGuardActive = sharedDefaults.object(forKey: "broadcastKeepAwakeEnabled") as? Bool
        switch (keepPreference, keepGuardActive) {
        case (.some(false), _):
            keepAwakeStatusText = "Off"
        case (.some(true), .some(true)):
            keepAwakeStatusText = "On · Active"
        case (.some(true), .some(false)):
            keepAwakeStatusText = "On · App inactive"
        case (.some(true), .none):
            keepAwakeStatusText = "On · Pending"
        case (.none, .some(true)):
            keepAwakeStatusText = "Active"
        case (.none, .some(false)):
            keepAwakeStatusText = "Inactive"
        case (.none, .none):
            keepAwakeStatusText = "Unavailable"
        }

        let signature = [
            broadcastStatus,
            senderStatus,
            lifecycleEvent,
            statusAgeText,
            heartbeatAgeText,
            lastVideoSampleAgeText,
            keepAwakeStatusText,
            videoCodecText,
            videoEncoderStatus,
            videoKeyframesText,
            videoEncodeText,
            audioSenderStatus,
            lastAudioSampleAgeText,
            audioPacketText,
            audioFormatText,
        ].joined(separator: "|")
        if signature != lastRefreshSignature {
            companionAppLog.info("[BroadcastDiagnostics] refreshed broadcast=\(self.broadcastStatus) sender=\(self.senderStatus) lifecycle=\(self.lifecycleEvent) statusAge=\(self.statusAgeText) heartbeatAge=\(self.heartbeatAgeText) videoAge=\(self.lastVideoSampleAgeText) keepAwake=\(self.keepAwakeStatusText) codec=\(self.videoCodecText) encoder=\(self.videoEncoderStatus) keyframes=\(self.videoKeyframesText) encode=\(self.videoEncodeText) audioSender=\(self.audioSenderStatus) audioAge=\(self.lastAudioSampleAgeText) audioPackets=\(self.audioPacketText) audioFormat=\(self.audioFormatText)")
            lastRefreshSignature = signature
        }
    }

    private static func relativeAgeText(for timestamp: Double, missing: String) -> String {
        guard timestamp > 0 else { return missing }
        let age = max(0, Int(Date().timeIntervalSince1970 - timestamp))
        return "\(age)s ago"
    }
}

@MainActor
final class IdleTimerController: ObservableObject {
    @Published private(set) var isAwakeGuardActive = false
    @Published private(set) var keepScreenAwakeEnabled = false
    @Published private(set) var currentScenePhaseLabel = scenePhaseLabel(for: .background)

    private let sharedDefaults = specchioCompanionSharedDefaults
    private var currentScenePhase: ScenePhase = .background

    init() {
        if let storedPreference = sharedDefaults?.object(forKey: "easyKeepScreenAwake") as? Bool {
            keepScreenAwakeEnabled = storedPreference
            companionAppLog.info("[IdleTimer] init branch=stored-preference enabled=\(storedPreference)")
        } else {
            companionAppLog.info("[IdleTimer] init branch=no-stored-preference default=false")
        }
        apply(trigger: "init")
    }

    func updatePreference(_ enabled: Bool, trigger: String) {
        companionAppLog.info("[IdleTimer] preference update trigger=\(trigger) enabled=\(enabled)")
        keepScreenAwakeEnabled = enabled
        sharedDefaults?.set(enabled, forKey: "easyKeepScreenAwake")
        apply(trigger: trigger)
    }

    func updateScenePhase(_ scenePhase: ScenePhase, trigger: String) {
        currentScenePhase = scenePhase
        currentScenePhaseLabel = Self.scenePhaseLabel(for: scenePhase)
        companionAppLog.info("[IdleTimer] scene update trigger=\(trigger) phase=\(self.currentScenePhaseLabel)")
        apply(trigger: trigger)
    }

    func syncStoredPreference(trigger: String) {
        let storedPreference = sharedDefaults?.object(forKey: "easyKeepScreenAwake") as? Bool ?? false
        companionAppLog.info("[IdleTimer] sync stored preference trigger=\(trigger) enabled=\(storedPreference)")
        keepScreenAwakeEnabled = storedPreference
        apply(trigger: trigger)
    }

    private func apply(trigger: String) {
        let shouldDisableIdleTimer: Bool
        if !keepScreenAwakeEnabled {
            companionAppLog.info("[IdleTimer] decision trigger=\(trigger) branch=setting-off phase=\(self.currentScenePhaseLabel)")
            shouldDisableIdleTimer = false
        } else if currentScenePhase != .active {
            companionAppLog.info("[IdleTimer] decision trigger=\(trigger) branch=scene-not-active phase=\(self.currentScenePhaseLabel)")
            shouldDisableIdleTimer = false
        } else {
            companionAppLog.info("[IdleTimer] decision trigger=\(trigger) branch=apply-guard phase=\(self.currentScenePhaseLabel)")
            shouldDisableIdleTimer = true
        }

        if UIApplication.shared.isIdleTimerDisabled == shouldDisableIdleTimer {
            companionAppLog.info("[IdleTimer] apply trigger=\(trigger) branch=no-op requested=\(shouldDisableIdleTimer)")
        } else {
            companionAppLog.info("[IdleTimer] apply trigger=\(trigger) branch=commit requested=\(shouldDisableIdleTimer)")
            UIApplication.shared.isIdleTimerDisabled = shouldDisableIdleTimer
        }

        isAwakeGuardActive = shouldDisableIdleTimer
        if let sharedDefaults {
            sharedDefaults.set(shouldDisableIdleTimer, forKey: "broadcastKeepAwakeEnabled")
        } else {
            companionAppLog.error("[IdleTimer] apply trigger=\(trigger) branch=missing-defaults")
        }
    }

    static func scenePhaseLabel(for scenePhase: ScenePhase) -> String {
        switch scenePhase {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }
}

/// Discovers the Specchio Mac app via Bonjour, resolves its IP,
/// and stores it in App Group UserDefaults for the keyboard extension.
final class MacDiscovery: ObservableObject {
    @Published var status: String = "Starting..."
    @Published var macIP: String? = nil
    @Published var replayKitPort: Int? = nil
    @Published var replayKitServiceName: String? = nil
    @Published var replayKitPolicySummary: String? = nil

    private var browser: NWBrowser?
    private var resolveConnection: NWConnection?
    private let sharedDefaults = UserDefaults(suiteName: "group.com.alexintosh.SpecchioKeyboard")
    private let replayKitBonjourType = "_specchio-replaykit._tcp"

    func start() {
        // Show previously stored IP
        if let stored = sharedDefaults?.string(forKey: "macHostIP"), !stored.isEmpty {
            macIP = stored
            let storedPort = sharedDefaults?.integer(forKey: "macReplayKitPort") ?? 0
            replayKitPort = storedPort > 0 ? storedPort : nil
            replayKitServiceName = sharedDefaults?.string(forKey: "macReplayKitServiceName")
            status = "Previously found Mac at \(stored) — rescanning..."
        }

        browser?.cancel()
        let descriptor = NWBrowser.Descriptor.bonjour(type: replayKitBonjourType, domain: nil)
        browser = NWBrowser(for: descriptor, using: .tcp)

        browser?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.status = (self?.macIP != nil)
                        ? "Scanning for updates..."
                        : "Scanning for Specchio Easy receiver..."
                case .waiting(let error):
                    self?.status = "Waiting: \(error.localizedDescription)"
                case .failed(let error):
                    self?.status = "Browse failed: \(error.localizedDescription)"
                default:
                    break
                }
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            for change in changes {
                if case .added(let result) = change {
                    DispatchQueue.main.async {
                    self.status = "Found Specchio Easy, resolving endpoint..."
                }
                self.storeReplayKitPolicyMetadata(result.metadata, source: "browse result")
                self.resolveEndpoint(result.endpoint)
                self.browser?.cancel()
                    self.browser = nil
                    return
                }
            }
        }

        browser?.start(queue: .main)
    }

    private func storeReplayKitPolicyMetadata(_ metadata: NWBrowser.Result.Metadata, source: String) {
        guard case .bonjour(let txtRecord) = metadata else {
            companionAppLog.info("[ReplayKitPolicy] \(source) metadata did not include Bonjour TXT record")
            return
        }

        let dictionary = txtRecord.dictionary
        guard dictionary["rkPolicy"] == "1" else {
            let keys = dictionary.keys.sorted().joined(separator: ",")
            companionAppLog.info("[ReplayKitPolicy] \(source) TXT record missing rkPolicy marker keys=\(keys)")
            return
        }

        let tier = dictionary["rkTier"] ?? "unknown"
        let premiumText = dictionary["rkPremium"] ?? "0"
        let jpegFPSText = dictionary["rkJPEGFPS"] ?? "15"
        let h264FPSText = dictionary["rkH264FPS"] ?? "30"
        let usbCableText = dictionary["rkUSBCable"] ?? "0"
        let usbReason = dictionary["rkUSBReason"] ?? "legacy transport metadata missing"
        let isPremium = premiumText == "1"
        let jpegFPS = Double(jpegFPSText) ?? 15
        let h264FPS = Double(h264FPSText) ?? 30
        let usbCableAttached = usbCableText == "1"

        sharedDefaults?.set(isPremium, forKey: "replayKitPolicyPremium")
        sharedDefaults?.set(tier, forKey: "replayKitPolicyTier")
        sharedDefaults?.set(jpegFPS, forKey: "replayKitPolicyJPEGFPS")
        sharedDefaults?.set(h264FPS, forKey: "replayKitPolicyH264FPS")
        sharedDefaults?.set(usbCableAttached, forKey: "replayKitPolicyUSBCableAttached")
        sharedDefaults?.set(usbReason, forKey: "replayKitPolicyUSBReason")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "replayKitPolicyStoredAt")
        sharedDefaults?.synchronize()

        let summary = "\(tier) - ReplayKit media enabled - JPEG \(Int(jpegFPS)) / H.264 \(Int(h264FPS)) FPS"
        DispatchQueue.main.async {
            self.replayKitPolicySummary = summary
        }
        companionAppLog.info("[ReplayKitPolicy] stored source=\(source, privacy: .public) tier=\(tier, privacy: .public) premiumMetadata=\(isPremium) legacyTransportMetadata=\(usbCableAttached) legacyTransportReason=\(usbReason, privacy: .public) jpegFPS=\(jpegFPS) h264FPS=\(h264FPS)")
    }

    private func resolveEndpoint(_ endpoint: NWEndpoint) {
        resolveConnection?.cancel()
        let conn = NWConnection(to: endpoint, using: .tcp)
        resolveConnection = conn

        if case .service(let name, let type, let domain, _) = endpoint {
            sharedDefaults?.set(name, forKey: "macReplayKitServiceName")
            sharedDefaults?.set(type, forKey: "macReplayKitServiceType")
            sharedDefaults?.set(domain, forKey: "macReplayKitServiceDomain")
            DispatchQueue.main.async {
                self.replayKitServiceName = name
            }
        }

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let path = conn.currentPath,
                   let remoteEndpoint = path.remoteEndpoint,
                   case .hostPort(let host, let remotePort) = remoteEndpoint {
                    let ip = "\(host)"
                    let port = Int(remotePort.rawValue)
                    DispatchQueue.main.async {
                        self.macIP = ip
                        self.replayKitPort = port
                        self.status = "Specchio Easy found at \(ip):\(port)"
                        self.sharedDefaults?.set(ip, forKey: "macHostIP")
                        self.sharedDefaults?.set(port, forKey: "macReplayKitPort")
                        if port < Int(UInt16.max) {
                            self.sharedDefaults?.set(port + 1, forKey: "macReplayKitAudioPort")
                            companionAppLog.info("[MacDiscovery] stored audio direct fallback host=\(ip, privacy: .public) port=\(port + 1)")
                        } else {
                            companionAppLog.info("[MacDiscovery] skipped audio direct fallback reason=video-port-max host=\(ip, privacy: .public) port=\(port)")
                        }
                        self.sharedDefaults?.synchronize()
                    }
                } else {
                    DispatchQueue.main.async {
                        self.status = "Connected but could not extract IP"
                    }
                }
                conn.cancel()
            case .failed(let error):
                DispatchQueue.main.async {
                    self.status = "Resolve failed: \(error.localizedDescription)"
                }
            default:
                break
            }
        }

        conn.start(queue: .main)
    }
}
