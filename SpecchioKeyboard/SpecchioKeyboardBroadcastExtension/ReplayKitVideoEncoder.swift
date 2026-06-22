import CoreMedia
import Foundation
import os.log
import QuartzCore
import VideoToolbox

struct ReplayKitEncodedH264AccessUnit {
    let packet: ReplayKitH264AccessUnitPacket
    let encodeDurationMilliseconds: UInt32
}

final class ReplayKitVideoEncoder {
    enum EncodeSubmission {
        case enqueued
        case unavailable(String)
    }

    struct EncodedOutput {
        let config: ReplayKitH264ConfigPayload?
        let accessUnit: ReplayKitEncodedH264AccessUnit
    }

    fileprivate final class FrameMetadata {
        let sequenceNumber: UInt64
        let captureWallClockMilliseconds: UInt64
        let encodeStartedAt: CFTimeInterval
        let width: Int
        let height: Int
        let targetFramesPerSecond: Int
        let keyframeIntervalFrames: Int
        let forcedKeyframeReason: String?
        let completion: (EncodedOutput) -> Void

        init(
            sequenceNumber: UInt64,
            captureWallClockMilliseconds: UInt64,
            encodeStartedAt: CFTimeInterval,
            width: Int,
            height: Int,
            targetFramesPerSecond: Int,
            keyframeIntervalFrames: Int,
            forcedKeyframeReason: String?,
            completion: @escaping (EncodedOutput) -> Void
        ) {
            self.sequenceNumber = sequenceNumber
            self.captureWallClockMilliseconds = captureWallClockMilliseconds
            self.encodeStartedAt = encodeStartedAt
            self.width = width
            self.height = height
            self.targetFramesPerSecond = targetFramesPerSecond
            self.keyframeIntervalFrames = keyframeIntervalFrames
            self.forcedKeyframeReason = forcedKeyframeReason
            self.completion = completion
        }
    }

    private struct SessionSignature: Equatable {
        let width: Int
        let height: Int
        let targetFramesPerSecond: Int
        let keyframeIntervalFrames: Int
    }

    private let log = OSLog(subsystem: "com.alexintosh.SpecchioKeyboard", category: "ReplayKitH264Encoder")
    private let lock = NSLock()
    private let maximumConsecutiveEncodeFailures = 3

    private var session: VTCompressionSession?
    private var sessionSignature: SessionSignature?
    private var latestSPS: Data?
    private var latestPPS: Data?
    private var nextConfigSequence = 1
    private var consecutiveEncodeFailures = 0
    private var unavailableReason: String?
    private var needsForcedKeyframe = true
    private var lastKeyframeRequestAt: CFTimeInterval?

    func reset(reason: String) {
        os_log("[ReplayKitH264Encoder] reset requested reason=%{public}@", log: log, type: .info, reason)
        lock.lock()
        defer { lock.unlock() }
        invalidateSessionLocked(reason: reason)
        latestSPS = nil
        latestPPS = nil
        nextConfigSequence = 1
        consecutiveEncodeFailures = 0
        unavailableReason = nil
        needsForcedKeyframe = true
        lastKeyframeRequestAt = nil
    }

