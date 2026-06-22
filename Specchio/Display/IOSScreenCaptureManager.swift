import AVFoundation
import CoreImage
import Foundation
import ImageIO

enum IOSScreenCaptureHealth: Equatable {
    case idle
    case discovering
    case starting(deviceName: String)
    case live
    case stale(lastFrameAge: TimeInterval)
    case interrupted(reason: String)
    case disconnected(reason: String)
    case failed(reason: String)

    var diagnosticDescription: String {
        switch self {
        case .idle:
            return "idle"
        case .discovering:
            return "discovering"
        case .starting(let deviceName):
            return "starting(deviceName=\(deviceName))"
        case .live:
            return "live"
        case .stale(let lastFrameAge):
            return "stale(lastFrameAge=\(String(format: "%.1f", lastFrameAge)))"
        case .interrupted(let reason):
            return "interrupted(reason=\(reason))"
        case .disconnected(let reason):
            return "disconnected(reason=\(reason))"
        case .failed(let reason):
            return "failed(reason=\(reason))"
        }
    }
}

enum IOSScreenCaptureAudioState: String, Equatable {
    case off
    case waiting
    case live
    case error

    var diagnosticDescription: String {
        rawValue
    }
}

struct NativeAVCaptureVideoOrientationSnapshot: Equatable {
    let videoOrientationRaw: Int?
    let videoOrientationName: String?
    let videoRotationAngleDegrees: Double?
    let frameWidth: Int
    let frameHeight: Int
    let timestamp: Double

    var frameAxis: String {
        ReplayKitVideoOrientationSnapshot.frameAxis(width: frameWidth, height: frameHeight)
    }

    var videoOrientationAxis: String? {
        guard let videoOrientationRaw else { return nil }
        return ReplayKitVideoOrientationSnapshot.cgImageOrientationAxis(for: videoOrientationRaw)
    }

    var rotationAngleAxis: String? {
        guard let videoRotationAngleDegrees, videoRotationAngleDegrees.isFinite else {
            return nil
        }

        let rounded = Int(videoRotationAngleDegrees.rounded())
        let normalized = ((rounded % 360) + 360) % 360
        switch normalized {
        case 0, 180: return "portrait"
        case 90, 270: return "landscape"
        default: return "unknown"
        }
    }

    var orientationSignature: String {
        [
            videoOrientationRaw.map(String.init) ?? "nil",
            videoRotationAngleDegrees.map { FrameDropDiagnostics.format($0, digits: 1) } ?? "nil",
            String(frameWidth),
            String(frameHeight)
        ].joined(separator: ":")
    }
}

private struct NativeUSBPolicySnapshot: Equatable {
    let configuredTargetFramesPerSecond: Double
    let effectiveTargetFramesPerSecond: Double
    let reason: String

    var framePublishIntervalSeconds: TimeInterval? {
        guard effectiveTargetFramesPerSecond > 0 else { return nil }
        return 1.0 / effectiveTargetFramesPerSecond
    }
}

private struct NativeAVCaptureAudioSourceFormat: Equatable {
    let sampleRate: Double
    let channelCount: Int
    let bitsPerChannel: Int
    let bytesPerSample: Int
    let formatFlags: AudioFormatFlags
    let isFloat: Bool
    let isSignedInteger: Bool
    let isNonInterleaved: Bool

    var diagnosticDescription: String {
        let commonFormat = isFloat ? "float" : (isSignedInteger ? "signedInteger" : "other")
        let layout = isNonInterleaved ? "nonInterleaved" : "interleaved"
        return "sampleRate=\(FrameDropDiagnostics.format(sampleRate, digits: 1)) channels=\(channelCount) bits=\(bitsPerChannel) bytesPerSample=\(bytesPerSample) commonFormat=\(commonFormat) layout=\(layout) flags=\(formatFlags)"
    }

    var playbackFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        )
    }

    init?(formatDescription: CMFormatDescription) {
        guard let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let asbd = basicDescription.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            return nil
        }

        sampleRate = asbd.mSampleRate
        channelCount = Int(asbd.mChannelsPerFrame)
        bitsPerChannel = Int(asbd.mBitsPerChannel)
        bytesPerSample = max(Int(asbd.mBitsPerChannel) / 8, 0)
        formatFlags = asbd.mFormatFlags
        isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        isSignedInteger = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        guard sampleRate > 0, channelCount > 0, bytesPerSample > 0 else {
            return nil
        }
    }
}

final class IOSScreenCaptureManager: NSObject, ObservableObject {
    @Published var isCapturing = false
    @Published var currentFPS: Double = 0
    @Published var currentFrame: CGImage?
    @Published var lastFrameSize: CGSize?
    @Published var lastVideoOrientation: NativeAVCaptureVideoOrientationSnapshot?
    @Published var streamHealth: IOSScreenCaptureHealth = .idle
    @Published var lastFrameReceivedAt: Date?
    @Published var statusMessage = "Idle"
    @Published var lastError: String?
    @Published var diagnosticDeviceName: String?
    @Published var diagnosticUniqueID: String?
    @Published var diagnosticMediaType: String?
    @Published var audioState: IOSScreenCaptureAudioState = .off
    @Published var audioStatusMessage = "USB Audio Off"
    @Published var isAudioPlaying = false
    @Published var audioSampleRate: Double = 0
    @Published var audioChannelCount = 0
    @Published var receivedAudioSampleBufferCount = 0
    @Published var droppedAudioSampleBufferCount = 0
    @Published var audioBufferedMilliseconds: Double = 0
    @Published var configuredTargetFramesPerSecond = AppSettings.Defaults.easyUSBTargetFPS
    @Published var effectiveTargetFramesPerSecond = AppSettings.Defaults.easyUSBTargetFPS
    @Published var capturePolicyMessage = "USB capture uses configured FPS and audio when available"

    var onStreamFailed: ((String) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.alexintosh.Specchio.iosScreenCapture.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.alexintosh.Specchio.iosScreenCapture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.alexintosh.Specchio.iosScreenCapture.audio", qos: .userInteractive)
    private let audioQueueKey = DispatchSpecificKey<Bool>()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let fpsLock = NSLock()
    private let nativePolicyLock = NSLock()
    private let staleThresholdSeconds: TimeInterval = 3.0
    private let nativeAudioTargetBufferedMilliseconds: Double = 20
    private let nativeAudioMaximumBufferedMilliseconds: Double = 180

    private var nativePolicyConfiguredTargetFramesPerSecond = AppSettings.Defaults.easyUSBTargetFPS
    private var nativePolicyEffectiveTargetFramesPerSecond = AppSettings.Defaults.easyUSBTargetFPS
    private var nativePolicyReason = "USB capture uses configured FPS and audio when available"
    private var nativeZeroFPSTargetLogged = false
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var notificationTokens: [NSObjectProtocol] = []
    private var fpsTimer: Timer?
    private var staleTimer: Timer?
    private var framesSinceLastFPSSample = 0
    private var lastPublishedFrameAt = Date.distantPast
    private var captureStartedAt: Date?
    private var restartAttemptedForCurrentDevice = false
    private var isStoppingIntentionally = false
    private var isDeinitializing = false
    private var firstFrameLogged = false
    private var nativeAudioConnectionDeferredUntilFirstFrame = false
    private var selectedDescriptor: IOSScreenCaptureDeviceDescriptor?
    private let nativeDiagnosticsLock = NSLock()
    private var nativeDiagnosticsWindowStartedAt = Date()
    private var nativeDiagnosticsSamples = 0
    private var nativeDiagnosticsPublishedFrames = 0
    private var nativeDiagnosticsThrottledFrames = 0
    private var nativeDiagnosticsConversionFailures = 0
    private var nativeDiagnosticsDroppedSamples = 0
    private var nativeDiagnosticsTotalSamples = 0
    private var nativeDiagnosticsTotalPublishedFrames = 0
    private var nativeDiagnosticsTotalThrottledFrames = 0
    private var nativeDiagnosticsTotalConversionFailures = 0
    private var nativeDiagnosticsTotalDroppedSamples = 0
    private var nativeDiagnosticsLastSampleAt: Date?
    private var nativeDiagnosticsLastPublishedAt: Date?
    private var nativeDiagnosticsMaxSampleGapMilliseconds: Double = 0
    private var nativeDiagnosticsMaxPublishGapMilliseconds: Double = 0
    private var nativeAudioEngine: AVAudioEngine?
    private var nativeAudioPlayer: AVAudioPlayerNode?
    private var nativeAudioFormat: AVAudioFormat?
    private var nativeAudioFormatDescription = "none"
    private var nativeAudioPlayerStarted = false
    private var nativeAudioBufferedMilliseconds: Double = 0
    private var nativeAudioWindowStartedAt = Date()
    private var nativeAudioWindowSampleBuffers = 0
    private var nativeAudioWindowScheduledBuffers = 0
    private var nativeAudioWindowDroppedBuffers = 0
    private var nativeAudioWindowFrames = 0
    private var nativeAudioWindowBytes = 0
    private var nativeAudioTotalSampleBuffers = 0
    private var nativeAudioTotalScheduledBuffers = 0
    private var nativeAudioTotalDroppedBuffers = 0
    private var nativeAudioTotalFrames = 0
    private var nativeAudioLastSampleAt: Date?
    private var nativeAudioMaxArrivalGapMilliseconds: Double = 0

    override init() {
        super.init()
        let storedTargetFPS = UserDefaults.standard.object(
            forKey: AppSettings.Keys.easyUSBTargetFPS
        ) as? NSNumber
        let sanitizedTargetFPS = AppSettings.sanitizedEasyUSBTargetFPS(
            storedTargetFPS?.doubleValue ?? AppSettings.Defaults.easyUSBTargetFPS
        )
        nativePolicyConfiguredTargetFramesPerSecond = sanitizedTargetFPS
        nativePolicyEffectiveTargetFramesPerSecond = sanitizedTargetFPS
        configuredTargetFramesPerSecond = sanitizedTargetFPS
        effectiveTargetFramesPerSecond = nativePolicyEffectiveTargetFramesPerSecond
        capturePolicyMessage = nativePolicyReason
        audioQueue.setSpecific(key: audioQueueKey, value: true)
        SpecchioLogger.iosScreenCapture.info("[NativeUSBPolicy] initialized configuredFPS=\(self.nativePolicyConfiguredTargetFramesPerSecond) effectiveFPS=\(self.nativePolicyEffectiveTargetFramesPerSecond) reason=\(self.nativePolicyReason, privacy: .public)")
    }

    deinit {
        isDeinitializing = true
        SpecchioLogger.iosScreenCapture.info("[Manager] deinit teardown starting onMainThread=\(Thread.isMainThread)")
        isStoppingIntentionally = true
        tearDownSession(
            reason: "manager deinit",
            publishIdle: false,
            clearFrame: true,
            publishAsyncState: false
        )
    }

    func updateTargetFramesPerSecond(_ rawValue: Double, source: String) {
        let sanitizedValue = AppSettings.sanitizedEasyUSBTargetFPS(rawValue)
        let snapshot = updateNativeUSBPolicy(
            configuredTargetFramesPerSecond: sanitizedValue,
            source: source
        )
        SpecchioLogger.iosScreenCapture.info("[NativeUSBPolicy] target FPS update source=\(source, privacy: .public) raw=\(rawValue) sanitized=\(sanitizedValue) effectiveFPS=\(snapshot.effectiveTargetFramesPerSecond)")
    }

    func startCapture(
        deviceDescriptor: IOSScreenCaptureDeviceDescriptor,
        trigger: String
    ) {
        startCapture(deviceDescriptor: deviceDescriptor, trigger: trigger, isRetry: false)
    }

    func stopCapture(reason: String, clearFrame: Bool = false) {
        guard Thread.isMainThread else {
            guard !isDeinitializing else {
                SpecchioLogger.iosScreenCapture.warning("[Manager] stop requested off-main during deinit; running nonpublishing teardown reason=\(reason, privacy: .public)")
                tearDownSession(
                    reason: reason,
                    publishIdle: false,
                    clearFrame: clearFrame,
                    publishAsyncState: false
                )
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.stopCapture(reason: reason, clearFrame: clearFrame)
            }
            return
        }

        SpecchioLogger.iosScreenCapture.info("[Manager] stop requested reason=\(reason, privacy: .public) hasSession=\(self.captureSession != nil) isCapturing=\(self.isCapturing)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "nativeAVCapture",
            event: "stopRequested",
            reason: reason,
            details: nativeDiagnosticDetails([
                "hasSession": String(captureSession != nil),
                "isCapturing": String(isCapturing)
            ])
        )
        isStoppingIntentionally = true
        tearDownSession(reason: reason, publishIdle: true, clearFrame: clearFrame)
    }

    private func startCapture(
        deviceDescriptor: IOSScreenCaptureDeviceDescriptor,
        trigger: String,
        isRetry: Bool
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.startCapture(deviceDescriptor: deviceDescriptor, trigger: trigger, isRetry: isRetry)
            }
            return
        }

