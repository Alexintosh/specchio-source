import BigInt
import CommonCrypto
import CryptoKit
import Foundation
import Security

private let airPlayPairingLog = SpecchioLogger.airPlay

struct AirPlayPairingSession {
    enum Phase: Equatable {
        case idle
        case setupReceived(requestBytes: Int)
        case verifyReceived(requestBytes: Int)
        case verifyChallengeSent(requestBytes: Int)
        case verified
        case pinStarted
        case pinSetupChallenge(requestBytes: Int)
        case pinProofAccepted(requestBytes: Int)
        case pinSetupComplete(requestBytes: Int)
        case rejected(reason: String)

        var diagnosticDescription: String {
            switch self {
            case .idle:
                return "idle"
            case .setupReceived(let requestBytes):
                return "setupReceived(requestBytes=\(requestBytes))"
            case .verifyReceived(let requestBytes):
                return "verifyReceived(requestBytes=\(requestBytes))"
            case .verifyChallengeSent(let requestBytes):
                return "verifyChallengeSent(requestBytes=\(requestBytes))"
            case .verified:
                return "verified"
            case .pinStarted:
                return "pinStarted"
            case .pinSetupChallenge(let requestBytes):
                return "pinSetupChallenge(requestBytes=\(requestBytes))"
            case .pinProofAccepted(let requestBytes):
                return "pinProofAccepted(requestBytes=\(requestBytes))"
            case .pinSetupComplete(let requestBytes):
                return "pinSetupComplete(requestBytes=\(requestBytes))"
            case .rejected(let reason):
                return "rejected(reason=\(reason))"
            }
        }
    }

    struct Result: Equatable {
        let response: AirPlayControlResponse
        let phase: Phase
        let message: String
        let visiblePIN: String?
        let shouldClearVisiblePIN: Bool

        init(
            response: AirPlayControlResponse,
            phase: Phase,
            message: String,
            visiblePIN: String? = nil,
            shouldClearVisiblePIN: Bool = false
        ) {
            self.response = response
            self.phase = phase
            self.message = message
            self.visiblePIN = visiblePIN
            self.shouldClearVisiblePIN = shouldClearVisiblePIN
        }
    }

    private struct PinFlow {
        var pin: String
        var srpServer: AirPlayPinSRPServer?
    }

    private struct PairVerifyState {
        let serverKeyAgreementKey: Curve25519.KeyAgreement.PrivateKey
        let serverPublicKey: Data
        let clientPublicKey: Data
        let clientSigningPublicKey: Data
        let sharedSecret: Data
    }

    private let receiverSigningKey: Curve25519.Signing.PrivateKey
    private let pinGenerator: () -> String
    private(set) var phase: Phase = .idle
    private(set) var verifiedPairingSharedSecret: Data?
    private var pinFlow: PinFlow?
    private var pairVerifyState: PairVerifyState?

    init(pinGenerator: @escaping () -> String = AirPlayPairingSession.makePIN) {
        self.receiverSigningKey = Curve25519.Signing.PrivateKey()
        self.pinGenerator = pinGenerator
    }

    var receiverPublicKey: Data {
        receiverSigningKey.publicKey.rawRepresentation
    }

    var receiverPublicKeyHex: String {
        receiverPublicKey.map { String(format: "%02x", $0) }.joined()
    }

    var shouldPreservePINOnControlDisconnect: Bool {
        guard pinFlow != nil else {
            return false
        }

        switch phase {
        case .pinStarted, .pinSetupChallenge, .pinProofAccepted:
            return true
        case .idle, .setupReceived, .verifyReceived, .verifyChallengeSent, .verified, .pinSetupComplete, .rejected:
            return false
        }
    }

    mutating func reset(reason: String) {
        let previousPhaseDescription = phase.diagnosticDescription
        let pinActive = pinFlow != nil
        let verifyActive = pairVerifyState != nil
        airPlayPairingLog.info("[AirPlayPairing] reset requested reason=\(reason, privacy: .public) previousPhase=\(previousPhaseDescription, privacy: .public) pinActive=\(pinActive) verifyActive=\(verifyActive)")
        phase = .idle
        verifiedPairingSharedSecret = nil
        pinFlow = nil
        pairVerifyState = nil
    }