    func encode(
        sampleBuffer: CMSampleBuffer,
        sequenceNumber: UInt64,
        captureWallClockMilliseconds: UInt64,
        targetFramesPerSecond: Double,
        completion: @escaping (EncodedOutput) -> Void
    ) -> EncodeSubmission {
        os_log("[ReplayKitH264Encoder] encode requested seq=%llu targetFPS=%.1f", log: log, type: .debug, sequenceNumber, targetFramesPerSecond)

        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            os_log("[ReplayKitH264Encoder] encode rejected seq=%llu reason=sampleBufferNotReady", log: log, type: .debug, sequenceNumber)
            return .unavailable("sample buffer not ready")
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            os_log("[ReplayKitH264Encoder] encode rejected seq=%llu reason=missingPixelBuffer", log: log, type: .error, sequenceNumber)
            return .unavailable("missing CVPixelBuffer")
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard UInt16(exactly: width) != nil, UInt16(exactly: height) != nil else {
            os_log("[ReplayKitH264Encoder] encode rejected seq=%llu reason=dimensionsExceedUInt16 width=%d height=%d", log: log, type: .error, sequenceNumber, width, height)
            return .unavailable("dimensions exceed H.264 packet header")
        }

        let targetFPS = max(1, Int(targetFramesPerSecond.rounded()))
        let keyframeIntervalFrames = targetFPS * 2
        let signature = SessionSignature(
            width: width,
            height: height,
            targetFramesPerSecond: targetFPS,
            keyframeIntervalFrames: keyframeIntervalFrames
        )

        lock.lock()
        if let unavailableReason {
            lock.unlock()
            os_log("[ReplayKitH264Encoder] encode rejected seq=%llu reason=%{public}@", log: log, type: .info, sequenceNumber, unavailableReason)
            return .unavailable(unavailableReason)
        }

        if sessionSignature != signature || session == nil {
            os_log(
                "[ReplayKitH264Encoder] session create decision seq=%llu oldSignature=%{public}@ newWidth=%d newHeight=%d targetFPS=%d keyInterval=%d",
                log: log,
                type: .info,
                sequenceNumber,
                sessionSignature.map { "\($0.width)x\($0.height)@\($0.targetFramesPerSecond)" } ?? "nil",
                width,
                height,
                targetFPS,
                keyframeIntervalFrames
            )
            invalidateSessionLocked(reason: "signature changed")
            guard createSessionLocked(signature: signature) else {
                let reason = unavailableReason ?? "VTCompressionSessionCreate failed"
                lock.unlock()
                return .unavailable(reason)
            }
        }

        guard let activeSession = session else {
            let reason = "compression session missing after setup"
            unavailableReason = reason
            lock.unlock()
            os_log("[ReplayKitH264Encoder] encode rejected seq=%llu reason=%{public}@", log: log, type: .error, sequenceNumber, reason)
            return .unavailable(reason)
        }
        lock.unlock()

        let encodeStartedAt = CACurrentMediaTime()
        let keyframeIntervalDurationSeconds = Double(keyframeIntervalFrames) / Double(targetFPS)
        lock.lock()
        let forcedKeyframeReason = takeForcedKeyframeReasonLocked(
            now: encodeStartedAt,
            keyframeIntervalDurationSeconds: keyframeIntervalDurationSeconds
        )
        lock.unlock()

        if let forcedKeyframeReason {
            os_log(
                "[ReplayKitH264Encoder] keyframe request seq=%llu reason=%{public}@ intervalSeconds=%.2f",
                log: log,
                type: .info,
                sequenceNumber,
                forcedKeyframeReason,
                keyframeIntervalDurationSeconds
            )
        }

        let metadata = FrameMetadata(
            sequenceNumber: sequenceNumber,
            captureWallClockMilliseconds: captureWallClockMilliseconds,
            encodeStartedAt: encodeStartedAt,
            width: width,
            height: height,
            targetFramesPerSecond: targetFPS,
            keyframeIntervalFrames: keyframeIntervalFrames,
            forcedKeyframeReason: forcedKeyframeReason,
            completion: completion
        )

        let presentationTime = ReplayKitVideoEncoder.presentationTime(for: sampleBuffer, captureWallClockMilliseconds: captureWallClockMilliseconds)
        let metadataRef = Unmanaged.passRetained(metadata).toOpaque()
        var infoFlags = VTEncodeInfoFlags()
        let frameProperties: CFDictionary?
        if forcedKeyframeReason != nil {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any] as CFDictionary
        } else {
            frameProperties = nil
        }
        let status = VTCompressionSessionEncodeFrame(
            activeSession,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: frameProperties,
            sourceFrameRefcon: metadataRef,
            infoFlagsOut: &infoFlags
        )

