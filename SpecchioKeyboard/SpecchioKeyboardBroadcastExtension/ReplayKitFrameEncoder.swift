import CoreImage
import CoreMedia
import Foundation
import os.log
import QuartzCore
import ReplayKit
import UIKit

final class ReplayKitFrameEncoder {
    private let log = OSLog(subsystem: "com.alexintosh.SpecchioKeyboard", category: "ReplayKitEncoder")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private let jpegCompressionQuality: CGFloat = 0.62
    private let jpegQualityHeaderValue: UInt8 = 62

    func encode(sampleBuffer: CMSampleBuffer, sequenceNumber: UInt64, captureWallClockMilliseconds: UInt64) -> ReplayKitEncodedFrame? {
        let encodeStart = CACurrentMediaTime()
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            os_log("[ReplayKitEncoder] sampleBuffer not ready; dropping", log: log, type: .debug)
            return nil
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            os_log("[ReplayKitEncoder] missing CVPixelBuffer; dropping", log: log, type: .error)
            return nil
        }

        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        os_log("[ReplayKitEncoder] encoding source width=%d height=%d", log: log, type: .debug, sourceWidth, sourceHeight)

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let options: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegCompressionQuality,
        ]

        guard let jpegData = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else {
            os_log("[ReplayKitEncoder] JPEG representation failed", log: log, type: .error)
            return nil
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampSeconds: Double
        if presentationTime.isValid {
            timestampSeconds = CMTimeGetSeconds(presentationTime)
            os_log("[ReplayKitEncoder] timestamp path: presentation time %.4f", log: log, type: .debug, timestampSeconds)
        } else {
            timestampSeconds = Date().timeIntervalSince1970
            os_log("[ReplayKitEncoder] timestamp path: wall clock fallback %.4f", log: log, type: .debug, timestampSeconds)
        }

        guard let width = UInt16(exactly: sourceWidth), let height = UInt16(exactly: sourceHeight) else {
            os_log("[ReplayKitEncoder] dimensions exceed UInt16 width=%d height=%d", log: log, type: .error, sourceWidth, sourceHeight)
            return nil
        }

        os_log("[ReplayKitEncoder] JPEG encoded bytes=%d", log: log, type: .debug, jpegData.count)
        let encodeDurationMilliseconds = UInt32(((CACurrentMediaTime() - encodeStart) * 1000).rounded())
        let encodedWallClockMilliseconds = UInt64(Date().timeIntervalSince1970 * 1000)
        if encodeDurationMilliseconds > 20 {
            os_log(
                "[ReplayKitEncoder] seq=%llu slow encodeMs=%u width=%d height=%d jpegBytes=%d",
                log: log,
                type: .info,
                sequenceNumber,
                encodeDurationMilliseconds,
                sourceWidth,
                sourceHeight,
                jpegData.count
            )
        }
        return ReplayKitEncodedFrame(
            sequenceNumber: sequenceNumber,
            timestampMilliseconds: UInt64(timestampSeconds * 1000),
            width: width,
            height: height,
            quality: jpegQualityHeaderValue,
            orientation: UInt8(UIDevice.current.orientation.rawValue),
            captureWallClockMilliseconds: captureWallClockMilliseconds,
            encodeDurationMilliseconds: encodeDurationMilliseconds,
            encodedWallClockMilliseconds: encodedWallClockMilliseconds,
            jpegData: jpegData
        )
    }
}
