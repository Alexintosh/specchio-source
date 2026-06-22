import CommonCrypto
import CryptoKit
import Darwin
import Foundation

private let airPlayFairPlayLog = SpecchioLogger.airPlay

protocol AirPlayFairPlayProvider {
    var diagnosticName: String { get }

    func setupReply(for request: Data, mode: Int) throws -> Data
    func keyMessageReply(for request: Data) throws -> Data
    func decryptStreamKey(keyMessage: Data, encryptedKey: Data) throws -> Data
}

struct AirPlayFairPlaySession {
    enum Phase: Equatable {
        case idle
        case setupReceived(requestBytes: Int)
        case setupReplyProviderMissing(version: Int, mode: Int, requestBytes: Int)
        case setupReplyProvided(version: Int, mode: Int, responseBytes: Int)
        case keyMessageReceived(requestBytes: Int)
        case encryptedStreamKeyReceived(keyBytes: Int, ivBytes: Int, encryptionType: Int?)
        case streamKeyUnwrapped(keyBytes: Int)
        case streamConnectionReceived(String)
        case unsupported(reason: String)
        case ready(keyBytes: Int, ivBytes: Int)

        var diagnosticDescription: String {
            switch self {
            case .idle:
                return "idle"
            case .setupReceived(let requestBytes):
                return "setupReceived(requestBytes=\(requestBytes))"
            case .setupReplyProviderMissing(let version, let mode, let requestBytes):
                return "setupReplyProviderMissing(version=\(version), mode=\(mode), requestBytes=\(requestBytes))"
            case .setupReplyProvided(let version, let mode, let responseBytes):
                return "setupReplyProvided(version=\(version), mode=\(mode), responseBytes=\(responseBytes))"
            case .keyMessageReceived(let requestBytes):
                return "keyMessageReceived(requestBytes=\(requestBytes))"
            case .encryptedStreamKeyReceived(let keyBytes, let ivBytes, let encryptionType):
                return "encryptedStreamKeyReceived(keyBytes=\(keyBytes), ivBytes=\(ivBytes), encryptionType=\(encryptionType.map(String.init) ?? "nil"))"
            case .streamKeyUnwrapped(let keyBytes):
                return "streamKeyUnwrapped(keyBytes=\(keyBytes))"
            case .streamConnectionReceived(let streamConnectionID):
                return "streamConnectionReceived(idBytes=\(streamConnectionID.utf8.count))"
            case .unsupported(let reason):
                return "unsupported(reason=\(reason))"
            case .ready(let keyBytes, let ivBytes):
                return "ready(keyBytes=\(keyBytes), ivBytes=\(ivBytes))"
            }
        }
    }

