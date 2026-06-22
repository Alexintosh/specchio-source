import Foundation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case usb(host: String, port: Int, deviceID: String? = nil)
    case wifi(host: String, port: Int)
    case failed(error: String)

    var isConnected: Bool {
        switch self {
        case .usb, .wifi: return true
        default: return false
        }
    }

    var baseURL: URL? {
        switch self {
        case .usb(let host, let port, _), .wifi(let host, let port):
            return URL(string: "http://\(host):\(port)")
        default: return nil
        }
    }
}

enum DisplayMode: String, CaseIterable {
    case auto = "Auto"
    case screenshot = "Screen"
    case accessibility = "Lite"
}