        SpecchioLogger.iosScreenCapture.info("[Manager] session start requested trigger=\(trigger, privacy: .public) retry=\(isRetry) selected=\(deviceDescriptor.logSummary, privacy: .public)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "nativeAVCapture",
            event: "startRequested",
            reason: trigger,
            details: descriptorDiagnosticDetails(deviceDescriptor).merging([
                "retry": String(isRetry)
            ]) { current, _ in current }
        )
        guard deviceDescriptor.isLikelyIOSScreenCapture else {
            let reason = "Rejected native USB capture start: selected device is not CoreMedia embedded device screen recording"
            SpecchioLogger.iosScreenCapture.error("[Manager] \(reason, privacy: .public) selected=\(deviceDescriptor.logSummary, privacy: .public)")
            FrameDropDiagnostics.shared.recordDrop(
                source: "nativeAVCapture",
                stage: "device-selection",
                reason: reason,
                details: descriptorDiagnosticDetails(deviceDescriptor)
            )
            lastError = reason
            statusMessage = reason
            streamHealth = .failed(reason: reason)
            onStreamFailed?(reason)
            return
        }

        isStoppingIntentionally = false
        selectedDescriptor = deviceDescriptor
        if !isRetry {
            restartAttemptedForCurrentDevice = false
        }
        tearDownSession(reason: "replacing session for \(trigger)", publishIdle: false, clearFrame: false)

        diagnosticDeviceName = deviceDescriptor.localizedName
        diagnosticUniqueID = deviceDescriptor.uniqueID
        diagnosticMediaType = deviceDescriptor.mediaType.rawValue
        statusMessage = "Starting USB native capture"
        streamHealth = .starting(deviceName: deviceDescriptor.localizedName)
        lastError = nil
        lastVideoOrientation = nil
        captureStartedAt = Date()
        firstFrameLogged = false
        resetNativeFrameDiagnostics(reason: "start \(trigger)", descriptor: deviceDescriptor)
        resetNativeAudioState(reason: "start \(trigger)", descriptor: deviceDescriptor)

        let session = AVCaptureSession()
        session.sessionPreset = .high

        captureSession = session
        registerNotifications(for: session, selectedUniqueID: deviceDescriptor.uniqueID)
        startFPSTimer()
        startStaleTimer()