    mutating func handlePairSetup(_ request: AirPlayControlRequest) -> Result {
        phase = .setupReceived(requestBytes: request.body.count)
        let publicKey = receiverPublicKey
        let response = AirPlayControlResponse.ok(
            headers: [
                "Content-Type": "application/octet-stream",
                "X-Specchio-AirPlay-Phase": "pair-setup-public-key"
            ],
            body: publicKey
        )
        let bodyByteCount = request.body.count
        let publicKeyByteCount = publicKey.count
        airPlayPairingLog.info("[AirPlayPairing] pair-setup branch=PUBLIC_KEY bodyBytes=\(bodyByteCount) publicKeyBytes=\(publicKeyByteCount)")
        return Result(
            response: response,
            phase: phase,
            message: "pair-setup returned receiver Ed25519 public key"
        )
    }

    mutating func beginPinPairing() -> Result {
        let pin = pinGenerator()
        pinFlow = PinFlow(pin: pin, srpServer: nil)
        pairVerifyState = nil
        phase = .pinStarted
        airPlayPairingLog.info("[AirPlayPairing] pair-pin-start branch=STARTED visiblePINLength=\(pin.count) previousVerifyStateCleared=true")
        return Result(
            response: .ok(headers: ["X-Specchio-AirPlay-Phase": "pair-pin-started"]),
            phase: phase,
            message: "AirPlay PIN pairing started; waiting for SRP setup request",
            visiblePIN: pin
        )
    }

    mutating func handlePairSetupPin(_ request: AirPlayControlRequest) -> Result {
        airPlayPairingLog.info("[AirPlayPairing] pair-setup-pin dispatch bodyBytes=\(request.body.count)")
        let plist: [String: Any]
        do {
            plist = try Self.decodePlistDictionary(request.body)
        } catch {
            return reject(
                reason: "pair-setup-pin plist parse failed: \(error.localizedDescription)",
                response: .badRequest("Malformed AirPlay pair-setup-pin plist"),
                clearPIN: false
            )
        }

        let keys = plist.keys.sorted().joined(separator: ",")
        airPlayPairingLog.info("[AirPlayPairing] pair-setup-pin parsed keys=\(keys, privacy: .public)")

        if let method = plist["method"] as? String {
            airPlayPairingLog.info("[AirPlayPairing] pair-setup-pin branch=SRP_CHALLENGE_REQUEST method=\(method, privacy: .public) userPresent=\(plist["user"] != nil)")
            guard let user = plist["user"] as? String else {
                return reject(
                    reason: "pair-setup-pin challenge missing user",
                    response: .badRequest("AirPlay pair-setup-pin challenge missing user"),
                    clearPIN: false
                )
            }
            return handlePinChallenge(method: method, user: user, requestBytes: request.body.count)
        }

        if let clientPublicKey = plist["pk"] as? Data, let clientProof = plist["proof"] as? Data {
            airPlayPairingLog.info("[AirPlayPairing] pair-setup-pin branch=SRP_PROOF pkBytes=\(clientPublicKey.count) proofBytes=\(clientProof.count)")
            return handlePinProof(
                clientPublicKey: clientPublicKey,
                clientProof: clientProof,
                requestBytes: request.body.count
            )
        }

        if let encryptedPublicKey = plist["epk"] as? Data, let authTag = plist["authTag"] as? Data {
            airPlayPairingLog.info("[AirPlayPairing] pair-setup-pin branch=ENCRYPTED_PUBLIC_KEY epkBytes=\(encryptedPublicKey.count) authTagBytes=\(authTag.count)")
            return handlePinEncryptedPublicKey(
                encryptedPublicKey: encryptedPublicKey,
                authTag: authTag,
                requestBytes: request.body.count
            )
        }

        return reject(
            reason: "pair-setup-pin did not match any supported SRP step",
            response: .badRequest("Unsupported AirPlay pair-setup-pin payload"),
            clearPIN: false
        )
    }