        guard status == noErr else {
            _ = Unmanaged<FrameMetadata>.fromOpaque(metadataRef).takeRetainedValue()
            recordEncodeFailure(reason: "VTCompressionSessionEncodeFrame status=\(status)")
            os_log("[ReplayKitH264Encoder] encode failed seq=%llu status=%d infoFlags=%u", log: log, type: .error, sequenceNumber, status, infoFlags.rawValue)
            return .unavailable("VTCompressionSessionEncodeFrame failed \(status)")
        }

        os_log("[ReplayKitH264Encoder] encode enqueued seq=%llu infoFlags=%u", log: log, type: .debug, sequenceNumber, infoFlags.rawValue)
        return .enqueued
    }

    private func createSessionLocked(signature: SessionSignature) -> Bool {
        var newSession: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(signature.width),
            height: Int32(signature.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: replayKitVideoCompressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )

        guard createStatus == noErr, let newSession else {
            unavailableReason = "VTCompressionSessionCreate failed \(createStatus)"
            os_log("[ReplayKitH264Encoder] session create failed status=%d width=%d height=%d", log: log, type: .error, createStatus, signature.width, signature.height)
            return false
        }

        setPropertyLocked(newSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue, label: "realtime")
        setPropertyLocked(newSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse, label: "allowFrameReordering")
        setPropertyLocked(newSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel, label: "profile")
        setPropertyLocked(newSession, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: ReplayKitH264Constants.averageBitrate), label: "averageBitrate")
        setPropertyLocked(newSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: signature.targetFramesPerSecond), label: "expectedFrameRate")
        setPropertyLocked(newSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: signature.keyframeIntervalFrames), label: "keyframeInterval")
        setPropertyLocked(
            newSession,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: NSNumber(value: Double(signature.keyframeIntervalFrames) / Double(signature.targetFramesPerSecond)),
            label: "keyframeIntervalDuration"
        )

        VTCompressionSessionPrepareToEncodeFrames(newSession)
        session = newSession
        sessionSignature = signature
        latestSPS = nil
        latestPPS = nil
        needsForcedKeyframe = true
        lastKeyframeRequestAt = nil
        os_log(
            "[ReplayKitH264Encoder] session create success width=%d height=%d bitrate=%d targetFPS=%d keyInterval=%d",
            log: log,
            type: .info,
            signature.width,
            signature.height,
            ReplayKitH264Constants.averageBitrate,
            signature.targetFramesPerSecond,
            signature.keyframeIntervalFrames
        )
        return true
    }

    private func takeForcedKeyframeReasonLocked(
        now: CFTimeInterval,
        keyframeIntervalDurationSeconds: CFTimeInterval
    ) -> String? {
        if needsForcedKeyframe {
            needsForcedKeyframe = false
            lastKeyframeRequestAt = now
            return "session-start"
        }

        guard let lastKeyframeRequestAt else {
            self.lastKeyframeRequestAt = now
            return nil
        }

        let elapsed = now - lastKeyframeRequestAt
        guard elapsed >= keyframeIntervalDurationSeconds else {
            return nil
        }

        self.lastKeyframeRequestAt = now
        return String(format: "wall-clock-interval %.2fs", elapsed)
    }

    private func setPropertyLocked(_ session: VTCompressionSession, key: CFString, value: CFTypeRef, label: String) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status == noErr {
            os_log("[ReplayKitH264Encoder] property set label=%{public}@ status=ok", log: log, type: .debug, label)
        } else {
            os_log("[ReplayKitH264Encoder] property set failed label=%{public}@ status=%d", log: log, type: .error, label, status)
        }
    }

    private func invalidateSessionLocked(reason: String) {
        guard let session else {
            os_log("[ReplayKitH264Encoder] session invalidate skipped reason=%{public}@ sessionPresent=NO", log: log, type: .debug, reason)
            return
        }

        os_log("[ReplayKitH264Encoder] session invalidate reason=%{public}@", log: log, type: .info, reason)
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        self.sessionSignature = nil
    }

    fileprivate func handleCompressionOutput(
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?,
        metadata: FrameMetadata
    ) {
        guard status == noErr else {
            recordEncodeFailure(reason: "output status=\(status)")
            os_log("[ReplayKitH264Encoder] encode failed seq=%llu branch=callbackStatus status=%d infoFlags=%u", log: log, type: .error, metadata.sequenceNumber, status, infoFlags.rawValue)
            return
        }

        guard let sampleBuffer else {
            recordEncodeFailure(reason: "callback missing sampleBuffer")
            os_log("[ReplayKitH264Encoder] encode failed seq=%llu branch=missingSampleBuffer", log: log, type: .error, metadata.sequenceNumber)
            return
        }

        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            recordEncodeFailure(reason: "encoded sampleBuffer not ready")
            os_log("[ReplayKitH264Encoder] encode failed seq=%llu branch=encodedSampleNotReady", log: log, type: .error, metadata.sequenceNumber)
            return
        }

        let isKeyframe = Self.isKeyframe(sampleBuffer)
        let parameterSets = Self.parameterSets(from: sampleBuffer)
        let config = updateFormatIfNeeded(
            sps: parameterSets.sps,
            pps: parameterSets.pps,
            metadata: metadata
        )
        let parameterSetsForIDR = isKeyframe ? currentParameterSets() : nil

        guard let annexBBytes = Self.annexBAccessUnit(from: sampleBuffer, parameterSetsToPrepend: parameterSetsForIDR) else {
            recordEncodeFailure(reason: "AVCC to Annex B conversion failed")
            os_log("[ReplayKitH264Encoder] encode failed seq=%llu branch=annexBConversion", log: log, type: .error, metadata.sequenceNumber)
            return
        }

        guard annexBBytes.count <= ReplayKitH264Constants.maximumAccessUnitBytes else {
            recordEncodeFailure(reason: "access unit too large \(annexBBytes.count)")
            os_log("[ReplayKitH264Encoder] encode failed seq=%llu branch=accessUnitTooLarge bytes=%d max=%d", log: log, type: .error, metadata.sequenceNumber, annexBBytes.count, ReplayKitH264Constants.maximumAccessUnitBytes)
            return
        }

        var flags: ReplayKitH264AccessUnitFlags = []
        if isKeyframe || ReplayKitAnnexBParser.containsIDR(in: annexBBytes) {
            flags.insert(.keyframe)
        }
        if parameterSetsForIDR != nil {
            flags.insert(.includesParameterSets)
        }
        if config != nil {
            flags.insert(.formatChanged)
        }

        if let forcedKeyframeReason = metadata.forcedKeyframeReason, !flags.contains(.keyframe) {
            lock.lock()
            needsForcedKeyframe = true
            lock.unlock()
            os_log(
                "[ReplayKitH264Encoder] keyframe request not honored seq=%llu reason=%{public}@ flags=%u",
                log: log,
                type: .error,
                metadata.sequenceNumber,
                forcedKeyframeReason,
                flags.rawValue
            )
        }

        guard let width = UInt16(exactly: metadata.width),
              let height = UInt16(exactly: metadata.height),
              let nalByteCount = UInt32(exactly: annexBBytes.count) else {
            recordEncodeFailure(reason: "encoded packet values exceed header limits")
            os_log("[ReplayKitH264Encoder] encode failed seq=%llu branch=packetHeaderLimit width=%d height=%d bytes=%d", log: log, type: .error, metadata.sequenceNumber, metadata.width, metadata.height, annexBBytes.count)
            return
        }

        let encodeDurationMilliseconds = UInt32(((CACurrentMediaTime() - metadata.encodeStartedAt) * 1000).rounded())
        let encodedWallClockMilliseconds = UInt64(Date().timeIntervalSince1970 * 1000)
        let presentationTimestampMilliseconds = Self.presentationTimestampMilliseconds(for: sampleBuffer, fallback: metadata.captureWallClockMilliseconds)
        let header = ReplayKitH264AccessUnitHeader(
            sequenceNumber: metadata.sequenceNumber,
            presentationTimestampMilliseconds: presentationTimestampMilliseconds,
            captureWallClockMilliseconds: metadata.captureWallClockMilliseconds,
            encodedWallClockMilliseconds: encodedWallClockMilliseconds,
            width: width,
            height: height,
            flags: flags,
            nalByteCount: nalByteCount
        )
        let packet = ReplayKitH264AccessUnitPacket(header: header, annexBBytes: annexBBytes)
        recordEncodeSuccess()

        if flags.contains(.keyframe) || config != nil || encodeDurationMilliseconds > 20 {
            os_log(
                "[ReplayKitH264Encoder] keyframe=%{public}@ seq=%llu bytes=%d flags=%u encodeMs=%u config=%{public}@ forced=%{public}@",
                log: log,
                type: .info,
                flags.contains(.keyframe) ? "YES" : "NO",
                metadata.sequenceNumber,
                annexBBytes.count,
                flags.rawValue,
                encodeDurationMilliseconds,
                config == nil ? "NO" : "YES",
                metadata.forcedKeyframeReason ?? "NO"
            )
        } else {
            os_log("[ReplayKitH264Encoder] access unit ready seq=%llu bytes=%d encodeMs=%u", log: log, type: .debug, metadata.sequenceNumber, annexBBytes.count, encodeDurationMilliseconds)
        }

        metadata.completion(EncodedOutput(
            config: config,
            accessUnit: ReplayKitEncodedH264AccessUnit(
                packet: packet,
                encodeDurationMilliseconds: encodeDurationMilliseconds
            )
        ))
    }

    private func updateFormatIfNeeded(sps: Data?, pps: Data?, metadata: FrameMetadata) -> ReplayKitH264ConfigPayload? {
        guard let sps, let pps, !sps.isEmpty, !pps.isEmpty else {
            os_log("[ReplayKitH264Encoder] format skipped seq=%llu reason=missingParameterSets", log: log, type: .debug, metadata.sequenceNumber)
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        guard latestSPS != sps || latestPPS != pps else {
            os_log("[ReplayKitH264Encoder] format unchanged seq=%llu", log: log, type: .debug, metadata.sequenceNumber)
            return nil
        }

        latestSPS = sps
        latestPPS = pps
        let sequence = nextConfigSequence
        nextConfigSequence += 1
        let payload = ReplayKitH264ConfigPayload(
            sequence: sequence,
            width: metadata.width,
            height: metadata.height,
            bitrate: ReplayKitH264Constants.averageBitrate,
            targetFPS: metadata.targetFramesPerSecond,
            keyframeIntervalFrames: metadata.keyframeIntervalFrames,
            sps: sps,
            pps: pps,
            timestamp: Date().timeIntervalSince1970
        )
        os_log(
            "[ReplayKitH264Encoder] format changed seq=%llu configSeq=%d width=%d height=%d spsBytes=%d ppsBytes=%d",
            log: log,
            type: .info,
            metadata.sequenceNumber,
            sequence,
            metadata.width,
            metadata.height,
            sps.count,
            pps.count
        )
        return payload
    }

    private func currentParameterSets() -> (sps: Data, pps: Data)? {
        lock.lock()
        defer { lock.unlock() }
        guard let latestSPS, let latestPPS else { return nil }
        return (latestSPS, latestPPS)
    }

    private func recordEncodeSuccess() {
        lock.lock()
        consecutiveEncodeFailures = 0
        lock.unlock()
    }

    private func recordEncodeFailure(reason: String) {
        lock.lock()
        consecutiveEncodeFailures += 1
        let failures = consecutiveEncodeFailures
        if failures >= maximumConsecutiveEncodeFailures {
            unavailableReason = "H.264 encoder disabled after \(failures) failures: \(reason)"
        }
        lock.unlock()
        os_log("[ReplayKitH264Encoder] encode failed reason=%{public}@ consecutive=%d", log: log, type: .error, reason, failures)
    }

    private static func presentationTime(for sampleBuffer: CMSampleBuffer, captureWallClockMilliseconds: UInt64) -> CMTime {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else {
            return CMTime(value: CMTimeValue(captureWallClockMilliseconds), timescale: CMTimeScale(ReplayKitH264Constants.timescale))
        }
        return presentationTime
    }

    private static func presentationTimestampMilliseconds(for sampleBuffer: CMSampleBuffer, fallback: UInt64) -> UInt64 {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else { return fallback }
        return UInt64(max(0, CMTimeGetSeconds(presentationTime)) * 1000)
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let first = attachments.first,
              let notSync = first[kCMSampleAttachmentKey_NotSync as String] as? Bool else {
            return true
        }
        return !notSync
    }

    private static func parameterSets(from sampleBuffer: CMSampleBuffer) -> (sps: Data?, pps: Data?) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return (nil, nil)
        }
        return (
            copyH264ParameterSet(formatDescription: formatDescription, index: 0),
            copyH264ParameterSet(formatDescription: formatDescription, index: 1)
        )
    }

    private static func copyH264ParameterSet(formatDescription: CMFormatDescription, index: Int) -> Data? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var count = 0
        var nalHeaderLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: index,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &nalHeaderLength
        )
        guard status == noErr, let pointer, size > 0 else {
            return nil
        }
        return Data(bytes: pointer, count: size)
    }

    private static func annexBAccessUnit(
        from sampleBuffer: CMSampleBuffer,
        parameterSetsToPrepend: (sps: Data, pps: Data)?
    ) -> Data? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        let dataLength = CMBlockBufferGetDataLength(dataBuffer)
        guard dataLength > 0 else {
            return nil
        }

        var avccData = Data(count: dataLength)
        let copyStatus = avccData.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: dataLength,
                destination: baseAddress
            )
        }
        guard copyStatus == noErr else {
            return nil
        }

        var annexB = Data(capacity: dataLength + ((parameterSetsToPrepend == nil) ? 0 : 16))
        if let parameterSetsToPrepend {
            annexB.append(ReplayKitH264Constants.annexBStartCode)
            annexB.append(parameterSetsToPrepend.sps)
            annexB.append(ReplayKitH264Constants.annexBStartCode)
            annexB.append(parameterSetsToPrepend.pps)
        }

        var offset = 0
        while offset + 4 <= avccData.count {
            let nalLength = Int(avccData.replayKitReadUInt32BE(at: offset))
            offset += 4
            guard nalLength > 0, offset + nalLength <= avccData.count else {
                return nil
            }
            annexB.append(ReplayKitH264Constants.annexBStartCode)
            annexB.append(avccData.subdata(in: offset..<(offset + nalLength)))
            offset += nalLength
        }

        guard offset == avccData.count, !annexB.isEmpty else {
            return nil
        }

        return annexB
    }
}

private func replayKitVideoCompressionOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let outputCallbackRefCon else {
        if let sourceFrameRefCon {
            _ = Unmanaged<ReplayKitVideoEncoder.FrameMetadata>.fromOpaque(sourceFrameRefCon).takeRetainedValue()
        }
        return
    }

    guard let sourceFrameRefCon else {
        return
    }

    let encoder = Unmanaged<ReplayKitVideoEncoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
    let metadata = Unmanaged<ReplayKitVideoEncoder.FrameMetadata>.fromOpaque(sourceFrameRefCon).takeRetainedValue()
    encoder.handleCompressionOutput(
        status: status,
        infoFlags: infoFlags,
        sampleBuffer: sampleBuffer,
        metadata: metadata
    )
}
