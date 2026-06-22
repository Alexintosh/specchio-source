import Foundation

enum AirPlayStreamHealth: Equatable {
    case idle
    case advertising
    case waitingForPhone
    case pairing
    case settingUp
    case receivingVideo
    case screenOff(lastFrameAge: TimeInterval)
    case stale(lastFrameAge: TimeInterval)
    case failed(reason: String)
    case disconnected(reason: String)

    var diagnosticDescription: String {
        switch self {
        case .idle:
            return "idle"
        case .advertising:
            return "advertising"
        case .waitingForPhone:
            return "waitingForPhone"
        case .pairing:
            return "pairing"
        case .settingUp:
            return "settingUp"
        case .receivingVideo:
            return "receivingVideo"
        case .screenOff(let lastFrameAge):
            return "screenOff(lastFrameAge=\(String(format: "%.1f", lastFrameAge)))"
        case .stale(let lastFrameAge):
            return "stale(lastFrameAge=\(String(format: "%.1f", lastFrameAge)))"
        case .failed(let reason):
            return "failed(reason=\(reason))"
        case .disconnected(let reason):
            return "disconnected(reason=\(reason))"
        }
    }

    var statusText: String {
        switch self {
        case .idle:
            return "AirPlay: Idle"
        case .advertising:
            return "AirPlay: Advertising"
        case .waitingForPhone:
            return "AirPlay: Waiting for iPhone"
        case .pairing:
            return "AirPlay: Pairing"
        case .settingUp:
            return "AirPlay: Setting up video"
        case .receivingVideo:
            return "AirPlay: Receiving video"
        case .screenOff:
            return "AirPlay: Screen off"
        case .stale:
            return "AirPlay: Stale"
        case .failed:
            return "AirPlay: Failed"
        case .disconnected:
            return "AirPlay: Disconnected"
        }
    }

    var isReceivingVideo: Bool {
        if case .receivingVideo = self {
            return true
        }
        return false
    }

    var allowsFrameStalenessEvaluation: Bool {
        switch self {
        case .receivingVideo, .screenOff:
            return true
        default:
            return false
        }
    }

    static func inferredHealthForStaleVideo(
        lastFrameAge: TimeInterval,
        mirrorPacketAge: TimeInterval?,
        freshnessThreshold: TimeInterval
    ) -> AirPlayStreamHealth {
        if let mirrorPacketAge, mirrorPacketAge <= freshnessThreshold {
            return .screenOff(lastFrameAge: lastFrameAge)
        }
        return .stale(lastFrameAge: lastFrameAge)
    }
}