    mutating func handlePairVerify(_ request: AirPlayControlRequest) -> Result {
        phase = .verifyReceived(requestBytes: request.body.count)
        airPlayPairingLog.info("[AirPlayPairing] pair-verify dispatch bodyBytes=\(request.body.count)")

        guard request.body.count >= 4 else {
            return reject(
                reason: "pair-verify body too short",
                response: .badRequest("AirPlay pair-verify body too short"),
                clearPIN: false
            )
        }

        let step = request.body[request.body.startIndex]
        switch step {
        case 1:
            return handlePairVerifyChallenge(request)
        case 0:
            return handlePairVerifySignature(request)
        default:
            return reject(
                reason: "pair-verify unsupported step \(step)",
                response: .badRequest("Unsupported AirPlay pair-verify step \(step)"),
                clearPIN: false
            )
        }
    }

    private mutating func handlePinChallenge(method: String, user: String, requestBytes: Int) -> Result {
        guard method == "pin" else {
            return reject(
                reason: "pair-setup-pin requested unsupported method \(method)",
                response: .badRequest("Unsupported AirPlay pair-setup-pin method"),
                clearPIN: false
            )
        }

        guard var flow = pinFlow else {
            return reject(
                reason: "pair-setup-pin challenge arrived before pair-pin-start",
                response: .badRequest("AirPlay pair-pin-start is required before pair-setup-pin"),
                clearPIN: false
            )
        }

        do {
            let srpServer = try AirPlayPinSRPServer(username: user, pin: flow.pin)
            let responseBody = try Self.encodePlistDictionary([
                "pk": srpServer.serverPublicKey,
                "salt": srpServer.salt
            ])
            flow.srpServer = srpServer
            pinFlow = flow
            phase = .pinSetupChallenge(requestBytes: requestBytes)
            airPlayPairingLog.info("[AirPlayPairing] pair-setup-pin challenge response saltBytes=\(srpServer.salt.count) serverPublicKeyBytes=\(srpServer.serverPublicKey.count)")
            return Result(
                response: .ok(
                    headers: [
                        "Content-Type": "application/x-apple-binary-plist",
                        "X-Specchio-AirPlay-Phase": "pair-setup-pin-challenge"
                    ],
                    body: responseBody
                ),
                phase: phase,
                message: "pair-setup-pin returned SRP salt and server public key"
            )
        } catch {
            return reject(
                reason: "pair-setup-pin SRP challenge creation failed: \(error.localizedDescription)",
                response: .badRequest("Could not create AirPlay SRP challenge"),
                clearPIN: true
            )
        }
    }

    private mutating func handlePinProof(clientPublicKey: Data, clientProof: Data, requestBytes: Int) -> Result {
        guard var flow = pinFlow, var srpServer = flow.srpServer else {
            return reject(
                reason: "pair-setup-pin proof arrived before SRP challenge",
                response: .badRequest("AirPlay SRP challenge has not started"),
                clearPIN: false
            )
        }

        do {
            let serverProof = try srpServer.verify(clientPublicKey: clientPublicKey, clientProof: clientProof)
            flow.srpServer = srpServer
            pinFlow = flow
            let responseBody = try Self.encodePlistDictionary(["proof": serverProof])
            phase = .pinProofAccepted(requestBytes: requestBytes)
            airPlayPairingLog.info("[AirPlayPairing] pair-setup-pin proof accepted serverProofBytes=\(serverProof.count)")
            return Result(
                response: .ok(
                    headers: [
                        "Content-Type": "application/x-apple-binary-plist",
                        "X-Specchio-AirPlay-Phase": "pair-setup-pin-proof"
                    ],
                    body: responseBody
                ),
                phase: phase,
                message: "pair-setup-pin SRP client proof accepted"
            )
        } catch {
            return reject(
                reason: "pair-setup-pin proof rejected: \(error.localizedDescription)",
                response: .clientAuthenticationFailure("AirPlay SRP proof rejected"),
                clearPIN: true
            )
        }
    }

