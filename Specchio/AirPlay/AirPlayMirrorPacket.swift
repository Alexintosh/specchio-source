import CoreGraphics
import Foundation

enum AirPlayMirrorVideoCodec: String {
    case h264
    case hevc
    case unknown

    var diagnosticName: String {
        rawValue
    }
}

struct AirPlayMirrorVideoCodecDecision: Equatable {
    let codec: AirPlayMirrorVideoCodec
    let branch: String
}

struct AirPlayMirrorPacket: Equatable {
    static let headerByteCount = 128
    static let videoPayloadType = 0
    static let codecConfigurationPayloadType = 1
    static let oldProtocolKeepAlivePayloadType = 2
    static let streamingReportPayloadType = 5

    let payloadSize: Int
    let rawPayloadType: UInt16
    let payloadType: Int
    let payloadOption: UInt16
    let ntpTimestamp: UInt64?
    let presentationTimestampMilliseconds: UInt64?
    let sourceDimensions: CGSize?
    let renderDimensions: CGSize?

    init?(headerData: Data) {
        guard headerData.count == Self.headerByteCount else {
            return nil
        }

        let payloadSize = Int(Self.readUInt32LE(headerData, at: 0))
        let rawPayloadType = Self.readUInt16LE(headerData, at: 4)
        let payloadType = Int(rawPayloadType & 0x00FF)
        self.payloadSize = payloadSize
        self.rawPayloadType = rawPayloadType
        self.payloadType = payloadType
        self.payloadOption = Self.readUInt16LE(headerData, at: 6)

        if payloadType == Self.videoPayloadType {
            let ntp = Self.readUInt64LE(headerData, at: 8)
            self.ntpTimestamp = ntp
            self.presentationTimestampMilliseconds = Self.ntpToMilliseconds(ntp)
        } else {
            self.ntpTimestamp = nil
            self.presentationTimestampMilliseconds = nil
        }

        if payloadType == Self.codecConfigurationPayloadType {
            let sourceWidth = CGFloat(Self.readFloat32LE(headerData, at: 40))
            let sourceHeight = CGFloat(Self.readFloat32LE(headerData, at: 44))
            let renderWidth = CGFloat(Self.readFloat32LE(headerData, at: 56))
            let renderHeight = CGFloat(Self.readFloat32LE(headerData, at: 60))
            self.sourceDimensions = Self.validDimensions(width: sourceWidth, height: sourceHeight)
            self.renderDimensions = Self.validDimensions(width: renderWidth, height: renderHeight)
        } else {
            self.sourceDimensions = nil
            self.renderDimensions = nil
        }
    }

    var isVideoPayload: Bool {
        payloadType == Self.videoPayloadType
    }

    var isIDRVideoPayload: Bool {
        isVideoPayload && (rawPayloadType == 0x1000 || rawPayloadType == 0x0010)
    }

    var isCodecConfigurationPayload: Bool {
        payloadType == Self.codecConfigurationPayloadType
    }

    var codecConfigurationVideoCodec: AirPlayMirrorVideoCodec {
        codecConfigurationVideoCodecDecision(payload: nil).codec
    }

    func codecConfigurationVideoCodecDecision(payload: Data?) -> AirPlayMirrorVideoCodecDecision {
        guard isCodecConfigurationPayload else {
            return AirPlayMirrorVideoCodecDecision(codec: .unknown, branch: "not-codec-configuration")
        }
        switch payloadOption {
        case 0x011E:
            return AirPlayMirrorVideoCodecDecision(codec: .hevc, branch: "option-wire-hevc-config")
        case 0x015E:
            return AirPlayMirrorVideoCodecDecision(codec: .hevc, branch: "option-wire-hevc-stop")
        case 0x0116:
            return AirPlayMirrorVideoCodecDecision(codec: .h264, branch: "option-wire-h264-config")
        case 0x0156:
            return AirPlayMirrorVideoCodecDecision(codec: .h264, branch: "option-wire-h264-stop")
        case 0x1E01, 0x5E01:
            return AirPlayMirrorVideoCodecDecision(codec: .hevc, branch: "option-reversed-hevc-compat")
        case 0x1601, 0x5601:
            return AirPlayMirrorVideoCodecDecision(codec: .h264, branch: "option-reversed-h264-compat")
        default:
            if let payload, AirPlayHEVCFrameAdapter.payloadLooksLikeConfiguration(payload) {
                return AirPlayMirrorVideoCodecDecision(codec: .hevc, branch: "payload-hevc-signature")
            }
            if let payload, AirPlayH264FrameAdapter.payloadLooksLikeConfiguration(payload) {
                return AirPlayMirrorVideoCodecDecision(codec: .h264, branch: "payload-h264-signature")
            }
            return AirPlayMirrorVideoCodecDecision(codec: .h264, branch: "default-h264")
        }
    }

    var isCodecStopPayload: Bool {
        isCodecConfigurationPayload && (payloadOption == 0x0156 || payloadOption == 0x015E || payloadOption == 0x5601 || payloadOption == 0x5E01)
    }

    var isOldProtocolKeepAlivePayload: Bool {
        payloadType == Self.oldProtocolKeepAlivePayloadType
    }

    var isStreamingReportPayload: Bool {
        payloadType == Self.streamingReportPayloadType
    }

    var diagnosticDescription: String {
        let sourceText = sourceDimensions.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil"
        let renderText = renderDimensions.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil"
        let ptsText = presentationTimestampMilliseconds.map(String.init) ?? "nil"
        return "type=\(payloadType) rawType=\(Self.hex(rawPayloadType)) bytes=\(payloadSize) option=\(Self.hex(payloadOption)) ptsMs=\(ptsText) source=\(sourceText) render=\(renderText) idr=\(isIDRVideoPayload)"
    }

    private static func validDimensions(width: CGFloat, height: CGFloat) -> CGSize? {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private static func ntpToMilliseconds(_ ntp: UInt64) -> UInt64 {
        let seconds = ntp >> 32
        let fraction = ntp & 0xFFFF_FFFF
        let fractionalMilliseconds = (fraction * 1000) / UInt64(UInt32.max)
        return seconds * 1000 + fractionalMilliseconds
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in stride(from: offset + 7, through: offset, by: -1) {
            value = (value << 8) | UInt64(data[index])
        }
        return value
    }

    private static func readFloat32LE(_ data: Data, at offset: Int) -> Float32 {
        Float32(bitPattern: readUInt32LE(data, at: offset))
    }

    private static func hex(_ value: UInt16) -> String {
        "0x" + String(format: "%04X", value)
    }
}
