import CoreMedia
import Foundation
import os.log
import QuartzCore
import ReplayKit
import UIKit

final class SampleHandler: RPBroadcastSampleHandler {
    private struct ReplayKitBroadcastPolicy {
        static let fallbackFramesPerSecond: Double = 15
        static let fallbackH264FramesPerSecond: Double = 30

        let isKnown: Bool
        let isPremium: Bool
        let transport: ReplayKitTransport
        let usbCableAttached: Bool
        let usbGateReason: String
        let jpegFramesPerSecond: Double
        let h264FramesPerSecond: Double
        let reason: String

        var signature: String {
            "\(isKnown)-\(isPremium)-\(transport.rawValue)-\(usbCableAttached)-\(usbGateReason)-\(jpegFramesPerSecond)-\(h264FramesPerSecond)-\(reason)"
        }

        func maxFramesPerSecond(for preference: ReplayKitVideoCodecPreference) -> Double {
            switch preference {
            case .jpegOnly:
                return jpegFramesPerSecond
            case .h264Preferred:
                return h264FramesPerSecond
            }
        }

        static func resolve(sharedDefaults: UserDefaults?, transport: ReplayKitTransport) -> ReplayKitBroadcastPolicy {
            let policyIsKnown = sharedDefaults?.object(forKey: "replayKitPolicyPremium") != nil
            let isPremium = sharedDefaults?.bool(forKey: "replayKitPolicyPremium") ?? false
            let usbCableAttached = sharedDefaults?.bool(forKey: "replayKitPolicyUSBCableAttached") ?? false
            let usbGateReason = sharedDefaults?.string(forKey: "replayKitPolicyUSBReason") ?? "legacy transport metadata missing"
            let storedJPEGFPS = sharedDefaults?.double(forKey: "replayKitPolicyJPEGFPS") ?? 0
            let storedH264FPS = sharedDefaults?.double(forKey: "replayKitPolicyH264FPS") ?? 0
            let jpegFPS = storedJPEGFPS.isFinite && storedJPEGFPS > 0 ? storedJPEGFPS : fallbackFramesPerSecond
            let h264FPS = storedH264FPS.isFinite && storedH264FPS > 0 ? storedH264FPS : fallbackH264FramesPerSecond

            guard policyIsKnown else {
                return ReplayKitBroadcastPolicy(
                    isKnown: false,
                    isPremium: false,
                    transport: transport,
                    usbCableAttached: false,
                    usbGateReason: "policy missing",
                    jpegFramesPerSecond: fallbackFramesPerSecond,
                    h264FramesPerSecond: fallbackH264FramesPerSecond,
                    reason: "policy missing; ReplayKit media allowed; Mac receiver handles license"
                )
            }

            return ReplayKitBroadcastPolicy(
                isKnown: true,
                isPremium: isPremium,
                transport: transport,
                usbCableAttached: usbCableAttached,
                usbGateReason: usbGateReason,
                jpegFramesPerSecond: jpegFPS,
                h264FramesPerSecond: h264FPS,
                reason: "ReplayKit media allowed; Mac receiver handles license; legacy transport metadata retained"
            )
        }
    }

    private struct VideoSampleDecision {
        let receivedVideoFrames: Int
        let sentVideoFrames: Int
        let shouldSendFirstFrameEvent: Bool
        let firstFrameEventSequence: Int?
        let firstFrameReason: String
        let isBroadcastPaused: Bool
        let wasVideoStalled: Bool
    }

    private struct FrameReservation {
        let sequenceNumber: UInt64
        let receivedVideoFrames: Int
    }

    private struct AudioReservation {
        let packetSequenceNumber: UInt64
        let formatSequence: Int
        let receivedAppAudioSamples: Int
        let sentAudioPackets: Int
        let droppedAudioPackets: Int
        let unsupportedAudioSamples: Int
        let isBroadcastPaused: Bool
    }

    private struct AudioCountersSnapshot {
        let sequence: Int
        let receivedAppAudioSamples: Int
        let sentAudioPackets: Int
        let droppedAudioPackets: Int
        let unsupportedAudioSamples: Int
    }

    private struct HeartbeatSnapshot {
        let sequence: Int
        let receivedVideoFrames: Int
        let sentVideoFrames: Int
        let isBroadcastPaused: Bool
        let isVideoStalled: Bool
        let lastVideoSampleAgeSeconds: Double?
        let videoOrientation: ReplayKitVideoOrientationSnapshot?
        let shouldSendVideoStalled: Bool
        let videoStalledSequence: Int?
        let videoStalledReason: String?
    }

    private let log = OSLog(subsystem: "com.alexintosh.SpecchioKeyboard", category: "Broadcast")
    private let sharedDefaults = UserDefaults(suiteName: "group.com.alexintosh.SpecchioKeyboard")
    private let sender = ReplayKitFrameSender()
    private let encoder = ReplayKitFrameEncoder()
    private let videoEncoder = ReplayKitVideoEncoder()
    private let audioSender = ReplayKitAudioSender()
    private let audioEncoder = ReplayKitAudioEncoder()
    private let stateQueue = DispatchQueue(label: "com.alexintosh.SpecchioKeyboard.broadcast.state", qos: .userInitiated)

    private let staleFrameThresholdSeconds: TimeInterval = 3.0
    private let heartbeatIntervalSeconds: TimeInterval = 1.0
    private let broadcastFinishedFlushDelaySeconds: TimeInterval = 0.25

    private var watchdogTimer: DispatchSourceTimer?
    private var lastSentTimestamp: Double = 0
    private var receivedVideoFrames = 0
    private var sentVideoFrames = 0
    private var nextFrameSequenceNumber: UInt64 = 1
    private var nextControlSequenceNumber = 1
    private var nextHeartbeatSequenceNumber = 1
    private var isBroadcastActive = false
    private var isBroadcastPaused = false
    private var hasReportedVideoStalled = false
    private var needsFirstFrameEvent = true
    private var isAudioSenderRunning = false
    private var broadcastStartedAt: Date?
    private var videoExpectationStartedAt: Date?
    private var lastVideoSampleAt: Date?
    private var lastBroadcastPolicySignature = ""
    private var lastVideoCodecPreferenceSignature = ""
    private var broadcastVideoPacketsSent = 0
    private var broadcastVideoPacketsDropped = 0
    private var broadcastVideoKeyframesSent = 0
    private var receivedAppAudioSamples = 0
    private var sentAudioPackets = 0
    private var droppedAudioPackets = 0
    private var unsupportedAudioSamples = 0
    private var nextAudioPacketSequenceNumber: UInt64 = 1
    private var nextAudioStatusSequenceNumber = 1
    private var nextAudioFormatSequenceNumber = 1
    private var lastAudioSampleAt: Date?
    private var latestVideoOrientationSnapshot: ReplayKitVideoOrientationSnapshot?
    private var broadcastAudioFormatSummary = "waiting"
    private var videoMetricsWindowStartedAt = Date()
    private var metricsReceivedSamples = 0
    private var metricsReservedFrames = 0
    private var metricsFPSGateDrops = 0
    private var metricsH264Packets = 0
    private var metricsH264Bytes = 0
    private var metricsH264Keyframes = 0
    private var metricsJPEGFrames = 0
    private var metricsJPEGBytes = 0
    private var metricsPacketDrops = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        os_log("[Broadcast] started setupInfoPresent=%{public}@", log: log, type: .info, setupInfo == nil ? "NO" : "YES")
        let snapshot = stateQueue.sync { () -> (sequence: Int, received: Int, sent: Int) in
            resetBroadcastStateLocked()
            isBroadcastActive = true
            broadcastStartedAt = Date()
            videoExpectationStartedAt = broadcastStartedAt
            return (nextControlSequenceLocked(), receivedVideoFrames, sentVideoFrames)
        }
        videoEncoder.reset(reason: "broadcastStarted")