    private mutating func handlePinEncryptedPublicKey(
        encryptedPublicKey: Data,
        authTag: Data,
        requestBytes: Int
    ) -> Result {
        guard var flow = pinFlow, var srpServer = flow.srpServer else {
            return reject(
                reason: "pair-setup-pin encrypted public key arrived before proof acceptance",
                response: .badRequest("AirPlay SRP proof has not been accepted"),
                clearPIN: false
            )
        }

        do {
            let encryptedResponse = try srpServer.completePairSetup(
                encryptedClientPublicKey: encryptedPublicKey,
                authTag: authTag,
                receiverPublicKey: receiverPublicKey
            )
            flow.srpServer = srpServer
            pinFlow = nil
            let responseBody = try Self.encodePlistDictionary([
                "epk": encryptedResponse.encryptedPublicKey,
                "authTag": encryptedResponse.authTag
            ])
            phase = .pinSetupComplete(requestBytes: requestBytes)
            airPlayPairingLog.info("[AirPlayPairing] pair-setup-pin encrypted key exchange complete responseEpkBytes=\(encryptedResponse.encryptedPublicKey.count) responseAuthTagBytes=\(encryptedResponse.authTag.count)")
            return Result(
                response: .ok(
                    headers: [
                        "Content-Type": "application/x-apple-binary-plist",
                        "X-Specchio-AirPlay-Phase": "pair-setup-pin-complete"
                    ],
                    body: responseBody
                ),
                phase: phase,
                message: "pair-setup-pin encrypted public key exchange completed",
                shouldClearVisiblePIN: true
            )
        } catch {
            return reject(
                reason: "pair-setup-pin encrypted key exchange failed: \(error.localizedDescription)",
                response: .clientAuthenticationFailure("AirPlay encrypted key exchange rejected"),
                clearPIN: true
            )
        }
    }

