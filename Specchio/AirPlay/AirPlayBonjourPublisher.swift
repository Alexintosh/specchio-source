import Foundation
import SystemConfiguration

private let airPlayBonjourLog = SpecchioLogger.airPlay

enum AirPlayFeatureMask {
    static let baseLowWord: UInt64 = 0x5A7FFFF7
    static let baseHighWord: UInt64 = 0x1E
    static let screenMultiCodecBit = 42

    static func receiverInfoFeatures(supportsScreenMultiCodec: Bool) -> UInt64 {
        (highWord(supportsScreenMultiCodec: supportsScreenMultiCodec) << 32) | baseLowWord
    }

    static func txtRecordFeatures(supportsScreenMultiCodec: Bool) -> String {
        String(format: "0x%llX,0x%llX", baseLowWord, highWord(supportsScreenMultiCodec: supportsScreenMultiCodec))
    }

    static func includesScreenMultiCodec(_ features: UInt64) -> Bool {
        (features & (UInt64(1) << UInt64(screenMultiCodecBit))) != 0
    }

    private static func highWord(supportsScreenMultiCodec: Bool) -> UInt64 {
        guard supportsScreenMultiCodec else { return baseHighWord }
        return baseHighWord | (UInt64(1) << UInt64(screenMultiCodecBit - 32))
    }
}

final class AirPlayBonjourPublisher: NSObject, NetServiceDelegate {
    enum Event: Equatable {
        case publishRequested(type: String, name: String, port: UInt16, txtKeys: [String])
        case didPublish(type: String, name: String, port: Int)
        case didNotPublish(type: String, name: String, error: String)
        case didStop(type: String, name: String, publisherID: UUID, remainingServices: Int)
    }

    struct Configuration: Equatable {
        let serviceName: String
        let controlPort: UInt16
        let publicKeyHex: String
        let persistentIdentifier: String
        let deviceID: String
        let supportsScreenMultiCodec: Bool

        init(
            serviceName: String,
            controlPort: UInt16,
            publicKeyHex: String,
            persistentIdentifier: String,
            deviceID: String,
            supportsScreenMultiCodec: Bool = false
        ) {
            self.serviceName = serviceName
            self.controlPort = controlPort
            self.publicKeyHex = publicKeyHex
            self.persistentIdentifier = persistentIdentifier
            self.deviceID = deviceID
            self.supportsScreenMultiCodec = supportsScreenMultiCodec
        }

        static func make(
            serviceName: String? = nil,
            controlPort: UInt16,
            publicKeyHex: String,
            supportsScreenMultiCodec: Bool = false
        ) -> Configuration {
            let resolvedServiceName: String
            if let serviceName {
                let sanitizedExplicitServiceName = sanitizedServiceName(serviceName)
                if sanitizedExplicitServiceName.isEmpty {
                    resolvedServiceName = defaultServiceName()
                    airPlayBonjourLog.warning("[AirPlayBonjourName] explicit service name branch=EMPTY_USING_DEFAULT resolved=\(resolvedServiceName, privacy: .public)")
                } else {
                    resolvedServiceName = sanitizedExplicitServiceName
                    airPlayBonjourLog.info("[AirPlayBonjourName] explicit service name branch=USING_EXPLICIT resolved=\(resolvedServiceName, privacy: .public)")
                }
            } else {
                resolvedServiceName = defaultServiceName()
            }

            return Configuration(
                serviceName: resolvedServiceName,
                controlPort: controlPort,
                publicKeyHex: publicKeyHex,
                persistentIdentifier: Self.persistentUUIDString(),
                deviceID: Self.persistentDeviceID(),
                supportsScreenMultiCodec: supportsScreenMultiCodec
            )
        }

        private static func defaultServiceName() -> String {
            let appName = "Specchio"
            guard let computerName = localComputerName() else {
                airPlayBonjourLog.warning("[AirPlayBonjourName] default service name branch=FALLBACK_APP_NAME resolved=\(appName, privacy: .public)")
                return appName
            }

            let serviceName = "\(appName) - \(computerName)"
            airPlayBonjourLog.info("[AirPlayBonjourName] default service name branch=COMPUTER_NAME computerName=\(computerName, privacy: .public) resolved=\(serviceName, privacy: .public)")
            return serviceName
        }

        private static func localComputerName() -> String? {
            var encoding: CFStringEncoding = 0
            guard let rawName = SCDynamicStoreCopyComputerName(nil, &encoding) as String? else {
                airPlayBonjourLog.warning("[AirPlayBonjourName] computer name branch=MISSING")
                return nil
            }

            let sanitizedName = sanitizedServiceName(rawName)
            guard !sanitizedName.isEmpty else {
                airPlayBonjourLog.warning("[AirPlayBonjourName] computer name branch=EMPTY raw=\(rawName, privacy: .public)")
                return nil
            }

            airPlayBonjourLog.info("[AirPlayBonjourName] computer name branch=FOUND raw=\(rawName, privacy: .public) sanitized=\(sanitizedName, privacy: .public) encoding=\(encoding)")
            return sanitizedName
        }

        private static func sanitizedServiceName(_ value: String) -> String {
            value
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        private static func persistentUUIDString() -> String {
            let key = "Specchio.AirPlay.PersistentIdentifier"
            if let stored = UserDefaults.standard.string(forKey: key), UUID(uuidString: stored) != nil {
                return stored
            }
            let value = UUID().uuidString.lowercased()
            UserDefaults.standard.set(value, forKey: key)
            return value
        }

        private static func persistentDeviceID() -> String {
            let key = "Specchio.AirPlay.DeviceID"
            if let stored = UserDefaults.standard.string(forKey: key), stored.split(separator: ":").count == 6 {
                return stored
            }

            let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
            let pairs = stride(from: 0, to: hex.count, by: 2).map { index -> String in
                let start = hex.index(hex.startIndex, offsetBy: index)
                let end = hex.index(start, offsetBy: 2)
                return String(hex[start..<end]).uppercased()
            }
            let value = pairs.joined(separator: ":")
            UserDefaults.standard.set(value, forKey: key)
            return value
        }
    }