        let device = deviceDescriptor.device
        let mediaType = deviceDescriptor.mediaType

        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureAndRun(session: session, device: device, mediaType: mediaType, trigger: trigger)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.handleStartFailure(error.localizedDescription, trigger: trigger)
                }
            }
        }
    }

    private func configureAndRun(
        session: AVCaptureSession,
        device: AVCaptureDevice,
        mediaType: AVMediaType,
        trigger: String
    ) throws {
        SpecchioLogger.iosScreenCapture.info("[Manager] configuring session trigger=\(trigger, privacy: .public) deviceName=\(device.localizedName, privacy: .public) uniqueID=\(device.uniqueID, privacy: .public) modelID=\(device.modelID, privacy: .public) mediaType=\(mediaType.rawValue, privacy: .public) formats=\(device.formats.count)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "nativeAVCapture",
            event: "configureSession",
            reason: trigger,
            details: nativeDiagnosticDetails([
                "deviceName": device.localizedName,
                "uniqueID": device.uniqueID,
                "modelID": device.modelID,
                "mediaType": mediaType.rawValue,
                "formats": String(device.formats.count)
            ])
        )

        session.beginConfiguration()
        let policy = nativeUSBPolicySnapshot()
        SpecchioLogger.iosScreenCapture.info("[NativeUSBPolicy] configure session source=\(trigger, privacy: .public) configuredFPS=\(policy.configuredTargetFramesPerSecond) effectiveFPS=\(policy.effectiveTargetFramesPerSecond) reason=\(policy.reason, privacy: .public)")
        let output: AVCaptureVideoDataOutput
        let audioOutput: AVCaptureAudioDataOutput?
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                SpecchioLogger.iosScreenCapture.error("[Manager] cannot add device input deviceName=\(device.localizedName, privacy: .public) mediaType=\(mediaType.rawValue, privacy: .public)")
                throw WDAError.connectionFailed("Cannot add iOS screen capture device input")
            }
            session.addInput(input)
            let inputPorts = input.ports.map { $0.mediaType.rawValue }.joined(separator: ",")
            SpecchioLogger.iosScreenCapture.info("[NativeAudio] device input ports mediaTypes=\(inputPorts, privacy: .public) deviceName=\(device.localizedName, privacy: .public)")
            FrameDropDiagnostics.shared.recordLifecycle(
                source: "nativeAVCaptureAudio",
                event: "inputPortsDiscovered",
                reason: trigger,
                details: nativeDiagnosticDetails([
                    "inputPorts": inputPorts
                ])
            )

            output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            output.setSampleBufferDelegate(self, queue: videoQueue)

            guard session.canAddOutput(output) else {
                SpecchioLogger.iosScreenCapture.error("[Manager] cannot add video output deviceName=\(device.localizedName, privacy: .public) mediaType=\(mediaType.rawValue, privacy: .public)")
                throw WDAError.connectionFailed("Cannot add iOS screen capture video output")
            }
            session.addOutput(output)

            if let connection = output.connection(with: .video) {
                connection.isEnabled = true
                SpecchioLogger.iosScreenCapture.info("[Manager] video output connection configured enabled=\(connection.isEnabled)")
            } else {
                SpecchioLogger.iosScreenCapture.info("[Manager] video output connection unavailable immediately after output add")
            }

            let candidateAudioOutput = AVCaptureAudioDataOutput()
            candidateAudioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(candidateAudioOutput) {
                session.addOutput(candidateAudioOutput)
                audioOutput = candidateAudioOutput
                if let connection = candidateAudioOutput.connection(with: .audio) {
                    connection.isEnabled = false
                    SpecchioLogger.iosScreenCapture.info("[NativeAudio] audio output connection configured enabled=\(connection.isEnabled) deferral=until-first-video-frame policy=\(policy.reason, privacy: .public)")
                    FrameDropDiagnostics.shared.recordLifecycle(
                        source: "nativeAVCaptureAudio",
                        event: "audioOutputAdded",
                        reason: trigger,
                        details: nativeDiagnosticDetails([
                            "connectionEnabled": String(connection.isEnabled),
                            "deferredUntilFirstFrame": "true",
                            "policyReason": policy.reason
                        ])
                    )
                } else {
                    SpecchioLogger.iosScreenCapture.info("[NativeAudio] audio output connection unavailable immediately after output add")
                    FrameDropDiagnostics.shared.recordLifecycle(
                        source: "nativeAVCaptureAudio",
                        event: "audioConnectionUnavailable",
                        reason: trigger,
                        details: nativeDiagnosticDetails(),
                        severity: "warning"
                    )
                }
            } else {
                audioOutput = nil
                candidateAudioOutput.setSampleBufferDelegate(nil, queue: nil)
                SpecchioLogger.iosScreenCapture.warning("[NativeAudio] cannot add audio output deviceName=\(device.localizedName, privacy: .public) mediaType=\(mediaType.rawValue, privacy: .public)")
                FrameDropDiagnostics.shared.recordLifecycle(
                    source: "nativeAVCaptureAudio",
                    event: "audioOutputUnavailable",
                    reason: "AVCaptureSession rejected AVCaptureAudioDataOutput",
                    details: nativeDiagnosticDetails(),
                    severity: "warning"
                )
            }
        } catch {
            SpecchioLogger.iosScreenCapture.info("[Manager] committing failed AVCaptureSession configuration before propagating error trigger=\(trigger, privacy: .public)")
            session.commitConfiguration()
            throw error
        }

        SpecchioLogger.iosScreenCapture.info("[Manager] committing AVCaptureSession configuration trigger=\(trigger, privacy: .public)")
        session.commitConfiguration()

        DispatchQueue.main.async { [weak self] in
            self?.videoOutput = output
            self?.audioOutput = audioOutput
            self?.nativeAudioConnectionDeferredUntilFirstFrame = audioOutput != nil
            if audioOutput != nil {
                self?.audioStatusMessage = "USB Audio Waiting"
                self?.audioState = .waiting
                self?.capturePolicyMessage = policy.reason
                SpecchioLogger.iosScreenCapture.info("[NativeAudio] audio connection deferral armed trigger=\(trigger, privacy: .public) firstFrameLogged=\(self?.firstFrameLogged ?? false)")
                if self?.firstFrameLogged == true {
                    self?.enableDeferredNativeAudioConnectionIfNeeded(reason: "audio output stored after first video frame")
                }
            } else {
                self?.nativeAudioConnectionDeferredUntilFirstFrame = false
                self?.audioStatusMessage = "USB Audio Unavailable"
                self?.audioState = .error
                self?.capturePolicyMessage = policy.reason
            }
        }

        SpecchioLogger.iosScreenCapture.info("[Manager] starting AVCaptureSession trigger=\(trigger, privacy: .public)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "nativeAVCapture",
            event: "startRunning",
            reason: trigger,
            details: nativeDiagnosticDetails()
        )
        session.startRunning()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.captureSession === session else {
                SpecchioLogger.iosScreenCapture.info("[Manager] started session ignored trigger=\(trigger, privacy: .public) reason=session-replaced")
                return
            }

            self.isCapturing = session.isRunning
            self.statusMessage = session.isRunning ? "USB native capture running" : "USB native capture did not start"
            if session.isRunning {
                SpecchioLogger.iosScreenCapture.info("[Manager] session started trigger=\(trigger, privacy: .public)")
                FrameDropDiagnostics.shared.recordLifecycle(
                    source: "nativeAVCapture",
                    event: "sessionStarted",
                    reason: trigger,
                    details: self.nativeDiagnosticDetails()
                )
            } else {
                self.fail(reason: "AVCaptureSession did not report running after start", trigger: "session start")
            }
        }
    }

    private func registerNotifications(for session: AVCaptureSession, selectedUniqueID: String) {
        removeNotifications()
        let center = NotificationCenter.default

        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: .main
        ) { [weak self] notification in
            self?.handleRuntimeError(notification)
        })

        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: session,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        })

        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: session,
            queue: .main
        ) { [weak self] _ in
            SpecchioLogger.iosScreenCapture.info("[Manager] session interruption ended")
            self?.streamHealth = .starting(deviceName: self?.diagnosticDeviceName ?? "unknown")
            self?.statusMessage = "USB native capture resuming"
        })

        notificationTokens.append(center.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let device = notification.object as? AVCaptureDevice
            SpecchioLogger.iosScreenCapture.info("[Manager] device disconnected notification name=\(device?.localizedName ?? "unknown", privacy: .public) uniqueID=\(device?.uniqueID ?? "unknown", privacy: .public) selectedUniqueID=\(selectedUniqueID, privacy: .public)")
            guard device?.uniqueID == selectedUniqueID else { return }
            self?.handleSelectedDeviceDisconnected(deviceName: device?.localizedName ?? "iOS device")
        })
    }

    private func removeNotifications() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    private func tearDownSession(
        reason: String,
        publishIdle: Bool,
        clearFrame: Bool,
        publishAsyncState: Bool = true
    ) {
        removeNotifications()
        fpsTimer?.invalidate()
        fpsTimer = nil
        staleTimer?.invalidate()
        staleTimer = nil

        let session = captureSession
        captureSession = nil
        videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        videoOutput = nil
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        audioOutput = nil
        nativeAudioConnectionDeferredUntilFirstFrame = false
        stopNativeAudioPlayback(reason: reason, publishAsyncState: publishAsyncState)
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "nativeAVCapture",
            event: "tearDownSession",
            reason: reason,
            details: nativeDiagnosticDetails([
                "hadSession": String(session != nil),
                "publishIdle": String(publishIdle),
                "clearFrame": String(clearFrame)
            ])
        )

        sessionQueue.async {
            if let session, session.isRunning {
                SpecchioLogger.iosScreenCapture.info("[Manager] stopping AVCaptureSession reason=\(reason, privacy: .public)")
                session.stopRunning()
            } else {
                SpecchioLogger.iosScreenCapture.info("[Manager] no running AVCaptureSession to stop reason=\(reason, privacy: .public)")
            }
        }

        resetFPSCounter()
        currentFPS = 0
        isCapturing = false
        captureStartedAt = nil

        if clearFrame {
            currentFrame = nil
            lastFrameSize = nil
            lastVideoOrientation = nil
            lastFrameReceivedAt = nil
        }

        if publishIdle {
            statusMessage = "Stopped"
            streamHealth = .idle
            audioStatusMessage = "USB Audio Off"
            audioState = .off
            isAudioPlaying = false
            audioBufferedMilliseconds = 0
        }
    }

    private func startFPSTimer() {
        resetFPSCounter()
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sampleFPS()
        }
    }

    private func startStaleTimer() {
        staleTimer?.invalidate()
        staleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.evaluateStaleHealth()
        }
    }

    private func resetFPSCounter() {
        fpsLock.lock()
        framesSinceLastFPSSample = 0
        fpsLock.unlock()
    }

    private func incrementFPSCounter() {
        fpsLock.lock()
        framesSinceLastFPSSample += 1
        fpsLock.unlock()
    }

    private func sampleFPS() {
        fpsLock.lock()
        let count = framesSinceLastFPSSample
        framesSinceLastFPSSample = 0
        fpsLock.unlock()

        currentFPS = Double(count)
        guard isCapturing else { return }
        let policy = nativeUSBPolicySnapshot()
        SpecchioLogger.iosScreenCapture.info("[Manager] FPS sample fps=\(self.currentFPS) effectiveTargetFPS=\(policy.effectiveTargetFramesPerSecond) configuredTargetFPS=\(policy.configuredTargetFramesPerSecond) health=\(self.streamHealth.diagnosticDescription, privacy: .public) frameSize=\(self.lastFrameSize.map { "\($0.width)x\($0.height)" } ?? "unknown", privacy: .public)")
    }

    private func descriptorDiagnosticDetails(_ descriptor: IOSScreenCaptureDeviceDescriptor) -> [String: String] {
        [
            "deviceName": descriptor.localizedName,
            "uniqueID": descriptor.uniqueID,
            "mediaType": descriptor.mediaType.rawValue,
            "modelID": descriptor.modelID,
            "manufacturer": descriptor.manufacturer,
            "formats": String(descriptor.formatsCount),
            "hasEmbeddedDeviceScreenRecordingFormat": String(descriptor.hasEmbeddedDeviceScreenRecordingFormat),
            "selectionScore": String(descriptor.selectionScore),
            "selectionReason": descriptor.selectionReason
        ]
    }

    private func nativeUSBPolicySnapshot() -> NativeUSBPolicySnapshot {
        nativePolicyLock.lock()
        let snapshot = NativeUSBPolicySnapshot(
            configuredTargetFramesPerSecond: nativePolicyConfiguredTargetFramesPerSecond,
            effectiveTargetFramesPerSecond: nativePolicyEffectiveTargetFramesPerSecond,
            reason: nativePolicyReason
        )
        nativePolicyLock.unlock()
        return snapshot
    }

    @discardableResult
    private func updateNativeUSBPolicy(
        configuredTargetFramesPerSecond: Double?,
        source: String
    ) -> NativeUSBPolicySnapshot {
        nativePolicyLock.lock()
        let oldSnapshot = NativeUSBPolicySnapshot(
            configuredTargetFramesPerSecond: nativePolicyConfiguredTargetFramesPerSecond,
            effectiveTargetFramesPerSecond: nativePolicyEffectiveTargetFramesPerSecond,
            reason: nativePolicyReason
        )

        if let configuredTargetFramesPerSecond {
            nativePolicyConfiguredTargetFramesPerSecond = AppSettings.sanitizedEasyUSBTargetFPS(configuredTargetFramesPerSecond)
        }

        nativePolicyEffectiveTargetFramesPerSecond = nativePolicyConfiguredTargetFramesPerSecond
        nativePolicyReason = "USB capture uses configured FPS and audio when available"

        let newSnapshot = NativeUSBPolicySnapshot(
            configuredTargetFramesPerSecond: nativePolicyConfiguredTargetFramesPerSecond,
            effectiveTargetFramesPerSecond: nativePolicyEffectiveTargetFramesPerSecond,
            reason: nativePolicyReason
        )
        nativeZeroFPSTargetLogged = false
        nativePolicyLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.configuredTargetFramesPerSecond = newSnapshot.configuredTargetFramesPerSecond
            self.effectiveTargetFramesPerSecond = newSnapshot.effectiveTargetFramesPerSecond
            self.capturePolicyMessage = newSnapshot.reason
            self.applyNativeAudioPolicyToPublishedState(source: source)
            self.applyNativeAudioConnectionPolicy(source: source)
        }

        if oldSnapshot != newSnapshot {
            SpecchioLogger.iosScreenCapture.info("[NativeUSBPolicy] changed source=\(source, privacy: .public) previousConfiguredFPS=\(oldSnapshot.configuredTargetFramesPerSecond) newConfiguredFPS=\(newSnapshot.configuredTargetFramesPerSecond) previousEffectiveFPS=\(oldSnapshot.effectiveTargetFramesPerSecond) newEffectiveFPS=\(newSnapshot.effectiveTargetFramesPerSecond) reason=\(newSnapshot.reason, privacy: .public)")
            FrameDropDiagnostics.shared.recordLifecycle(
                source: "nativeAVCapture",
                event: "capturePolicyChanged",
                reason: source,
                details: nativeDiagnosticDetails([
                    "configuredTargetFPS": FrameDropDiagnostics.format(newSnapshot.configuredTargetFramesPerSecond),
                    "effectiveTargetFPS": FrameDropDiagnostics.format(newSnapshot.effectiveTargetFramesPerSecond),
                    "policyReason": newSnapshot.reason
                ])
            )
        } else {
            SpecchioLogger.iosScreenCapture.info("[NativeUSBPolicy] unchanged source=\(source, privacy: .public) configuredFPS=\(newSnapshot.configuredTargetFramesPerSecond) effectiveFPS=\(newSnapshot.effectiveTargetFramesPerSecond)")
        }

        return newSnapshot
    }

    private func applyNativeAudioPolicyToPublishedState(source: String) {
        if audioState == .off {
            audioState = captureSession == nil ? .off : .waiting
            audioStatusMessage = captureSession == nil ? "USB Audio Off" : "USB Audio Waiting"
        }
        SpecchioLogger.iosScreenCapture.info("[NativeUSBPolicy] audio UI branch=available source=\(source, privacy: .public) state=\(self.audioState.rawValue, privacy: .public) message=\(self.audioStatusMessage, privacy: .public)")
    }

    private func applyNativeAudioConnectionPolicy(source: String) {
        guard let connection = audioOutput?.connection(with: .audio) else {
            SpecchioLogger.iosScreenCapture.info("[NativeUSBPolicy] audio connection update skipped source=\(source, privacy: .public) reason=no-audio-output")
            return
        }

        guard !nativeAudioConnectionDeferredUntilFirstFrame || firstFrameLogged else {
            SpecchioLogger.iosScreenCapture.info("[NativeUSBPolicy] audio connection update deferred source=\(source, privacy: .public) reason=waiting-for-first-video-frame enabled=\(connection.isEnabled)")
            FrameDropDiagnostics.shared.recordLifecycle(
                source: "nativeAVCaptureAudio",
                event: "audioConnectionEnableDeferred",
                reason: source,
                details: audioDiagnosticDetails([
                    "connectionEnabled": String(connection.isEnabled),
                    "deferredUntilFirstFrame": String(nativeAudioConnectionDeferredUntilFirstFrame),
                    "firstFrameLogged": String(firstFrameLogged)
                ])
            )
            return
        }

        connection.isEnabled = true
        nativeAudioConnectionDeferredUntilFirstFrame = false
        SpecchioLogger.iosScreenCapture.info("[NativeUSBPolicy] audio connection update source=\(source, privacy: .public) enabled=\(connection.isEnabled)")
    }

    private func enableDeferredNativeAudioConnectionIfNeeded(reason: String) {
        guard nativeAudioConnectionDeferredUntilFirstFrame else {
            SpecchioLogger.iosScreenCapture.info("[NativeAudio] deferred audio enable skipped reason=\(reason, privacy: .public) branch=not-deferred")
            return
        }

        guard firstFrameLogged else {
            SpecchioLogger.iosScreenCapture.info("[NativeAudio] deferred audio enable skipped reason=\(reason, privacy: .public) branch=waiting-for-first-video-frame")
            return
        }

        guard let connection = audioOutput?.connection(with: .audio) else {
            SpecchioLogger.iosScreenCapture.warning("[NativeAudio] deferred audio enable failed reason=\(reason, privacy: .public) branch=no-audio-connection")
            FrameDropDiagnostics.shared.recordLifecycle(
                source: "nativeAVCaptureAudio",
                event: "audioConnectionEnableFailed",
                reason: reason,
                details: audioDiagnosticDetails([
                    "deferredUntilFirstFrame": String(nativeAudioConnectionDeferredUntilFirstFrame),
                    "firstFrameLogged": String(firstFrameLogged)
                ]),
                severity: "warning"
            )
            return
        }

        connection.isEnabled = true
        nativeAudioConnectionDeferredUntilFirstFrame = false
        audioState = .waiting
        audioStatusMessage = "USB Audio Waiting"

        SpecchioLogger.iosScreenCapture.info("[NativeAudio] deferred audio connection enabled reason=\(reason, privacy: .public) enabled=\(connection.isEnabled)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "nativeAVCaptureAudio",
            event: "audioConnectionEnabledAfterFirstFrame",
            reason: reason,
            details: audioDiagnosticDetails([
                "connectionEnabled": String(connection.isEnabled),
                "deferredUntilFirstFrame": String(nativeAudioConnectionDeferredUntilFirstFrame),
                "firstFrameLogged": String(firstFrameLogged)
            ])
        )
    }

    private func nativeDiagnosticDetails(_ details: [String: String] = [:]) -> [String: String] {
        var merged = details
        let descriptor = selectedDescriptor
        let policy = nativeUSBPolicySnapshot()
        merged["deviceName"] = merged["deviceName"] ?? diagnosticDeviceName ?? descriptor?.localizedName ?? "unknown"
        merged["uniqueID"] = merged["uniqueID"] ?? diagnosticUniqueID ?? descriptor?.uniqueID ?? "unknown"
        merged["mediaType"] = merged["mediaType"] ?? diagnosticMediaType ?? descriptor?.mediaType.rawValue ?? "unknown"
        merged["health"] = merged["health"] ?? streamHealth.diagnosticDescription
        merged["configuredTargetFPS"] = merged["configuredTargetFPS"] ?? FrameDropDiagnostics.format(policy.configuredTargetFramesPerSecond)
        merged["effectiveTargetFPS"] = merged["effectiveTargetFPS"] ?? FrameDropDiagnostics.format(policy.effectiveTargetFramesPerSecond)
        merged["policyReason"] = merged["policyReason"] ?? policy.reason
        return merged
    }

    private func makeNativeVideoOrientationSnapshot(
        sampleBuffer: CMSampleBuffer,
        connection: AVCaptureConnection,
        frameSize: CGSize
    ) -> NativeAVCaptureVideoOrientationSnapshot {
        let orientationRaw = Self.nativeVideoOrientationRaw(sampleBuffer)
        return NativeAVCaptureVideoOrientationSnapshot(
            videoOrientationRaw: orientationRaw,
            videoOrientationName: orientationRaw.map(ReplayKitVideoOrientationSnapshot.cgImageOrientationName),
            videoRotationAngleDegrees: Self.videoRotationAngleDegrees(for: connection),
            frameWidth: Int(frameSize.width.rounded()),
            frameHeight: Int(frameSize.height.rounded()),
            timestamp: Date().timeIntervalSince1970
        )
    }

    private func updateNativeVideoOrientation(_ snapshot: NativeAVCaptureVideoOrientationSnapshot) {
        guard lastVideoOrientation?.orientationSignature != snapshot.orientationSignature else { return }

        let previous = lastVideoOrientation
        lastVideoOrientation = snapshot
        SpecchioLogger.iosScreenCapture.info("[NativeVideoOrientation] changed previousVideo=\(previous?.videoOrientationName ?? "nil", privacy: .public) previousAngle=\(previous?.videoRotationAngleDegrees.map { FrameDropDiagnostics.format($0, digits: 1) } ?? "nil", privacy: .public) video=\(snapshot.videoOrientationName ?? "nil", privacy: .public) videoAxis=\(snapshot.videoOrientationAxis ?? "nil", privacy: .public) angle=\(snapshot.videoRotationAngleDegrees.map { FrameDropDiagnostics.format($0, digits: 1) } ?? "nil", privacy: .public) angleAxis=\(snapshot.rotationAngleAxis ?? "nil", privacy: .public) frameWidth=\(snapshot.frameWidth) frameHeight=\(snapshot.frameHeight) frameAxis=\(snapshot.frameAxis, privacy: .public)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "nativeAVCaptureOrientation",
            event: "orientationChanged",
            reason: "sample",
            details: nativeDiagnosticDetails([
                "previousVideoOrientation": previous?.videoOrientationName ?? "nil",
                "previousRotationAngle": previous?.videoRotationAngleDegrees.map { FrameDropDiagnostics.format($0, digits: 1) } ?? "nil",
                "videoOrientation": snapshot.videoOrientationName ?? "nil",
                "videoAxis": snapshot.videoOrientationAxis ?? "nil",
                "rotationAngle": snapshot.videoRotationAngleDegrees.map { FrameDropDiagnostics.format($0, digits: 1) } ?? "nil",
                "rotationAngleAxis": snapshot.rotationAngleAxis ?? "nil",
                "frameWidth": String(snapshot.frameWidth),
                "frameHeight": String(snapshot.frameHeight),
                "frameAxis": snapshot.frameAxis
            ])
        )
    }

    private static func nativeVideoOrientationRaw(_ sampleBuffer: CMSampleBuffer) -> Int? {
        if let attachment = CMGetAttachment(
            sampleBuffer,
            key: kCGImagePropertyOrientation,
            attachmentModeOut: nil
        ) as? NSNumber {
            return attachment.intValue
        }

        if let sampleAttachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]],
           let attachment = sampleAttachments.first?[kCGImagePropertyOrientation] as? NSNumber {
            return attachment.intValue
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let attachment = CVBufferGetAttachment(
                pixelBuffer,
                kCGImagePropertyOrientation,
                nil
              ) as? NSNumber else {
            return nil
        }

        return attachment.intValue
    }

    private static func videoRotationAngleDegrees(for connection: AVCaptureConnection) -> Double? {
        if #available(macOS 14.0, *) {
            return Double(connection.videoRotationAngle)
        }

        return nil
    }

    private func resetNativeFrameDiagnostics(reason: String, descriptor: IOSScreenCaptureDeviceDescriptor?) {
        nativeDiagnosticsLock.lock()
        nativeDiagnosticsWindowStartedAt = Date()
        nativeDiagnosticsSamples = 0
        nativeDiagnosticsPublishedFrames = 0
        nativeDiagnosticsThrottledFrames = 0
        nativeDiagnosticsConversionFailures = 0
        nativeDiagnosticsDroppedSamples = 0
        nativeDiagnosticsTotalSamples = 0
        nativeDiagnosticsTotalPublishedFrames = 0
        nativeDiagnosticsTotalThrottledFrames = 0
        nativeDiagnosticsTotalConversionFailures = 0
        nativeDiagnosticsTotalDroppedSamples = 0
        nativeDiagnosticsLastSampleAt = nil
        nativeDiagnosticsLastPublishedAt = nil
        nativeDiagnosticsMaxSampleGapMilliseconds = 0
        nativeDiagnosticsMaxPublishGapMilliseconds = 0
        nativeDiagnosticsLock.unlock()

        let details = descriptor.map(descriptorDiagnosticDetails) ?? nativeDiagnosticDetails()
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "nativeAVCapture",
            event: "windowReset",
            reason: reason,
            details: details
        )
    }

    private func recordNativeFrameDiagnostics(
        sampleAt: Date,
        frameSize: CGSize,
        published: Bool,
        throttled: Bool,
        conversionFailed: Bool
    ) {
        var windowMetrics: [String: String]?
        var windowSeconds: TimeInterval = 0

        nativeDiagnosticsLock.lock()
        nativeDiagnosticsSamples += 1
        nativeDiagnosticsTotalSamples += 1

        if throttled {
            nativeDiagnosticsThrottledFrames += 1
            nativeDiagnosticsTotalThrottledFrames += 1
        }

        if conversionFailed {
            nativeDiagnosticsConversionFailures += 1
            nativeDiagnosticsTotalConversionFailures += 1
        }

        if let previousSampleAt = nativeDiagnosticsLastSampleAt {
            let gap = sampleAt.timeIntervalSince(previousSampleAt) * 1000
            nativeDiagnosticsMaxSampleGapMilliseconds = max(nativeDiagnosticsMaxSampleGapMilliseconds, gap)
        }
        nativeDiagnosticsLastSampleAt = sampleAt

        if published {
            nativeDiagnosticsPublishedFrames += 1
            nativeDiagnosticsTotalPublishedFrames += 1
            if let previousPublishedAt = nativeDiagnosticsLastPublishedAt {
                let gap = sampleAt.timeIntervalSince(previousPublishedAt) * 1000
                nativeDiagnosticsMaxPublishGapMilliseconds = max(nativeDiagnosticsMaxPublishGapMilliseconds, gap)
            }
            nativeDiagnosticsLastPublishedAt = sampleAt
        }

        let elapsed = sampleAt.timeIntervalSince(nativeDiagnosticsWindowStartedAt)
        if elapsed >= 1.0 {
            let safeElapsed = max(elapsed, 0.001)
            windowSeconds = elapsed
            windowMetrics = [
                "samples": String(nativeDiagnosticsSamples),
                "sampleFPS": FrameDropDiagnostics.format(Double(nativeDiagnosticsSamples) / safeElapsed),
                "publishedFrames": String(nativeDiagnosticsPublishedFrames),
                "publishedFPS": FrameDropDiagnostics.format(Double(nativeDiagnosticsPublishedFrames) / safeElapsed),
                "throttledFrames": String(nativeDiagnosticsThrottledFrames),
                "conversionFailures": String(nativeDiagnosticsConversionFailures),
                "avCaptureDroppedSamples": String(nativeDiagnosticsDroppedSamples),
                "maxSampleGapMs": FrameDropDiagnostics.format(nativeDiagnosticsMaxSampleGapMilliseconds),
                "maxPublishGapMs": FrameDropDiagnostics.format(nativeDiagnosticsMaxPublishGapMilliseconds),
                "frameWidth": String(Int(frameSize.width)),
                "frameHeight": String(Int(frameSize.height)),
                "totalSamples": String(nativeDiagnosticsTotalSamples),
                "totalPublishedFrames": String(nativeDiagnosticsTotalPublishedFrames),
                "totalThrottledFrames": String(nativeDiagnosticsTotalThrottledFrames),
                "totalConversionFailures": String(nativeDiagnosticsTotalConversionFailures),
                "totalDroppedSamples": String(nativeDiagnosticsTotalDroppedSamples)
            ]

            nativeDiagnosticsWindowStartedAt = sampleAt
            nativeDiagnosticsSamples = 0
            nativeDiagnosticsPublishedFrames = 0
            nativeDiagnosticsThrottledFrames = 0
            nativeDiagnosticsConversionFailures = 0
            nativeDiagnosticsDroppedSamples = 0
            nativeDiagnosticsMaxSampleGapMilliseconds = 0
            nativeDiagnosticsMaxPublishGapMilliseconds = 0
        }
        nativeDiagnosticsLock.unlock()

        if var windowMetrics {
            windowMetrics = nativeDiagnosticDetails(windowMetrics)
            FrameDropDiagnostics.shared.recordWindow(
                source: "nativeAVCapture",
                trigger: "sample",
                windowSeconds: windowSeconds,
                metrics: windowMetrics
            )
        }

        if conversionFailed {
            recordNativeDrop(
                stage: "cgimage-conversion",
                reason: "CIContext did not produce a CGImage for a publishable sample",
                details: [
                    "frameWidth": String(Int(frameSize.width)),
                    "frameHeight": String(Int(frameSize.height))
                ],
                countForWindow: false
            )
        }
    }

    private func recordNativeDrop(
        stage: String,
        reason: String,
        details: [String: String] = [:],
        countForWindow: Bool = true
    ) {
        var windowMetrics: [String: String]?
        var windowSeconds: TimeInterval = 0

        if countForWindow {
            nativeDiagnosticsLock.lock()
            nativeDiagnosticsDroppedSamples += 1
            nativeDiagnosticsTotalDroppedSamples += 1
            let now = Date()
            let elapsed = now.timeIntervalSince(nativeDiagnosticsWindowStartedAt)
            if elapsed >= 1.0 {
                let safeElapsed = max(elapsed, 0.001)
                windowSeconds = elapsed
                windowMetrics = [
                    "samples": String(nativeDiagnosticsSamples),
                    "sampleFPS": FrameDropDiagnostics.format(Double(nativeDiagnosticsSamples) / safeElapsed),
                    "publishedFrames": String(nativeDiagnosticsPublishedFrames),
                    "publishedFPS": FrameDropDiagnostics.format(Double(nativeDiagnosticsPublishedFrames) / safeElapsed),
                    "throttledFrames": String(nativeDiagnosticsThrottledFrames),
                    "conversionFailures": String(nativeDiagnosticsConversionFailures),
                    "avCaptureDroppedSamples": String(nativeDiagnosticsDroppedSamples),
                    "maxSampleGapMs": FrameDropDiagnostics.format(nativeDiagnosticsMaxSampleGapMilliseconds),
                    "maxPublishGapMs": FrameDropDiagnostics.format(nativeDiagnosticsMaxPublishGapMilliseconds),
                    "totalSamples": String(nativeDiagnosticsTotalSamples),
                    "totalPublishedFrames": String(nativeDiagnosticsTotalPublishedFrames),
                    "totalThrottledFrames": String(nativeDiagnosticsTotalThrottledFrames),
                    "totalConversionFailures": String(nativeDiagnosticsTotalConversionFailures),
                    "totalDroppedSamples": String(nativeDiagnosticsTotalDroppedSamples)
                ]

                nativeDiagnosticsWindowStartedAt = now
                nativeDiagnosticsSamples = 0
                nativeDiagnosticsPublishedFrames = 0
                nativeDiagnosticsThrottledFrames = 0
                nativeDiagnosticsConversionFailures = 0
                nativeDiagnosticsDroppedSamples = 0
                nativeDiagnosticsMaxSampleGapMilliseconds = 0
                nativeDiagnosticsMaxPublishGapMilliseconds = 0
            }
            nativeDiagnosticsLock.unlock()
        }

        FrameDropDiagnostics.shared.recordDrop(
            source: "nativeAVCapture",
            stage: stage,
            reason: reason,
            details: nativeDiagnosticDetails(details)
        )

        if var windowMetrics {
            windowMetrics = nativeDiagnosticDetails(windowMetrics)
            FrameDropDiagnostics.shared.recordWindow(
                source: "nativeAVCapture",
                trigger: "drop",
                windowSeconds: windowSeconds,
                metrics: windowMetrics
            )
        }
    }

    private func resetNativeAudioState(reason: String, descriptor: IOSScreenCaptureDeviceDescriptor?) {
        let policy = nativeUSBPolicySnapshot()
        runOnAudioQueueSync {
            nativeAudioWindowStartedAt = Date()
            nativeAudioWindowSampleBuffers = 0
            nativeAudioWindowScheduledBuffers = 0
            nativeAudioWindowDroppedBuffers = 0
            nativeAudioWindowFrames = 0
            nativeAudioWindowBytes = 0
            nativeAudioTotalSampleBuffers = 0
            nativeAudioTotalScheduledBuffers = 0
            nativeAudioTotalDroppedBuffers = 0
            nativeAudioTotalFrames = 0
            nativeAudioLastSampleAt = nil
            nativeAudioMaxArrivalGapMilliseconds = 0
            nativeAudioBufferedMilliseconds = 0
            nativeAudioFormatDescription = "none"
            nativeAudioPlayerStarted = false
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.audioState = .waiting
            self.audioStatusMessage = "USB Audio Waiting"
            self.isAudioPlaying = false
            self.audioSampleRate = 0
            self.audioChannelCount = 0
            self.receivedAudioSampleBufferCount = 0
            self.droppedAudioSampleBufferCount = 0
            self.audioBufferedMilliseconds = 0
            self.capturePolicyMessage = policy.reason
        }

        let details = descriptor.map(descriptorDiagnosticDetails) ?? nativeDiagnosticDetails()
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "nativeAVCaptureAudio",
            event: "audioStateReset",
            reason: reason,
            details: audioDiagnosticDetails(details.merging([
                "policyReason": policy.reason
            ]) { current, _ in current })
        )
    }

    private func runOnAudioQueueSync(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: audioQueueKey) == true {
            work()
        } else {
            audioQueue.sync(execute: work)
        }
    }

    private func audioDiagnosticDetails(_ details: [String: String] = [:]) -> [String: String] {
        var merged = nativeDiagnosticDetails(details)
        merged["audioState"] = merged["audioState"] ?? audioState.diagnosticDescription
        merged["audioSampleRate"] = merged["audioSampleRate"] ?? FrameDropDiagnostics.format(audioSampleRate, digits: 1)
        merged["audioChannelCount"] = merged["audioChannelCount"] ?? String(audioChannelCount)
        merged["audioFormat"] = merged["audioFormat"] ?? nativeAudioFormatDescription
        return merged
    }

    private func stopNativeAudioPlayback(reason: String, publishAsyncState: Bool = true) {
        runOnAudioQueueSync {
            stopNativeAudioPlaybackLocked(reason: reason, publishAsyncState: publishAsyncState)
        }
    }

    private func stopNativeAudioPlaybackLocked(reason: String, publishAsyncState: Bool = true) {
        SpecchioLogger.iosScreenCapture.info("[NativeAudio] playback stop reason=\(reason, privacy: .public) enginePresent=\(self.nativeAudioEngine != nil) playerPresent=\(self.nativeAudioPlayer != nil) bufferedMs=\(self.nativeAudioBufferedMilliseconds)")
        nativeAudioPlayer?.stop()
        nativeAudioEngine?.stop()
        if let nativeAudioPlayer, let nativeAudioEngine {
            nativeAudioEngine.detach(nativeAudioPlayer)
        }
        nativeAudioPlayer = nil
        nativeAudioEngine = nil
        nativeAudioFormat = nil
        nativeAudioPlayerStarted = false
        nativeAudioBufferedMilliseconds = 0
        nativeAudioFormatDescription = "none"

        FrameDropDiagnostics.shared.recordLifecycle(
            source: "nativeAVCaptureAudio",
            event: "playbackStopped",
            reason: reason,
            details: audioDiagnosticDetails()
        )

        guard publishAsyncState else {
            SpecchioLogger.iosScreenCapture.info("[NativeAudio] playback stop skipped async state publish reason=\(reason, privacy: .public) branch=deinit-safe")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isAudioPlaying = false
            self.audioBufferedMilliseconds = 0
            if self.audioState != .off {
                self.audioState = .waiting
                self.audioStatusMessage = "USB Audio Waiting"
            }
        }
    }

    private func rebuildNativeAudioPlaybackLocked(
        playbackFormat: AVAudioFormat,
        sourceFormat: NativeAVCaptureAudioSourceFormat,
        reason: String
    ) {
        stopNativeAudioPlaybackLocked(reason: "format change: \(reason)")

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        do {
            try engine.start()
            nativeAudioEngine = engine
            nativeAudioPlayer = player
            nativeAudioFormat = playbackFormat
            nativeAudioPlayerStarted = false
            nativeAudioBufferedMilliseconds = 0
            nativeAudioFormatDescription = sourceFormat.diagnosticDescription
            SpecchioLogger.iosScreenCapture.info("[NativeAudio] playback engine started reason=\(reason, privacy: .public) sourceFormat=\(sourceFormat.diagnosticDescription, privacy: .public) playbackCommonFormat=\(playbackFormat.commonFormat.rawValue) playbackInterleaved=\(playbackFormat.isInterleaved)")
            FrameDropDiagnostics.shared.recordLifecycle(
                source: "nativeAVCaptureAudio",
                event: "playbackStarted",
                reason: reason,
                details: audioDiagnosticDetails([
                    "sourceFormat": sourceFormat.diagnosticDescription,
                    "playbackCommonFormat": String(playbackFormat.commonFormat.rawValue),
                    "playbackInterleaved": String(playbackFormat.isInterleaved)
                ])
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.audioState = .waiting
                self.audioStatusMessage = "USB Audio Waiting"
                self.audioSampleRate = sourceFormat.sampleRate
                self.audioChannelCount = sourceFormat.channelCount
            }
        } catch {
            nativeAudioEngine = nil
            nativeAudioPlayer = nil
            nativeAudioFormat = nil
            nativeAudioPlayerStarted = false
            nativeAudioBufferedMilliseconds = 0
            SpecchioLogger.iosScreenCapture.error("[NativeAudio] playback engine start failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            FrameDropDiagnostics.shared.recordLifecycle(
                source: "nativeAVCaptureAudio",
                event: "playbackStartFailed",
                reason: error.localizedDescription,
                details: audioDiagnosticDetails([
                    "sourceFormat": sourceFormat.diagnosticDescription
                ]),
                severity: "error"
            )
            DispatchQueue.main.async { [weak self] in
                self?.audioState = .error
                self?.audioStatusMessage = "USB Audio Error"
                self?.isAudioPlaying = false
            }
        }
    }

    private func handleNativeAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, connection: AVCaptureConnection) {
        let receivedAt = Date()

        guard captureSession != nil else {
            recordNativeAudioDrop(
                stage: "sample-buffer",
                reason: "audio sample ignored because capture session is gone",
                details: ["connectionEnabled": String(connection.isEnabled)]
            )
            return
        }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            recordNativeAudioDrop(
                stage: "format",
                reason: "audio sample missing format description",
                details: ["connectionEnabled": String(connection.isEnabled)]
            )
            return
        }

        guard let sourceFormat = NativeAVCaptureAudioSourceFormat(formatDescription: formatDescription) else {
            let mediaType = CMFormatDescriptionGetMediaType(formatDescription)
            let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription)
            recordNativeAudioDrop(
                stage: "format",
                reason: "unsupported or invalid audio format description",
                details: [
                    "mediaType": String(describing: mediaType),
                    "mediaSubType": String(describing: mediaSubType)
                ]
            )
            return
        }

        guard sourceFormat.isFloat || (sourceFormat.isSignedInteger && sourceFormat.bitsPerChannel == 16) else {
            recordNativeAudioDrop(
                stage: "format",
                reason: "unsupported audio PCM sample format",
                details: ["sourceFormat": sourceFormat.diagnosticDescription]
            )
            return
        }

        guard let playbackFormat = sourceFormat.playbackFormat else {
            recordNativeAudioDrop(
                stage: "format",
                reason: "failed to create AVAudioFormat for native audio",
                details: ["sourceFormat": sourceFormat.diagnosticDescription]
            )
            return
        }

        let shouldRebuild = nativeAudioFormat == nil
            || nativeAudioPlayer == nil
            || nativeAudioEngine == nil
            || nativeAudioFormatDescription != sourceFormat.diagnosticDescription

        if shouldRebuild {
            SpecchioLogger.iosScreenCapture.info("[NativeAudio] rebuilding playback pipeline sourceFormat=\(sourceFormat.diagnosticDescription, privacy: .public)")
            rebuildNativeAudioPlaybackLocked(
                playbackFormat: playbackFormat,
                sourceFormat: sourceFormat,
                reason: "first sample or format changed"
            )
        }

        guard let player = nativeAudioPlayer, let activePlaybackFormat = nativeAudioFormat else {
            recordNativeAudioDrop(
                stage: "playback",
                reason: "audio playback pipeline unavailable after rebuild",
                details: ["sourceFormat": sourceFormat.diagnosticDescription]
            )
            return
        }

        guard let buffer = makeNativeAudioPCMBuffer(
            sampleBuffer: sampleBuffer,
            sourceFormat: sourceFormat,
            playbackFormat: activePlaybackFormat
        ) else {
            recordNativeAudioDrop(
                stage: "buffer-copy",
                reason: "failed to copy audio CMSampleBuffer into AVAudioPCMBuffer",
                details: ["sourceFormat": sourceFormat.diagnosticDescription]
            )
            return
        }

        let durationMilliseconds = Double(buffer.frameLength) / max(activePlaybackFormat.sampleRate, 1) * 1000.0
        if nativeAudioBufferedMilliseconds + durationMilliseconds > nativeAudioMaximumBufferedMilliseconds {
            SpecchioLogger.iosScreenCapture.warning("[NativeAudio] overbuffer drop action=drop-incoming bufferedMs=\(self.nativeAudioBufferedMilliseconds) incomingDurationMs=\(durationMilliseconds) capMs=\(self.nativeAudioMaximumBufferedMilliseconds)")
            recordNativeAudioDrop(
                stage: "playback",
                reason: "audio overbuffer cap",
                details: [
                    "durationMs": FrameDropDiagnostics.format(durationMilliseconds),
                    "bufferedMs": FrameDropDiagnostics.format(nativeAudioBufferedMilliseconds),
                    "capMs": FrameDropDiagnostics.format(nativeAudioMaximumBufferedMilliseconds)
                ]
            )
            return
        }

        nativeAudioBufferedMilliseconds += durationMilliseconds
        recordNativeAudioSample(
            receivedAt: receivedAt,
            sourceFormat: sourceFormat,
            frameCount: Int(buffer.frameLength),
            byteCount: nativeAudioByteCount(sampleBuffer: sampleBuffer, sourceFormat: sourceFormat),
            durationMilliseconds: durationMilliseconds
        )

        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.audioQueue.async {
                guard let self else { return }
                self.nativeAudioBufferedMilliseconds = max(0, self.nativeAudioBufferedMilliseconds - durationMilliseconds)
                let bufferedMilliseconds = self.nativeAudioBufferedMilliseconds
                DispatchQueue.main.async { [weak self] in
                    self?.audioBufferedMilliseconds = bufferedMilliseconds
                }
            }
        }

        if !nativeAudioPlayerStarted, nativeAudioBufferedMilliseconds >= nativeAudioTargetBufferedMilliseconds {
            player.play()
            nativeAudioPlayerStarted = true
            SpecchioLogger.iosScreenCapture.info("[NativeAudio] player started bufferedMs=\(self.nativeAudioBufferedMilliseconds) targetMs=\(self.nativeAudioTargetBufferedMilliseconds)")
        } else if nativeAudioPlayerStarted, !player.isPlaying {
            player.play()
            SpecchioLogger.iosScreenCapture.info("[NativeAudio] player resumed bufferedMs=\(self.nativeAudioBufferedMilliseconds)")
        } else {
            SpecchioLogger.iosScreenCapture.debug("[NativeAudio] sample scheduled frames=\(buffer.frameLength) bufferedMs=\(self.nativeAudioBufferedMilliseconds) started=\(self.nativeAudioPlayerStarted)")
        }

        let isPlayerStarted = nativeAudioPlayerStarted
        let bufferedMilliseconds = nativeAudioBufferedMilliseconds
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.audioState = isPlayerStarted ? .live : .waiting
            self.audioStatusMessage = isPlayerStarted ? "USB Audio Live" : "USB Audio Waiting"
            self.isAudioPlaying = isPlayerStarted
            self.audioBufferedMilliseconds = bufferedMilliseconds
        }
    }

    private func handleNativeAudioDroppedSampleBuffer(_ sampleBuffer: CMSampleBuffer, connection: AVCaptureConnection) {
        var details = [
            "connectionEnabled": String(connection.isEnabled)
        ]
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if presentationTimeStamp.isValid {
            details["presentationTimeSeconds"] = FrameDropDiagnostics.format(presentationTimeStamp.seconds, digits: 4)
        }
        recordNativeAudioDrop(
            stage: "avcapture-output",
            reason: "AVCaptureAudioDataOutput didDrop sample",
            details: details
        )
    }

    private func makeNativeAudioPCMBuffer(
        sampleBuffer: CMSampleBuffer,
        sourceFormat: NativeAVCaptureAudioSourceFormat,
        playbackFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else {
            SpecchioLogger.iosScreenCapture.warning("[NativeAudio] buffer copy branch=no-samples")
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            SpecchioLogger.iosScreenCapture.warning("[NativeAudio] buffer allocation failed frames=\(frameCount)")
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let channelData = buffer.floatChannelData else {
            SpecchioLogger.iosScreenCapture.warning("[NativeAudio] buffer copy branch=missing-float-channel-data")
            return nil
        }

        let maximumBuffers = sourceFormat.isNonInterleaved ? sourceFormat.channelCount : 1
        let audioBufferList = AudioBufferList.allocate(maximumBuffers: max(1, maximumBuffers))
        defer { free(audioBufferList.unsafeMutablePointer) }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: max(1, maximumBuffers)),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            SpecchioLogger.iosScreenCapture.warning("[NativeAudio] buffer list copy failed status=\(status) sourceFormat=\(sourceFormat.diagnosticDescription, privacy: .public)")
            return nil
        }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList.unsafeMutablePointer)
        if sourceFormat.isFloat {
            return copyNativeAudioFloat32(
                sourceBuffers: sourceBuffers,
                sourceFormat: sourceFormat,
                frameCount: frameCount,
                destinationChannelData: channelData
            ) ? buffer : nil
        }

        return copyNativeAudioInt16(
            sourceBuffers: sourceBuffers,
            sourceFormat: sourceFormat,
            frameCount: frameCount,
            destinationChannelData: channelData
        ) ? buffer : nil
    }

    private func copyNativeAudioFloat32(
        sourceBuffers: UnsafeMutableAudioBufferListPointer,
        sourceFormat: NativeAVCaptureAudioSourceFormat,
        frameCount: Int,
        destinationChannelData: UnsafePointer<UnsafeMutablePointer<Float>>
    ) -> Bool {
        guard sourceFormat.bitsPerChannel == 32 else {
            SpecchioLogger.iosScreenCapture.warning("[NativeAudio] float copy rejected bitsPerChannel=\(sourceFormat.bitsPerChannel)")
            return false
        }

        return copyNativeAudioSamples(
            sourceBuffers: sourceBuffers,
            sourceFormat: sourceFormat,
            frameCount: frameCount,
            bytesPerSample: MemoryLayout<Float>.size,
            destinationChannelData: destinationChannelData
        ) { rawPointer, byteOffset in
            rawPointer.loadUnaligned(fromByteOffset: byteOffset, as: Float.self)
        }
    }

    private func copyNativeAudioInt16(
        sourceBuffers: UnsafeMutableAudioBufferListPointer,
        sourceFormat: NativeAVCaptureAudioSourceFormat,
        frameCount: Int,
        destinationChannelData: UnsafePointer<UnsafeMutablePointer<Float>>
    ) -> Bool {
        guard sourceFormat.bitsPerChannel == 16 else {
            SpecchioLogger.iosScreenCapture.warning("[NativeAudio] int16 copy rejected bitsPerChannel=\(sourceFormat.bitsPerChannel)")
            return false
        }

        return copyNativeAudioSamples(
            sourceBuffers: sourceBuffers,
            sourceFormat: sourceFormat,
            frameCount: frameCount,
            bytesPerSample: MemoryLayout<Int16>.size,
            destinationChannelData: destinationChannelData
        ) { rawPointer, byteOffset in
            Float(rawPointer.loadUnaligned(fromByteOffset: byteOffset, as: Int16.self)) / 32768.0
        }
    }

    private func copyNativeAudioSamples(
        sourceBuffers: UnsafeMutableAudioBufferListPointer,
        sourceFormat: NativeAVCaptureAudioSourceFormat,
        frameCount: Int,
        bytesPerSample: Int,
        destinationChannelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        loadSample: (UnsafeRawPointer, Int) -> Float
    ) -> Bool {
        let channelCount = sourceFormat.channelCount
        guard channelCount > 0 else {
            SpecchioLogger.iosScreenCapture.warning("[NativeAudio] sample copy rejected reason=no-channels")
            return false
        }

        if sourceFormat.isNonInterleaved {
            guard sourceBuffers.count >= channelCount else {
                SpecchioLogger.iosScreenCapture.warning("[NativeAudio] sample copy rejected reason=missing-noninterleaved-buffers buffers=\(sourceBuffers.count) channels=\(channelCount)")
                return false
            }

            for channelIndex in 0..<channelCount {
                let sourceBuffer = sourceBuffers[channelIndex]
                let expectedBytes = frameCount * bytesPerSample
                guard Int(sourceBuffer.mDataByteSize) >= expectedBytes,
                      let dataPointer = sourceBuffer.mData else {
                    SpecchioLogger.iosScreenCapture.warning("[NativeAudio] sample copy rejected reason=noninterleaved-byte-count channel=\(channelIndex) expected=\(expectedBytes) actual=\(sourceBuffer.mDataByteSize)")
                    return false
                }
                let rawPointer = UnsafeRawPointer(dataPointer)
                for frameIndex in 0..<frameCount {
                    let byteOffset = frameIndex * bytesPerSample
                    destinationChannelData[channelIndex][frameIndex] = loadSample(rawPointer, byteOffset)
                }
            }
            return true
        }

        guard let sourceBuffer = sourceBuffers.first,
              let dataPointer = sourceBuffer.mData else {
            SpecchioLogger.iosScreenCapture.warning("[NativeAudio] sample copy rejected reason=missing-interleaved-buffer")
            return false
        }
        let expectedBytes = frameCount * channelCount * bytesPerSample
        guard Int(sourceBuffer.mDataByteSize) >= expectedBytes else {
            SpecchioLogger.iosScreenCapture.warning("[NativeAudio] sample copy rejected reason=interleaved-byte-count expected=\(expectedBytes) actual=\(sourceBuffer.mDataByteSize)")
            return false
        }

        let rawPointer = UnsafeRawPointer(dataPointer)
        for frameIndex in 0..<frameCount {
            for channelIndex in 0..<channelCount {
                let sampleIndex = frameIndex * channelCount + channelIndex
                let byteOffset = sampleIndex * bytesPerSample
                destinationChannelData[channelIndex][frameIndex] = loadSample(rawPointer, byteOffset)
            }
        }
        return true
    }

    private func nativeAudioByteCount(
        sampleBuffer: CMSampleBuffer,
        sourceFormat: NativeAVCaptureAudioSourceFormat
    ) -> Int {
        CMSampleBufferGetNumSamples(sampleBuffer)
            * sourceFormat.channelCount
            * sourceFormat.bytesPerSample
    }

    private func recordNativeAudioSample(
        receivedAt: Date,
        sourceFormat: NativeAVCaptureAudioSourceFormat,
        frameCount: Int,
        byteCount: Int,
        durationMilliseconds: Double
    ) {
        nativeAudioWindowSampleBuffers += 1
        nativeAudioWindowScheduledBuffers += 1
        nativeAudioWindowFrames += frameCount
        nativeAudioWindowBytes += byteCount
        nativeAudioTotalSampleBuffers += 1
        nativeAudioTotalScheduledBuffers += 1
        nativeAudioTotalFrames += frameCount

        if let nativeAudioLastSampleAt {
            let gap = receivedAt.timeIntervalSince(nativeAudioLastSampleAt) * 1000
            nativeAudioMaxArrivalGapMilliseconds = max(nativeAudioMaxArrivalGapMilliseconds, gap)
        }
        nativeAudioLastSampleAt = receivedAt

        SpecchioLogger.iosScreenCapture.debug("[NativeAudio] sample received frames=\(frameCount) bytes=\(byteCount) durationMs=\(durationMilliseconds) bufferedMs=\(self.nativeAudioBufferedMilliseconds) sourceFormat=\(sourceFormat.diagnosticDescription, privacy: .public)")
        publishNativeAudioCounters(sourceFormat: sourceFormat)
        logNativeAudioWindowIfNeeded(now: receivedAt, trigger: "sample")
    }

    private func recordNativeAudioDrop(
        stage: String,
        reason: String,
        details: [String: String] = [:]
    ) {
        nativeAudioWindowDroppedBuffers += 1
        nativeAudioTotalDroppedBuffers += 1
        SpecchioLogger.iosScreenCapture.warning("[NativeAudio] drop stage=\(stage, privacy: .public) reason=\(reason, privacy: .public)")
        FrameDropDiagnostics.shared.recordDrop(
            source: "nativeAVCaptureAudio",
            stage: stage,
            reason: reason,
            details: audioDiagnosticDetails(details)
        )
        publishNativeAudioCounters()
        logNativeAudioWindowIfNeeded(now: Date(), trigger: "drop")
    }

    private func publishNativeAudioCounters(sourceFormat: NativeAVCaptureAudioSourceFormat? = nil) {
        let bufferedMilliseconds = nativeAudioBufferedMilliseconds
        let received = nativeAudioTotalSampleBuffers
        let dropped = nativeAudioTotalDroppedBuffers
        let sampleRate = sourceFormat?.sampleRate ?? nativeAudioFormat?.sampleRate ?? 0
        let channelCount = sourceFormat?.channelCount ?? Int(nativeAudioFormat?.channelCount ?? 0)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.audioBufferedMilliseconds = bufferedMilliseconds
            self.receivedAudioSampleBufferCount = received
            self.droppedAudioSampleBufferCount = dropped
            if sampleRate > 0 {
                self.audioSampleRate = sampleRate
            }
            if channelCount > 0 {
                self.audioChannelCount = channelCount
            }
        }
    }

    private func logNativeAudioWindowIfNeeded(now: Date, trigger: String) {
        let elapsed = now.timeIntervalSince(nativeAudioWindowStartedAt)
        guard elapsed >= 1.0 else { return }

        let safeElapsed = max(elapsed, 0.001)
        let framesPerSecond = Double(nativeAudioWindowFrames) / safeElapsed
        let kbps = Double(nativeAudioWindowBytes) / 1024.0 / safeElapsed
        let metrics = audioDiagnosticDetails([
            "trigger": trigger,
            "sampleBuffers": String(nativeAudioWindowSampleBuffers),
            "scheduledBuffers": String(nativeAudioWindowScheduledBuffers),
            "droppedBuffers": String(nativeAudioWindowDroppedBuffers),
            "frames": String(nativeAudioWindowFrames),
            "audioFPS": FrameDropDiagnostics.format(framesPerSecond),
            "audioKBps": FrameDropDiagnostics.format(kbps, digits: 1),
            "maxArrivalGapMs": FrameDropDiagnostics.format(nativeAudioMaxArrivalGapMilliseconds),
            "bufferedMs": FrameDropDiagnostics.format(nativeAudioBufferedMilliseconds),
            "totalSampleBuffers": String(nativeAudioTotalSampleBuffers),
            "totalScheduledBuffers": String(nativeAudioTotalScheduledBuffers),
            "totalDroppedBuffers": String(nativeAudioTotalDroppedBuffers),
            "totalFrames": String(nativeAudioTotalFrames)
        ])

        SpecchioLogger.iosScreenCapture.info("[NativeAudio] metrics trigger=\(trigger, privacy: .public) windowSeconds=\(String(format: "%.2f", safeElapsed), privacy: .public) sampleBuffers=\(self.nativeAudioWindowSampleBuffers) scheduledBuffers=\(self.nativeAudioWindowScheduledBuffers) droppedBuffers=\(self.nativeAudioWindowDroppedBuffers) audioFPS=\(String(format: "%.2f", framesPerSecond), privacy: .public) audioKBps=\(String(format: "%.1f", kbps), privacy: .public) maxArrivalGapMs=\(String(format: "%.2f", self.nativeAudioMaxArrivalGapMilliseconds), privacy: .public) bufferedMs=\(String(format: "%.2f", self.nativeAudioBufferedMilliseconds), privacy: .public)")
        FrameDropDiagnostics.shared.recordWindow(
            source: "nativeAVCaptureAudio",
            trigger: trigger,
            windowSeconds: safeElapsed,
            metrics: metrics
        )

        nativeAudioWindowStartedAt = now
        nativeAudioWindowSampleBuffers = 0
        nativeAudioWindowScheduledBuffers = 0
        nativeAudioWindowDroppedBuffers = 0
        nativeAudioWindowFrames = 0
        nativeAudioWindowBytes = 0
        nativeAudioMaxArrivalGapMilliseconds = 0
    }

    private func evaluateStaleHealth() {
        guard isCapturing else { return }
        let now = Date()
        let frameAge = lastFrameReceivedAt.map { now.timeIntervalSince($0) }
            ?? captureStartedAt.map { now.timeIntervalSince($0) }
            ?? 0

        guard frameAge >= staleThresholdSeconds else { return }

        SpecchioLogger.iosScreenCapture.info("[Manager] stale detection fired age=\(frameAge) retryAttempted=\(self.restartAttemptedForCurrentDevice)")
        FrameDropDiagnostics.shared.recordDrop(
            source: "nativeAVCapture",
            stage: "stale-detection",
            reason: "no native frames before stale threshold",
            details: nativeDiagnosticDetails([
                "frameAgeSeconds": FrameDropDiagnostics.format(frameAge),
                "retryAttempted": String(restartAttemptedForCurrentDevice)
            ])
        )
        streamHealth = .stale(lastFrameAge: frameAge)
        statusMessage = "USB native capture stalled"

        if restartAttemptedForCurrentDevice {
            fail(reason: "USB native capture stale after restart", trigger: "stale detection")
        } else {
            restartAfterFailure(reason: "stale for \(String(format: "%.1f", frameAge))s", trigger: "stale detection")
        }
    }

    private func handleStartFailure(_ reason: String, trigger: String) {
        SpecchioLogger.iosScreenCapture.error("[Manager] session start failed trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "nativeAVCapture",
            event: "startFailed",
            reason: reason,
            details: nativeDiagnosticDetails(["trigger": trigger]),
            severity: "error"
        )
        restartAfterFailure(reason: reason, trigger: "start failure")
    }

    private func handleRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        let reason = error?.localizedDescription ?? "AVCaptureSession runtime error"
        SpecchioLogger.iosScreenCapture.error("[Manager] runtime error reason=\(reason, privacy: .public)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "nativeAVCapture",
            event: "runtimeError",
            reason: reason,
            details: nativeDiagnosticDetails(),
            severity: "error"
        )
        restartAfterFailure(reason: reason, trigger: "runtime error")
    }

    private func handleInterruption(_ notification: Notification) {
        let reason = notification.userInfo.map { "AVCaptureSession interrupted userInfo=\($0)" }
            ?? "AVCaptureSession interrupted"
        SpecchioLogger.iosScreenCapture.info("[Manager] session interrupted reason=\(reason, privacy: .public)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "nativeAVCapture",
            event: "interrupted",
            reason: reason,
            details: nativeDiagnosticDetails()
        )
        streamHealth = .interrupted(reason: reason)
        statusMessage = "USB native capture interrupted"
    }

    private func handleSelectedDeviceDisconnected(deviceName: String) {
        let reason = "\(deviceName) disconnected"
        SpecchioLogger.iosScreenCapture.info("[Manager] selected device disconnected reason=\(reason, privacy: .public)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "nativeAVCapture",
            event: "deviceDisconnected",
            reason: reason,
            details: nativeDiagnosticDetails()
        )
        streamHealth = .disconnected(reason: reason)
        statusMessage = "USB native capture disconnected"
        fail(
            reason: reason,
            trigger: "device disconnect",
            health: .disconnected(reason: reason)
        )
    }

    private func restartAfterFailure(reason: String, trigger: String) {
        guard !isStoppingIntentionally else {
            SpecchioLogger.iosScreenCapture.info("[Manager] restart skipped trigger=\(trigger, privacy: .public) reason=intentional-stop failure=\(reason, privacy: .public)")
            return
        }

        guard let selectedDescriptor else {
            fail(reason: reason, trigger: "\(trigger) no selected descriptor")
            return
        }

        guard !restartAttemptedForCurrentDevice else {
            fail(reason: reason, trigger: "\(trigger) retry already attempted")
            return
        }

        restartAttemptedForCurrentDevice = true
        SpecchioLogger.iosScreenCapture.info("[Manager] restarting once trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public) selected=\(selectedDescriptor.logSummary, privacy: .public)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "nativeAVCapture",
            event: "restartAttempt",
            reason: reason,
            details: nativeDiagnosticDetails(["trigger": trigger])
        )
        startCapture(deviceDescriptor: selectedDescriptor, trigger: "retry after \(trigger): \(reason)", isRetry: true)
    }

    private func fail(
        reason: String,
        trigger: String,
        health: IOSScreenCaptureHealth? = nil,
        clearFrame: Bool = true
    ) {
        guard !isStoppingIntentionally else {
            SpecchioLogger.iosScreenCapture.info("[Manager] fail ignored trigger=\(trigger, privacy: .public) reason=intentional-stop failure=\(reason, privacy: .public)")
            return
        }

        SpecchioLogger.iosScreenCapture.error("[Manager] stream failed trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public) clearFrame=\(clearFrame)")
        FrameDropDiagnostics.shared.recordLifecycle(
            source: "nativeAVCapture",
            event: "streamFailed",
            reason: reason,
            details: nativeDiagnosticDetails([
                "trigger": trigger,
                "clearFrame": String(clearFrame)
            ]),
            severity: "error"
        )
        lastError = reason
        statusMessage = reason
        streamHealth = health ?? .failed(reason: reason)
        tearDownSession(reason: "failure \(trigger): \(reason)", publishIdle: false, clearFrame: clearFrame)
        onStreamFailed?(reason)
    }
}