    private mutating func handlePairVerifyChallenge(_ request: AirPlayControlRequest) -> Result {
        let expectedBytes = 4 + AirPlayPinSRPServer.curve25519KeyByteCount + AirPlayPinSRPServer.curve25519KeyByteCount
        guard request.body.count == expectedBytes else {
            return reject(
                reason: "pair-verify step 1 invalid length \(request.body.count), expected \(expectedBytes)",
                response: .badRequest("Invalid AirPlay pair-verify step 1 length"),
                clearPIN: false
            )
        }

        let clientAgreementStart = request.body.startIndex + 4
        let clientAgreementEnd = clientAgreementStart + AirPlayPinSRPServer.curve25519KeyByteCount
        let clientSigningEnd = clientAgreementEnd + AirPlayPinSRPServer.curve25519KeyByteCount
        let clientAgreementPublicKey = request.body.subdata(in: clientAgreementStart..<clientAgreementEnd)
        let clientSigningPublicKey = request.body.subdata(in: clientAgreementEnd..<clientSigningEnd)

        do {
            let clientAgreementKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientAgreementPublicKey)
            let serverAgreementKey = Curve25519.KeyAgreement.PrivateKey()
            let sharedSecret = try serverAgreementKey.sharedSecretFromKeyAgreement(with: clientAgreementKey).dataRepresentation
            let serverAgreementPublicKey = serverAgreementKey.publicKey.rawRepresentation
            let signatureMessage = serverAgreementPublicKey + clientAgreementPublicKey
            let signature = try receiverSigningKey.signature(for: signatureMessage)
            let encryptedSignature = try AirPlayAESCTR.crypt(
                Data(signature),
                key: AirPlayPairVerifyCrypto.aesKey(from: sharedSecret),
                iv: AirPlayPairVerifyCrypto.aesIV(from: sharedSecret)
            )
            pairVerifyState = PairVerifyState(
                serverKeyAgreementKey: serverAgreementKey,
                serverPublicKey: serverAgreementPublicKey,
                clientPublicKey: clientAgreementPublicKey,
                clientSigningPublicKey: clientSigningPublicKey,
                sharedSecret: sharedSecret
            )
            phase = .verifyChallengeSent(requestBytes: request.body.count)
            airPlayPairingLog.info("[AirPlayPairing] pair-verify step=1 challenge sent serverPublicKeyBytes=\(serverAgreementPublicKey.count) encryptedSignatureBytes=\(encryptedSignature.count)")
            return Result(
                response: .ok(
                    headers: [
                        "Content-Type": "application/octet-stream",
                        "X-Specchio-AirPlay-Phase": "pair-verify-challenge"
                    ],
                    body: serverAgreementPublicKey + encryptedSignature
                ),
                phase: phase,
                message: "pair-verify returned receiver X25519 public key and encrypted Ed25519 signature"
            )
        } catch {
            return reject(
                reason: "pair-verify step 1 failed: \(error.localizedDescription)",
                response: .clientAuthenticationFailure("AirPlay pair-verify challenge failed"),
                clearPIN: false
            )
        }
    }

    private mutating func handlePairVerifySignature(_ request: AirPlayControlRequest) -> Result {
        let expectedBytes = 4 + AirPlayPinSRPServer.ed25519SignatureByteCount
        guard request.body.count == expectedBytes else {
            return reject(
                reason: "pair-verify step 2 invalid length \(request.body.count), expected \(expectedBytes)",
                response: .badRequest("Invalid AirPlay pair-verify step 2 length"),
                clearPIN: false
            )
        }
        guard let verifyState = pairVerifyState else {
            return reject(
                reason: "pair-verify step 2 arrived before step 1",
                response: .badRequest("AirPlay pair-verify step 1 has not started"),
                clearPIN: false
            )
        }

        let encryptedSignature = request.body.subdata(in: (request.body.startIndex + 4)..<request.body.endIndex)
        do {
            let signature = try AirPlayAESCTR.crypt(
                encryptedSignature,
                key: AirPlayPairVerifyCrypto.aesKey(from: verifyState.sharedSecret),
                iv: AirPlayPairVerifyCrypto.aesIV(from: verifyState.sharedSecret),
                skipBytes: AirPlayPinSRPServer.ed25519SignatureByteCount
            )
            let clientSigningPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: verifyState.clientSigningPublicKey)
            let signedMessage = verifyState.clientPublicKey + verifyState.serverPublicKey
            guard clientSigningPublicKey.isValidSignature(signature, for: signedMessage) else {
                return reject(
                    reason: "pair-verify step 2 client signature invalid",
                    response: .clientAuthenticationFailure("AirPlay pair-verify signature rejected"),
                    clearPIN: false
                )
            }

            phase = .verified
            verifiedPairingSharedSecret = verifyState.sharedSecret
            pairVerifyState = nil
            airPlayPairingLog.info("[AirPlayPairing] pair-verify step=2 signature verified signatureBytes=\(signature.count) sharedSecretBytes=\(verifyState.sharedSecret.count)")
            return Result(
                response: .ok(
                    headers: [
                        "Content-Type": "application/octet-stream",
                        "X-Specchio-AirPlay-Phase": "pair-verify-complete"
                    ]
                ),
                phase: phase,
                message: "pair-verify client signature verified"
            )
        } catch {
            return reject(
                reason: "pair-verify step 2 failed: \(error.localizedDescription)",
                response: .clientAuthenticationFailure("AirPlay pair-verify signature failed"),
                clearPIN: false
            )
        }
    }

    private mutating func reject(
        reason: String,
        response: AirPlayControlResponse,
        clearPIN: Bool
    ) -> Result {
        airPlayPairingLog.warning("[AirPlayPairing] rejected reason=\(reason, privacy: .public) clearPIN=\(clearPIN)")
        phase = .rejected(reason: reason)
        if clearPIN {
            pinFlow = nil
        }
        return Result(
            response: response,
            phase: phase,
            message: reason,
            shouldClearVisiblePIN: clearPIN
        )
    }

    private static func makePIN() -> String {
        String(format: "%04d", UInt32.random(in: 0...9999))
    }

    private static func decodePlistDictionary(_ body: Data) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: body, options: [], format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw AirPlayPairingError.nonDictionaryPlist
        }
        return dictionary
    }

    private static func encodePlistDictionary(_ dictionary: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }
}

enum AirPlayPairingError: LocalizedError {
    case nonDictionaryPlist
    case secureRandomFailed(OSStatus)
    case invalidClientPublicKeyLength(Int)
    case invalidClientProofLength(Int)
    case invalidEncryptedPublicKeyLength(Int)
    case invalidAuthenticationTagLength(Int)
    case invalidClientPublicKey
    case invalidClientProof
    case missingSessionKey
    case invalidEncryptedPublicKey
    case aesGCMFailed(String)
    case aesCTRFailed(CCCryptorStatus)