        updateBroadcastStatus("broadcastStarted")
        resetVideoPacketDiagnostics()
        resetAudioPacketDiagnostics()
        updateVideoCodecDiagnostics(codec: .unavailable, encoderStatus: "broadcastStarted waiting for video")
        updateLifecycleDiagnostics(.broadcastStarted)
        _ = currentBroadcastPolicy()
        startAudioSenderIfNeeded(reason: "broadcastStarted media policy")
        sendAudioStatusEvent(.broadcastStarted, reason: "broadcastStarted hook")
        sender.sendControlEvent(
            .broadcastStarted,
            sequence: snapshot.sequence,
            receivedVideoFrames: snapshot.received,
            sentVideoFrames: snapshot.sent,
            reason: "broadcastStarted hook"
        )
        sender.start()
        startWatchdogTimer()
    }

    override func broadcastPaused() {
        os_log("[Broadcast] paused hook entered", log: log, type: .info)
        let snapshot = stateQueue.sync { () -> (sequence: Int, received: Int, sent: Int) in
            os_log(
                "[Broadcast] paused path state before change active=%{public}@ stalled=%{public}@",
                log: log,
                type: .info,
                isBroadcastActive ? "YES" : "NO",
                hasReportedVideoStalled ? "YES" : "NO"
            )
            isBroadcastPaused = true
            hasReportedVideoStalled = false
            videoExpectationStartedAt = nil
            return (nextControlSequenceLocked(), receivedVideoFrames, sentVideoFrames)
        }

        updateBroadcastStatus("broadcastPaused received=\(snapshot.received) sent=\(snapshot.sent)")
        updateLifecycleDiagnostics(.broadcastPaused)
        sendAudioStatusEvent(.broadcastPaused, reason: "broadcastPaused hook")
        sender.sendControlEvent(
            .broadcastPaused,
            sequence: snapshot.sequence,
            receivedVideoFrames: snapshot.received,
            sentVideoFrames: snapshot.sent,
            reason: "broadcastPaused hook"
        )
    }

    override func broadcastResumed() {
        os_log("[Broadcast] resumed hook entered", log: log, type: .info)
        let snapshot = stateQueue.sync { () -> (sequence: Int, received: Int, sent: Int) in
            os_log(
                "[Broadcast] resumed path state before change active=%{public}@ paused=%{public}@ lastVideoSamplePresent=%{public}@",
                log: log,
                type: .info,
                isBroadcastActive ? "YES" : "NO",
                isBroadcastPaused ? "YES" : "NO",
                lastVideoSampleAt == nil ? "NO" : "YES"
            )
            isBroadcastPaused = false
            hasReportedVideoStalled = false
            needsFirstFrameEvent = true
            videoExpectationStartedAt = Date()
            return (nextControlSequenceLocked(), receivedVideoFrames, sentVideoFrames)
        }

        updateBroadcastStatus("broadcastResumed")
        updateLifecycleDiagnostics(.broadcastResumed)
        sendAudioStatusEvent(.broadcastResumed, reason: "broadcastResumed hook")
        sender.sendControlEvent(
            .broadcastResumed,
            sequence: snapshot.sequence,
            receivedVideoFrames: snapshot.received,
            sentVideoFrames: snapshot.sent,
            reason: "broadcastResumed hook"
        )
    }

    override func broadcastFinished() {
        os_log("[Broadcast] finished hook entered", log: log, type: .info)
        let snapshot = stateQueue.sync { () -> (sequence: Int, received: Int, sent: Int) in
            os_log(
                "[Broadcast] finished path state active=%{public}@ paused=%{public}@ stalled=%{public}@",
                log: log,
                type: .info,
                isBroadcastActive ? "YES" : "NO",
                isBroadcastPaused ? "YES" : "NO",
                hasReportedVideoStalled ? "YES" : "NO"
            )
            let result = (nextControlSequenceLocked(), receivedVideoFrames, sentVideoFrames)
            isBroadcastActive = false
            isBroadcastPaused = false
            hasReportedVideoStalled = false
            needsFirstFrameEvent = false
            isAudioSenderRunning = false
            videoExpectationStartedAt = nil
            return result
        }

        updateBroadcastStatus("broadcastFinished received=\(snapshot.received) sent=\(snapshot.sent)")
        updateVideoCodecDiagnostics(codec: .unavailable, encoderStatus: "broadcastFinished")
        updateLifecycleDiagnostics(.broadcastFinished)
        stopWatchdogTimer(reason: "broadcastFinished")
        sendAudioStatusEvent(.broadcastFinished, reason: "broadcastFinished hook")
        sender.sendControlEvent(
            .broadcastFinished,
            sequence: snapshot.sequence,
            receivedVideoFrames: snapshot.received,
            sentVideoFrames: snapshot.sent,
            reason: "broadcastFinished hook"
        )
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + broadcastFinishedFlushDelaySeconds) { [sender = self.sender] in
            sender.stop()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + broadcastFinishedFlushDelaySeconds) { [audioSender = self.audioSender] in
            audioSender.stop()
        }
        videoEncoder.reset(reason: "broadcastFinished")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        os_log("[Broadcast] processSampleBuffer type=%{public}@", log: log, type: .debug, diagnosticName(for: sampleBufferType))
        switch sampleBufferType {
        case .video:
            processVideoSampleBuffer(sampleBuffer)
        case .audioApp:
            processAppAudioSampleBuffer(sampleBuffer)
        case .audioMic:
            os_log("[BroadcastAudio] audioMic sample ignored reason=microphone out of scope for v1", log: log, type: .debug)
        @unknown default:
            os_log("[Broadcast] unknown sample type ignored", log: log, type: .error)
        }
    }

    private func processAppAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let now = Date()
        let reservation = stateQueue.sync { recordAppAudioSampleLocked(at: now) }
        updateLastAudioSampleTime(now)

        os_log(
            "[BroadcastAudio] sample received received=%d sent=%d dropped=%d unsupported=%d paused=%{public}@ seq=%llu",
            log: log,
            type: .info,
            reservation.receivedAppAudioSamples,
            reservation.sentAudioPackets,
            reservation.droppedAudioPackets,
            reservation.unsupportedAudioSamples,
            reservation.isBroadcastPaused ? "YES" : "NO",
            reservation.packetSequenceNumber
        )

        guard !reservation.isBroadcastPaused else {
            os_log("[BroadcastAudio] dropped reason=broadcastPaused seq=%llu", log: log, type: .info, reservation.packetSequenceNumber)
            recordAudioPacketDropped(reason: "broadcastPaused", unsupported: false)
            return
        }

        startAudioSenderIfNeeded(reason: "audio sample media policy")

        let captureWallClockMilliseconds = UInt64(now.timeIntervalSince1970 * 1000)
        let result = audioEncoder.encode(
            sampleBuffer: sampleBuffer,
            packetSequenceNumber: reservation.packetSequenceNumber,
            formatSequence: reservation.formatSequence,
            captureWallClockMilliseconds: captureWallClockMilliseconds
        )

        switch result {
        case .encoded(let encodedAudio):
            let counters = stateQueue.sync { markAudioPacketEncodedLocked(formatSummary: encodedAudio.formatSummary) }
            recordAudioPacketSentDiagnostics(counters: counters, formatSummary: encodedAudio.formatSummary)
            os_log(
                "[BroadcastAudio] packet sending seq=%llu received=%d sent=%d dropped=%d unsupported=%d format=%{public}@",
                log: log,
                type: .info,
                encodedAudio.packet.header.sequenceNumber,
                counters.receivedAppAudioSamples,
                counters.sentAudioPackets,
                counters.droppedAudioPackets,
                counters.unsupportedAudioSamples,
                encodedAudio.formatSummary
            )
            audioSender.send(encodedAudio)
        case .dropped(let reason):
            let unsupported = reason == "unsupportedFormat"
            os_log("[BroadcastAudio] dropped reason=%{public}@ seq=%llu unsupported=%{public}@", log: log, type: .error, reason, reservation.packetSequenceNumber, unsupported ? "YES" : "NO")
            recordAudioPacketDropped(reason: reason, unsupported: unsupported)
        }
    }

    private func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let now = Date()
        let orientationSnapshot = makeVideoOrientationSnapshot(from: sampleBuffer, now: now)
        let sampleDecision = stateQueue.sync { recordVideoSampleLocked(at: now) }
        let previousOrientationSnapshot = stateQueue.sync { () -> ReplayKitVideoOrientationSnapshot? in
            let previous = latestVideoOrientationSnapshot
            latestVideoOrientationSnapshot = orientationSnapshot
            return previous
        }
        if previousOrientationSnapshot?.orientationSignature != orientationSnapshot.orientationSignature {
            logVideoOrientationSnapshot(orientationSnapshot, previous: previousOrientationSnapshot)
        }
        updateLastVideoSampleTime(now)

        os_log(
            "[Broadcast] video sample received received=%d sent=%d firstFrameEvent=%{public}@ reason=%{public}@ paused=%{public}@ stalled=%{public}@",
            log: log,
            type: .info,
            sampleDecision.receivedVideoFrames,
            sampleDecision.sentVideoFrames,
            sampleDecision.shouldSendFirstFrameEvent ? "YES" : "NO",
            sampleDecision.firstFrameReason,
            sampleDecision.isBroadcastPaused ? "YES" : "NO",
            sampleDecision.wasVideoStalled ? "YES" : "NO"
        )

        let broadcastPolicy = currentBroadcastPolicy()
        let videoCodecPreference = currentVideoCodecPreference()
        let targetFramesPerSecond = broadcastPolicy.maxFramesPerSecond(for: videoCodecPreference)
        sender.updateMaxFramesPerSecondForDiagnostics(targetFramesPerSecond)

        if sampleDecision.shouldSendFirstFrameEvent, let controlSequence = sampleDecision.firstFrameEventSequence {
            updateBroadcastStatus("firstFrame received=\(sampleDecision.receivedVideoFrames) sent=\(sampleDecision.sentVideoFrames)")
            updateLifecycleDiagnostics(.firstFrame)
            sender.sendControlEvent(
                .firstFrame,
                sequence: controlSequence,
                receivedVideoFrames: sampleDecision.receivedVideoFrames,
                sentVideoFrames: sampleDecision.sentVideoFrames,
                reason: sampleDecision.firstFrameReason,
                videoOrientation: orientationSnapshot
            )
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampSeconds: Double
        if presentationTime.isValid {
            timestampSeconds = CMTimeGetSeconds(presentationTime)
            os_log("[Broadcast] video timestamp path=sample timestampSeconds=%.4f", log: log, type: .debug, timestampSeconds)
        } else {
            timestampSeconds = CACurrentMediaTime()
            os_log("[Broadcast] video timestamp path=fallback timestampSeconds=%.4f", log: log, type: .debug, timestampSeconds)
        }

        let minimumFrameInterval = 1.0 / targetFramesPerSecond
        os_log(
            "[BroadcastVideo] fps policy preference=%{public}@ targetFPS=%.1f jpegFPS=%.1f h264FPS=%.1f minimumInterval=%.4f",
            log: log,
            type: .info,
            videoCodecPreference.rawValue,
            targetFramesPerSecond,
            broadcastPolicy.jpegFramesPerSecond,
            broadcastPolicy.h264FramesPerSecond,
            minimumFrameInterval
        )
        guard let frameReservation = stateQueue.sync(execute: {
            reserveFrameSendLocked(timestampSeconds: timestampSeconds, minimumFrameInterval: minimumFrameInterval)
        }) else {
            let delta = stateQueue.sync { timestampSeconds - lastSentTimestamp }
            os_log(
                "[Broadcast] video frame dropped by FPS gate received=%d delta=%.4f minimumInterval=%.4f",
                log: log,
                type: .debug,
                sampleDecision.receivedVideoFrames,
                delta,
                minimumFrameInterval
            )
            return
        }

        let captureWallClockMilliseconds = UInt64(now.timeIntervalSince1970 * 1000)
        routeVideoFrameForEncoding(
            sampleBuffer: sampleBuffer,
            frameReservation: frameReservation,
            captureWallClockMilliseconds: captureWallClockMilliseconds,
            targetFramesPerSecond: targetFramesPerSecond,
            preference: videoCodecPreference
        )
    }

    private func makeVideoOrientationSnapshot(
        from sampleBuffer: CMSampleBuffer,
        now: Date
    ) -> ReplayKitVideoOrientationSnapshot {
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        let width = imageBuffer.map { CVPixelBufferGetWidth($0) } ?? 0
        let height = imageBuffer.map { CVPixelBufferGetHeight($0) } ?? 0
        let deviceOrientationRaw = UIDevice.current.orientation.rawValue
        let videoOrientationRaw = Self.replayKitVideoOrientationRaw(sampleBuffer)
        let snapshot = ReplayKitVideoOrientationSnapshot(
            deviceOrientationRaw: deviceOrientationRaw,
            deviceOrientationName: ReplayKitVideoOrientationSnapshot.deviceOrientationName(for: deviceOrientationRaw),
            videoOrientationRaw: videoOrientationRaw,
            videoOrientationName: videoOrientationRaw.map(ReplayKitVideoOrientationSnapshot.cgImageOrientationName),
            frameWidth: width,
            frameHeight: height,
            timestamp: now.timeIntervalSince1970
        )
        return snapshot
    }

    private func logVideoOrientationSnapshot(
        _ snapshot: ReplayKitVideoOrientationSnapshot,
        previous: ReplayKitVideoOrientationSnapshot?
    ) {
        os_log(
            "[BroadcastVideoOrientation] changed previousDevice=%{public}@ previousVideo=%{public}@ device=%{public}@ deviceRaw=%d deviceAxis=%{public}@ video=%{public}@ videoRaw=%{public}@ videoAxis=%{public}@ frame=%dx%d frameAxis=%{public}@",
            log: log,
            type: .info,
            previous?.deviceOrientationName ?? "nil",
            previous?.videoOrientationName ?? "nil",
            snapshot.deviceOrientationName,
            snapshot.deviceOrientationRaw,
            snapshot.deviceAxis,
            snapshot.videoOrientationName ?? "nil",
            snapshot.videoOrientationRaw.map(String.init) ?? "nil",
            snapshot.videoOrientationAxis ?? "nil",
            snapshot.frameWidth,
            snapshot.frameHeight,
            snapshot.videoFrameAxis
        )
    }

    private static func replayKitVideoOrientationRaw(_ sampleBuffer: CMSampleBuffer) -> Int? {
        guard let attachment = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) else {
            return nil
        }

        return (attachment as? NSNumber)?.intValue
    }

    private func routeVideoFrameForEncoding(
        sampleBuffer: CMSampleBuffer,
        frameReservation: FrameReservation,
        captureWallClockMilliseconds: UInt64,
        targetFramesPerSecond: Double,
        preference: ReplayKitVideoCodecPreference
    ) {
        os_log(
            "[BroadcastVideo] routing seq=%llu preference=%{public}@ targetFPS=%.1f",
            log: log,
            type: .info,
            frameReservation.sequenceNumber,
            preference.rawValue,
            targetFramesPerSecond
        )

        guard preference != .jpegOnly else {
            os_log("[BroadcastVideo] route branch=jpegFallback reason=preference jpegOnly seq=%llu", log: log, type: .info, frameReservation.sequenceNumber)
            sendJPEGFallbackFrame(
                sampleBuffer: sampleBuffer,
                frameReservation: frameReservation,
                captureWallClockMilliseconds: captureWallClockMilliseconds,
                reason: "preference jpegOnly"
            )
            return
        }

        updateVideoCodecDiagnostics(codec: .h264, encoderStatus: "h264 enqueue requested")
        let submission = videoEncoder.encode(
            sampleBuffer: sampleBuffer,
            sequenceNumber: frameReservation.sequenceNumber,
            captureWallClockMilliseconds: captureWallClockMilliseconds,
            targetFramesPerSecond: targetFramesPerSecond
        ) { [weak self] output in
            self?.handleH264EncodedOutput(output)
        }

        switch submission {
        case .enqueued:
            os_log("[BroadcastVideo] route branch=h264Enqueued seq=%llu", log: log, type: .debug, frameReservation.sequenceNumber)
        case .unavailable(let reason):
            os_log("[BroadcastVideo] route branch=jpegFallback reason=%{public}@ seq=%llu", log: log, type: .error, reason, frameReservation.sequenceNumber)
            updateVideoCodecDiagnostics(codec: .jpegFallback, encoderStatus: "h264 unavailable: \(reason)")
            sendJPEGFallbackFrame(
                sampleBuffer: sampleBuffer,
                frameReservation: frameReservation,
                captureWallClockMilliseconds: captureWallClockMilliseconds,
                reason: reason
            )
        }
    }

    private func handleH264EncodedOutput(_ output: ReplayKitVideoEncoder.EncodedOutput) {
        let header = output.accessUnit.packet.header
        if let config = output.config {
            os_log(
                "[BroadcastVideo] h264 config ready configSeq=%d width=%d height=%d spsBytes=%d ppsBytes=%d",
                log: log,
                type: .info,
                config.sequence,
                config.width,
                config.height,
                config.spsData?.count ?? 0,
                config.ppsData?.count ?? 0
            )
            sender.send(config)
        }

        let sendSnapshot = stateQueue.sync { markFrameEncodedLocked() }
        recordVideoPacketSent(
            codec: .h264,
            encoderStatus: "h264 access unit ready",
            keyframe: header.flags.contains(.keyframe),
            encodeDurationMilliseconds: output.accessUnit.encodeDurationMilliseconds,
            byteCount: output.accessUnit.packet.annexBBytes.count
        )
        if sendSnapshot.sentVideoFrames == 1 || sendSnapshot.sentVideoFrames % 30 == 0 {
            updateBroadcastStatus("h264 encoded sent=\(sendSnapshot.sentVideoFrames) received=\(sendSnapshot.receivedVideoFrames)")
        }

        os_log(
            "[BroadcastVideo] h264 access unit sending seq=%llu received=%d sent=%d bytes=%d flags=%u encodeMs=%u",
            log: log,
            type: .info,
            header.sequenceNumber,
            sendSnapshot.receivedVideoFrames,
            sendSnapshot.sentVideoFrames,
            output.accessUnit.packet.annexBBytes.count,
            header.flags.rawValue,
            output.accessUnit.encodeDurationMilliseconds
        )
        sender.send(output.accessUnit)
    }

    private func sendJPEGFallbackFrame(
        sampleBuffer: CMSampleBuffer,
        frameReservation: FrameReservation,
        captureWallClockMilliseconds: UInt64,
        reason: String
    ) {
        updateVideoCodecDiagnostics(codec: .jpegFallback, encoderStatus: "jpeg fallback: \(reason)")
        guard let encodedFrame = encoder.encode(
            sampleBuffer: sampleBuffer,
            sequenceNumber: frameReservation.sequenceNumber,
            captureWallClockMilliseconds: captureWallClockMilliseconds
        ) else {
            os_log(
                "[BroadcastVideo] jpeg fallback encode failed received=%d reservedSeq=%llu reason=%{public}@",
                log: log,
                type: .error,
                frameReservation.receivedVideoFrames,
                frameReservation.sequenceNumber,
                reason
            )
            recordVideoPacketDropped(reason: "jpeg encode failed after \(reason)")
            updateBroadcastStatus("encodeFailed frame=\(frameReservation.receivedVideoFrames)")
            updateVideoCodecDiagnostics(codec: .unavailable, encoderStatus: "jpeg fallback encode failed")
            return
        }

        let sendSnapshot = stateQueue.sync { markFrameEncodedLocked() }
        recordVideoPacketSent(
            codec: .jpegFallback,
            encoderStatus: "jpeg fallback frame ready",
            keyframe: false,
            encodeDurationMilliseconds: encodedFrame.encodeDurationMilliseconds,
            byteCount: encodedFrame.jpegData.count
        )
        if sendSnapshot.sentVideoFrames == 1 || sendSnapshot.sentVideoFrames % 30 == 0 {
            updateBroadcastStatus("jpeg encoded sent=\(sendSnapshot.sentVideoFrames) received=\(sendSnapshot.receivedVideoFrames)")
        }

        if encodedFrame.encodeDurationMilliseconds > 20 || sendSnapshot.sentVideoFrames % 15 == 0 {
            os_log(
                "[BroadcastVideo] jpeg fallback frame ready seq=%llu received=%d sent=%d encodeMs=%u jpegBytes=%d reason=%{public}@",
                log: log,
                type: .info,
                encodedFrame.sequenceNumber,
                sendSnapshot.receivedVideoFrames,
                sendSnapshot.sentVideoFrames,
                encodedFrame.encodeDurationMilliseconds,
                encodedFrame.jpegData.count,
                reason
            )
        } else {
            os_log(
                "[BroadcastVideo] jpeg fallback frame sending seq=%llu received=%d sent=%d reason=%{public}@",
                log: log,
                type: .debug,
                encodedFrame.sequenceNumber,
                sendSnapshot.receivedVideoFrames,
                sendSnapshot.sentVideoFrames,
                reason
            )
        }
        sender.send(encodedFrame)
    }

    private func recordVideoSampleLocked(at now: Date) -> VideoSampleDecision {
        os_log(
            "[Broadcast] recordVideoSample locked active=%{public}@ paused=%{public}@ stalled=%{public}@",
            log: log,
            type: .debug,
            isBroadcastActive ? "YES" : "NO",
            isBroadcastPaused ? "YES" : "NO",
            hasReportedVideoStalled ? "YES" : "NO"
        )
        receivedVideoFrames += 1
        metricsReceivedSamples += 1
        lastVideoSampleAt = now

        let shouldSendFirstFrameEvent = needsFirstFrameEvent
        let priorStalled = hasReportedVideoStalled
        let pausedState = isBroadcastPaused
        var firstFrameEventSequence: Int?
        var firstFrameReason = "steady-state sample"

        if shouldSendFirstFrameEvent {
            needsFirstFrameEvent = false
            hasReportedVideoStalled = false
            videoExpectationStartedAt = nil
            firstFrameEventSequence = nextControlSequenceLocked()
            if receivedVideoFrames == 1 {
                firstFrameReason = "first video sample after broadcastStarted"
            } else if priorStalled {
                firstFrameReason = "video sample resumed after videoStalled"
            } else if pausedState {
                firstFrameReason = "video sample arrived while paused"
            } else {
                firstFrameReason = "video sample resumed after broadcastResumed"
            }
        }

        return VideoSampleDecision(
            receivedVideoFrames: receivedVideoFrames,
            sentVideoFrames: sentVideoFrames,
            shouldSendFirstFrameEvent: shouldSendFirstFrameEvent,
            firstFrameEventSequence: firstFrameEventSequence,
            firstFrameReason: firstFrameReason,
            isBroadcastPaused: pausedState,
            wasVideoStalled: priorStalled
        )
    }

    private func recordAppAudioSampleLocked(at now: Date) -> AudioReservation {
        os_log(
            "[BroadcastAudio] record sample locked active=%{public}@ paused=%{public}@ nextSeq=%llu nextFormatSeq=%d",
            log: log,
            type: .debug,
            isBroadcastActive ? "YES" : "NO",
            isBroadcastPaused ? "YES" : "NO",
            nextAudioPacketSequenceNumber,
            nextAudioFormatSequenceNumber
        )
        receivedAppAudioSamples += 1
        lastAudioSampleAt = now
        let packetSequence = nextAudioPacketSequenceNumber
        nextAudioPacketSequenceNumber += 1
        let formatSequence = nextAudioFormatSequenceNumber
        nextAudioFormatSequenceNumber += 1

        return AudioReservation(
            packetSequenceNumber: packetSequence,
            formatSequence: formatSequence,
            receivedAppAudioSamples: receivedAppAudioSamples,
            sentAudioPackets: sentAudioPackets,
            droppedAudioPackets: droppedAudioPackets,
            unsupportedAudioSamples: unsupportedAudioSamples,
            isBroadcastPaused: isBroadcastPaused
        )
    }

    private func markAudioPacketEncodedLocked(formatSummary: String) -> AudioCountersSnapshot {
        sentAudioPackets += 1
        broadcastAudioFormatSummary = formatSummary
        os_log(
            "[BroadcastAudio] mark packet encoded sent=%d received=%d dropped=%d unsupported=%d format=%{public}@",
            log: log,
            type: .debug,
            sentAudioPackets,
            receivedAppAudioSamples,
            droppedAudioPackets,
            unsupportedAudioSamples,
            formatSummary
        )
        return audioCountersSnapshotLocked()
    }

    private func markAudioPacketDroppedLocked(reason: String, unsupported: Bool) -> AudioCountersSnapshot {
        droppedAudioPackets += 1
        if unsupported {
            unsupportedAudioSamples += 1
        }
        os_log(
            "[BroadcastAudio] mark packet dropped reason=%{public}@ sent=%d received=%d dropped=%d unsupported=%d",
            log: log,
            type: .debug,
            reason,
            sentAudioPackets,
            receivedAppAudioSamples,
            droppedAudioPackets,
            unsupportedAudioSamples
        )
        return audioCountersSnapshotLocked()
    }

    private func audioCountersSnapshotLocked() -> AudioCountersSnapshot {
        let sequence = nextAudioStatusSequenceNumber
        nextAudioStatusSequenceNumber += 1
        return AudioCountersSnapshot(
            sequence: sequence,
            receivedAppAudioSamples: receivedAppAudioSamples,
            sentAudioPackets: sentAudioPackets,
            droppedAudioPackets: droppedAudioPackets,
            unsupportedAudioSamples: unsupportedAudioSamples
        )
    }

    private func currentBroadcastPolicy() -> ReplayKitBroadcastPolicy {
        let transport = sender.currentTransportForPolicy()
        let policy = ReplayKitBroadcastPolicy.resolve(sharedDefaults: sharedDefaults, transport: transport)
        let shouldLog = stateQueue.sync { () -> Bool in
            guard policy.signature != lastBroadcastPolicySignature else {
                return false
            }

            lastBroadcastPolicySignature = policy.signature
            return true
        }

        if shouldLog {
            sharedDefaults?.set(policy.transport.rawValue, forKey: "replayKitAppliedTransport")
            sharedDefaults?.set(policy.usbCableAttached, forKey: "replayKitAppliedUSBCableAttached")
            sharedDefaults?.set(policy.usbGateReason, forKey: "replayKitAppliedUSBReason")
            sharedDefaults?.set(true, forKey: "replayKitAppliedPolicyAllowsVideo")
            sharedDefaults?.set(true, forKey: "replayKitAppliedPolicyAllowsAudio")
            sharedDefaults?.set(policy.jpegFramesPerSecond, forKey: "replayKitAppliedPolicyJPEGFPS")
            sharedDefaults?.set(policy.h264FramesPerSecond, forKey: "replayKitAppliedPolicyH264FPS")
            sharedDefaults?.set(policy.reason, forKey: "replayKitAppliedPolicyReason")
            sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "replayKitAppliedPolicyTime")
            sharedDefaults?.synchronize()
            os_log(
                "[ReplayKitPolicy] applied known=%{public}@ premiumMetadata=%{public}@ legacyTransportMetadata=%{public}@ legacyTransportReason=%{public}@ transport=%{public}@ mediaEnabled=YES jpegFPS=%.1f h264FPS=%.1f reason=%{public}@",
                log: log,
                type: .info,
                policy.isKnown ? "YES" : "NO",
                policy.isPremium ? "YES" : "NO",
                policy.usbCableAttached ? "YES" : "NO",
                policy.usbGateReason,
                policy.transport.rawValue,
                policy.jpegFramesPerSecond,
                policy.h264FramesPerSecond,
                policy.reason
            )
        }

        return policy
    }

    private func startAudioSenderIfNeeded(reason: String) {
        let shouldStart = stateQueue.sync { () -> Bool in
            guard !isAudioSenderRunning else { return false }
            isAudioSenderRunning = true
            return true
        }

        guard shouldStart else {
            os_log("[ReplayKitPolicy] audio sender start skipped reason=already-running trigger=%{public}@", log: log, type: .debug, reason)
            return
        }

        os_log("[ReplayKitPolicy] audio sender starting reason=%{public}@", log: log, type: .info, reason)
        audioSender.start()
    }

    private func currentVideoCodecPreference() -> ReplayKitVideoCodecPreference {
        let rawValue = sharedDefaults?.string(forKey: ReplayKitVideoCodecPreference.storageKey)
        let preference = ReplayKitVideoCodecPreference.resolve(rawValue: rawValue)
        let signature = "\(rawValue ?? "nil")-\(preference.rawValue)"
        let shouldLog = stateQueue.sync { () -> Bool in
            guard signature != lastVideoCodecPreferenceSignature else {
                return false
            }

            lastVideoCodecPreferenceSignature = signature
            return true
        }

        if shouldLog {
            os_log(
                "[BroadcastVideo] codec preference resolved raw=%{public}@ preference=%{public}@",
                log: log,
                type: .info,
                rawValue ?? "nil",
                preference.rawValue
            )
            sharedDefaults?.set(preference.rawValue, forKey: ReplayKitVideoCodecPreference.storageKey)
            sharedDefaults?.synchronize()
        }

        return preference
    }

    private func reserveFrameSendLocked(timestampSeconds: Double, minimumFrameInterval: Double) -> FrameReservation? {
        let delta = timestampSeconds - lastSentTimestamp
        os_log(
            "[Broadcast] reserveFrameSend delta=%.4f minimumInterval=%.4f lastSentTimestamp=%.4f",
            log: log,
            type: .debug,
            delta,
            minimumFrameInterval,
            lastSentTimestamp
        )
        guard delta >= minimumFrameInterval else {
            metricsFPSGateDrops += 1
            os_log("[Broadcast] reserveFrameSend rejected reason=fpsGate", log: log, type: .debug)
            return nil
        }

        lastSentTimestamp = timestampSeconds
        let sequenceNumber = nextFrameSequenceNumber
        nextFrameSequenceNumber += 1
        metricsReservedFrames += 1
        os_log("[Broadcast] reserveFrameSend accepted seq=%llu", log: log, type: .debug, sequenceNumber)
        return FrameReservation(sequenceNumber: sequenceNumber, receivedVideoFrames: receivedVideoFrames)
    }

    private func markFrameEncodedLocked() -> (receivedVideoFrames: Int, sentVideoFrames: Int) {
        sentVideoFrames += 1
        os_log("[Broadcast] markFrameEncoded sent=%d received=%d", log: log, type: .debug, sentVideoFrames, receivedVideoFrames)
        return (receivedVideoFrames, sentVideoFrames)
    }

    private func startWatchdogTimer() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.stopWatchdogTimerLocked(reason: "restart")
            let timer = DispatchSource.makeTimerSource(queue: self.stateQueue)
            timer.schedule(deadline: .now() + self.heartbeatIntervalSeconds, repeating: self.heartbeatIntervalSeconds)
            timer.setEventHandler { [weak self] in
                self?.handleWatchdogTickLocked()
            }
            self.watchdogTimer = timer
            os_log(
                "[Broadcast] watchdog started interval=%.1f staleThreshold=%.1f",
                log: self.log,
                type: .info,
                self.heartbeatIntervalSeconds,
                self.staleFrameThresholdSeconds
            )
            timer.resume()
        }
    }

    private func stopWatchdogTimer(reason: String) {
        stateQueue.async { [weak self] in
            self?.stopWatchdogTimerLocked(reason: reason)
        }
    }

    private func stopWatchdogTimerLocked(reason: String) {
        guard let watchdogTimer else {
            os_log("[Broadcast] watchdog stop ignored reason=%{public}@ timerPresent=NO", log: log, type: .debug, reason)
            return
        }
        os_log("[Broadcast] watchdog stopping reason=%{public}@", log: log, type: .info, reason)
        watchdogTimer.setEventHandler {}
        watchdogTimer.cancel()
        self.watchdogTimer = nil
    }

    private func handleWatchdogTickLocked() {
        guard isBroadcastActive else {
            os_log("[Broadcast] watchdog tick ignored active=NO", log: log, type: .debug)
            return
        }

        let now = Date()
        let lastVideoSampleAgeSeconds = lastVideoSampleAt.map { now.timeIntervalSince($0) }
        let heartbeatSequence = nextHeartbeatSequenceLocked()
        let heartbeatSnapshot = buildHeartbeatSnapshotLocked(
            now: now,
            heartbeatSequence: heartbeatSequence,
            lastVideoSampleAgeSeconds: lastVideoSampleAgeSeconds
        )
        logVideoMetricsLocked(now: now, trigger: "watchdog")
        os_log(
            "[Broadcast] watchdog tick heartbeatSeq=%d received=%d sent=%d paused=%{public}@ stalled=%{public}@ lastVideoSampleAge=%{public}@",
            log: log,
            type: .info,
            heartbeatSnapshot.sequence,
            heartbeatSnapshot.receivedVideoFrames,
            heartbeatSnapshot.sentVideoFrames,
            heartbeatSnapshot.isBroadcastPaused ? "YES" : "NO",
            heartbeatSnapshot.isVideoStalled ? "YES" : "NO",
            heartbeatSnapshot.lastVideoSampleAgeSeconds.map { String(format: "%.2f", $0) } ?? "nil"
        )

        updateLastHeartbeatTime(now)
        sender.sendHeartbeat(
            sequence: heartbeatSnapshot.sequence,
            receivedVideoFrames: heartbeatSnapshot.receivedVideoFrames,
            sentVideoFrames: heartbeatSnapshot.sentVideoFrames,
            isBroadcastPaused: heartbeatSnapshot.isBroadcastPaused,
            isVideoStalled: heartbeatSnapshot.isVideoStalled,
            lastVideoSampleAgeSeconds: heartbeatSnapshot.lastVideoSampleAgeSeconds,
            videoOrientation: heartbeatSnapshot.videoOrientation
        )
        sendAudioStatusEventLocked(.heartbeat, reason: "watchdog")

        guard heartbeatSnapshot.shouldSendVideoStalled, let controlSequence = heartbeatSnapshot.videoStalledSequence else {
            return
        }

        let reason = heartbeatSnapshot.videoStalledReason ?? "unknown watchdog stall"
        os_log("[Broadcast] watchdog stall transition seq=%d reason=%{public}@", log: log, type: .info, controlSequence, reason)
        updateBroadcastStatus("videoStalled received=\(heartbeatSnapshot.receivedVideoFrames) sent=\(heartbeatSnapshot.sentVideoFrames)")
        updateLifecycleDiagnostics(.videoStalled)
        sender.sendControlEvent(
            .videoStalled,
            sequence: controlSequence,
            receivedVideoFrames: heartbeatSnapshot.receivedVideoFrames,
            sentVideoFrames: heartbeatSnapshot.sentVideoFrames,
            reason: reason,
            videoOrientation: heartbeatSnapshot.videoOrientation
        )
    }

    private func buildHeartbeatSnapshotLocked(
        now: Date,
        heartbeatSequence: Int,
        lastVideoSampleAgeSeconds: Double?
    ) -> HeartbeatSnapshot {
        if isBroadcastPaused {
            os_log("[Broadcast] watchdog stale check skipped reason=broadcastPaused", log: log, type: .debug)
            return HeartbeatSnapshot(
                sequence: heartbeatSequence,
                receivedVideoFrames: receivedVideoFrames,
                sentVideoFrames: sentVideoFrames,
                isBroadcastPaused: true,
                isVideoStalled: false,
                lastVideoSampleAgeSeconds: lastVideoSampleAgeSeconds,
                videoOrientation: latestVideoOrientationSnapshot,
                shouldSendVideoStalled: false,
                videoStalledSequence: nil,
                videoStalledReason: nil
            )
        }

        if hasReportedVideoStalled {
            os_log("[Broadcast] watchdog stale check skipped reason=alreadyStalled", log: log, type: .debug)
            return HeartbeatSnapshot(
                sequence: heartbeatSequence,
                receivedVideoFrames: receivedVideoFrames,
                sentVideoFrames: sentVideoFrames,
                isBroadcastPaused: false,
                isVideoStalled: true,
                lastVideoSampleAgeSeconds: lastVideoSampleAgeSeconds,
                videoOrientation: latestVideoOrientationSnapshot,
                shouldSendVideoStalled: false,
                videoStalledSequence: nil,
                videoStalledReason: nil
            )
        }

        let staleReason: String?
        if let lastVideoSampleAt {
            let age = now.timeIntervalSince(lastVideoSampleAt)
            os_log(
                "[Broadcast] watchdog stale check path=lastVideoSample age=%.2f threshold=%.2f",
                log: log,
                type: .debug,
                age,
                staleFrameThresholdSeconds
            )
            staleReason = age >= staleFrameThresholdSeconds ? String(format: "no video sample for %.2fs", age) : nil
        } else if let videoExpectationStartedAt {
            let age = now.timeIntervalSince(videoExpectationStartedAt)
            os_log(
                "[Broadcast] watchdog stale check path=awaitingFirstFrame age=%.2f threshold=%.2f",
                log: log,
                type: .debug,
                age,
                staleFrameThresholdSeconds
            )
            staleReason = age >= staleFrameThresholdSeconds ? String(format: "awaiting first video sample for %.2fs", age) : nil
        } else if let broadcastStartedAt {
            let age = now.timeIntervalSince(broadcastStartedAt)
            os_log(
                "[Broadcast] watchdog stale check path=broadcastStarted age=%.2f threshold=%.2f",
                log: log,
                type: .debug,
                age,
                staleFrameThresholdSeconds
            )
            staleReason = age >= staleFrameThresholdSeconds ? String(format: "broadcast active without video for %.2fs", age) : nil
        } else {
            os_log("[Broadcast] watchdog stale check skipped reason=noReferenceDate", log: log, type: .debug)
            staleReason = nil
        }

        guard let staleReason else {
            return HeartbeatSnapshot(
                sequence: heartbeatSequence,
                receivedVideoFrames: receivedVideoFrames,
                sentVideoFrames: sentVideoFrames,
                isBroadcastPaused: false,
                isVideoStalled: false,
                lastVideoSampleAgeSeconds: lastVideoSampleAgeSeconds,
                videoOrientation: latestVideoOrientationSnapshot,
                shouldSendVideoStalled: false,
                videoStalledSequence: nil,
                videoStalledReason: nil
            )
        }

        hasReportedVideoStalled = true
        needsFirstFrameEvent = true
        let controlSequence = nextControlSequenceLocked()
        return HeartbeatSnapshot(
            sequence: heartbeatSequence,
            receivedVideoFrames: receivedVideoFrames,
            sentVideoFrames: sentVideoFrames,
            isBroadcastPaused: false,
            isVideoStalled: true,
            lastVideoSampleAgeSeconds: lastVideoSampleAgeSeconds,
            videoOrientation: latestVideoOrientationSnapshot,
            shouldSendVideoStalled: true,
            videoStalledSequence: controlSequence,
            videoStalledReason: staleReason
        )
    }

    private func resetBroadcastStateLocked() {
        os_log("[Broadcast] reset state", log: log, type: .info)
        lastSentTimestamp = 0
        receivedVideoFrames = 0
        sentVideoFrames = 0
        nextFrameSequenceNumber = 1
        nextControlSequenceNumber = 1
        nextHeartbeatSequenceNumber = 1
        isBroadcastActive = false
        isBroadcastPaused = false
        hasReportedVideoStalled = false
        needsFirstFrameEvent = true
        isAudioSenderRunning = false
        broadcastStartedAt = nil
        videoExpectationStartedAt = nil
        lastVideoSampleAt = nil
        latestVideoOrientationSnapshot = nil
        lastBroadcastPolicySignature = ""
        lastVideoCodecPreferenceSignature = ""
        broadcastVideoPacketsSent = 0
        broadcastVideoPacketsDropped = 0
        broadcastVideoKeyframesSent = 0
        receivedAppAudioSamples = 0
        sentAudioPackets = 0
        droppedAudioPackets = 0
        unsupportedAudioSamples = 0
        nextAudioPacketSequenceNumber = 1
        nextAudioStatusSequenceNumber = 1
        nextAudioFormatSequenceNumber = 1
        lastAudioSampleAt = nil
        broadcastAudioFormatSummary = "waiting"
        resetVideoMetricsWindowLocked(startingAt: Date())
    }

    private func resetVideoMetricsWindowLocked(startingAt date: Date) {
        videoMetricsWindowStartedAt = date
        metricsReceivedSamples = 0
        metricsReservedFrames = 0
        metricsFPSGateDrops = 0
        metricsH264Packets = 0
        metricsH264Bytes = 0
        metricsH264Keyframes = 0
        metricsJPEGFrames = 0
        metricsJPEGBytes = 0
        metricsPacketDrops = 0
    }

    private func logVideoMetricsLocked(now: Date, trigger: String) {
        let elapsed = now.timeIntervalSince(videoMetricsWindowStartedAt)
        guard elapsed >= 1.0 else { return }

        let safeElapsed = max(elapsed, 0.001)
        let sampleFPS = Double(metricsReceivedSamples) / safeElapsed
        let reservedFPS = Double(metricsReservedFrames) / safeElapsed
        let h264PacketFPS = Double(metricsH264Packets) / safeElapsed
        let jpegFPS = Double(metricsJPEGFrames) / safeElapsed
        let h264KBps = Double(metricsH264Bytes) / 1024.0 / safeElapsed
        let jpegKBps = Double(metricsJPEGBytes) / 1024.0 / safeElapsed

        os_log(
            "[BroadcastVideoMetrics] trigger=%{public}@ windowSeconds=%.2f receivedSamples=%d sampleFPS=%.2f reservedFrames=%d reservedFPS=%.2f h264Packets=%d h264PacketFPS=%.2f h264Keyframes=%d h264KBps=%.1f jpegFrames=%d jpegFPS=%.2f jpegKBps=%.1f fpsGateDrops=%d packetDrops=%d totalReceived=%d totalSent=%d totalDropped=%d",
            log: log,
            type: .info,
            trigger,
            safeElapsed,
            metricsReceivedSamples,
            sampleFPS,
            metricsReservedFrames,
            reservedFPS,
            metricsH264Packets,
            h264PacketFPS,
            metricsH264Keyframes,
            h264KBps,
            metricsJPEGFrames,
            jpegFPS,
            jpegKBps,
            metricsFPSGateDrops,
            metricsPacketDrops,
            receivedVideoFrames,
            sentVideoFrames,
            broadcastVideoPacketsDropped
        )

        resetVideoMetricsWindowLocked(startingAt: now)
    }

    private func nextControlSequenceLocked() -> Int {
        let sequence = nextControlSequenceNumber
        nextControlSequenceNumber += 1
        return sequence
    }

    private func nextHeartbeatSequenceLocked() -> Int {
        let sequence = nextHeartbeatSequenceNumber
        nextHeartbeatSequenceNumber += 1
        return sequence
    }

    private func sendAudioStatusEvent(_ event: ReplayKitAudioEventName, reason: String?) {
        let snapshot = stateQueue.sync { audioCountersSnapshotLocked() }
        sendAudioStatusEvent(event, reason: reason, counters: snapshot)
    }

    private func sendAudioStatusEventLocked(_ event: ReplayKitAudioEventName, reason: String?) {
        let snapshot = audioCountersSnapshotLocked()
        sendAudioStatusEvent(event, reason: reason, counters: snapshot)
    }

    private func sendAudioStatusEvent(
        _ event: ReplayKitAudioEventName,
        reason: String?,
        counters: AudioCountersSnapshot
    ) {
        os_log(
            "[BroadcastAudio] status event=%{public}@ seq=%d received=%d sent=%d dropped=%d unsupported=%d reason=%{public}@",
            log: log,
            type: .info,
            event.rawValue,
            counters.sequence,
            counters.receivedAppAudioSamples,
            counters.sentAudioPackets,
            counters.droppedAudioPackets,
            counters.unsupportedAudioSamples,
            reason ?? "nil"
        )
        audioSender.sendStatus(
            event: event,
            sequence: counters.sequence,
            receivedAudioSamples: counters.receivedAppAudioSamples,
            sentAudioPackets: counters.sentAudioPackets,
            droppedAudioPackets: counters.droppedAudioPackets,
            unsupportedAudioSamples: counters.unsupportedAudioSamples,
            reason: reason
        )
    }

    private func diagnosticName(for sampleBufferType: RPSampleBufferType) -> String {
        switch sampleBufferType {
        case .video:
            return "video"
        case .audioApp:
            return "audioApp"
        case .audioMic:
            return "audioMic"
        @unknown default:
            return "unknown"
        }
    }

    private func updateBroadcastStatus(_ status: String) {
        sharedDefaults?.set(status, forKey: "broadcastLastStatus")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "broadcastLastStatusTime")
        sharedDefaults?.synchronize()
    }

    private func updateLifecycleDiagnostics(_ event: ReplayKitControlEventName) {
        sharedDefaults?.set(event.rawValue, forKey: "broadcastLastLifecycleEvent")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "broadcastLastLifecycleEventTime")
        sharedDefaults?.synchronize()
    }

    private func updateLastVideoSampleTime(_ date: Date) {
        sharedDefaults?.set(date.timeIntervalSince1970, forKey: "broadcastLastVideoSampleTime")
        sharedDefaults?.set(date.timeIntervalSince1970, forKey: "broadcastVideoLastSampleTime")
    }

    private func updateLastAudioSampleTime(_ date: Date) {
        sharedDefaults?.set(date.timeIntervalSince1970, forKey: "broadcastLastAudioSampleTime")
        sharedDefaults?.set(date.timeIntervalSince1970, forKey: "broadcastAudioLastSampleTime")
        sharedDefaults?.synchronize()
    }

    private func updateLastHeartbeatTime(_ date: Date) {
        sharedDefaults?.set(date.timeIntervalSince1970, forKey: "broadcastLastHeartbeatTime")
    }

    private func updateVideoCodecDiagnostics(codec: ReplayKitBroadcastVideoCodecStatus, encoderStatus: String) {
        sharedDefaults?.set(codec.rawValue, forKey: "broadcastVideoCodec")
        sharedDefaults?.set(encoderStatus, forKey: "broadcastVideoEncoderStatus")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "broadcastVideoEncoderStatusTime")
        sharedDefaults?.synchronize()
        os_log(
            "[BroadcastVideo] diagnostics codec=%{public}@ encoderStatus=%{public}@",
            log: log,
            type: .info,
            codec.rawValue,
            encoderStatus
        )
    }

    private func resetVideoPacketDiagnostics() {
        sharedDefaults?.set(0, forKey: "broadcastVideoPacketsSent")
        sharedDefaults?.set(0, forKey: "broadcastVideoPacketsDropped")
        sharedDefaults?.set(0, forKey: "broadcastVideoKeyframesSent")
        sharedDefaults?.set(0, forKey: "broadcastVideoLastEncodeMilliseconds")
        sharedDefaults?.synchronize()
        os_log("[BroadcastVideo] packet diagnostics reset", log: log, type: .info)
    }

    private func resetAudioPacketDiagnostics() {
        sharedDefaults?.set("starting", forKey: "broadcastAudioSenderStatus")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "broadcastAudioSenderStatusTime")
        sharedDefaults?.set(0, forKey: "broadcastAudioPacketsSent")
        sharedDefaults?.set(0, forKey: "broadcastAudioPacketsDropped")
        sharedDefaults?.set(0, forKey: "broadcastAudioUnsupportedSamples")
        sharedDefaults?.set("waiting", forKey: "broadcastAudioFormatSummary")
        sharedDefaults?.set(0, forKey: "broadcastLastAudioSampleTime")
        sharedDefaults?.set(0, forKey: "broadcastAudioLastSampleTime")
        sharedDefaults?.synchronize()
        os_log("[BroadcastAudio] packet diagnostics reset", log: log, type: .info)
    }

    private func recordAudioPacketSentDiagnostics(counters: AudioCountersSnapshot, formatSummary: String) {
        sharedDefaults?.set(counters.sentAudioPackets, forKey: "broadcastAudioPacketsSent")
        sharedDefaults?.set(counters.droppedAudioPackets, forKey: "broadcastAudioPacketsDropped")
        sharedDefaults?.set(counters.unsupportedAudioSamples, forKey: "broadcastAudioUnsupportedSamples")
        sharedDefaults?.set(formatSummary, forKey: "broadcastAudioFormatSummary")
        sharedDefaults?.synchronize()
        os_log(
            "[BroadcastAudio] diagnostics sent=%d dropped=%d unsupported=%d format=%{public}@",
            log: log,
            type: .info,
            counters.sentAudioPackets,
            counters.droppedAudioPackets,
            counters.unsupportedAudioSamples,
            formatSummary
        )
    }

    private func recordAudioPacketDropped(reason: String, unsupported: Bool) {
        let counters = stateQueue.sync { markAudioPacketDroppedLocked(reason: reason, unsupported: unsupported) }
        sharedDefaults?.set(counters.sentAudioPackets, forKey: "broadcastAudioPacketsSent")
        sharedDefaults?.set(counters.droppedAudioPackets, forKey: "broadcastAudioPacketsDropped")
        sharedDefaults?.set(counters.unsupportedAudioSamples, forKey: "broadcastAudioUnsupportedSamples")
        sharedDefaults?.set(reason, forKey: "broadcastAudioLastDropReason")
        sharedDefaults?.set(broadcastAudioFormatSummary, forKey: "broadcastAudioFormatSummary")
        sharedDefaults?.synchronize()
        os_log(
            "[BroadcastAudio] diagnostics dropped reason=%{public}@ sent=%d dropped=%d unsupported=%d",
            log: log,
            type: .error,
            reason,
            counters.sentAudioPackets,
            counters.droppedAudioPackets,
            counters.unsupportedAudioSamples
        )
    }

    private func recordVideoPacketSent(
        codec: ReplayKitBroadcastVideoCodecStatus,
        encoderStatus: String,
        keyframe: Bool,
        encodeDurationMilliseconds: UInt32,
        byteCount: Int
    ) {
        let counters = stateQueue.sync { () -> (sent: Int, dropped: Int, keyframes: Int) in
            broadcastVideoPacketsSent += 1
            if keyframe {
                broadcastVideoKeyframesSent += 1
            }
            switch codec {
            case .h264:
                metricsH264Packets += 1
                metricsH264Bytes += byteCount
                if keyframe {
                    metricsH264Keyframes += 1
                }
            case .jpegFallback:
                metricsJPEGFrames += 1
                metricsJPEGBytes += byteCount
            case .unavailable:
                break
            }
            return (broadcastVideoPacketsSent, broadcastVideoPacketsDropped, broadcastVideoKeyframesSent)
        }

        sharedDefaults?.set(codec.rawValue, forKey: "broadcastVideoCodec")
        sharedDefaults?.set(encoderStatus, forKey: "broadcastVideoEncoderStatus")
        sharedDefaults?.set(counters.sent, forKey: "broadcastVideoPacketsSent")
        sharedDefaults?.set(counters.dropped, forKey: "broadcastVideoPacketsDropped")
        sharedDefaults?.set(counters.keyframes, forKey: "broadcastVideoKeyframesSent")
        sharedDefaults?.set(encodeDurationMilliseconds, forKey: "broadcastVideoLastEncodeMilliseconds")
        sharedDefaults?.synchronize()
        os_log(
            "[BroadcastVideo] packet sent codec=%{public}@ keyframe=%{public}@ bytes=%d sent=%d dropped=%d keyframes=%d encodeMs=%u",
            log: log,
            type: .info,
            codec.rawValue,
            keyframe ? "YES" : "NO",
            byteCount,
            counters.sent,
            counters.dropped,
            counters.keyframes,
            encodeDurationMilliseconds
        )
    }

    private func recordVideoPacketDropped(reason: String) {
        let counters = stateQueue.sync { () -> (sent: Int, dropped: Int, keyframes: Int) in
            broadcastVideoPacketsDropped += 1
            metricsPacketDrops += 1
            return (broadcastVideoPacketsSent, broadcastVideoPacketsDropped, broadcastVideoKeyframesSent)
        }

        sharedDefaults?.set(counters.sent, forKey: "broadcastVideoPacketsSent")
        sharedDefaults?.set(counters.dropped, forKey: "broadcastVideoPacketsDropped")
        sharedDefaults?.set(counters.keyframes, forKey: "broadcastVideoKeyframesSent")
        sharedDefaults?.set(reason, forKey: "broadcastVideoEncoderStatus")
        sharedDefaults?.synchronize()
        os_log(
            "[BroadcastVideo] packet dropped reason=%{public}@ sent=%d dropped=%d keyframes=%d",
            log: log,
            type: .error,
            reason,
            counters.sent,
            counters.dropped,
            counters.keyframes
        )
    }
}