extension IOSScreenCaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output is AVCaptureAudioDataOutput {
            handleNativeAudioSampleBuffer(sampleBuffer, connection: connection)
            return
        }

        incrementFPSCounter()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            if !firstFrameLogged {
                SpecchioLogger.iosScreenCapture.info("[Manager] sample buffer without image buffer before first frame")
            }
            recordNativeDrop(
                stage: "sample-buffer",
                reason: "CMSampleBuffer did not contain an image buffer"
            )
            return
        }

        let now = Date()
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let frameSize = CGSize(width: width, height: height)
        let orientationSnapshot = makeNativeVideoOrientationSnapshot(
            sampleBuffer: sampleBuffer,
            connection: connection,
            frameSize: frameSize
        )

        let policy = nativeUSBPolicySnapshot()
        let shouldPublishFrame: Bool
        if let framePublishIntervalSeconds = policy.framePublishIntervalSeconds {
            shouldPublishFrame = now.timeIntervalSince(lastPublishedFrameAt) >= framePublishIntervalSeconds
        } else {
            nativePolicyLock.lock()
            let shouldLogZeroTarget = !nativeZeroFPSTargetLogged
            nativeZeroFPSTargetLogged = true
            nativePolicyLock.unlock()
            if shouldLogZeroTarget {
                SpecchioLogger.iosScreenCapture.info("[NativeUSBPolicy] video publish paused reason=zero-target-fps configuredFPS=\(policy.configuredTargetFramesPerSecond) effectiveFPS=\(policy.effectiveTargetFramesPerSecond)")
                FrameDropDiagnostics.shared.recordLifecycle(
                    source: "nativeAVCapture",
                    event: "videoPublishPaused",
                    reason: "zero target FPS",
                    details: nativeDiagnosticDetails([
                        "configuredTargetFPS": FrameDropDiagnostics.format(policy.configuredTargetFramesPerSecond),
                        "effectiveTargetFPS": FrameDropDiagnostics.format(policy.effectiveTargetFramesPerSecond)
                    ])
                )
            }
            shouldPublishFrame = false
        }
        let cgImage: CGImage?
        if shouldPublishFrame {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            cgImage = ciContext.createCGImage(
                ciImage,
                from: CGRect(x: 0, y: 0, width: width, height: height)
            )
            lastPublishedFrameAt = now
        } else {
            cgImage = nil
        }
        let conversionFailed = shouldPublishFrame && cgImage == nil
        recordNativeFrameDiagnostics(
            sampleAt: now,
            frameSize: frameSize,
            published: cgImage != nil,
            throttled: !shouldPublishFrame,
            conversionFailed: conversionFailed
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.captureSession != nil else { return }

            self.updateNativeVideoOrientation(orientationSnapshot)

            if !self.firstFrameLogged {
                self.firstFrameLogged = true
                SpecchioLogger.iosScreenCapture.info("[Manager] first frame received width=\(width) height=\(height) device=\(self.diagnosticDeviceName ?? "unknown", privacy: .public) mediaType=\(self.diagnosticMediaType ?? "unknown", privacy: .public)")
                self.enableDeferredNativeAudioConnectionIfNeeded(reason: "first video frame received")
            }

            self.lastFrameReceivedAt = now
            self.lastFrameSize = frameSize
            self.statusMessage = "USB native capture live"
            self.streamHealth = .live

            if let cgImage {
                self.currentFrame = cgImage
            } else if shouldPublishFrame {
                SpecchioLogger.iosScreenCapture.info("[Manager] frame conversion failed width=\(width) height=\(height)")
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output is AVCaptureAudioDataOutput {
            handleNativeAudioDroppedSampleBuffer(sampleBuffer, connection: connection)
            return
        }

        SpecchioLogger.iosScreenCapture.debug("[Manager] dropped video sample")
        var details = [
            "connectionEnabled": String(connection.isEnabled)
        ]
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if presentationTimeStamp.isValid {
            details["presentationTimeSeconds"] = FrameDropDiagnostics.format(presentationTimeStamp.seconds, digits: 4)
        }
        recordNativeDrop(
            stage: "avcapture-output",
            reason: "AVCaptureVideoDataOutput didDrop sample",
            details: details
        )
    }
}