    var errorDescription: String? {
        switch self {
        case .nonDictionaryPlist:
            return "AirPlay plist body is not a dictionary"
        case .secureRandomFailed(let status):
            return "secure random failed with status \(status)"
        case .invalidClientPublicKeyLength(let length):
            return "client public key length \(length) is invalid"
        case .invalidClientProofLength(let length):
            return "client proof length \(length) is invalid"
        case .invalidEncryptedPublicKeyLength(let length):
            return "encrypted public key length \(length) is invalid"
        case .invalidAuthenticationTagLength(let length):
            return "authentication tag length \(length) is invalid"
        case .invalidClientPublicKey:
            return "client public key is invalid"
        case .invalidClientProof:
            return "client proof is invalid"
        case .missingSessionKey:
            return "SRP session key is not available"
        case .invalidEncryptedPublicKey:
            return "encrypted client public key is invalid"
        case .aesGCMFailed(let message):
            return "AES-GCM failed: \(message)"
        case .aesCTRFailed(let status):
            return "AES-CTR failed with status \(status)"
        }
    }
}

struct AirPlayPinSRPServer {
    static let groupPrimeHex = """
    AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4\
    A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF60\
    95179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF\
    747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B907\
    8717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB37861\
    60279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DB\
    FBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73
    """
    static let groupByteCount = 256
    static let saltByteCount = 16
    static let privateKeyByteCount = 32
    static let proofByteCount = 20
    static let sessionKeyByteCount = 40
    static let curve25519KeyByteCount = 32
    static let ed25519SignatureByteCount = 64
    static let authenticationTagByteCount = 16
    static let groupGenerator = BigUInt(2)
    static let groupPrime = BigUInt(groupPrimeHex.filter { !$0.isWhitespace }, radix: 16)!

    let username: String
    let salt: Data
    let serverPublicKey: Data
    private let privateValue: BigUInt
    private let verifier: BigUInt
    private let serverPublicValue: BigUInt
    private var sessionKey: Data?
    private(set) var pairedClientPublicKey: Data?

    init(username: String, pin: String) throws {
        let salt = try Self.randomNonZeroPrefixedData(count: Self.saltByteCount)
        let privateKey = try Self.randomNonZeroPrefixedData(count: Self.privateKeyByteCount)
        try self.init(username: username, pin: pin, salt: salt, privateKey: privateKey)
    }

    init(username: String, pin: String, salt: Data, privateKey: Data) throws {
        self.username = username
        self.salt = salt
        self.privateValue = BigUInt(privateKey)

        let x = Self.passwordPrivateKey(username: username, pin: pin, salt: salt)
        self.verifier = Self.groupGenerator.power(x, modulus: Self.groupPrime)
        let multiplier = Self.multiplier()
        let ephemeral = Self.groupGenerator.power(privateValue, modulus: Self.groupPrime)
        self.serverPublicValue = ((multiplier * verifier) + ephemeral) % Self.groupPrime
        let computedServerPublicKey = Self.paddedData(serverPublicValue)
        self.serverPublicKey = computedServerPublicKey

        let usernameByteCount = Data(username.utf8).count
        let saltByteCount = salt.count
        let privateKeyByteCount = privateKey.count
        let verifierByteCount = Self.minimalData(verifier).count
        let publicKeyByteCount = computedServerPublicKey.count
        airPlayPairingLog.info("[AirPlaySRP] server initialized usernameBytes=\(usernameByteCount) saltBytes=\(saltByteCount) privateKeyBytes=\(privateKeyByteCount) verifierBytes=\(verifierByteCount) publicKeyBytes=\(publicKeyByteCount)")
    }