    enum DecryptionResult: Equatable {
        case decrypted(Data)
        case unavailable(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var streamKey: Data?
    private(set) var streamIV: Data?
    private(set) var unwrappedStreamKey: Data?
    private var fairPlayKeyMessage: Data?
    private var encryptedStreamKey: Data?
    private var encryptedStreamIV: Data?
    private var pairVerifySharedSecret: Data?
    private var streamConnectionID: String?
    private var videoDecryptor: AirPlayAESCTRStream?
    private let provider: AirPlayFairPlayProvider?
    private let providerDiagnostic: String

    init() {
        let lookup = AirPlayFairPlayExternalProvider.lookupFromEnvironment()
        self.init(
            provider: lookup.provider,
            providerDiagnosticDescription: lookup.diagnosticDescription
        )
    }

    init(
        provider: AirPlayFairPlayProvider?,
        providerDiagnosticDescription: String? = nil
    ) {
        self.provider = provider
        self.providerDiagnostic = providerDiagnosticDescription ?? provider.map { "loaded(\($0.diagnosticName))" } ?? "missing"
        if let provider {
            airPlayFairPlayLog.info("[AirPlayFairPlay] provider branch=LOADED name=\(provider.diagnosticName, privacy: .public)")
        } else {
            let diagnostic = providerDiagnostic
            airPlayFairPlayLog.warning("[AirPlayFairPlay] provider branch=UNAVAILABLE diagnostic=\(diagnostic, privacy: .public)")
        }
    }

    var providerDiagnosticDescription: String {
        providerDiagnostic
    }

    var setupFailureDescription: String {
        if provider == nil {
            return "AirPlay FairPlay provider is unavailable; encrypted video cannot be decoded on this Mac."
        }
        if case .unsupported(let reason) = phase {
            return reason
        }
        return "AirPlay FairPlay setup is not complete; encrypted video cannot be decoded yet"
    }

    var canDecryptVideo: Bool {
        streamKey?.count == Self.aes128ByteCount && streamIV?.count == Self.aes128ByteCount && videoDecryptor != nil
    }

    var audioKeyMaterial: (key: Data, iv: Data)? {
        guard let unwrappedStreamKey,
              let encryptedStreamIV,
              unwrappedStreamKey.count == Self.aes128ByteCount,
              encryptedStreamIV.count == Self.aes128ByteCount else {
            return nil
        }
        return (key: unwrappedStreamKey, iv: encryptedStreamIV)
    }

    var canDecryptAudio: Bool {
        audioKeyMaterial != nil
    }

    func audioReadinessFailureReason(trigger: String) -> String? {
        if canDecryptAudio {
            let keyBytes = audioKeyMaterial?.key.count ?? 0
            let ivBytes = audioKeyMaterial?.iv.count ?? 0
            airPlayFairPlayLog.info("[AirPlayFairPlay] readiness branch=AUDIO_READY trigger=\(trigger, privacy: .public) keyBytes=\(keyBytes) ivBytes=\(ivBytes)")
            return nil
        }

        if let streamKeyReason = streamKeyReadinessFailureReason(trigger: trigger) {
            airPlayFairPlayLog.warning("[AirPlayFairPlay] readiness branch=AUDIO_STREAM_KEY_UNAVAILABLE trigger=\(trigger, privacy: .public) reason=\(streamKeyReason, privacy: .public)")
            return streamKeyReason
        }

        guard let encryptedStreamIV else {
            let reason = "AirPlay SETUP has not provided the audio stream IV"
            airPlayFairPlayLog.warning("[AirPlayFairPlay] readiness branch=AUDIO_IV_MISSING trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public)")
            return reason
        }

        guard encryptedStreamIV.count == Self.aes128ByteCount else {
            let reason = "AirPlay audio stream IV has \(encryptedStreamIV.count) bytes, expected \(Self.aes128ByteCount)"
            airPlayFairPlayLog.warning("[AirPlayFairPlay] readiness branch=AUDIO_IV_INVALID trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public)")
            return reason
        }

        let reason = "AirPlay audio decryption is not ready"
        airPlayFairPlayLog.warning("[AirPlayFairPlay] readiness branch=AUDIO_WAITING trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public)")
        return reason
    }

    func streamKeyReadinessFailureReason(trigger: String) -> String? {
        if unwrappedStreamKey != nil {
            let keyBytes = unwrappedStreamKey?.count ?? 0
            airPlayFairPlayLog.info("[AirPlayFairPlay] readiness branch=STREAM_KEY_READY trigger=\(trigger, privacy: .public) keyBytes=\(keyBytes)")
            return nil
        }

        if case .unsupported(let reason) = phase {
            airPlayFairPlayLog.warning("[AirPlayFairPlay] readiness branch=STREAM_KEY_UNSUPPORTED trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public)")
            return reason
        }

        guard provider != nil else {
            let reason = "AirPlay FairPlay provider is not configured"
            airPlayFairPlayLog.warning("[AirPlayFairPlay] readiness branch=STREAM_KEY_PROVIDER_MISSING trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public)")
            return reason
        }

        guard fairPlayKeyMessage != nil else {
            let reason = "AirPlay FairPlay key message has not been received"
            airPlayFairPlayLog.warning("[AirPlayFairPlay] readiness branch=STREAM_KEY_MESSAGE_MISSING trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public)")
            return reason
        }

        guard encryptedStreamKey != nil, encryptedStreamIV != nil else {
            let reason = "AirPlay SETUP has not provided encrypted stream key material"
            airPlayFairPlayLog.warning("[AirPlayFairPlay] readiness branch=STREAM_KEY_ENCRYPTED_MATERIAL_MISSING trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public)")
            return reason
        }

        let reason = "AirPlay FairPlay stream key has not been unwrapped yet"
        airPlayFairPlayLog.warning("[AirPlayFairPlay] readiness branch=STREAM_KEY_WAITING trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public) pairSharedSecretBytes=\(pairVerifySharedSecret?.count ?? 0)")
        return reason
    }

    func videoReadinessFailureReason(trigger: String) -> String? {
        if canDecryptVideo {
            let keyBytes = streamKey?.count ?? 0
            let ivBytes = streamIV?.count ?? 0
            airPlayFairPlayLog.info("[AirPlayFairPlay] readiness branch=VIDEO_READY trigger=\(trigger, privacy: .public) keyBytes=\(keyBytes) ivBytes=\(ivBytes)")
            return nil
        }

        if let streamKeyReason = streamKeyReadinessFailureReason(trigger: trigger) {
            airPlayFairPlayLog.warning("[AirPlayFairPlay] readiness branch=VIDEO_STREAM_KEY_UNAVAILABLE trigger=\(trigger, privacy: .public) reason=\(streamKeyReason, privacy: .public)")
            return streamKeyReason
        }

        guard streamConnectionID != nil else {
            let reason = "AirPlay mirror streamConnectionID has not been received"
            airPlayFairPlayLog.warning("[AirPlayFairPlay] readiness branch=VIDEO_STREAM_CONNECTION_MISSING trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public)")
            return reason
        }

        guard streamKey != nil, streamIV != nil else {
            let reason = "AirPlay video key material has not been derived yet"
            airPlayFairPlayLog.warning("[AirPlayFairPlay] readiness branch=VIDEO_KEY_MATERIAL_MISSING trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public)")
            return reason
        }

        guard videoDecryptor != nil else {
            let reason = "AirPlay video decryptor is unavailable"
            airPlayFairPlayLog.warning("[AirPlayFairPlay] readiness branch=VIDEO_DECRYPTOR_MISSING trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public)")
            return reason
        }

        let reason = "AirPlay video decryption is not ready"
        airPlayFairPlayLog.warning("[AirPlayFairPlay] readiness branch=VIDEO_WAITING trigger=\(trigger, privacy: .public) reason=\(reason, privacy: .public)")
        return reason
    }

    mutating func reset(reason: String) {
        let previousPhase = phase.diagnosticDescription
        airPlayFairPlayLog.info("[AirPlayFairPlay] reset reason=\(reason, privacy: .public) previousPhase=\(previousPhase, privacy: .public)")
        phase = .idle
        streamKey = nil
        streamIV = nil
        unwrappedStreamKey = nil
        fairPlayKeyMessage = nil
        encryptedStreamKey = nil
        encryptedStreamIV = nil
        pairVerifySharedSecret = nil
        streamConnectionID = nil
        videoDecryptor = nil
    }

    mutating func handleFPSetup(
        _ request: AirPlayControlRequest,
        routeName: String = "/fp-setup"
    ) -> AirPlayControlResponse {
        phase = .setupReceived(requestBytes: request.body.count)
        let encryptionTypeHeader = request.headerValue("X-Apple-ET") ?? "nil"
        airPlayFairPlayLog.info("[AirPlayFairPlay] fp-setup dispatch route=\(routeName, privacy: .public) bodyBytes=\(request.body.count) xAppleET=\(encryptionTypeHeader, privacy: .public)")

        switch request.body.count {
        case Self.setupChallengeByteCount:
            return handleSetupChallenge(request.body, routeName: routeName)
        case Self.keyMessageByteCount:
            return handleKeyMessage(request.body, routeName: routeName)
        default:
            let reason = "Unsupported AirPlay FairPlay setup body length \(request.body.count)"
            airPlayFairPlayLog.warning("[AirPlayFairPlay] fp-setup branch=UNSUPPORTED_LENGTH route=\(routeName, privacy: .public) bodyBytes=\(request.body.count)")
            phase = .unsupported(reason: reason)
            return .badRequest(reason)
        }
    }

    mutating func observeEncryptedStreamKey(
        encryptedKey: Data?,
        encryptedIV: Data?,
        encryptionType: Int?,
        pairVerifySharedSecret: Data?
    ) {
        let keyBytes = encryptedKey?.count ?? 0
        let ivBytes = encryptedIV?.count ?? 0
        let sharedSecretBytes = pairVerifySharedSecret?.count ?? 0
        airPlayFairPlayLog.info("[AirPlayFairPlay] setup key material observed keyBytes=\(keyBytes) ivBytes=\(ivBytes) encryptionType=\(encryptionType.map(String.init) ?? "nil", privacy: .public) pairSharedSecretBytes=\(sharedSecretBytes)")

        guard let encryptedKey, let encryptedIV else {
            let reason = "AirPlay SETUP did not include both ekey and eiv"
            airPlayFairPlayLog.warning("[AirPlayFairPlay] setup key material branch=MISSING reason=\(reason, privacy: .public)")
            phase = .unsupported(reason: reason)
            return
        }

        self.encryptedStreamKey = encryptedKey
        self.encryptedStreamIV = encryptedIV
        if let pairVerifySharedSecret {
            self.pairVerifySharedSecret = pairVerifySharedSecret
            airPlayFairPlayLog.info("[AirPlayFairPlay] setup key material branch=PAIR_SECRET_OBSERVED bytes=\(pairVerifySharedSecret.count)")
        } else {
            airPlayFairPlayLog.warning("[AirPlayFairPlay] setup key material branch=PAIR_SECRET_MISSING")
        }
        phase = .encryptedStreamKeyReceived(
            keyBytes: encryptedKey.count,
            ivBytes: encryptedIV.count,
            encryptionType: encryptionType
        )

        unwrapStreamKeyIfPossible(trigger: "SETUP key material")
        installVideoStreamKeyIfPossible(trigger: "SETUP key material")
    }

    mutating func observeStreamConnectionID(
        _ streamConnectionID: String?,
        pairVerifySharedSecret: Data?
    ) {
        guard let streamConnectionID, !streamConnectionID.isEmpty else {
            airPlayFairPlayLog.warning("[AirPlayFairPlay] stream connection branch=MISSING")
            return
        }

        self.streamConnectionID = streamConnectionID
        if let pairVerifySharedSecret {
            self.pairVerifySharedSecret = pairVerifySharedSecret
            airPlayFairPlayLog.info("[AirPlayFairPlay] stream connection branch=PAIR_SECRET_OBSERVED bytes=\(pairVerifySharedSecret.count)")
        } else {
            airPlayFairPlayLog.warning("[AirPlayFairPlay] stream connection branch=PAIR_SECRET_MISSING")
        }
        phase = .streamConnectionReceived(streamConnectionID)
        airPlayFairPlayLog.info("[AirPlayFairPlay] stream connection branch=OBSERVED id=\(AirPlayStreamConnectionID.diagnosticPreview(streamConnectionID), privacy: .public)")

        guard streamKey == nil else {
            let keyBytes = streamKey?.count ?? 0
            let ivBytes = streamIV?.count ?? 0
            airPlayFairPlayLog.info("[AirPlayFairPlay] stream connection branch=KEY_ALREADY_READY keyBytes=\(keyBytes) ivBytes=\(ivBytes)")
            return
        }

        guard encryptedStreamKey != nil, encryptedStreamIV != nil else {
            airPlayFairPlayLog.warning("[AirPlayFairPlay] stream connection branch=WAITING_FOR_ENCRYPTED_KEY_MATERIAL")
            return
        }

        let encryptedKeyBytes = encryptedStreamKey?.count ?? 0
        let encryptedIVBytes = encryptedStreamIV?.count ?? 0
        airPlayFairPlayLog.info("[AirPlayFairPlay] stream connection branch=KEY_MATERIAL_AVAILABLE encryptedKeyBytes=\(encryptedKeyBytes) encryptedIVBytes=\(encryptedIVBytes)")
        unwrapStreamKeyIfPossible(trigger: "stream connection")
        installVideoStreamKeyIfPossible(trigger: "stream connection")
    }

    private mutating func handleSetupChallenge(_ body: Data, routeName: String) -> AirPlayControlResponse {
        guard body.starts(with: Self.fairPlayMarker) else {
            let reason = "AirPlay FairPlay setup challenge did not start with FPLY marker"
            airPlayFairPlayLog.warning("[AirPlayFairPlay] fp-setup branch=BAD_MARKER route=\(routeName, privacy: .public) bodyBytes=\(body.count)")
            phase = .unsupported(reason: reason)
            return .badRequest(reason)
        }

        let version = Int(body[body.startIndex + 4])
        let mode = Int(body[body.startIndex + 14])
        airPlayFairPlayLog.info("[AirPlayFairPlay] fp-setup branch=SETUP_CHALLENGE route=\(routeName, privacy: .public) version=\(version) mode=\(mode) bodyBytes=\(body.count)")

        guard version == Self.supportedFairPlayVersion else {
            let reason = "Unsupported AirPlay FairPlay version \(version)"
            airPlayFairPlayLog.warning("[AirPlayFairPlay] fp-setup branch=UNSUPPORTED_VERSION route=\(routeName, privacy: .public) version=\(version) mode=\(mode)")
            phase = .unsupported(reason: reason)
            return .badRequest(reason)
        }

        let reason = "FairPlay setup reply provider is intentionally not bundled until reviewed"
        guard let provider else {
            phase = .setupReplyProviderMissing(version: version, mode: mode, requestBytes: body.count)
            airPlayFairPlayLog.warning("[AirPlayFairPlay] fp-setup branch=PROVIDER_MISSING route=\(routeName, privacy: .public) version=\(version) mode=\(mode) reason=\(reason, privacy: .public)")
            return .notImplemented(reason)
        }

        do {
            let reply = try provider.setupReply(for: body, mode: mode)
            guard reply.count == Self.setupReplyByteCount else {
                let reason = "AirPlay FairPlay setup provider returned \(reply.count) bytes, expected \(Self.setupReplyByteCount)"
                phase = .unsupported(reason: reason)
                airPlayFairPlayLog.error("[AirPlayFairPlay] fp-setup branch=PROVIDER_BAD_SETUP_REPLY route=\(routeName, privacy: .public) provider=\(provider.diagnosticName, privacy: .public) responseBytes=\(reply.count)")
                return .badRequest(reason)
            }

            phase = .setupReplyProvided(version: version, mode: mode, responseBytes: reply.count)
            airPlayFairPlayLog.info("[AirPlayFairPlay] fp-setup branch=PROVIDER_SETUP_REPLY route=\(routeName, privacy: .public) provider=\(provider.diagnosticName, privacy: .public) responseBytes=\(reply.count)")
            return .ok(headers: ["Content-Type": "application/octet-stream"], body: reply)
        } catch {
            let reason = "AirPlay FairPlay setup provider failed: \(error.localizedDescription)"
            phase = .unsupported(reason: reason)
            airPlayFairPlayLog.error("[AirPlayFairPlay] fp-setup branch=PROVIDER_SETUP_FAILED route=\(routeName, privacy: .public) provider=\(provider.diagnosticName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return .badRequest(reason)
        }
    }

    private mutating func handleKeyMessage(_ body: Data, routeName: String) -> AirPlayControlResponse {
        guard body.starts(with: Self.fairPlayMarker) else {
            let reason = "AirPlay FairPlay key message did not start with FPLY marker"
            airPlayFairPlayLog.warning("[AirPlayFairPlay] fp-setup branch=KEY_MESSAGE_BAD_MARKER route=\(routeName, privacy: .public) bodyBytes=\(body.count)")
            phase = .unsupported(reason: reason)
            return .badRequest(reason)
        }

        let version = Int(body[body.startIndex + 4])
        airPlayFairPlayLog.info("[AirPlayFairPlay] fp-setup branch=KEY_MESSAGE route=\(routeName, privacy: .public) version=\(version) bodyBytes=\(body.count)")

        guard version == Self.supportedFairPlayVersion else {
            let reason = "Unsupported AirPlay FairPlay key-message version \(version)"
            airPlayFairPlayLog.warning("[AirPlayFairPlay] fp-setup branch=KEY_MESSAGE_UNSUPPORTED_VERSION route=\(routeName, privacy: .public) version=\(version)")
            phase = .unsupported(reason: reason)
            return .badRequest(reason)
        }

        fairPlayKeyMessage = body
        phase = .keyMessageReceived(requestBytes: body.count)
        let reason = "FairPlay key-message unwrap provider is intentionally not bundled until reviewed"
        guard let provider else {
            airPlayFairPlayLog.warning("[AirPlayFairPlay] fp-setup branch=KEY_MESSAGE_PROVIDER_MISSING route=\(routeName, privacy: .public) bodyBytes=\(body.count) reason=\(reason, privacy: .public)")
            return .notImplemented(reason)
        }

        do {
            let reply = try provider.keyMessageReply(for: body)
            guard reply.count == Self.keyMessageReplyByteCount else {
                let reason = "AirPlay FairPlay key-message provider returned \(reply.count) bytes, expected \(Self.keyMessageReplyByteCount)"
                phase = .unsupported(reason: reason)
                airPlayFairPlayLog.error("[AirPlayFairPlay] fp-setup branch=PROVIDER_BAD_KEY_REPLY route=\(routeName, privacy: .public) provider=\(provider.diagnosticName, privacy: .public) responseBytes=\(reply.count)")
                return .badRequest(reason)
            }

            airPlayFairPlayLog.info("[AirPlayFairPlay] fp-setup branch=PROVIDER_KEY_REPLY route=\(routeName, privacy: .public) provider=\(provider.diagnosticName, privacy: .public) responseBytes=\(reply.count)")
            return .ok(headers: ["Content-Type": "application/octet-stream"], body: reply)
        } catch {
            let reason = "AirPlay FairPlay key-message provider failed: \(error.localizedDescription)"
            phase = .unsupported(reason: reason)
            airPlayFairPlayLog.error("[AirPlayFairPlay] fp-setup branch=PROVIDER_KEY_FAILED route=\(routeName, privacy: .public) provider=\(provider.diagnosticName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return .badRequest(reason)
        }
    }

    mutating func installStreamKeyForTestsOnly(key: Data, iv: Data) {
        do {
            try installStreamKey(key: key, iv: iv, trigger: "tests")
        } catch {
            airPlayFairPlayLog.error("[AirPlayFairPlay] test key install failed error=\(error.localizedDescription, privacy: .public)")
            streamKey = key
            streamIV = iv
            videoDecryptor = nil
            phase = .unsupported(reason: error.localizedDescription)
        }
    }

    mutating func decryptVideoPayload(_ payload: Data) -> DecryptionResult {
        guard canDecryptVideo else {
            let reason = "AirPlay video payload is encrypted and stream key material is unavailable"
            let currentPhase = phase.diagnosticDescription
            airPlayFairPlayLog.warning("[AirPlayFairPlay] decrypt branch=UNAVAILABLE payloadBytes=\(payload.count) phase=\(currentPhase, privacy: .public)")
            return .unavailable(reason)
        }

        guard let videoDecryptor else {
            let reason = "AirPlay video decryptor is unavailable"
            airPlayFairPlayLog.warning("[AirPlayFairPlay] decrypt branch=NO_DECRYPTOR payloadBytes=\(payload.count)")
            return .unavailable(reason)
        }

        do {
            let decrypted = try videoDecryptor.crypt(payload)
            airPlayFairPlayLog.info("[AirPlayFairPlay] decrypt branch=OK payloadBytes=\(payload.count) decryptedBytes=\(decrypted.count)")
            return .decrypted(decrypted)
        } catch {
            let reason = "AirPlay AES-CTR video decryption failed: \(error.localizedDescription)"
            airPlayFairPlayLog.error("[AirPlayFairPlay] decrypt branch=FAILED payloadBytes=\(payload.count) error=\(error.localizedDescription, privacy: .public)")
            return .unavailable(reason)
        }
    }

    @discardableResult
    private mutating func unwrapStreamKeyIfPossible(trigger: String) -> Bool {
        guard unwrappedStreamKey == nil else {
            let keyBytes = unwrappedStreamKey?.count ?? 0
            airPlayFairPlayLog.info("[AirPlayFairPlay] unwrap branch=ALREADY_READY trigger=\(trigger, privacy: .public) keyBytes=\(keyBytes)")
            return true
        }

        guard let provider else {
            let keyMessageBytes = fairPlayKeyMessage?.count ?? 0
            airPlayFairPlayLog.warning("[AirPlayFairPlay] unwrap branch=PROVIDER_MISSING trigger=\(trigger, privacy: .public) keyMessageBytes=\(keyMessageBytes)")
            return false
        }

        guard let fairPlayKeyMessage else {
            airPlayFairPlayLog.warning("[AirPlayFairPlay] unwrap branch=NO_FAIRPLAY_KEY_MESSAGE trigger=\(trigger, privacy: .public)")
            return false
        }

        guard let encryptedStreamKey else {
            airPlayFairPlayLog.warning("[AirPlayFairPlay] unwrap branch=NO_ENCRYPTED_KEY trigger=\(trigger, privacy: .public)")
            return false
        }

        do {
            let fairPlayKey = try provider.decryptStreamKey(
                keyMessage: fairPlayKeyMessage,
                encryptedKey: encryptedStreamKey
            )
            guard fairPlayKey.count == Self.aes128ByteCount else {
                let reason = "AirPlay FairPlay provider returned \(fairPlayKey.count) key bytes, expected \(Self.aes128ByteCount)"
                phase = .unsupported(reason: reason)
                airPlayFairPlayLog.error("[AirPlayFairPlay] unwrap branch=BAD_PROVIDER_KEY provider=\(provider.diagnosticName, privacy: .public) keyBytes=\(fairPlayKey.count)")
                return false
            }

            let pairSharedSecretBytes = pairVerifySharedSecret?.count ?? 0
            let keySource = Self.streamKeySource(pairVerifySharedSecret: pairVerifySharedSecret)
            let audioStreamKey = Self.streamKey(
                fromFairPlayKey: fairPlayKey,
                pairVerifySharedSecret: pairVerifySharedSecret
            )
            unwrappedStreamKey = audioStreamKey
            phase = .streamKeyUnwrapped(keyBytes: audioStreamKey.count)
            airPlayFairPlayLog.info("[AirPlayFairPlay] unwrap branch=OK provider=\(provider.diagnosticName, privacy: .public) trigger=\(trigger, privacy: .public) fairPlayKeyBytes=\(fairPlayKey.count) streamKeyBytes=\(audioStreamKey.count) keySource=\(keySource, privacy: .public) pairSharedSecretBytes=\(pairSharedSecretBytes)")
            return true
        } catch {
            let reason = "AirPlay FairPlay stream-key unwrap failed: \(error.localizedDescription)"
            phase = .unsupported(reason: reason)
            airPlayFairPlayLog.error("[AirPlayFairPlay] unwrap branch=FAILED provider=\(provider.diagnosticName, privacy: .public) trigger=\(trigger, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private mutating func installVideoStreamKeyIfPossible(trigger: String) -> Bool {
        guard streamKey == nil else {
            let keyBytes = streamKey?.count ?? 0
            let ivBytes = streamIV?.count ?? 0
            airPlayFairPlayLog.info("[AirPlayFairPlay] video key branch=ALREADY_READY trigger=\(trigger, privacy: .public) keyBytes=\(keyBytes) ivBytes=\(ivBytes)")
            return true
        }

        guard let unwrappedStreamKey else {
            airPlayFairPlayLog.warning("[AirPlayFairPlay] video key branch=WAITING_FOR_UNWRAPPED_KEY trigger=\(trigger, privacy: .public)")
            return false
        }

        guard let streamConnectionID, !streamConnectionID.isEmpty else {
            airPlayFairPlayLog.warning("[AirPlayFairPlay] video key branch=WAITING_FOR_STREAM_CONNECTION trigger=\(trigger, privacy: .public)")
            return false
        }

        let derived = Self.videoKeyMaterial(
            audioStreamKey: unwrappedStreamKey,
            streamConnectionID: streamConnectionID
        )
        do {
            try installStreamKey(key: derived.key, iv: derived.iv, trigger: trigger)
            airPlayFairPlayLog.info("[AirPlayFairPlay] video key branch=DERIVED trigger=\(trigger, privacy: .public) streamConnectionID=\(AirPlayStreamConnectionID.diagnosticPreview(streamConnectionID), privacy: .public)")
            return true
        } catch {
            phase = .unsupported(reason: error.localizedDescription)
            airPlayFairPlayLog.error("[AirPlayFairPlay] video key branch=INSTALL_FAILED trigger=\(trigger, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private mutating func installStreamKey(key: Data, iv: Data, trigger: String) throws {
        guard key.count == Self.aes128ByteCount else {
            throw AirPlayFairPlayError.invalidAESKeyLength(key.count)
        }
        guard iv.count == Self.aes128ByteCount else {
            throw AirPlayFairPlayError.invalidAESIVLength(iv.count)
        }

        streamKey = key
        streamIV = iv
        videoDecryptor = try AirPlayAESCTRStream(key: key, iv: iv)
        phase = .ready(keyBytes: key.count, ivBytes: iv.count)
        airPlayFairPlayLog.info("[AirPlayFairPlay] stream key installed trigger=\(trigger, privacy: .public) keyBytes=\(key.count) ivBytes=\(iv.count)")
    }

    static func streamKey(
        fromFairPlayKey fairPlayKey: Data,
        pairVerifySharedSecret: Data?
    ) -> Data {
        guard let pairVerifySharedSecret else {
            airPlayFairPlayLog.info("[AirPlayFairPlay] stream key branch=RAW_NO_PAIR_SECRET fairPlayKeyBytes=\(fairPlayKey.count)")
            return fairPlayKey
        }

        guard pairVerifySharedSecret.count == 32 else {
            airPlayFairPlayLog.warning("[AirPlayFairPlay] stream key branch=RAW_INVALID_PAIR_SECRET fairPlayKeyBytes=\(fairPlayKey.count) pairSharedSecretBytes=\(pairVerifySharedSecret.count)")
            return fairPlayKey
        }

        let hashedStreamKey = Data(SHA512.hash(data: fairPlayKey + pairVerifySharedSecret).prefix(aes128ByteCount))
        airPlayFairPlayLog.info("[AirPlayFairPlay] stream key branch=SHA512_PAIR_VERIFY fairPlayKeyBytes=\(fairPlayKey.count) pairSharedSecretBytes=\(pairVerifySharedSecret.count) streamKeyBytes=\(hashedStreamKey.count)")
        return hashedStreamKey
    }

    private static func streamKeySource(pairVerifySharedSecret: Data?) -> String {
        guard let pairVerifySharedSecret else {
            return "FAIRPLAY_EKEY_RAW_NO_PAIR_SECRET"
        }
        guard pairVerifySharedSecret.count == 32 else {
            return "FAIRPLAY_EKEY_RAW_INVALID_PAIR_SECRET_LENGTH"
        }
        return "FAIRPLAY_EKEY_SHA512_PAIR_VERIFY"
    }

    static func videoKeyMaterial(
        audioStreamKey: Data,
        streamConnectionID: String
    ) -> (key: Data, iv: Data) {
        let normalizedStreamConnectionID = AirPlayStreamConnectionID.normalizedString(from: streamConnectionID) ?? streamConnectionID
        let keySeed = Data("AirPlayStreamKey\(normalizedStreamConnectionID)".utf8) + audioStreamKey
        let ivSeed = Data("AirPlayStreamIV\(normalizedStreamConnectionID)".utf8) + audioStreamKey
        return (
            key: Data(SHA512.hash(data: keySeed).prefix(aes128ByteCount)),
            iv: Data(SHA512.hash(data: ivSeed).prefix(aes128ByteCount))
        )
    }

    private static let setupChallengeByteCount = 16
    private static let setupReplyByteCount = 142
    private static let keyMessageByteCount = 164
    private static let keyMessageReplyByteCount = 32
    private static let aes128ByteCount = 16
    private static let supportedFairPlayVersion = 3
    private static let fairPlayMarker = Data([0x46, 0x50, 0x4c, 0x59])
}

enum AirPlayFairPlayError: LocalizedError {
    case invalidAESKeyLength(Int)
    case invalidAESIVLength(Int)
    case aesCTRCreateFailed(CCCryptorStatus)
    case aesCTRUpdateFailed(CCCryptorStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAESKeyLength(let length):
            return "AES key length \(length) is invalid"
        case .invalidAESIVLength(let length):
            return "AES IV length \(length) is invalid"
        case .aesCTRCreateFailed(let status):
            return "AES-CTR create failed with status \(status)"
        case .aesCTRUpdateFailed(let status):
            return "AES-CTR update failed with status \(status)"
        }
    }
}

enum AirPlayFairPlayProviderError: LocalizedError {
    case openFailed(path: String, reason: String)
    case symbolMissing(name: String, path: String)
    case unsupportedABI(path: String)
    case contextCreateFailed(path: String)
    case callFailed(name: String, status: Int32)
    case outputTooLarge(name: String, capacity: Int, actual: UInt)

    var errorDescription: String? {
        switch self {
        case .openFailed(let path, let reason):
            return "Could not load FairPlay provider at \(path): \(reason)"
        case .symbolMissing(let name, let path):
            return "FairPlay provider \(path) is missing symbol \(name)"
        case .unsupportedABI(let path):
            return "FairPlay provider \(path) does not expose the Specchio or fairplay C ABI"
        case .contextCreateFailed(let path):
            return "FairPlay provider \(path) failed to create a fairplay context"
        case .callFailed(let name, let status):
            return "FairPlay provider call \(name) failed with status \(status)"
        case .outputTooLarge(let name, let capacity, let actual):
            return "FairPlay provider call \(name) returned \(actual) bytes, larger than capacity \(capacity)"
        }
    }
}

final class AirPlayFairPlayExternalProvider: AirPlayFairPlayProvider {
    private typealias UnaryFunction = @convention(c) (
        UnsafePointer<UInt8>,
        UInt,
        UnsafeMutablePointer<UInt8>,
        UnsafeMutablePointer<UInt>
    ) -> Int32
    private typealias DecryptFunction = @convention(c) (
        UnsafePointer<UInt8>,
        UInt,
        UnsafePointer<UInt8>,
        UInt,
        UnsafeMutablePointer<UInt8>,
        UnsafeMutablePointer<UInt>
    ) -> Int32
    private typealias FairPlayInitFunction = @convention(c) (
        UnsafeMutableRawPointer?
    ) -> UnsafeMutableRawPointer?
    private typealias FairPlayUnaryFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<UInt8>,
        UnsafeMutablePointer<UInt8>
    ) -> Int32
    private typealias FairPlayDestroyFunction = @convention(c) (
        UnsafeMutableRawPointer?
    ) -> Void

    private enum Backend {
        case specchio(
            setupReply: UnaryFunction,
            keyMessageReply: UnaryFunction,
            decryptKey: DecryptFunction
        )
        case fairplay(
            context: UnsafeMutableRawPointer,
            setup: FairPlayUnaryFunction,
            handshake: FairPlayUnaryFunction,
            decrypt: FairPlayUnaryFunction,
            destroy: FairPlayDestroyFunction
        )

        var diagnosticName: String {
            switch self {
            case .specchio:
                return "specchio-abi"
            case .fairplay:
                return "fairplay-abi"
            }
        }
    }

    private static let providerPathEnvironmentKey = "SPECCHIO_AIRPLAY_FAIRPLAY_PROVIDER"
    private static let defaultProviderDirectoryName = "AirPlayFairPlay"
    private static let defaultProviderFileNames = [
        "libSpecchioAirPlayFairPlayProvider.dylib",
        "libfairplay.dylib"
    ]
    private static let setupReplySymbol = "specchio_airplay_fairplay_setup_reply"
    private static let keyMessageReplySymbol = "specchio_airplay_fairplay_key_message_reply"
    private static let decryptKeySymbol = "specchio_airplay_fairplay_decrypt_key"
    private static let fairPlayInitSymbol = "fairplay_init"
    private static let fairPlaySetupSymbol = "fairplay_setup"
    private static let fairPlayHandshakeSymbol = "fairplay_handshake"
    private static let fairPlayDecryptSymbol = "fairplay_decrypt"
    private static let fairPlayDestroySymbol = "fairplay_destroy"

    let diagnosticName: String
    private let handle: UnsafeMutableRawPointer
    private let backend: Backend

    struct LookupResult {
        let provider: AirPlayFairPlayExternalProvider?
        let diagnosticDescription: String
    }

    static func makeFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> AirPlayFairPlayExternalProvider? {
        lookupFromEnvironment(environment: environment, fileManager: fileManager).provider
    }

    static func lookupFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> LookupResult {
        let bundledProviderDirectory = Bundle.main.privateFrameworksURL
        let applicationSupportDirectory = userApplicationSupportDirectory(fileManager: fileManager)
        return lookupFromEnvironment(
            environment: environment,
            fileManager: fileManager,
            bundledProviderDirectory: bundledProviderDirectory,
            applicationSupportDirectory: applicationSupportDirectory
        )
    }

    static func lookupFromEnvironment(
        environment: [String: String],
        fileManager: FileManager = .default,
        bundledProviderDirectory: URL?,
        applicationSupportDirectory: URL?
    ) -> LookupResult {
        let candidates = providerPathCandidates(
            environment: environment,
            bundledProviderDirectory: bundledProviderDirectory,
            applicationSupportDirectory: applicationSupportDirectory,
            fileExists: { fileManager.fileExists(atPath: $0.path) }
        )
        guard !candidates.isEmpty else {
            let searchPaths = bundledProviderURLs(frameworksDirectory: bundledProviderDirectory)
                + defaultProviderURLs(applicationSupportDirectory: applicationSupportDirectory)
            airPlayFairPlayLog.warning("[AirPlayFairPlayProvider] lookup branch=NO_CANDIDATES envKey=\(providerPathEnvironmentKey, privacy: .public) defaultPaths=\(searchPaths.map(\.path).joined(separator: ","), privacy: .public)")
            return LookupResult(provider: nil, diagnosticDescription: "missing(no-candidates)")
        }

        var failures: [String] = []
        for candidate in candidates {
            do {
                airPlayFairPlayLog.info("[AirPlayFairPlayProvider] lookup branch=ATTEMPT source=\(candidate.source, privacy: .public) path=\(candidate.url.path, privacy: .public)")
                let provider = try AirPlayFairPlayExternalProvider(path: candidate.url.path)
                return LookupResult(
                    provider: provider,
                    diagnosticDescription: "loaded(\(provider.diagnosticName))"
                )
            } catch {
                failures.append("\(candidate.source): \(error.localizedDescription)")
                airPlayFairPlayLog.error("[AirPlayFairPlayProvider] lookup branch=LOAD_FAILED source=\(candidate.source, privacy: .public) path=\(candidate.url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        let diagnostic = failures.isEmpty ? "missing(no-load-attempts)" : "failed(\(failures.joined(separator: " | ")))"
        airPlayFairPlayLog.error("[AirPlayFairPlayProvider] lookup branch=ALL_FAILED diagnostic=\(diagnostic, privacy: .public)")
        return LookupResult(provider: nil, diagnosticDescription: diagnostic)
    }

    struct ProviderPathCandidate: Equatable {
        let source: String
        let url: URL
    }

    static func providerPathCandidates(
        environment: [String: String],
        bundledProviderDirectory: URL? = nil,
        applicationSupportDirectory: URL?,
        fileExists: (URL) -> Bool
    ) -> [ProviderPathCandidate] {
        var candidates: [ProviderPathCandidate] = []
        if let environmentPath = environment[providerPathEnvironmentKey], !environmentPath.isEmpty {
            let url = URL(fileURLWithPath: environmentPath)
            airPlayFairPlayLog.info("[AirPlayFairPlayProvider] lookup branch=ENVIRONMENT_CANDIDATE path=\(url.path, privacy: .public)")
            candidates.append(ProviderPathCandidate(source: "environment", url: url))
        } else {
            airPlayFairPlayLog.warning("[AirPlayFairPlayProvider] lookup branch=ENVIRONMENT_MISSING key=\(providerPathEnvironmentKey, privacy: .public)")
        }

        let bundledURLs = bundledProviderURLs(frameworksDirectory: bundledProviderDirectory)
        if bundledURLs.isEmpty {
            airPlayFairPlayLog.warning("[AirPlayFairPlayProvider] lookup branch=BUNDLE_FRAMEWORKS_UNAVAILABLE")
        }
        for bundledURL in bundledURLs {
            if fileExists(bundledURL) {
                airPlayFairPlayLog.info("[AirPlayFairPlayProvider] lookup branch=BUNDLE_FRAMEWORKS_CANDIDATE path=\(bundledURL.path, privacy: .public)")
                candidates.append(ProviderPathCandidate(source: "bundle-frameworks", url: bundledURL))
            } else {
                airPlayFairPlayLog.warning("[AirPlayFairPlayProvider] lookup branch=BUNDLE_FRAMEWORKS_MISSING path=\(bundledURL.path, privacy: .public)")
            }
        }

        let defaultURLs = defaultProviderURLs(applicationSupportDirectory: applicationSupportDirectory)
        guard !defaultURLs.isEmpty else {
            airPlayFairPlayLog.warning("[AirPlayFairPlayProvider] lookup branch=APP_SUPPORT_UNAVAILABLE")
            return candidates
        }

        for defaultURL in defaultURLs {
            if fileExists(defaultURL) {
                airPlayFairPlayLog.info("[AirPlayFairPlayProvider] lookup branch=APP_SUPPORT_CANDIDATE path=\(defaultURL.path, privacy: .public)")
                candidates.append(ProviderPathCandidate(source: "application-support", url: defaultURL))
            } else {
                airPlayFairPlayLog.warning("[AirPlayFairPlayProvider] lookup branch=APP_SUPPORT_MISSING path=\(defaultURL.path, privacy: .public)")
            }
        }
        return candidates
    }

    private static func userApplicationSupportDirectory(fileManager: FileManager) -> URL? {
        try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
    }

    private static func defaultProviderURLs(applicationSupportDirectory: URL?) -> [URL] {
        guard let directory = applicationSupportDirectory?
            .appendingPathComponent("Specchio", isDirectory: true)
            .appendingPathComponent(defaultProviderDirectoryName, isDirectory: true) else {
            return []
        }

        return defaultProviderFileNames.map { directory.appendingPathComponent($0) }
    }

    private static func bundledProviderURLs(frameworksDirectory: URL?) -> [URL] {
        guard let frameworksDirectory else {
            return []
        }

        return defaultProviderFileNames.map { frameworksDirectory.appendingPathComponent($0) }
    }

    init(path: String) throws {
        guard let loadedHandle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw AirPlayFairPlayProviderError.openFailed(
                path: path,
                reason: Self.lastDynamicLoaderError()
            )
        }

        let loadedBackend: Backend
        do {
            loadedBackend = try Self.loadBackend(from: loadedHandle, path: path)
        } catch {
            dlclose(loadedHandle)
            throw error
        }

        handle = loadedHandle
        backend = loadedBackend
        diagnosticName = "\(URL(fileURLWithPath: path).lastPathComponent):\(backend.diagnosticName)"
        airPlayFairPlayLog.info("[AirPlayFairPlayProvider] load branch=OK path=\(path, privacy: .public) abi=\(loadedBackend.diagnosticName, privacy: .public)")
    }

    deinit {
        if case .fairplay(let context, _, _, _, let destroyFunction) = backend {
            airPlayFairPlayLog.info("[AirPlayFairPlayProvider] destroy branch=FAIRPLAY_ABI contextPresent=true")
            destroyFunction(context)
        }
        dlclose(handle)
    }

    func setupReply(for request: Data, mode: Int) throws -> Data {
        airPlayFairPlayLog.info("[AirPlayFairPlayProvider] call branch=SETUP_REPLY requestBytes=\(request.count) mode=\(mode)")
        switch backend {
        case .specchio(let setupReplyFunction, _, _):
            return try callSpecchioUnary(
                setupReplyFunction,
                name: Self.setupReplySymbol,
                request: request,
                capacity: 256
            )
        case .fairplay(let context, let setupFunction, _, _, _):
            return try callFairPlayUnary(
                setupFunction,
                name: Self.fairPlaySetupSymbol,
                context: context,
                request: request,
                requiredRequestBytes: 16,
                outputBytes: 142
            )
        }
    }

    func keyMessageReply(for request: Data) throws -> Data {
        airPlayFairPlayLog.info("[AirPlayFairPlayProvider] call branch=KEY_MESSAGE_REPLY requestBytes=\(request.count)")
        switch backend {
        case .specchio(_, let keyMessageReplyFunction, _):
            return try callSpecchioUnary(
                keyMessageReplyFunction,
                name: Self.keyMessageReplySymbol,
                request: request,
                capacity: 64
            )
        case .fairplay(let context, _, let handshakeFunction, _, _):
            return try callFairPlayUnary(
                handshakeFunction,
                name: Self.fairPlayHandshakeSymbol,
                context: context,
                request: request,
                requiredRequestBytes: 164,
                outputBytes: 32
            )
        }
    }

    func decryptStreamKey(keyMessage: Data, encryptedKey: Data) throws -> Data {
        airPlayFairPlayLog.info("[AirPlayFairPlayProvider] call branch=DECRYPT_KEY keyMessageBytes=\(keyMessage.count) encryptedKeyBytes=\(encryptedKey.count)")
        switch backend {
        case .specchio(_, _, let decryptKeyFunction):
            return try callSpecchioDecrypt(
                decryptKeyFunction,
                keyMessage: keyMessage,
                encryptedKey: encryptedKey
            )
        case .fairplay(let context, _, _, let decryptFunction, _):
            return try callFairPlayUnary(
                decryptFunction,
                name: Self.fairPlayDecryptSymbol,
                context: context,
                request: encryptedKey,
                requiredRequestBytes: 72,
                outputBytes: 16
            )
        }
    }

    private static func loadBackend(from handle: UnsafeMutableRawPointer, path: String) throws -> Backend {
        if let setup: UnaryFunction = optionalSymbol(setupReplySymbol, from: handle),
           let keyMessageReply: UnaryFunction = optionalSymbol(keyMessageReplySymbol, from: handle),
           let decryptKey: DecryptFunction = optionalSymbol(decryptKeySymbol, from: handle) {
            airPlayFairPlayLog.info("[AirPlayFairPlayProvider] abi branch=SPECCHIO symbols=ok")
            return .specchio(
                setupReply: setup,
                keyMessageReply: keyMessageReply,
                decryptKey: decryptKey
            )
        }

        airPlayFairPlayLog.warning("[AirPlayFairPlayProvider] abi branch=SPECCHIO symbols=missing attempting=fairplay")
        if let initialize: FairPlayInitFunction = optionalSymbol(fairPlayInitSymbol, from: handle),
           let setup: FairPlayUnaryFunction = optionalSymbol(fairPlaySetupSymbol, from: handle),
           let handshake: FairPlayUnaryFunction = optionalSymbol(fairPlayHandshakeSymbol, from: handle),
           let decrypt: FairPlayUnaryFunction = optionalSymbol(fairPlayDecryptSymbol, from: handle),
           let destroy: FairPlayDestroyFunction = optionalSymbol(fairPlayDestroySymbol, from: handle) {
            guard let context = initialize(nil) else {
                airPlayFairPlayLog.error("[AirPlayFairPlayProvider] abi branch=FAIRPLAY context=failed")
                throw AirPlayFairPlayProviderError.contextCreateFailed(path: path)
            }
            airPlayFairPlayLog.info("[AirPlayFairPlayProvider] abi branch=FAIRPLAY symbols=ok context=created")
            return .fairplay(
                context: context,
                setup: setup,
                handshake: handshake,
                decrypt: decrypt,
                destroy: destroy
            )
        }

        airPlayFairPlayLog.error("[AirPlayFairPlayProvider] abi branch=UNSUPPORTED path=\(path, privacy: .public)")
        throw AirPlayFairPlayProviderError.unsupportedABI(path: path)
    }

    private func callSpecchioUnary(
        _ function: UnaryFunction,
        name: String,
        request: Data,
        capacity: Int
    ) throws -> Data {
        try request.withUnsafeBytes { requestBytes in
            guard let requestPointer = requestBytes.bindMemory(to: UInt8.self).baseAddress else {
                throw AirPlayFairPlayProviderError.callFailed(name: name, status: -1)
            }

            var output = Data(count: capacity)
            var outputLength = UInt(output.count)
            let status = output.withUnsafeMutableBytes { outputBytes in
                function(
                    requestPointer,
                    UInt(request.count),
                    outputBytes.bindMemory(to: UInt8.self).baseAddress!,
                    &outputLength
                )
            }

            guard status == 0 else {
                throw AirPlayFairPlayProviderError.callFailed(name: name, status: status)
            }
            guard outputLength <= UInt(output.count) else {
                throw AirPlayFairPlayProviderError.outputTooLarge(
                    name: name,
                    capacity: output.count,
                    actual: outputLength
                )
            }

            output.count = Int(outputLength)
            return output
        }
    }

    private func callSpecchioDecrypt(
        _ function: DecryptFunction,
        keyMessage: Data,
        encryptedKey: Data
    ) throws -> Data {
        try keyMessage.withUnsafeBytes { keyMessageBytes in
            try encryptedKey.withUnsafeBytes { encryptedKeyBytes in
                guard let keyMessagePointer = keyMessageBytes.bindMemory(to: UInt8.self).baseAddress,
                      let encryptedKeyPointer = encryptedKeyBytes.bindMemory(to: UInt8.self).baseAddress else {
                    throw AirPlayFairPlayProviderError.callFailed(name: Self.decryptKeySymbol, status: -1)
                }

                var output = Data(count: 32)
                var outputLength = UInt(output.count)
                let status = output.withUnsafeMutableBytes { outputBytes in
                    function(
                        keyMessagePointer,
                        UInt(keyMessage.count),
                        encryptedKeyPointer,
                        UInt(encryptedKey.count),
                        outputBytes.bindMemory(to: UInt8.self).baseAddress!,
                        &outputLength
                    )
                }

                guard status == 0 else {
                    throw AirPlayFairPlayProviderError.callFailed(name: Self.decryptKeySymbol, status: status)
                }
                guard outputLength <= UInt(output.count) else {
                    throw AirPlayFairPlayProviderError.outputTooLarge(
                        name: Self.decryptKeySymbol,
                        capacity: output.count,
                        actual: outputLength
                    )
                }

                output.count = Int(outputLength)
                return output
            }
        }
    }

    private func callFairPlayUnary(
        _ function: FairPlayUnaryFunction,
        name: String,
        context: UnsafeMutableRawPointer,
        request: Data,
        requiredRequestBytes: Int,
        outputBytes: Int
    ) throws -> Data {
        guard request.count == requiredRequestBytes else {
            airPlayFairPlayLog.error("[AirPlayFairPlayProvider] fairplay call branch=BAD_REQUEST_LENGTH name=\(name, privacy: .public) requestBytes=\(request.count) expected=\(requiredRequestBytes)")
            throw AirPlayFairPlayProviderError.callFailed(name: name, status: -2)
        }

        return try request.withUnsafeBytes { requestBytes in
            guard let requestPointer = requestBytes.bindMemory(to: UInt8.self).baseAddress else {
                throw AirPlayFairPlayProviderError.callFailed(name: name, status: -1)
            }

            var output = Data(count: outputBytes)
            let status = output.withUnsafeMutableBytes { outputBuffer in
                function(
                    context,
                    requestPointer,
                    outputBuffer.bindMemory(to: UInt8.self).baseAddress!
                )
            }

            guard status == 0 else {
                throw AirPlayFairPlayProviderError.callFailed(name: name, status: status)
            }
            return output
        }
    }

    private static func loadSymbol<T>(
        _ name: String,
        from handle: UnsafeMutableRawPointer,
        path: String
    ) throws -> T {
        guard let symbol = dlsym(handle, name) else {
            throw AirPlayFairPlayProviderError.symbolMissing(name: name, path: path)
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static func optionalSymbol<T>(
        _ name: String,
        from handle: UnsafeMutableRawPointer
    ) -> T? {
        guard let symbol = dlsym(handle, name) else {
            airPlayFairPlayLog.warning("[AirPlayFairPlayProvider] symbol branch=MISSING name=\(name, privacy: .public)")
            return nil
        }
        airPlayFairPlayLog.info("[AirPlayFairPlayProvider] symbol branch=FOUND name=\(name, privacy: .public)")
        return unsafeBitCast(symbol, to: T.self)
    }

    private static func lastDynamicLoaderError() -> String {
        guard let error = dlerror() else { return "unknown dynamic loader error" }
        return String(cString: error)
    }
}

private final class AirPlayAESCTRStream {
    private static let blockByteCount = kCCBlockSizeAES128

    private var cryptor: CCCryptorRef?
    private var overflowBlock = Data(repeating: 0, count: blockByteCount)
    private var nextDecryptCount = 0
    private var packetCount = 0

    init(key: Data, iv: Data) throws {
        var createdCryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress,
                    key.count,
                    nil,
                    0,
                    0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &createdCryptor
                )
            }
        }

        guard createStatus == kCCSuccess, let createdCryptor else {
            throw AirPlayFairPlayError.aesCTRCreateFailed(createStatus)
        }

        cryptor = createdCryptor
    }

    deinit {
        if let cryptor {
            CCCryptorRelease(cryptor)
        }
    }

    func crypt(_ input: Data) throws -> Data {
        packetCount += 1

        guard !input.isEmpty else {
            airPlayFairPlayLog.debug("[AirPlayFairPlay] aes-ctr branch=EMPTY packet=\(self.packetCount)")
            return Data()
        }

        let pendingAtStart = nextDecryptCount
        var output = Data(input)

        if pendingAtStart > 0 {
            let pendingBytes = min(pendingAtStart, input.count)
            let overflowStart = Self.blockByteCount - pendingAtStart
            for offset in 0..<pendingBytes {
                output[offset] = input[offset] ^ overflowBlock[overflowStart + offset]
            }

            guard pendingBytes == pendingAtStart else {
                nextDecryptCount = pendingAtStart - pendingBytes
                airPlayFairPlayLog.warning("[AirPlayFairPlay] aes-ctr branch=OVERFLOW_ONLY packet=\(self.packetCount) inputBytes=\(input.count) pendingOverflow=\(pendingAtStart) consumedOverflow=\(pendingBytes) nextOverflow=\(self.nextDecryptCount)")
                return output
            }
        }

        let encryptedStart = pendingAtStart
        let remainingBytes = input.count - encryptedStart
        let fullBlockBytes = (remainingBytes / Self.blockByteCount) * Self.blockByteCount
        if fullBlockBytes > 0 {
            let fullBlockRange = encryptedStart..<(encryptedStart + fullBlockBytes)
            let decryptedFullBlocks = try cryptBlock(input.subdata(in: fullBlockRange))
            output.replaceSubrange(fullBlockRange, with: decryptedFullBlocks)
        }

        let restByteCount = remainingBytes % Self.blockByteCount
        nextDecryptCount = 0
        if restByteCount > 0 {
            let restStart = input.count - restByteCount
            var paddedRest = Data(repeating: 0, count: Self.blockByteCount)
            paddedRest.replaceSubrange(0..<restByteCount, with: input.subdata(in: restStart..<input.count))
            let decryptedRestBlock = try cryptBlock(paddedRest)
            output.replaceSubrange(restStart..<input.count, with: decryptedRestBlock.prefix(restByteCount))
            overflowBlock = decryptedRestBlock
            nextDecryptCount = Self.blockByteCount - restByteCount
        }

        airPlayFairPlayLog.debug("[AirPlayFairPlay] aes-ctr branch=UXPLAY_PACKET packet=\(self.packetCount) inputBytes=\(input.count) pendingOverflow=\(pendingAtStart) fullBlockBytes=\(fullBlockBytes) restBytes=\(restByteCount) nextOverflow=\(self.nextDecryptCount)")
        return output
    }

    private func cryptBlock(_ input: Data) throws -> Data {
        guard let cryptor else {
            throw AirPlayFairPlayError.aesCTRCreateFailed(CCCryptorStatus(kCCUnimplemented))
        }

        var output = Data(count: input.count + Self.blockByteCount)
        let outputCapacity = output.count
        var moved = 0
        let updateStatus = input.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                CCCryptorUpdate(
                    cryptor,
                    inputBytes.baseAddress,
                    input.count,
                    outputBytes.baseAddress,
                    outputCapacity,
                    &moved
                )
            }
        }

        guard updateStatus == kCCSuccess else {
            throw AirPlayFairPlayError.aesCTRUpdateFailed(updateStatus)
        }

        output.count = moved
        return output
    }
}
