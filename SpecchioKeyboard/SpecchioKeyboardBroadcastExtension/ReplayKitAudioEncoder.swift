import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import os.log

struct ReplayKitEncodedAudioPacket {
    let format: ReplayKitAudioFormatPayload
    let packet: ReplayKitAudioPCMPacket
    let formatSummary: String
}

enum ReplayKitAudioEncodeResult {
    case encoded(ReplayKitEncodedAudioPacket)
    case dropped(reason: String)
}

private struct ReplayKitCanonicalAudioPCM {
    let pcmBytes: Data
    let frameCount: Int
    let channelCount: UInt32
    let sourceLayoutSummary: String
    let sourceTotalBytes: Int
    let peakLevel: Double
    let rmsLevel: Double
}

final class ReplayKitAudioEncoder {
    private let log = OSLog(subsystem: "com.alexintosh.SpecchioKeyboard", category: "BroadcastAudio")

    func encode(
        sampleBuffer: CMSampleBuffer,
        packetSequenceNumber: UInt64,
        formatSequence: Int,
        captureWallClockMilliseconds: UInt64
    ) -> ReplayKitAudioEncodeResult {
        os_log("[BroadcastAudio] sample received seq=%llu formatSeq=%d", log: log, type: .info, packetSequenceNumber, formatSequence)

        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            os_log("[BroadcastAudio] dropped reason=notReady seq=%llu", log: log, type: .error, packetSequenceNumber)
            return .dropped(reason: "notReady")
        }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            os_log("[BroadcastAudio] dropped reason=missingFormatDescription seq=%llu", log: log, type: .error, packetSequenceNumber)
            return .dropped(reason: "missingFormatDescription")
        }

        guard let streamDescriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            os_log("[BroadcastAudio] dropped reason=missingASBD seq=%llu", log: log, type: .error, packetSequenceNumber)
            return .dropped(reason: "missingASBD")
        }

        let streamDescription = streamDescriptionPointer.pointee
        guard streamDescription.mFormatID == kAudioFormatLinearPCM else {
            os_log("[BroadcastAudio] dropped reason=unsupportedFormat seq=%llu formatID=%u", log: log, type: .error, packetSequenceNumber, streamDescription.mFormatID)
            return .dropped(reason: "unsupportedFormat")
        }

        guard let commonFormat = commonFormat(from: streamDescription) else {
            os_log(
                "[BroadcastAudio] dropped reason=unsupportedFormat seq=%llu flags=%u bits=%u bytesPerFrame=%u channels=%u",
                log: log,
                type: .error,
                packetSequenceNumber,
                streamDescription.mFormatFlags,
                streamDescription.mBitsPerChannel,
                streamDescription.mBytesPerFrame,
                streamDescription.mChannelsPerFrame
            )
            return .dropped(reason: "unsupportedFormat")
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, frameCount <= Int(UInt32.max) else {
            os_log("[BroadcastAudio] dropped reason=invalidFrameCount seq=%llu frameCount=%d", log: log, type: .error, packetSequenceNumber, frameCount)
            return .dropped(reason: "invalidFrameCount")
        }

        guard streamDescription.mSampleRate.isFinite, streamDescription.mSampleRate > 0 else {
            os_log("[BroadcastAudio] dropped reason=invalidSampleRate seq=%llu sampleRate=%.4f", log: log, type: .error, packetSequenceNumber, streamDescription.mSampleRate)
            return .dropped(reason: "invalidSampleRate")
        }

        guard streamDescription.mChannelsPerFrame > 0, streamDescription.mChannelsPerFrame <= UInt32(UInt16.max) else {
            os_log("[BroadcastAudio] dropped reason=invalidChannelCount seq=%llu channels=%u", log: log, type: .error, packetSequenceNumber, streamDescription.mChannelsPerFrame)
            return .dropped(reason: "invalidChannelCount")
        }

        guard let canonicalPCM = copyCanonicalPCMBytes(
            from: sampleBuffer,
            streamDescriptionPointer: streamDescriptionPointer,
            streamDescription: streamDescription,
            frameCount: frameCount,
            sourceCommonFormat: commonFormat,
            sequenceNumber: packetSequenceNumber
        ) else {
            os_log("[BroadcastAudio] dropped reason=copyFailed seq=%llu", log: log, type: .error, packetSequenceNumber)
            return .dropped(reason: "copyFailed")
        }

        let pcmBytes = canonicalPCM.pcmBytes
        guard !pcmBytes.isEmpty, pcmBytes.count <= ReplayKitAudioConstants.maximumEnvelopePayloadBytes else {
            os_log("[BroadcastAudio] dropped reason=invalidPCMByteCount seq=%llu bytes=%d max=%d", log: log, type: .error, packetSequenceNumber, pcmBytes.count, ReplayKitAudioConstants.maximumEnvelopePayloadBytes)
            return .dropped(reason: "invalidPCMByteCount")
        }

        let destinationCommonFormat: ReplayKitAudioCommonFormat = .pcmFloat32
        let destinationIsInterleaved = false
        let destinationBytesPerFrame = UInt16(MemoryLayout<Float>.size)
        let sourceIsInterleaved = (streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let presentationTimestampMilliseconds = presentationTimestampMilliseconds(for: sampleBuffer)
        let sampleRateMilliHz = UInt64((streamDescription.mSampleRate * 1000.0).rounded())
        let format = ReplayKitAudioFormatPayload(
            sequence: formatSequence,
            sampleRate: streamDescription.mSampleRate,
            channelCount: Int(canonicalPCM.channelCount),
            commonFormat: destinationCommonFormat,
            isInterleaved: destinationIsInterleaved,
            timestamp: Date().timeIntervalSince1970
        )
        let header = ReplayKitAudioPCMHeader(
            sequenceNumber: packetSequenceNumber,
            presentationTimestampMilliseconds: presentationTimestampMilliseconds,
            captureWallClockMilliseconds: captureWallClockMilliseconds,
            sampleRateMilliHz: sampleRateMilliHz,
            frameCount: UInt32(canonicalPCM.frameCount),
            channelCount: UInt16(canonicalPCM.channelCount),
            formatFlags: destinationCommonFormat.packetFlag,
            bytesPerFrame: destinationBytesPerFrame,
            isInterleaved: destinationIsInterleaved,
            source: .appAudio,
            pcmByteCount: UInt32(pcmBytes.count)
        )
        let packet = ReplayKitAudioPCMPacket(header: header, pcmBytes: pcmBytes)
        let summary = "\(Int(streamDescription.mSampleRate.rounded()))Hz \(canonicalPCM.channelCount)ch \(destinationCommonFormat.rawValue) noninterleaved canonical source=\(canonicalPCM.sourceLayoutSummary)"

        os_log(
            "[BroadcastAudio] copied seq=%llu frames=%u bytes=%d sampleRate=%.1f channels=%u sourceCommonFormat=%{public}@ sourceInterleaved=%{public}@ sourceFlags=0x%08x sourceBytesPerFrame=%u sourceBytes=%d sourceLayout=%{public}@ outputCommonFormat=%{public}@ outputInterleaved=%{public}@ peak=%.5f rms=%.5f ptsMs=%llu",
            log: log,
            type: .info,
            packetSequenceNumber,
            header.frameCount,
            pcmBytes.count,
            streamDescription.mSampleRate,
            canonicalPCM.channelCount,
            commonFormat.rawValue,
            sourceIsInterleaved ? "YES" : "NO",
            streamDescription.mFormatFlags,
            streamDescription.mBytesPerFrame,
            canonicalPCM.sourceTotalBytes,
            canonicalPCM.sourceLayoutSummary,
            destinationCommonFormat.rawValue,
            "NO",
            canonicalPCM.peakLevel,
            canonicalPCM.rmsLevel,
            presentationTimestampMilliseconds
        )

        return .encoded(ReplayKitEncodedAudioPacket(format: format, packet: packet, formatSummary: summary))
    }

    private func commonFormat(from streamDescription: AudioStreamBasicDescription) -> ReplayKitAudioCommonFormat? {
        let flags = streamDescription.mFormatFlags
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (flags & kAudioFormatFlagIsSignedInteger) != 0

        if isFloat, streamDescription.mBitsPerChannel == 32 {
            os_log("[BroadcastAudio] format branch=pcmFloat32 flags=%u", log: log, type: .info, flags)
            return .pcmFloat32
        }

        if isSignedInteger, streamDescription.mBitsPerChannel == 16 {
            os_log("[BroadcastAudio] format branch=pcmInt16 flags=%u", log: log, type: .info, flags)
            return .pcmInt16
        }

        os_log("[BroadcastAudio] format branch=unsupported flags=%u bits=%u", log: log, type: .error, flags, streamDescription.mBitsPerChannel)
        return nil
    }

    private func copyCanonicalPCMBytes(
        from sampleBuffer: CMSampleBuffer,
        streamDescriptionPointer: UnsafePointer<AudioStreamBasicDescription>,
        streamDescription: AudioStreamBasicDescription,
        frameCount: Int,
        sourceCommonFormat: ReplayKitAudioCommonFormat,
        sequenceNumber: UInt64
    ) -> ReplayKitCanonicalAudioPCM? {
        var requiredBufferListSize = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredBufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )

        guard sizeStatus == noErr, requiredBufferListSize > 0 else {
            os_log("[BroadcastAudio] canonicalize path=size-query-failed seq=%llu status=%d size=%d", log: log, type: .error, sequenceNumber, sizeStatus, requiredBufferListSize)
            return nil
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: requiredBufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            rawPointer.deallocate()
        }

        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlockBuffer: CMBlockBuffer?
        let copyStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferListPointer,
            bufferListSize: requiredBufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlockBuffer
        )

        guard copyStatus == noErr else {
            os_log("[BroadcastAudio] canonicalize path=buffer-list-failed seq=%llu status=%d", log: log, type: .error, sequenceNumber, copyStatus)
            return nil
        }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        let sourceLayoutSummary = audioBufferLayoutDescription(audioBuffers)
        let sourceTotalBytes = totalAudioBufferByteCount(audioBuffers)

        guard let sourceFormat = AVAudioFormat(streamDescription: streamDescriptionPointer) else {
            os_log("[BroadcastAudio] canonicalize path=source-format-failed seq=%llu flags=0x%08x bits=%u bytesPerFrame=%u channels=%u layout=%{public}@", log: log, type: .error, sequenceNumber, streamDescription.mFormatFlags, streamDescription.mBitsPerChannel, streamDescription.mBytesPerFrame, streamDescription.mChannelsPerFrame, sourceLayoutSummary)
            return nil
        }

        let sourceIsInterleaved = (streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        os_log(
            "[BroadcastAudio] canonicalize source seq=%llu commonFormat=%{public}@ sampleRate=%.1f channels=%u asbdInterleaved=%{public}@ flags=0x%08x bits=%u bytesPerFrame=%u bytesPerPacket=%u framesPerPacket=%u retainedBlockBuffer=%{public}@ layout=%{public}@",
            log: log,
            type: .info,
            sequenceNumber,
            sourceCommonFormat.rawValue,
            streamDescription.mSampleRate,
            streamDescription.mChannelsPerFrame,
            sourceIsInterleaved ? "YES" : "NO",
            streamDescription.mFormatFlags,
            streamDescription.mBitsPerChannel,
            streamDescription.mBytesPerFrame,
            streamDescription.mBytesPerPacket,
            streamDescription.mFramesPerPacket,
            retainedBlockBuffer == nil ? "NO" : "YES",
            sourceLayoutSummary
        )

        for index in 0..<audioBuffers.count {
            let audioBuffer = audioBuffers[index]
            let byteCount = Int(audioBuffer.mDataByteSize)
            guard byteCount > 0 else {
                os_log("[BroadcastAudio] canonicalize path=empty-buffer seq=%llu index=%d layout=%{public}@", log: log, type: .error, sequenceNumber, index, sourceLayoutSummary)
                return nil
            }

            guard audioBuffer.mData != nil else {
                os_log("[BroadcastAudio] canonicalize path=nil-buffer-data seq=%llu index=%d layout=%{public}@", log: log, type: .error, sequenceNumber, index, sourceLayoutSummary)
                return nil
            }
        }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            bufferListNoCopy: audioBuffers.unsafePointer,
            deallocator: nil
        ) else {
            os_log("[BroadcastAudio] canonicalize path=source-buffer-failed seq=%llu layout=%{public}@", log: log, type: .error, sequenceNumber, sourceLayoutSummary)
            return nil
        }

        let requestedFrameLength = AVAudioFrameCount(frameCount)
        guard sourceBuffer.frameCapacity >= requestedFrameLength else {
            os_log("[BroadcastAudio] canonicalize path=source-capacity-too-small seq=%llu capacity=%u requested=%u layout=%{public}@", log: log, type: .error, sequenceNumber, sourceBuffer.frameCapacity, requestedFrameLength, sourceLayoutSummary)
            return nil
        }
        sourceBuffer.frameLength = requestedFrameLength

        guard let destinationFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: streamDescription.mSampleRate,
            channels: AVAudioChannelCount(streamDescription.mChannelsPerFrame),
            interleaved: false
        ) else {
            os_log("[BroadcastAudio] canonicalize path=destination-format-failed seq=%llu sampleRate=%.1f channels=%u", log: log, type: .error, sequenceNumber, streamDescription.mSampleRate, streamDescription.mChannelsPerFrame)
            return nil
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: destinationFormat) else {
            os_log("[BroadcastAudio] canonicalize path=converter-failed seq=%llu sourceLayout=%{public}@ destination=float32-noninterleaved", log: log, type: .error, sequenceNumber, sourceLayoutSummary)
            return nil
        }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: destinationFormat,
            frameCapacity: requestedFrameLength
        ) else {
            os_log("[BroadcastAudio] canonicalize path=output-buffer-failed seq=%llu frames=%u", log: log, type: .error, sequenceNumber, requestedFrameLength)
            return nil
        }

        do {
            try converter.convert(to: outputBuffer, from: sourceBuffer)
        } catch {
            os_log("[BroadcastAudio] canonicalize path=converter-error seq=%llu error=%{public}@ sourceLayout=%{public}@", log: log, type: .error, sequenceNumber, error.localizedDescription, sourceLayoutSummary)
            return nil
        }

        guard outputBuffer.frameLength > 0 else {
            os_log("[BroadcastAudio] canonicalize path=empty-output seq=%llu sourceLayout=%{public}@", log: log, type: .error, sequenceNumber, sourceLayoutSummary)
            return nil
        }

        return serializeFloat32NonInterleavedPCM(
            outputBuffer,
            sourceLayoutSummary: sourceLayoutSummary,
            sourceTotalBytes: sourceTotalBytes,
            sequenceNumber: sequenceNumber
        )
    }

    private func serializeFloat32NonInterleavedPCM(
        _ buffer: AVAudioPCMBuffer,
        sourceLayoutSummary: String,
        sourceTotalBytes: Int,
        sequenceNumber: UInt64
    ) -> ReplayKitCanonicalAudioPCM? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let expectedByteCount = frameCount * channelCount * MemoryLayout<Float>.size

        guard frameCount > 0, channelCount > 0 else {
            os_log("[BroadcastAudio] canonicalize path=invalid-output-shape seq=%llu frames=%d channels=%d", log: log, type: .error, sequenceNumber, frameCount, channelCount)
            return nil
        }

        guard let channelData = buffer.floatChannelData else {
            os_log("[BroadcastAudio] canonicalize path=missing-float-channel-data seq=%llu frames=%d channels=%d", log: log, type: .error, sequenceNumber, frameCount, channelCount)
            return nil
        }

        var pcmBytes = Data(capacity: expectedByteCount)
        var peakLevel = 0.0
        var sumSquares = 0.0
        var sampleCount = 0

        for channelIndex in 0..<channelCount {
            let channelPointer = channelData[channelIndex]
            for frameIndex in 0..<frameCount {
                let sample = Double(channelPointer[frameIndex])
                let magnitude = abs(sample)
                peakLevel = max(peakLevel, magnitude)
                sumSquares += sample * sample
                sampleCount += 1
            }

            let channelBytes = UnsafeRawBufferPointer(
                start: channelPointer,
                count: frameCount * MemoryLayout<Float>.size
            )
            pcmBytes.append(contentsOf: channelBytes)
        }

        guard pcmBytes.count == expectedByteCount else {
            os_log("[BroadcastAudio] canonicalize path=output-byte-count-mismatch seq=%llu expected=%d actual=%d frames=%d channels=%d", log: log, type: .error, sequenceNumber, expectedByteCount, pcmBytes.count, frameCount, channelCount)
            return nil
        }

        let rmsLevel = sampleCount > 0 ? sqrt(sumSquares / Double(sampleCount)) : 0
        os_log(
            "[BroadcastAudio] canonicalize path=complete seq=%llu frames=%d channels=%d bytes=%d sourceBytes=%d sourceLayout=%{public}@ peak=%.5f rms=%.5f",
            log: log,
            type: .info,
            sequenceNumber,
            frameCount,
            channelCount,
            pcmBytes.count,
            sourceTotalBytes,
            sourceLayoutSummary,
            peakLevel,
            rmsLevel
        )

        return ReplayKitCanonicalAudioPCM(
            pcmBytes: pcmBytes,
            frameCount: frameCount,
            channelCount: UInt32(channelCount),
            sourceLayoutSummary: sourceLayoutSummary,
            sourceTotalBytes: sourceTotalBytes,
            peakLevel: peakLevel,
            rmsLevel: rmsLevel
        )
    }

    private func audioBufferLayoutDescription(_ audioBuffers: UnsafeMutableAudioBufferListPointer) -> String {
        var descriptions: [String] = []
        descriptions.reserveCapacity(audioBuffers.count)

        for index in 0..<audioBuffers.count {
            let audioBuffer = audioBuffers[index]
            descriptions.append("\(index):\(audioBuffer.mNumberChannels)ch/\(audioBuffer.mDataByteSize)B")
        }

        return "\(audioBuffers.count)[\(descriptions.joined(separator: ","))]"
    }

    private func totalAudioBufferByteCount(_ audioBuffers: UnsafeMutableAudioBufferListPointer) -> Int {
        var byteCount = 0
        for index in 0..<audioBuffers.count {
            byteCount += Int(audioBuffers[index].mDataByteSize)
        }
        return byteCount
    }

    private func presentationTimestampMilliseconds(for sampleBuffer: CMSampleBuffer) -> UInt64 {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isValid else {
            os_log("[BroadcastAudio] timestamp path=fallback reason=invalid", log: log, type: .info)
            return 0
        }

        let seconds = CMTimeGetSeconds(timestamp)
        guard seconds.isFinite, seconds >= 0 else {
            os_log("[BroadcastAudio] timestamp path=fallback reason=nonFinite seconds=%.4f", log: log, type: .info, seconds)
            return 0
        }

        return UInt64((seconds * 1000.0).rounded())
    }
}