    mutating func verify(clientPublicKey: Data, clientProof: Data) throws -> Data {
        guard clientPublicKey.count <= Self.groupByteCount else {
            throw AirPlayPairingError.invalidClientPublicKeyLength(clientPublicKey.count)
        }
        guard clientProof.count == Self.proofByteCount else {
            throw AirPlayPairingError.invalidClientProofLength(clientProof.count)
        }

        let clientPublicValue = BigUInt(clientPublicKey)
        guard clientPublicValue % Self.groupPrime != 0 else {
            throw AirPlayPairingError.invalidClientPublicKey
        }

        let scramblingParameter = Self.scramblingParameter(
            clientPublicValue: clientPublicValue,
            serverPublicValue: serverPublicValue
        )
        let verifierPower = verifier.power(scramblingParameter, modulus: Self.groupPrime)
        let sharedSecretBase = (clientPublicValue * verifierPower) % Self.groupPrime
        let sharedSecret = sharedSecretBase.power(privateValue, modulus: Self.groupPrime)
        let derivedSessionKey = Self.sessionKey(from: sharedSecret)
        let expectedProof = Self.clientProof(
            username: username,
            salt: salt,
            clientPublicValue: clientPublicValue,
            serverPublicValue: serverPublicValue,
            sessionKey: derivedSessionKey
        )

        guard Self.constantTimeEquals(clientProof, expectedProof) else {
            throw AirPlayPairingError.invalidClientProof
        }

        sessionKey = derivedSessionKey
        let serverProof = Self.serverProof(
            clientPublicValue: clientPublicValue,
            clientProof: expectedProof,
            sessionKey: derivedSessionKey
        )
        airPlayPairingLog.info("[AirPlaySRP] proof verified clientPublicKeyBytes=\(clientPublicKey.count) sessionKeyBytes=\(derivedSessionKey.count) serverProofBytes=\(serverProof.count)")
        return serverProof
    }

    mutating func completePairSetup(
        encryptedClientPublicKey: Data,
        authTag: Data,
        receiverPublicKey: Data
    ) throws -> (encryptedPublicKey: Data, authTag: Data) {
        guard encryptedClientPublicKey.count == Self.curve25519KeyByteCount else {
            throw AirPlayPairingError.invalidEncryptedPublicKeyLength(encryptedClientPublicKey.count)
        }
        guard authTag.count == Self.authenticationTagByteCount else {
            throw AirPlayPairingError.invalidAuthenticationTagLength(authTag.count)
        }
        guard let sessionKey else {
            throw AirPlayPairingError.missingSessionKey
        }

        let aesKey = AirPlayPairSetupCrypto.aesKey(from: sessionKey)
        var aesIV = AirPlayPairSetupCrypto.aesIV(from: sessionKey)
        Self.incrementLastByte(&aesIV)

        do {
            let nonce = try AES.GCM.Nonce(data: aesIV)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encryptedClientPublicKey, tag: authTag)
            let clientPublicKey = try AES.GCM.open(sealedBox, using: SymmetricKey(data: aesKey))
            guard clientPublicKey.count == Self.curve25519KeyByteCount else {
                throw AirPlayPairingError.invalidEncryptedPublicKey
            }
            pairedClientPublicKey = clientPublicKey

            Self.incrementLastByte(&aesIV)
            let responseNonce = try AES.GCM.Nonce(data: aesIV)
            let response = try AES.GCM.seal(receiverPublicKey, using: SymmetricKey(data: aesKey), nonce: responseNonce)
            airPlayPairingLog.info("[AirPlaySRP] encrypted public key exchange complete clientPublicKeyBytes=\(clientPublicKey.count) receiverPublicKeyBytes=\(receiverPublicKey.count) responseCiphertextBytes=\(response.ciphertext.count) responseTagBytes=\(response.tag.count)")
            return (response.ciphertext, response.tag)
        } catch let error as AirPlayPairingError {
            throw error
        } catch {
            throw AirPlayPairingError.aesGCMFailed(error.localizedDescription)
        }
    }

    static func passwordPrivateKey(username: String, pin: String, salt: Data) -> BigUInt {
        let identityHash = sha1(Data(username.utf8) + Data(":".utf8) + Data(pin.utf8))
        return BigUInt(sha1(minimalData(BigUInt(salt)) + identityHash))
    }

    static func multiplier() -> BigUInt {
        BigUInt(sha1(paddedData(groupPrime) + paddedData(groupGenerator)))
    }

    static func scramblingParameter(clientPublicValue: BigUInt, serverPublicValue: BigUInt) -> BigUInt {
        BigUInt(sha1(paddedData(clientPublicValue) + paddedData(serverPublicValue)))
    }

    static func sessionKey(from sharedSecret: BigUInt) -> Data {
        let secret = minimalData(sharedSecret)
        return sha1(secret + Data([0, 0, 0, 0])) + sha1(secret + Data([0, 0, 0, 1]))
    }

    static func clientProof(
        username: String,
        salt: Data,
        clientPublicValue: BigUInt,
        serverPublicValue: BigUInt,
        sessionKey: Data
    ) -> Data {
        let primeHash = sha1(minimalData(groupPrime))
        let generatorHash = sha1(minimalData(groupGenerator))
        let xorHash = Data(zip(primeHash, generatorHash).map { $0 ^ $1 })
        return sha1(
            xorHash
                + sha1(Data(username.utf8))
                + minimalData(BigUInt(salt))
                + minimalData(clientPublicValue)
                + minimalData(serverPublicValue)
                + sessionKey
        )
    }

    static func serverProof(clientPublicValue: BigUInt, clientProof: Data, sessionKey: Data) -> Data {
        sha1(minimalData(clientPublicValue) + clientProof + sessionKey)
    }

    static func paddedData(_ value: BigUInt, count: Int = groupByteCount) -> Data {
        let serialized = value.serialize()
        if serialized.count >= count {
            return serialized
        }
        return Data(repeating: 0, count: count - serialized.count) + serialized
    }

    static func minimalData(_ value: BigUInt) -> Data {
        value.serialize()
    }

    static func sha1(_ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }

    static func sha512(_ data: Data) -> Data {
        Data(SHA512.hash(data: data))
    }

    private static func randomNonZeroPrefixedData(count: Int) throws -> Data {
        var data = try randomData(count: count)
        while data.first == 0 {
            data = try randomData(count: count)
        }
        return data
    }

    private static func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw AirPlayPairingError.secureRandomFailed(status)
        }
        return Data(bytes)
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private static func incrementLastByte(_ data: inout Data) {
        guard let lastIndex = data.indices.last else { return }
        data[lastIndex] = data[lastIndex] &+ 1
    }
}