    enum ServiceType {
        static let airPlay = "_airplay._tcp"
        static let raop = "_raop._tcp"
    }

    static let requiredInfoPlistServiceTypes = [
        ServiceType.airPlay,
        ServiceType.raop
    ]

    private var services: [NetService] = []
    private let onEvent: (Event) -> Void
    let identifier = UUID()

    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        super.init()
    }

    func start(configuration: Configuration) {
        guard services.isEmpty else {
            airPlayBonjourLog.info("[AirPlayBonjour] start skipped reason=already-advertising serviceCount=\(self.services.count)")
            return
        }

        let airPlayTXT = Self.airPlayTXTRecord(configuration: configuration)
        let raopTXT = Self.raopTXTRecord(configuration: configuration)
        publish(
            type: ServiceType.airPlay,
            name: configuration.serviceName,
            port: configuration.controlPort,
            txt: airPlayTXT
        )
        publish(
            type: ServiceType.raop,
            name: "\(configuration.deviceID.replacingOccurrences(of: ":", with: ""))@\(configuration.serviceName)",
            port: configuration.controlPort,
            txt: raopTXT
        )
    }

    func stop() {
        guard !services.isEmpty else {
            airPlayBonjourLog.info("[AirPlayBonjour] stop skipped reason=no-services")
            return
        }

        for service in services {
            airPlayBonjourLog.info("[AirPlayBonjour] stopping service type=\(service.type, privacy: .public) name=\(service.name, privacy: .public)")
            service.stop()
        }
        services.removeAll()
    }

    private func publish(type: String, name: String, port: UInt16, txt: [String: Data]) {
        let configuredServices = Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] ?? []
        let exactPlistMatch = configuredServices.contains(type)
        airPlayBonjourLog.info("[AirPlayBonjour] plist preflight bundle=\(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public) type=\(type, privacy: .public) exactMatch=\(exactPlistMatch) configured=\(configuredServices.joined(separator: ","), privacy: .public)")
        if !exactPlistMatch {
            airPlayBonjourLog.error("[AirPlayBonjour] plist preflight failed reason=missing-exact-service-type type=\(type, privacy: .public)")
        }

        for key in txt.keys.sorted() {
            let value = txt[key].flatMap { String(data: $0, encoding: .utf8) } ?? "<binary>"
            let loggedValue = key == "pk" ? "<public-key-\(value.count)-hex-chars>" : value
            airPlayBonjourLog.info("[AirPlayBonjour] TXT key=\(key, privacy: .public) value=\(loggedValue, privacy: .public) type=\(type, privacy: .public)")
        }

        let service = NetService(domain: "local.", type: type, name: name, port: Int32(port))
        service.delegate = self
        service.includesPeerToPeer = true
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        services.append(service)
        service.publish(options: [])
        onEvent(.publishRequested(type: type, name: name, port: port, txtKeys: txt.keys.sorted()))
    }

    static func airPlayTXTRecord(configuration: Configuration) -> [String: Data] {
        [
            "deviceid": Data(configuration.deviceID.utf8),
            "features": Data(AirPlayFeatureMask.txtRecordFeatures(supportsScreenMultiCodec: configuration.supportsScreenMultiCodec).utf8),
            "flags": Data("0x4".utf8),
            "model": Data("AppleTV5,3".utf8),
            "pi": Data(configuration.persistentIdentifier.utf8),
            "pk": Data(configuration.publicKeyHex.utf8),
            "pw": Data("false".utf8),
            "srcvers": Data("220.68".utf8),
            "vv": Data("2".utf8)
        ]
    }

    static func raopTXTRecord(configuration: Configuration) -> [String: Data] {
        [
            "am": Data("AppleTV5,3".utf8),
            "ft": Data(AirPlayFeatureMask.txtRecordFeatures(supportsScreenMultiCodec: configuration.supportsScreenMultiCodec).utf8),
            "pk": Data(configuration.publicKeyHex.utf8),
            "pw": Data("false".utf8),
            "sf": Data("0x4".utf8),
            "tp": Data("TCP".utf8),
            "vn": Data("65537".utf8),
            "vs": Data("220.68".utf8),
            "vv": Data("2".utf8)
        ]
    }

    func netServiceDidPublish(_ sender: NetService) {
        airPlayBonjourLog.info("[AirPlayBonjour] did publish type=\(sender.type, privacy: .public) name=\(sender.name, privacy: .public) port=\(sender.port)")
        onEvent(.didPublish(type: sender.type, name: sender.name, port: sender.port))
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        let errorText = String(describing: errorDict)
        airPlayBonjourLog.error("[AirPlayBonjour] did not publish type=\(sender.type, privacy: .public) name=\(sender.name, privacy: .public) error=\(errorText, privacy: .public)")
        onEvent(.didNotPublish(type: sender.type, name: sender.name, error: errorText))
    }

    func netServiceDidStop(_ sender: NetService) {
        airPlayBonjourLog.info("[AirPlayBonjour] did stop type=\(sender.type, privacy: .public) name=\(sender.name, privacy: .public)")
        services.removeAll { $0 === sender }
        onEvent(.didStop(
            type: sender.type,
            name: sender.name,
            publisherID: identifier,
            remainingServices: services.count
        ))
    }
}