enum AirPlayPairSetupCrypto {
    static func aesKey(from sessionKey: Data) -> Data {
        Data(AirPlayPinSRPServer.sha512(Data("Pair-Setup-AES-Key".utf8) + sessionKey).prefix(16))
    }

    static func aesIV(from sessionKey: Data) -> Data {
        Data(AirPlayPinSRPServer.sha512(Data("Pair-Setup-AES-IV".utf8) + sessionKey).prefix(16))
    }
}

enum AirPlayPairVerifyCrypto {
    static func aesKey(from sharedSecret: Data) -> Data {
        Data(AirPlayPinSRPServer.sha512(Data("Pair-Verify-AES-Key".utf8) + sharedSecret).prefix(16))
    }

    static func aesIV(from sharedSecret: Data) -> Data {
        Data(AirPlayPinSRPServer.sha512(Data("Pair-Verify-AES-IV".utf8) + sharedSecret).prefix(16))
    }
}

enum AirPlayAESCTR {
    static func crypt(_ input: Data, key: Data, iv: Data, skipBytes: Int = 0) throws -> Data {
        let prefixedInput = skipBytes > 0 ? Data(repeating: 0, count: skipBytes) + input : input
        var cryptor: CCCryptorRef?
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
                    &cryptor
                )
            }
        }
        guard createStatus == kCCSuccess, let cryptor else {
            throw AirPlayPairingError.aesCTRFailed(createStatus)
        }
        defer { CCCryptorRelease(cryptor) }

        var output = Data(count: prefixedInput.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var moved = 0
        let updateStatus = prefixedInput.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                CCCryptorUpdate(
                    cryptor,
                    inputBytes.baseAddress,
                    prefixedInput.count,
                    outputBytes.baseAddress,
                    outputCapacity,
                    &moved
                )
            }
        }
        guard updateStatus == kCCSuccess else {
            throw AirPlayPairingError.aesCTRFailed(updateStatus)
        }

        var finalMoved = 0
        let finalCapacity = outputCapacity - moved
        let finalStatus = output.withUnsafeMutableBytes { outputBytes in
            CCCryptorFinal(
                cryptor,
                outputBytes.baseAddress?.advanced(by: moved),
                finalCapacity,
                &finalMoved
            )
        }
        guard finalStatus == kCCSuccess else {
            throw AirPlayPairingError.aesCTRFailed(finalStatus)
        }

        output.count = moved + finalMoved
        if skipBytes > 0 {
            return output.subdata(in: skipBytes..<output.count)
        }
        return output
    }
}

private extension SharedSecret {
    var dataRepresentation: Data {
        withUnsafeBytes { Data($0) }
    }
}
