import Cocoa
import ObjectiveC
import IOBluetooth

typealias BTDiagnosticLogger = (String) -> Void

private var cachedClassicManager: AnyObject? = nil
private let cachedClassicManagerLock = NSLock()

func btDefaultDiagnosticLogger(_ message: String) {
    NSLog("%@", message)
}

private func btCachedClassicManager() -> AnyObject? {
    cachedClassicManagerLock.lock()
    let cached = cachedClassicManager
    cachedClassicManagerLock.unlock()
    return cached
}

@discardableResult
private func btCacheClassicManagerIfEmpty(_ manager: AnyObject) -> AnyObject {
    cachedClassicManagerLock.lock()
    if let cachedClassicManager {
        cachedClassicManagerLock.unlock()
        return cachedClassicManager
    }
    cachedClassicManager = manager
    cachedClassicManagerLock.unlock()
    NSLog("[Swizzle] CBClassicManager.init -> FIRST instance cached: %@", String(describing: manager))
    return manager
}

@discardableResult
private func btClearCachedClassicManager(reason: String) -> Bool {
    cachedClassicManagerLock.lock()
    let hadCachedManager = cachedClassicManager != nil
    cachedClassicManager = nil
    cachedClassicManagerLock.unlock()
    NSLog("[Swizzle] Cleared cached CBClassicManager reason=%@ hadCachedManager=%@", reason, hadCachedManager ? "YES" : "NO")
    return hadCachedManager
}

private func btForwardVoidSelectorToCachedClassicManager(_ selector: Selector, sourceObject: AnyObject, label: String) {
    guard let manager = btCachedClassicManager() as? NSObject else {
        NSLog("[Swizzle] %@ requested by %@ but no cached CBClassicManager is available", label, String(describing: type(of: sourceObject)))
        return
    }
    guard manager.responds(to: selector) else {
        NSLog("[Swizzle] %@ requested by %@ but cached manager %@ does not respond", label, String(describing: type(of: sourceObject)), String(describing: type(of: manager)))
        return
    }
    guard let method = class_getInstanceMethod(type(of: manager), selector) else {
        NSLog("[Swizzle] %@ requested by %@ but implementation lookup failed on %@", label, String(describing: type(of: sourceObject)), String(describing: type(of: manager)))
        return
    }

    typealias Forwarder = @convention(c) (AnyObject, Selector) -> Void
    let forward = unsafeBitCast(method_getImplementation(method), to: Forwarder.self)
    forward(manager, selector)
    NSLog("[Swizzle] Forwarded %@ from %@ to cached %@", label, String(describing: type(of: sourceObject)), String(describing: type(of: manager)))
}

private func btForwardBoolSelectorToCachedClassicManager(_ selector: Selector, value: Bool, sourceObject: AnyObject, label: String) {
    guard let manager = btCachedClassicManager() as? NSObject else {
        NSLog("[Swizzle] %@=%@ requested by %@ but no cached CBClassicManager is available", label, value ? "YES" : "NO", String(describing: type(of: sourceObject)))
        return
    }
    guard manager.responds(to: selector) else {
        NSLog("[Swizzle] %@=%@ requested by %@ but cached manager %@ does not respond", label, value ? "YES" : "NO", String(describing: type(of: sourceObject)), String(describing: type(of: manager)))
        return
    }
    guard let method = class_getInstanceMethod(type(of: manager), selector) else {
        NSLog("[Swizzle] %@=%@ requested by %@ but implementation lookup failed on %@", label, value ? "YES" : "NO", String(describing: type(of: sourceObject)), String(describing: type(of: manager)))
        return
    }

    typealias Forwarder = @convention(c) (AnyObject, Selector, Bool) -> Void
    let forward = unsafeBitCast(method_getImplementation(method), to: Forwarder.self)
    forward(manager, selector, value)
    NSLog("[Swizzle] Forwarded %@=%@ from %@ to cached %@", label, value ? "YES" : "NO", String(describing: type(of: sourceObject)), String(describing: type(of: manager)))
}

private func btForwardObjectSelectorToCachedClassicManager(_ selector: Selector, sourceObject: AnyObject, label: String) -> AnyObject? {
    guard let manager = btCachedClassicManager() as? NSObject else {
        NSLog("[Swizzle] %@ requested by %@ but no cached CBClassicManager is available", label, String(describing: type(of: sourceObject)))
        return nil
    }
    guard manager.responds(to: selector) else {
        NSLog("[Swizzle] %@ requested by %@ but cached manager %@ does not respond", label, String(describing: type(of: sourceObject)), String(describing: type(of: manager)))
        return nil
    }

    let result = btTakePerformObjectResult(manager.perform(selector), selector: selector)
    NSLog("[Swizzle] Forwarded %@ from %@ to cached %@ result=%@", label, String(describing: type(of: sourceObject)), String(describing: type(of: manager)), String(describing: result))
    return result
}

private func btPerformString(_ object: AnyObject?, selectorName: String) -> String? {
    guard let object = object as? NSObject else { return nil }
    let selector = NSSelectorFromString(selectorName)
    guard object.responds(to: selector) else { return nil }
    return btTakePerformObjectResult(object.perform(selector), selector: selector) as? String
}

private func btPostPairingNotification(_ name: Notification.Name, peer: AnyObject?, extraUserInfo: [AnyHashable: Any] = [:]) {
    var userInfo = extraUserInfo
    if let address = btPerformString(peer, selectorName: "addressString") ?? btPerformString(peer, selectorName: "address") {
        userInfo["address"] = address
    }
    if let peerName = btPerformString(peer, selectorName: "name") {
        userInfo["name"] = peerName
    }
    if let peer {
        userInfo["peer"] = peer
        userInfo["peerDescription"] = String(describing: peer)
    }
    NSLog("[Swizzle] Posting pairing notification %@ userInfo=%@", name.rawValue, String(describing: userInfo))
    NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
}

private func btSelectorReturnsRetainedObject(_ selector: Selector) -> Bool {
    let selectorName = NSStringFromSelector(selector)
    let selectorStem = selectorName.split(separator: ":").first.map(String.init) ?? selectorName

    if selectorStem.hasPrefix("alloc") || selectorStem.hasPrefix("new") || selectorStem.hasPrefix("copy") || selectorStem.hasPrefix("mutableCopy") {
        return true
    }

    return selectorStem.hasPrefix("init")
}

private func btTakePerformObjectResult(
    _ result: Unmanaged<AnyObject>?,
    selector: Selector,
    log: BTDiagnosticLogger = btDefaultDiagnosticLogger
) -> AnyObject? {
    guard let result else {
        return nil
    }

    if btSelectorReturnsRetainedObject(selector) {
        return result.takeRetainedValue()
    }

    return result.takeUnretainedValue()
}

func btNormalizedClassicAddressCandidates(from rawAddress: String?) -> [String] {
    guard let rawAddress else { return [] }

    let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let colon = trimmed.replacingOccurrences(of: "-", with: ":").uppercased()
    let dash = trimmed.replacingOccurrences(of: ":", with: "-").uppercased()

    var candidates: [String] = []
    for candidate in [colon, dash] where !candidate.isEmpty && !candidates.contains(candidate) {
        candidates.append(candidate)
    }
    return candidates
}

func btClassicPeerAddressCandidates(_ peer: NSObject, log: BTDiagnosticLogger = btDefaultDiagnosticLogger) -> [String] {
    var candidates: [String] = []

    for selectorName in ["addressString", "address"] {
        let selector = NSSelectorFromString(selectorName)
        guard peer.responds(to: selector) else {
            log("[PeerPath] Peer \(peer) does not respond to \(selectorName)")
            continue
        }

        guard let rawAddress = btTakePerformObjectResult(peer.perform(selector), selector: selector, log: log) as? String else {
            log("[PeerPath] Peer \(peer).\(selectorName) returned no String address")
            continue
        }

        for candidate in btNormalizedClassicAddressCandidates(from: rawAddress) where !candidates.contains(candidate) {
            candidates.append(candidate)
        }
    }

    log("[PeerPath] Peer \(peer) address candidates = \(candidates)")
    return candidates
}

func btClassicPeerMatches(_ peer: NSObject, expectedAddress: String?, log: BTDiagnosticLogger = btDefaultDiagnosticLogger) -> Bool {
    let expectedCandidates = Set(btNormalizedClassicAddressCandidates(from: expectedAddress).map { $0.lowercased() })
    guard !expectedCandidates.isEmpty else {
        log("[PeerPath] Cannot validate peer match because expected address is empty")
        return false
    }

    let peerCandidates = Set(btClassicPeerAddressCandidates(peer, log: log).map { $0.lowercased() })
    guard !peerCandidates.isEmpty else {
        log("[PeerPath] Cannot validate peer match because peer has no address candidates")
        return false
    }

    let matches = !peerCandidates.isDisjoint(with: expectedCandidates)
    log("[PeerPath] Peer match check expected=\(Array(expectedCandidates)) peer=\(Array(peerCandidates)) matches=\(matches)")
    return matches
}

func btLogDevicePeerState(_ device: IOBluetoothDevice, log: BTDiagnosticLogger = btDefaultDiagnosticLogger) {
    let peerSel = NSSelectorFromString("peer")
    let classicPeerSel = NSSelectorFromString("classicPeer")

    let peer = device.responds(to: peerSel) ? btTakePerformObjectResult(device.perform(peerSel), selector: peerSel, log: log) : nil
    let classicPeer = device.responds(to: classicPeerSel) ? btTakePerformObjectResult(device.perform(classicPeerSel), selector: classicPeerSel, log: log) : nil

    // Only log peer state at debug level (not in hot paths)
}

func btClassicCoordinator(log: BTDiagnosticLogger = btDefaultDiagnosticLogger) -> NSObject? {
    guard let coordinatorClass = NSClassFromString("IOBluetoothCoreBluetoothCoordinator") as? NSObject.Type else {
        log("[PeerPath] Missing IOBluetoothCoreBluetoothCoordinator class")
        return nil
    }

    let sharedSel = NSSelectorFromString("sharedInstance")
    guard coordinatorClass.responds(to: sharedSel) else {
        log("[PeerPath] IOBluetoothCoreBluetoothCoordinator.sharedInstance is unavailable")
        return nil
    }

    guard let coordinator = btTakePerformObjectResult(coordinatorClass.perform(sharedSel), selector: sharedSel, log: log) as? NSObject else {
        log("[PeerPath] IOBluetoothCoreBluetoothCoordinator.sharedInstance returned nil")
        return nil
    }

    log("[PeerPath] sharedInstance = \(coordinator)")

    let classicManagerSel = NSSelectorFromString("classicManager")
    if coordinator.responds(to: classicManagerSel) {
        let classicManager = btTakePerformObjectResult(coordinator.perform(classicManagerSel), selector: classicManagerSel, log: log)
        log("[PeerPath] coordinator.classicManager = \(String(describing: classicManager))")
    } else {
        log("[PeerPath] coordinator does not respond to classicManager")
    }

    return coordinator
}

func btResolveClassicPeer(
    for device: IOBluetoothDevice,
    coordinator: NSObject,
    log: BTDiagnosticLogger = btDefaultDiagnosticLogger
) -> NSObject? {
    let peerSel = NSSelectorFromString("peerForAddressString:")
    guard coordinator.responds(to: peerSel) else {
        log("[PeerPath] coordinator does not respond to peerForAddressString:")
        return nil
    }

    let candidates = btNormalizedClassicAddressCandidates(from: device.addressString)
    log("[PeerPath] peer lookup candidates for \(device.nameOrAddress ?? "?"): \(candidates)")

    for candidate in candidates {
        if let peer = btTakePerformObjectResult(coordinator.perform(peerSel, with: candidate), selector: peerSel, log: log) as? NSObject {
            log("[PeerPath] peerForAddressString(\(candidate)) -> \(peer)")
            return peer
        }
        log("[PeerPath] peerForAddressString(\(candidate)) -> nil")
    }

    return nil
}

@discardableResult
func btAttachClassicPeer(
    _ peer: NSObject,
    to device: IOBluetoothDevice,
    log: BTDiagnosticLogger = btDefaultDiagnosticLogger
) -> Bool {
    let setPeerSel = NSSelectorFromString("setPeer:")
    guard device.responds(to: setPeerSel) else {
        log("[PeerPath] device does not respond to setPeer:")
        btLogDevicePeerState(device, log: log)
        return false
    }

    log("[PeerPath] Attaching peer \(peer) to \(device.nameOrAddress ?? "?") [\(device.addressString ?? "?")] via setPeer:")
    device.perform(setPeerSel, with: peer)
    btLogDevicePeerState(device, log: log)
    return true
}

func btConnectDeviceViaClassicPeer(
    _ device: IOBluetoothDevice,
    preferredPeer: NSObject? = nil,
    pollCount: Int = 30,
    pollIntervalUsec: useconds_t = 500_000,
    log: BTDiagnosticLogger = btDefaultDiagnosticLogger
) -> Bool {
    log("[PeerPath] Starting peer-backed connect for \(device.nameOrAddress ?? "?") [\(device.addressString ?? "?")]")

    guard let coordinator = btClassicCoordinator(log: log) else {
        log("[PeerPath] Aborting peer-backed connect because coordinator lookup failed")
        return false
    }

    let peer: NSObject
    if let preferredPeer {
        log("[PeerPath] Preferred peer supplied for \(device.nameOrAddress ?? "?"): \(preferredPeer)")
        if btClassicPeerMatches(preferredPeer, expectedAddress: device.addressString, log: log) {
            peer = preferredPeer
        } else {
            log("[PeerPath] Ignoring preferred peer because it does not match target device")
            guard let resolvedPeer = btResolveClassicPeer(for: device, coordinator: coordinator, log: log) else {
                log("[PeerPath] Aborting peer-backed connect because preferred peer mismatched and coordinator peer lookup failed")
                btLogDevicePeerState(device, log: log)
                return false
            }
            peer = resolvedPeer
        }
    } else {
        guard let resolvedPeer = btResolveClassicPeer(for: device, coordinator: coordinator, log: log) else {
            log("[PeerPath] Aborting peer-backed connect because peer lookup failed")
            btLogDevicePeerState(device, log: log)
            return false
        }
        peer = resolvedPeer
    }

    guard btAttachClassicPeer(peer, to: device, log: log) else {
        log("[PeerPath] Aborting peer-backed connect because device peer attachment failed")
        return false
    }

    if device.isConnected() {
        log("[PeerPath] Device was already ACL-connected after peer attachment")
        return true
    }

    let connectSel = NSSelectorFromString("connectPeer:options:")
    guard coordinator.responds(to: connectSel) else {
        log("[PeerPath] coordinator does not respond to connectPeer:options:")
        return false
    }

    log("[PeerPath] Invoking coordinator.connectPeer:options:")
    coordinator.perform(connectSel, with: peer, with: nil)

    for poll in 0..<pollCount {
        usleep(pollIntervalUsec)

        let connected = device.isConnected()
        if connected || poll == 0 || poll == 1 || poll == 3 || poll == 7 || poll == pollCount - 1 {
            log("[PeerPath] Poll \(poll + 1)/\(pollCount): device.isConnected = \(connected)")
        }
        if connected {
            btLogDevicePeerState(device, log: log)
            return true
        }
    }

    log("[PeerPath] Timed out waiting for peer-backed ACL connection")
    btLogDevicePeerState(device, log: log)
    return false
}

@discardableResult
func btEnsureClassicPeerAttachedForL2CAP(
    _ device: IOBluetoothDevice,
    log: BTDiagnosticLogger = btDefaultDiagnosticLogger
) -> Bool {
    log("[L2CAP] Ensuring classic peer attachment for \(device.nameOrAddress ?? "?") [\(device.addressString ?? "?")]")

    if let coordinator = btClassicCoordinator(log: log),
       let peer = btResolveClassicPeer(for: device, coordinator: coordinator, log: log) {
        let attached = btAttachClassicPeer(peer, to: device, log: log)
        log("[L2CAP] Coordinator peer attachment result = \(attached)")
        if attached {
            return true
        }
    } else {
        log("[L2CAP] Coordinator peer lookup path did not produce an attachable peer")
    }

    guard let cached = btCachedClassicManager() as? NSObject else {
        log("[L2CAP] cachedClassicManager unavailable for fallback peer attachment")
        btLogDevicePeerState(device, log: log)
        return false
    }

    let peersSel = NSSelectorFromString("peers")
    guard cached.responds(to: peersSel) else {
        log("[L2CAP] cachedClassicManager does not respond to peers")
        btLogDevicePeerState(device, log: log)
        return false
    }

    guard let peersMap = btTakePerformObjectResult(cached.perform(peersSel), selector: peersSel, log: log) as? NSObject else {
        log("[L2CAP] cachedClassicManager.peers returned nil or a non-object")
        btLogDevicePeerState(device, log: log)
        return false
    }

    let enumSel = NSSelectorFromString("objectEnumerator")
    guard peersMap.responds(to: enumSel) else {
        log("[L2CAP] cachedClassicManager.peers does not provide objectEnumerator")
        btLogDevicePeerState(device, log: log)
        return false
    }

    let normalizedDeviceAddresses = Set(btNormalizedClassicAddressCandidates(from: device.addressString).map { $0.lowercased() })
    log("[L2CAP] Fallback peer enumeration candidates = \(Array(normalizedDeviceAddresses))")

    guard !normalizedDeviceAddresses.isEmpty else {
        log("[L2CAP] Device has no address candidates for fallback peer matching")
        btLogDevicePeerState(device, log: log)
        return false
    }

    let enumerator = btTakePerformObjectResult(peersMap.perform(enumSel), selector: enumSel, log: log) as? NSEnumerator
    while let peer = enumerator?.nextObject() as? NSObject {
        let addrSel = NSSelectorFromString("address")
        guard peer.responds(to: addrSel) else {
            log("[L2CAP] Skipping cached peer without address selector: \(peer)")
            continue
        }

        let peerAddress = btTakePerformObjectResult(peer.perform(addrSel), selector: addrSel, log: log) as? String
        let normalizedPeerAddresses = Set(btNormalizedClassicAddressCandidates(from: peerAddress).map { $0.lowercased() })
        log("[L2CAP] Examining cached peer address candidates = \(Array(normalizedPeerAddresses))")

        guard !normalizedPeerAddresses.isDisjoint(with: normalizedDeviceAddresses) else {
            log("[L2CAP] Cached peer does not match target device")
            continue
        }

        log("[L2CAP] Found matching cached peer \(peer)")
        let attached = btAttachClassicPeer(peer, to: device, log: log)
        log("[L2CAP] Cached peer attachment result = \(attached)")
        if attached {
            return true
        }
    }

    log("[L2CAP] No matching cached peer was attachable")
    btLogDevicePeerState(device, log: log)
    return false
}

private func btDescribeL2CAPChannel(_ channel: IOBluetoothL2CAPChannel?) -> String {
    guard let channel else { return "nil" }
    return "\(channel) PSM:\(channel.psm) objectID:\(channel.objectID)"
}

private final class BTL2CAPOpenRunnerBlock: NSObject {
    let work: () -> Void

    init(work: @escaping () -> Void) {
        self.work = work
    }
}

private final class BTL2CAPOpenRunner: NSObject {
    static let shared = BTL2CAPOpenRunner()

    private let stateLock = NSLock()
    private var workerThread: Thread?
    private var readySemaphore: DispatchSemaphore?

    func enqueue(_ work: @escaping () -> Void) {
        let thread = ensureThread()
        let block = BTL2CAPOpenRunnerBlock(work: work)
        NSLog("[Swizzle] Scheduling L2CAP open work on runner thread %@", String(describing: thread))
        perform(#selector(runBlock(_:)), on: thread, with: block, waitUntilDone: false, modes: [RunLoop.Mode.default.rawValue])
    }

    func reset(reason: String) {
        stateLock.lock()
        let thread = workerThread
        workerThread = nil
        readySemaphore?.signal()
        readySemaphore = nil
        stateLock.unlock()

        NSLog(
            "[Swizzle] Resetting dedicated L2CAP runner reason=%@ hadThread=%@",
            reason,
            thread == nil ? "NO" : "YES"
        )

        guard let thread else { return }
        thread.cancel()
        perform(
            #selector(runBlock(_:)),
            on: thread,
            with: BTL2CAPOpenRunnerBlock(work: {}),
            waitUntilDone: false,
            modes: [RunLoop.Mode.default.rawValue]
        )
    }

    private func ensureThread() -> Thread {
        stateLock.lock()
        if let workerThread, !workerThread.isFinished {
            stateLock.unlock()
            return workerThread
        }

        let readySemaphore = DispatchSemaphore(value: 0)
        self.readySemaphore = readySemaphore

        let thread = Thread(target: self, selector: #selector(threadMain), object: nil)
        thread.name = "BTHIDApp.L2CAPOpenRunner"
        workerThread = thread
        NSLog("[Swizzle] Starting dedicated L2CAP runner thread")
        thread.start()
        stateLock.unlock()

        let waitResult = readySemaphore.wait(timeout: .now() + 5)
        if waitResult == .success {
            NSLog("[Swizzle] L2CAP runner thread signaled ready")
        } else {
            NSLog("[Swizzle] L2CAP runner thread failed to signal readiness within 5 seconds")
        }

        return thread
    }

    @objc private func threadMain() {
        autoreleasepool {
            let runLoop = RunLoop.current
            let keepAliveTimer = Timer(timeInterval: 60, repeats: true) { _ in }
            runLoop.add(keepAliveTimer, forMode: .default)
            runLoop.add(keepAliveTimer, forMode: .common)

            stateLock.lock()
            let readySemaphore = self.readySemaphore
            self.readySemaphore = nil
            stateLock.unlock()

            NSLog("[Swizzle] Dedicated L2CAP runner thread entered run loop: %@", String(describing: Thread.current))
            readySemaphore?.signal()

            while !Thread.current.isCancelled {
                let ranSource = runLoop.run(mode: .default, before: Date(timeIntervalSinceNow: 60))
                if !ranSource {
                    NSLog("[Swizzle] Dedicated L2CAP runner thread woke without handling a source")
                }
            }

            NSLog("[Swizzle] Dedicated L2CAP runner thread exiting")
        }
    }

    @objc private func runBlock(_ block: BTL2CAPOpenRunnerBlock) {
        NSLog("[Swizzle] Dedicated L2CAP runner executing scheduled open work")
        block.work()
    }
}

private final class BTL2CAPAsyncOpenRetainRegistry {
    static let shared = BTL2CAPAsyncOpenRetainRegistry()

    private let stateLock = NSLock()
    private var retainedContexts: [ObjectIdentifier: BTL2CAPAsyncOpenContext] = [:]

    func retain(_ context: BTL2CAPAsyncOpenContext, reason: String) {
        let identifier = ObjectIdentifier(context)

        stateLock.lock()
        let alreadyRetained = retainedContexts[identifier] != nil
        retainedContexts[identifier] = context
        let retainCount = retainedContexts.count
        stateLock.unlock()

        NSLog(
            "[Swizzle] Retain registry %@ context=%@ reason=%@ retainedCount=%d",
            alreadyRetained ? "already held" : "retained",
            String(describing: context),
            reason,
            retainCount
        )
    }

    func release(_ context: BTL2CAPAsyncOpenContext, reason: String) {
        let identifier = ObjectIdentifier(context)

        stateLock.lock()
        let removed = retainedContexts.removeValue(forKey: identifier) != nil
        let retainCount = retainedContexts.count
        stateLock.unlock()

        NSLog(
            "[Swizzle] Retain registry %@ context=%@ reason=%@ retainedCount=%d",
            removed ? "released" : "release-miss",
            String(describing: context),
            reason,
            retainCount
        )
    }

    func reset(reason: String) {
        stateLock.lock()
        let contexts = Array(retainedContexts.values)
        retainedContexts.removeAll()
        stateLock.unlock()

        NSLog(
            "[Swizzle] Reset L2CAP async retain registry reason=%@ contexts=%d",
            reason,
            contexts.count
        )

        for context in contexts {
            context.detachForRuntimeReset(reason: reason)
        }
    }
}

private final class BTL2CAPAsyncOpenContext: NSObject, IOBluetoothL2CAPChannelDelegate {
    let deviceName: String
    let deviceAddress: String
    let psm: BluetoothL2CAPPSM
    let requestedDelegate: AnyObject?
    let channelConfiguration: NSDictionary?

    private let stateLock = NSLock()
    private let completionSemaphore = DispatchSemaphore(value: 0)
    private var completionSignaled = false
    private var startStatus: IOReturn?
    private var openStatus: IOReturn?
    private var provisionalChannel: IOBluetoothL2CAPChannel?
    private var completedChannel: IOBluetoothL2CAPChannel?
    private var callbackReceived = false
    private var timedOut = false
    private var retainedByRegistry = false
    private var runtimeResetDetached = false

    init(
        device: IOBluetoothDevice,
        psm: BluetoothL2CAPPSM,
        requestedDelegate: AnyObject?,
        channelConfiguration: NSDictionary?
    ) {
        deviceName = device.nameOrAddress ?? "?"
        deviceAddress = device.addressString ?? "?"
        self.psm = psm
        self.requestedDelegate = requestedDelegate
        self.channelConfiguration = channelConfiguration
    }

    deinit {
        NSLog("[Swizzle] Async L2CAP context deinit for %@ [%@] PSM:%d", deviceName, deviceAddress, psm)
    }

    func retainForAsyncCallbackLifetime(reason: String) {
        stateLock.lock()
        let shouldRetain = !retainedByRegistry
        if shouldRetain {
            retainedByRegistry = true
        }
        stateLock.unlock()

        if shouldRetain {
            NSLog("[Swizzle] Async L2CAP context retaining for callback lifetime PSM:%d reason=%@", psm, reason)
            BTL2CAPAsyncOpenRetainRegistry.shared.retain(self, reason: reason)
        } else {
            NSLog("[Swizzle] Async L2CAP context already retained for callback lifetime PSM:%d reason=%@", psm, reason)
        }
    }

    private func releaseFromRegistryIfNeeded(reason: String) {
        stateLock.lock()
        let shouldRelease = retainedByRegistry
        if shouldRelease {
            retainedByRegistry = false
        }
        stateLock.unlock()

        if shouldRelease {
            NSLog("[Swizzle] Async L2CAP context releasing callback lifetime retain PSM:%d reason=%@", psm, reason)
            BTL2CAPAsyncOpenRetainRegistry.shared.release(self, reason: reason)
        } else {
            NSLog("[Swizzle] Async L2CAP context callback lifetime retain already released PSM:%d reason=%@", psm, reason)
        }
    }

    private func installBridgeDelegateRetention(on channel: IOBluetoothL2CAPChannel) {
        let delegateInstallResult: IOReturn

        if let channelConfiguration {
            delegateInstallResult = channel.setDelegate(self, withConfiguration: channelConfiguration as? [AnyHashable: Any] ?? [:])
            NSLog(
                "[Swizzle] Installed bridge delegate with configuration on provisional channel for %@ [%@] PSM:%d result=%d channel=%@",
                deviceName,
                deviceAddress,
                psm,
                delegateInstallResult,
                btDescribeL2CAPChannel(channel)
            )
        } else {
            delegateInstallResult = channel.setDelegate(self)
            NSLog(
                "[Swizzle] Installed bridge delegate on provisional channel for %@ [%@] PSM:%d result=%d channel=%@",
                deviceName,
                deviceAddress,
                psm,
                delegateInstallResult,
                btDescribeL2CAPChannel(channel)
            )
        }
    }

    private func clearRetainedChannels(reason: String) {
        stateLock.lock()
        let hadProvisional = provisionalChannel != nil
        let hadCompleted = completedChannel != nil
        provisionalChannel = nil
        completedChannel = nil
        stateLock.unlock()

        NSLog(
            "[Swizzle] Cleared retained channel references for %@ [%@] PSM:%d reason=%@ hadProvisional=%@ hadCompleted=%@",
            deviceName,
            deviceAddress,
            psm,
            reason,
            hadProvisional ? "YES" : "NO",
            hadCompleted ? "YES" : "NO"
        )
    }

    func detachForRuntimeReset(reason: String) {
        stateLock.lock()
        let provisional = provisionalChannel
        let completed = completedChannel
        let shouldSignal = !completionSignaled
        runtimeResetDetached = true
        timedOut = true
        openStatus = openStatus ?? kIOReturnError
        provisionalChannel = nil
        completedChannel = nil
        retainedByRegistry = false
        if shouldSignal {
            completionSignaled = true
        }
        stateLock.unlock()

        if shouldSignal {
            completionSemaphore.signal()
        }

        if let provisional {
            let delegateResult = provisional.setDelegate(nil)
            let closeResult = provisional.close()
            NSLog(
                "[Swizzle] Runtime reset closed provisional L2CAP channel for %@ [%@] PSM:%d reason=%@ setDelegate=%d close=%d channel=%@",
                deviceName,
                deviceAddress,
                psm,
                reason,
                delegateResult,
                closeResult,
                btDescribeL2CAPChannel(provisional)
            )
        }

        if let completed {
            if let provisional, completed === provisional {
                NSLog("[Swizzle] Runtime reset skipped duplicate completed L2CAP close for PSM:%d reason=%@", psm, reason)
            } else {
                let delegateResult = completed.setDelegate(nil)
                let closeResult = completed.close()
                NSLog(
                    "[Swizzle] Runtime reset closed completed L2CAP channel for %@ [%@] PSM:%d reason=%@ setDelegate=%d close=%d channel=%@",
                    deviceName,
                    deviceAddress,
                    psm,
                    reason,
                    delegateResult,
                    closeResult,
                    btDescribeL2CAPChannel(completed)
                )
            }
        }

        NSLog(
            "[Swizzle] Detached async L2CAP context during runtime reset for %@ [%@] PSM:%d reason=%@ hadProvisional=%@ hadCompleted=%@ signaled=%@",
            deviceName,
            deviceAddress,
            psm,
            reason,
            provisional == nil ? "NO" : "YES",
            completed == nil ? "NO" : "YES",
            shouldSignal ? "YES" : "NO"
        )
    }

    func recordAsyncStart(status: IOReturn, provisionalChannel: IOBluetoothL2CAPChannel?) {
        // Explicitly retain the channel to prevent autorelease pool from cleaning it up
        if let ch = provisionalChannel {
            let _ = Unmanaged.passRetained(ch)
        }
        stateLock.lock()
        startStatus = status
        self.provisionalChannel = provisionalChannel
        let detachedByRuntimeReset = runtimeResetDetached
        let delegateDescription = String(describing: requestedDelegate)
        NSLog(
            "[Swizzle] Async L2CAP start returned for %@ [%@] PSM:%d status=%d provisionalChannel=%@ requestedDelegate=%@",
            deviceName,
            deviceAddress,
            psm,
            status,
            btDescribeL2CAPChannel(provisionalChannel),
            delegateDescription
        )

        if detachedByRuntimeReset {
            openStatus = kIOReturnError
            signalCompletionLocked(reason: "runtime reset already detached before async start")
            stateLock.unlock()

            if let provisionalChannel {
                let delegateResult = provisionalChannel.setDelegate(nil)
                let closeResult = provisionalChannel.close()
                NSLog(
                    "[Swizzle] Runtime reset closed late provisional channel from async start for %@ [%@] PSM:%d setDelegate=%d close=%d channel=%@",
                    deviceName,
                    deviceAddress,
                    psm,
                    delegateResult,
                    closeResult,
                    btDescribeL2CAPChannel(provisionalChannel)
                )
            }
            clearRetainedChannels(reason: "runtime reset detached before async start")
            return
        }

        if status != kIOReturnSuccess {
            openStatus = status
            signalCompletionLocked(reason: "async start failure")
            stateLock.unlock()
            clearRetainedChannels(reason: "async start failure")
            releaseFromRegistryIfNeeded(reason: "async start failure")
            return
        } else if provisionalChannel == nil {
            NSLog("[Swizzle] Async L2CAP start succeeded for PSM:%d but provisional channel is nil", psm)
        } else {
            NSLog("[Swizzle] Async L2CAP start succeeded for PSM:%d and returned provisional channel %@", psm, btDescribeL2CAPChannel(provisionalChannel))
        }
        stateLock.unlock()

        if let provisionalChannel {
            installBridgeDelegateRetention(on: provisionalChannel)
        } else {
            NSLog("[Swizzle] No provisional channel available to retain bridge delegate for PSM:%d", psm)
        }
    }

    func waitForCompletion(timeout: TimeInterval) -> IOReturn {
        let startDate = Date()
        NSLog("[Swizzle] Waiting for async L2CAP open callback for %@ [%@] PSM:%d timeout=%.3fs", deviceName, deviceAddress, psm, timeout)

        var waitIteration = 0
        while true {
            stateLock.lock()
            let alreadyCompleted = isCompletedLocked
            let currentStatus = resolvedStatusLocked
            let currentChannel = resolvedChannelLocked
            stateLock.unlock()

            if alreadyCompleted {
                let elapsed = Date().timeIntervalSince(startDate)
                NSLog(
                    "[Swizzle] Wait completed for %@ [%@] PSM:%d after %.3fs status=%d channel=%@ callbackReceived=%@",
                    deviceName,
                    deviceAddress,
                    psm,
                    elapsed,
                    currentStatus,
                    btDescribeL2CAPChannel(currentChannel),
                    callbackReceivedDescription
                )
                return currentStatus
            }

            let elapsed = Date().timeIntervalSince(startDate)
            let remaining = timeout - elapsed
            if remaining <= 0 {
                stateLock.lock()
                if isCompletedLocked {
                    let completedStatus = resolvedStatusLocked
                    let completedChannel = resolvedChannelLocked
                    stateLock.unlock()
                    NSLog(
                        "[Swizzle] Wait reached timeout boundary but callback already completed for %@ [%@] PSM:%d status=%d channel=%@",
                        deviceName,
                        deviceAddress,
                        psm,
                        completedStatus,
                        btDescribeL2CAPChannel(completedChannel)
                    )
                    return completedStatus
                }
                timedOut = true
                let hadCallback = callbackReceived
                let channelAtTimeout = resolvedChannelLocked
                stateLock.unlock()

                NSLog(
                    "[Swizzle] Timeout waiting for async L2CAP open callback for %@ [%@] PSM:%d after %.3fs callbackReceived=%@ channel=%@",
                    deviceName,
                    deviceAddress,
                    psm,
                    elapsed,
                    hadCallback ? "YES" : "NO",
                    btDescribeL2CAPChannel(channelAtTimeout)
                )
                return kIOReturnTimeout
            }

            waitIteration += 1
            let slice = min(0.2, remaining)

            let waitResult = completionSemaphore.wait(timeout: .now() + slice)
            if waitResult == .success {
                NSLog("[Swizzle] Completion semaphore signaled for %@ [%@] PSM:%d", deviceName, deviceAddress, psm)
            } else {
                NSLog("[Swizzle] Completion semaphore still waiting for %@ [%@] PSM:%d", deviceName, deviceAddress, psm)
            }
        }
    }

    func resolvedChannelForReturn(status: IOReturn) -> IOBluetoothL2CAPChannel? {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard status == kIOReturnSuccess else {
            NSLog("[Swizzle] Returning nil channel for PSM:%d because status=%d", psm, status)
            return nil
        }

        let channel = resolvedChannelLocked
        NSLog("[Swizzle] Returning opened channel for PSM:%d -> %@", psm, btDescribeL2CAPChannel(channel))
        return channel
    }

    func finalizeAfterSynchronousWait(status: IOReturn) {
        stateLock.lock()
        let hadCallback = callbackReceived
        let keepRetainedForLateCallback = status == kIOReturnTimeout && !hadCallback
        stateLock.unlock()

        if keepRetainedForLateCallback {
            NSLog(
                "[Swizzle] Preserving async bridge context after timeout for %@ [%@] PSM:%d so late callback can safely arrive",
                deviceName,
                deviceAddress,
                psm
            )
            return
        }

        NSLog(
            "[Swizzle] Finalizing async bridge context after synchronous wait for %@ [%@] PSM:%d status=%d callbackReceived=%@",
            deviceName,
            deviceAddress,
            psm,
            status,
            hadCallback ? "YES" : "NO"
        )
        clearRetainedChannels(reason: "synchronous wait finished status=\(status)")
        releaseFromRegistryIfNeeded(reason: "synchronous wait finished status=\(status)")
    }

    private var isCompletedLocked: Bool {
        openStatus != nil
    }

    private var resolvedStatusLocked: IOReturn {
        openStatus ?? startStatus ?? kIOReturnError
    }

    private var resolvedChannelLocked: IOBluetoothL2CAPChannel? {
        completedChannel ?? provisionalChannel
    }

    private var callbackReceivedDescription: String {
        stateLock.lock()
        let value = callbackReceived
        stateLock.unlock()
        return value ? "YES" : "NO"
    }

    private func signalCompletionLocked(reason: String) {
        if completionSignaled {
            NSLog("[Swizzle] Completion already signaled for %@ [%@] PSM:%d reason=%@", deviceName, deviceAddress, psm, reason)
            return
        }

        completionSignaled = true
        NSLog("[Swizzle] Signaling completion for %@ [%@] PSM:%d reason=%@", deviceName, deviceAddress, psm, reason)
        completionSemaphore.signal()
    }

    func l2capChannelOpenComplete(_ l2capChannel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
        stateLock.lock()
        callbackReceived = true
        openStatus = error
        completedChannel = l2capChannel
        let timedOutAtCallback = timedOut
        let detachedByRuntimeReset = runtimeResetDetached
        NSLog(
            "[Swizzle] l2capChannelOpenComplete received for %@ [%@] PSM:%d status=%d channel=%@ timedOut=%@",
            deviceName,
            deviceAddress,
            psm,
            error,
            btDescribeL2CAPChannel(l2capChannel),
            timedOutAtCallback ? "YES" : "NO"
        )
        signalCompletionLocked(reason: "l2capChannelOpenComplete")
        stateLock.unlock()

        if detachedByRuntimeReset {
            if let l2capChannel {
                let delegateResult = l2capChannel.setDelegate(nil)
                let closeResult = l2capChannel.close()
                NSLog(
                    "[Swizzle] Runtime reset closed late L2CAP open callback channel for %@ [%@] PSM:%d status=%d setDelegate=%d close=%d channel=%@",
                    deviceName,
                    deviceAddress,
                    psm,
                    error,
                    delegateResult,
                    closeResult,
                    btDescribeL2CAPChannel(l2capChannel)
                )
            } else {
                NSLog("[Swizzle] Runtime reset ignored late nil L2CAP open callback for %@ [%@] PSM:%d status=%d", deviceName, deviceAddress, psm, error)
            }
            clearRetainedChannels(reason: "runtime reset late open callback")
            return
        }

        guard error == kIOReturnSuccess else {
            NSLog("[Swizzle] Async L2CAP open callback reported failure for PSM:%d status=%d", psm, error)
            if timedOutAtCallback {
                NSLog("[Swizzle] Late async failure callback for PSM:%d releasing retained async bridge state", psm)
                clearRetainedChannels(reason: "late failure callback status=\(error)")
                releaseFromRegistryIfNeeded(reason: "late failure callback status=\(error)")
            }
            return
        }

        guard let l2capChannel else {
            NSLog("[Swizzle] Async L2CAP open callback reported success for PSM:%d but channel is nil", psm)
            return
        }

        if let requestedDelegate {
            if requestedDelegate === self {
                NSLog("[Swizzle] Requested delegate already equals bridge delegate for PSM:%d", psm)
            } else if let channelConfiguration {
                let setResult = l2capChannel.setDelegate(requestedDelegate, withConfiguration: channelConfiguration as? [AnyHashable: Any] ?? [:])
                NSLog("[Swizzle] Forwarded delegate with configuration for PSM:%d result=%d delegate=%@", psm, setResult, String(describing: requestedDelegate))
            } else {
                let setResult = l2capChannel.setDelegate(requestedDelegate)
                NSLog("[Swizzle] Forwarded delegate for PSM:%d result=%d delegate=%@", psm, setResult, String(describing: requestedDelegate))
            }
        } else {
            NSLog("[Swizzle] No original delegate supplied for PSM:%d; keeping bridge delegate attached", psm)
        }

        if timedOutAtCallback {
            let closeResult = l2capChannel.close()
            NSLog("[Swizzle] Late L2CAP success after timeout for PSM:%d; closeChannel=%d", psm, closeResult)
            if closeResult != kIOReturnSuccess {
                NSLog("[Swizzle] Late closeChannel failed for PSM:%d; releasing retained async bridge state immediately", psm)
                clearRetainedChannels(reason: "late callback close failure status=\(closeResult)")
                releaseFromRegistryIfNeeded(reason: "late callback close failure status=\(closeResult)")
            } else {
                NSLog("[Swizzle] Waiting for l2capChannelClosed before releasing late async bridge state for PSM:%d", psm)
            }
        } else {
            NSLog("[Swizzle] Async L2CAP open succeeded within timeout for PSM:%d", psm)
        }
    }

    func l2capChannelClosed(_ l2capChannel: IOBluetoothL2CAPChannel!) {
        NSLog("[Swizzle] l2capChannelClosed received for %@ [%@] PSM:%d channel=%@", deviceName, deviceAddress, psm, btDescribeL2CAPChannel(l2capChannel))
        clearRetainedChannels(reason: "l2capChannelClosed")
        releaseFromRegistryIfNeeded(reason: "l2capChannelClosed")
    }
}

private typealias BTL2CAPAsyncOpenNoConfigFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<AnyObject?>, BluetoothL2CAPPSM, AnyObject?) -> IOReturn
private typealias BTL2CAPAsyncOpenWithConfigFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<AnyObject?>, BluetoothL2CAPPSM, AnyObject?, AnyObject?) -> IOReturn

private func btOpenL2CAPChannelSyncViaAsync(
    device: IOBluetoothDevice,
    channelPtr: UnsafeMutablePointer<AnyObject?>,
    psm: BluetoothL2CAPPSM,
    channelConfiguration: NSDictionary?,
    requestedDelegate: AnyObject?,
    invokeOriginalAsync: @escaping (BTL2CAPAsyncOpenContext) -> Void
) -> IOReturn {
    let swizzleLogger: BTDiagnosticLogger = { message in
        NSLog("[Swizzle] %@", message)
    }

    swizzleLogger("Bridging sync L2CAP open through async path for \(device.nameOrAddress ?? "?") [\(device.addressString ?? "?")] PSM:\(psm)")
    channelPtr.pointee = nil

    let peerAttached = btEnsureClassicPeerAttachedForL2CAP(device, log: swizzleLogger)
    swizzleLogger("Peer attachment ready before async L2CAP open PSM:\(psm) = \(peerAttached)")

    let context = BTL2CAPAsyncOpenContext(
        device: device,
        psm: psm,
        requestedDelegate: requestedDelegate,
        channelConfiguration: channelConfiguration
    )
    context.retainForAsyncCallbackLifetime(reason: "btOpenL2CAPChannelSyncViaAsync start PSM=\(psm)")

    swizzleLogger("Queueing async L2CAP open work for PSM:\(psm)")
    BTL2CAPOpenRunner.shared.enqueue {
        swizzleLogger("Runner thread about to invoke original async L2CAP open for PSM:\(psm)")
        invokeOriginalAsync(context)
    }

    let waitStatus = context.waitForCompletion(timeout: 5.0)
    let resolvedChannel = context.resolvedChannelForReturn(status: waitStatus)
    channelPtr.pointee = resolvedChannel
    context.finalizeAfterSynchronousWait(status: waitStatus)
    swizzleLogger("Async-backed sync L2CAP open finished for PSM:\(psm) status=\(waitStatus) channel=\(btDescribeL2CAPChannel(resolvedChannel))")
    return waitStatus
}

func resetBluetoothHIDProcessRuntime(reason: String, log: BTDiagnosticLogger = btDefaultDiagnosticLogger) {
    log("[BTPrepare] process runtime reset starting reason=\(reason)")
    let hadCachedClassicManager = btClearCachedClassicManager(reason: reason)
    BTL2CAPAsyncOpenRetainRegistry.shared.reset(reason: reason)
    BTL2CAPOpenRunner.shared.reset(reason: reason)
    log(
        "[BTPrepare] process runtime reset complete reason=\(reason) cachedClassicManagerCleared=\(hadCachedClassicManager) coordinatorPreserved=true"
    )
}

private var didInstallBluetoothHIDRuntimeSwizzles = false

func installBluetoothHIDRuntimeSwizzles() {
    guard !didInstallBluetoothHIDRuntimeSwizzles else {
        NSLog("[Swizzle] Bluetooth HID runtime already installed")
        return
    }
    didInstallBluetoothHIDRuntimeSwizzles = true
    NSLog("[Swizzle] Installing Bluetooth HID runtime hooks")

    // === Crash Guard: CoreBluetoothUI can send CBManager selectors to AppKit's section controller ===
    // On macOS 26.1, CBDeviceCollectionView.viewDidLoad has been observed sending
    // private Bluetooth selectors to NSWindowSectionContentController while loading
    // IOBluetoothDeviceSelectorController as a sheet. AppKit does not implement those
    // selectors, so forward them to the cached CBClassicManager that owns the Bluetooth
    // state used by the selector.
    if let sectionClass = NSClassFromString("NSWindowSectionContentController") {
        let deviceStateSelector = NSSelectorFromString("sendLocalDeviceStateRequest")
        if !class_respondsToSelector(sectionClass, deviceStateSelector) {
            let block: @convention(block) (AnyObject) -> Void = { object in
                btForwardVoidSelectorToCachedClassicManager(
                    deviceStateSelector,
                    sourceObject: object,
                    label: "NSWindowSectionContentController.sendLocalDeviceStateRequest"
                )
            }
            if class_addMethod(sectionClass, deviceStateSelector, imp_implementationWithBlock(block), "v@:") {
                NSLog("[Swizzle] Added forwarding shim for NSWindowSectionContentController.sendLocalDeviceStateRequest")
            } else {
                NSLog("[Swizzle] Failed to add NSWindowSectionContentController.sendLocalDeviceStateRequest forwarding shim")
            }
        } else {
            NSLog("[Swizzle] NSWindowSectionContentController already responds to sendLocalDeviceStateRequest")
        }

        let tccApprovedSelector = NSSelectorFromString("setTccApproved:")
        if !class_respondsToSelector(sectionClass, tccApprovedSelector) {
            let block: @convention(block) (AnyObject, Bool) -> Void = { object, approved in
                btForwardBoolSelectorToCachedClassicManager(
                    tccApprovedSelector,
                    value: approved,
                    sourceObject: object,
                    label: "NSWindowSectionContentController.setTccApproved"
                )
            }
            if class_addMethod(sectionClass, tccApprovedSelector, imp_implementationWithBlock(block), "v@:B") {
                NSLog("[Swizzle] Added forwarding shim for NSWindowSectionContentController.setTccApproved:")
            } else {
                NSLog("[Swizzle] Failed to add NSWindowSectionContentController.setTccApproved: forwarding shim")
            }
        } else {
            NSLog("[Swizzle] NSWindowSectionContentController already responds to setTccApproved:")
        }

        let sharedPairingAgentSelector = NSSelectorFromString("sharedPairingAgent")
        if !class_respondsToSelector(sectionClass, sharedPairingAgentSelector) {
            let block: @convention(block) (AnyObject) -> AnyObject? = { object in
                btForwardObjectSelectorToCachedClassicManager(
                    sharedPairingAgentSelector,
                    sourceObject: object,
                    label: "NSWindowSectionContentController.sharedPairingAgent"
                )
            }
            if class_addMethod(sectionClass, sharedPairingAgentSelector, imp_implementationWithBlock(block), "@@:") {
                NSLog("[Swizzle] Added forwarding shim for NSWindowSectionContentController.sharedPairingAgent")
            } else {
                NSLog("[Swizzle] Failed to add NSWindowSectionContentController.sharedPairingAgent forwarding shim")
            }
        } else {
            NSLog("[Swizzle] NSWindowSectionContentController already responds to sharedPairingAgent")
        }
    } else {
        NSLog("[Swizzle] NSWindowSectionContentController class unavailable; selector forwarding shims not installed")
    }

    // === Swizzle 1: Fix setInitialFirstResponder assertion ===
    if let panelClass = NSClassFromString("TerminateEnabledModalPanel") {
        let originalSel = NSSelectorFromString("setInitialFirstResponder:")
        if let originalMethod = class_getInstanceMethod(panelClass, originalSel) {
            let originalIMP = method_getImplementation(originalMethod)
            let swizzledBlock: @convention(block) (AnyObject, AnyObject?) -> Void = { (self_, responder) in
                if responder == nil || responder is NSView {
                    let original = unsafeBitCast(originalIMP, to: (@convention(c) (AnyObject, Selector, AnyObject?) -> Void).self)
                    original(self_, originalSel, responder)
                } else {
                    NSLog("[Swizzle] Blocked setInitialFirstResponder: non-NSView: %@", String(describing: type(of: responder!)))
                }
            }
            method_setImplementation(originalMethod, imp_implementationWithBlock(swizzledBlock))
            NSLog("[Swizzle] Patched TerminateEnabledModalPanel.setInitialFirstResponder:")
        }
    }

    // === Swizzle 1b: keep CoreBluetoothUI pairing UI on the main thread ===
    // Pairing requests arrive from CoreBluetooth's XPC queue, but CoreBluetoothUI
    // presents AppKit sheets from that callback. AppKit requires every layout and
    // window mutation to happen on the main thread.
    if let deviceCollectionClass = NSClassFromString("CBDeviceCollectionView") {
        let pairingCallbackSel = NSSelectorFromString("pairingAgent:peerDidRequestPairing:type:passkey:")
        if let method = class_getInstanceMethod(deviceCollectionClass, pairingCallbackSel) {
            let originalIMP = method_getImplementation(method)
            typealias PairingCallbackFn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, Int64, AnyObject?) -> Void
            let original = unsafeBitCast(originalIMP, to: PairingCallbackFn.self)
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, Int64, AnyObject?) -> Void = { (self_, pairingAgent, peer, pairingType, passkey) in
                if Thread.isMainThread {
                    NSLog("[Swizzle] Pairing callback already on main thread type=%lld passkey=%@", pairingType, String(describing: passkey))
                    original(self_, pairingCallbackSel, pairingAgent, peer, pairingType, passkey)
                } else {
                    NSLog("[Swizzle] Pairing callback received off main thread; dispatching synchronously to main type=%lld passkey=%@ thread=%@", pairingType, String(describing: passkey), String(describing: Thread.current))
                    DispatchQueue.main.sync {
                        NSLog("[Swizzle] Pairing callback executing on main thread type=%lld passkey=%@", pairingType, String(describing: passkey))
                        original(self_, pairingCallbackSel, pairingAgent, peer, pairingType, passkey)
                        NSLog("[Swizzle] Pairing callback completed on main thread type=%lld", pairingType)
                    }
                    NSLog("[Swizzle] Pairing callback main-thread dispatch returned type=%lld", pairingType)
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
            NSLog("[Swizzle] Hooked CBDeviceCollectionView.pairingAgent:peerDidRequestPairing:type:passkey: for main-thread UI")
        } else {
            NSLog("[Swizzle] Missing CBDeviceCollectionView.pairingAgent:peerDidRequestPairing:type:passkey:; pairing UI main-thread hook not installed")
        }

        let completePairingSel = NSSelectorFromString("pairingAgent:peerDidCompletePairing:")
        if let method = class_getInstanceMethod(deviceCollectionClass, completePairingSel) {
            let originalIMP = method_getImplementation(method)
            typealias CompletePairingFn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
            let original = unsafeBitCast(originalIMP, to: CompletePairingFn.self)
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { (self_, pairingAgent, peer) in
                if Thread.isMainThread {
                    NSLog("[Swizzle] Pairing complete callback already on main thread peer=%@", String(describing: peer))
                    original(self_, completePairingSel, pairingAgent, peer)
                    btPostPairingNotification(.easyBluetoothPairingCompleted, peer: peer)
                } else {
                    NSLog("[Swizzle] Pairing complete callback received off main thread; dispatching synchronously to main peer=%@ thread=%@", String(describing: peer), String(describing: Thread.current))
                    DispatchQueue.main.sync {
                        NSLog("[Swizzle] Pairing complete callback executing on main thread peer=%@", String(describing: peer))
                        original(self_, completePairingSel, pairingAgent, peer)
                        btPostPairingNotification(.easyBluetoothPairingCompleted, peer: peer)
                        NSLog("[Swizzle] Pairing complete callback completed on main thread peer=%@", String(describing: peer))
                    }
                    NSLog("[Swizzle] Pairing complete callback main-thread dispatch returned peer=%@", String(describing: peer))
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
            NSLog("[Swizzle] Hooked CBDeviceCollectionView.pairingAgent:peerDidCompletePairing: for main-thread UI")
        } else {
            NSLog("[Swizzle] Missing CBDeviceCollectionView.pairingAgent:peerDidCompletePairing:; completion main-thread hook not installed")
        }

        let failPairingSel = NSSelectorFromString("pairingAgent:peerDidFailToCompletePairing:error:")
        if let method = class_getInstanceMethod(deviceCollectionClass, failPairingSel) {
            let originalIMP = method_getImplementation(method)
            typealias FailPairingFn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Void
            let original = unsafeBitCast(originalIMP, to: FailPairingFn.self)
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void = { (self_, pairingAgent, peer, error) in
                if Thread.isMainThread {
                    NSLog("[Swizzle] Pairing fail callback already on main thread peer=%@ error=%@", String(describing: peer), String(describing: error))
                    original(self_, failPairingSel, pairingAgent, peer, error)
                    btPostPairingNotification(.easyBluetoothPairingFailed, peer: peer, extraUserInfo: ["error": String(describing: error)])
                } else {
                    NSLog("[Swizzle] Pairing fail callback received off main thread; dispatching synchronously to main peer=%@ error=%@ thread=%@", String(describing: peer), String(describing: error), String(describing: Thread.current))
                    DispatchQueue.main.sync {
                        NSLog("[Swizzle] Pairing fail callback executing on main thread peer=%@ error=%@", String(describing: peer), String(describing: error))
                        original(self_, failPairingSel, pairingAgent, peer, error)
                        btPostPairingNotification(.easyBluetoothPairingFailed, peer: peer, extraUserInfo: ["error": String(describing: error)])
                        NSLog("[Swizzle] Pairing fail callback completed on main thread peer=%@", String(describing: peer))
                    }
                    NSLog("[Swizzle] Pairing fail callback main-thread dispatch returned peer=%@", String(describing: peer))
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
            NSLog("[Swizzle] Hooked CBDeviceCollectionView.pairingAgent:peerDidFailToCompletePairing:error: for main-thread UI")
        } else {
            NSLog("[Swizzle] Missing CBDeviceCollectionView.pairingAgent:peerDidFailToCompletePairing:error:; failure main-thread hook not installed")
        }

        let unpairSel = NSSelectorFromString("pairingAgent:peerDidUnpair:")
        if let method = class_getInstanceMethod(deviceCollectionClass, unpairSel) {
            let originalIMP = method_getImplementation(method)
            typealias UnpairFn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
            let original = unsafeBitCast(originalIMP, to: UnpairFn.self)
            let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { (self_, pairingAgent, peer) in
                if Thread.isMainThread {
                    NSLog("[Swizzle] Unpair callback already on main thread peer=%@", String(describing: peer))
                    original(self_, unpairSel, pairingAgent, peer)
                    btPostPairingNotification(.easyBluetoothPeerUnpaired, peer: peer)
                } else {
                    NSLog("[Swizzle] Unpair callback received off main thread; dispatching synchronously to main peer=%@ thread=%@", String(describing: peer), String(describing: Thread.current))
                    DispatchQueue.main.sync {
                        NSLog("[Swizzle] Unpair callback executing on main thread peer=%@", String(describing: peer))
                        original(self_, unpairSel, pairingAgent, peer)
                        btPostPairingNotification(.easyBluetoothPeerUnpaired, peer: peer)
                        NSLog("[Swizzle] Unpair callback completed on main thread peer=%@", String(describing: peer))
                    }
                    NSLog("[Swizzle] Unpair callback main-thread dispatch returned peer=%@", String(describing: peer))
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
            NSLog("[Swizzle] Hooked CBDeviceCollectionView.pairingAgent:peerDidUnpair: for main-thread UI")
        } else {
            NSLog("[Swizzle] Missing CBDeviceCollectionView.pairingAgent:peerDidUnpair:; unpair main-thread hook not installed")
        }

        let presentPairingSheetSel = NSSelectorFromString("presentModalSheetForPairingType:withPasskey:withPeer:")
        if let method = class_getInstanceMethod(deviceCollectionClass, presentPairingSheetSel) {
            let originalIMP = method_getImplementation(method)
            typealias PresentPairingSheetFn = @convention(c) (AnyObject, Selector, Int64, AnyObject?, AnyObject?) -> Void
            let original = unsafeBitCast(originalIMP, to: PresentPairingSheetFn.self)
            let block: @convention(block) (AnyObject, Int64, AnyObject?, AnyObject?) -> Void = { (self_, pairingType, passkey, peer) in
                if Thread.isMainThread {
                    NSLog("[Swizzle] Pairing sheet presentation already on main thread type=%lld passkey=%@", pairingType, String(describing: passkey))
                    original(self_, presentPairingSheetSel, pairingType, passkey, peer)
                } else {
                    NSLog("[Swizzle] Pairing sheet presentation received off main thread; dispatching synchronously to main type=%lld passkey=%@ thread=%@", pairingType, String(describing: passkey), String(describing: Thread.current))
                    DispatchQueue.main.sync {
                        NSLog("[Swizzle] Pairing sheet presentation executing on main thread type=%lld passkey=%@", pairingType, String(describing: passkey))
                        original(self_, presentPairingSheetSel, pairingType, passkey, peer)
                        NSLog("[Swizzle] Pairing sheet presentation completed on main thread type=%lld", pairingType)
                    }
                    NSLog("[Swizzle] Pairing sheet presentation main-thread dispatch returned type=%lld", pairingType)
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
            NSLog("[Swizzle] Hooked CBDeviceCollectionView.presentModalSheetForPairingType:withPasskey:withPeer: for main-thread UI")
        } else {
            NSLog("[Swizzle] Missing CBDeviceCollectionView.presentModalSheetForPairingType:withPasskey:withPeer:; pairing sheet main-thread hook not installed")
        }
    } else {
        NSLog("[Swizzle] Missing CBDeviceCollectionView class; pairing UI main-thread hooks not installed")
    }

    // === Swizzle 2: Add BT_deviceName property to CBUIBatteryControl ===
    // The NIB tries to connect an outlet "BT_deviceName" to CBUIBatteryControl but the property doesn't exist.
    // Add it dynamically so the NIB loading succeeds.
    if let batteryClass = NSClassFromString("CBUIBatteryControl") {
        let sel = NSSelectorFromString("setBT_deviceName:")
        if !class_respondsToSelector(batteryClass, sel) {
            // Add a stored property via associated objects
            var key = 0
            let setterBlock: @convention(block) (AnyObject, AnyObject?) -> Void = { (self_, value) in
                objc_setAssociatedObject(self_, &key, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                NSLog("[Swizzle] CBUIBatteryControl.BT_deviceName set to: %@", String(describing: value))
            }
            let setterIMP = imp_implementationWithBlock(setterBlock)
            class_addMethod(batteryClass, sel, setterIMP, "v@:@")

            let getterSel = NSSelectorFromString("BT_deviceName")
            if !class_respondsToSelector(batteryClass, getterSel) {
                let getterBlock: @convention(block) (AnyObject) -> AnyObject? = { (self_) in
                    return objc_getAssociatedObject(self_, &key) as AnyObject?
                }
                let getterIMP = imp_implementationWithBlock(getterBlock)
                class_addMethod(batteryClass, getterSel, getterIMP, "@@:")
            }
            NSLog("[Swizzle] Added BT_deviceName property to CBUIBatteryControl")
        }
    }

// === Swizzle 3: Singleton CBClassicManager — reuse the first working instance ===
// The first CBClassicManager (from our Prepare step) receives messages from bluetoothd.
// The selector creates a SECOND one that gets no messages.
// Solution: cache the first instance and return it for all subsequent inits.
if let classicMgrClass = NSClassFromString("CBClassicManager") {
    let initSel = NSSelectorFromString("initWithQueue:options:")
    if let method = class_getInstanceMethod(classicMgrClass, initSel) {
        let originalIMP = method_getImplementation(method)
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> AnyObject? = { (self_, queue, options) in
            if let cached = btCachedClassicManager() {
                return cached
            }
            let original = unsafeBitCast(originalIMP, to: (@convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> AnyObject?).self)
            let result = original(self_, initSel, queue, options)
            if let result = result {
                return btCacheClassicManagerIfEmpty(result)
            }
            return result
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        NSLog("[Swizzle] Hooked CBClassicManager.initWithQueue:options: for singleton")
    }
}

// Force _state and sendMsg bypass
if let cbManagerClass = NSClassFromString("CBManager"),
   let stateIvar = class_getInstanceVariable(cbManagerClass, "_state") {

    let stateOffset = ivar_getOffset(stateIvar)
    NSLog("[Swizzle] CBManager._state ivar offset: %d", stateOffset)

    // Hook sendMsg:args: to force _state=5 before each send for ClassicManager
    let sendMsgSel = NSSelectorFromString("sendMsg:args:")
    if let method = class_getInstanceMethod(cbManagerClass, sendMsgSel) {
        let originalIMP = method_getImplementation(method)
        let block: @convention(block) (AnyObject, Int, AnyObject?) -> Void = { (self_, msg, args) in
            let className = NSStringFromClass(type(of: self_ as AnyObject))
            if className.contains("ClassicManager") {
                // Force _state to 5 right before send
                let ptr = Unmanaged.passUnretained(self_ as AnyObject).toOpaque().advanced(by: stateOffset)
                ptr.storeBytes(of: 5, as: Int.self)
            }
            let original = unsafeBitCast(originalIMP, to: (@convention(c) (AnyObject, Selector, Int, AnyObject?) -> Void).self)
            original(self_, sendMsgSel, msg, args)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        NSLog("[Swizzle] Hooked CBManager.sendMsg:args: to force Classic _state=5")
    }

    // Also hook sendSyncMsg:args:
    let sendSyncSel = NSSelectorFromString("sendSyncMsg:args:")
    if let method = class_getInstanceMethod(cbManagerClass, sendSyncSel) {
        let originalIMP = method_getImplementation(method)
        let block: @convention(block) (AnyObject, Int, AnyObject?) -> AnyObject? = { (self_, msg, args) in
            let className = NSStringFromClass(type(of: self_ as AnyObject))
            if className.contains("ClassicManager") {
                let ptr = Unmanaged.passUnretained(self_ as AnyObject).toOpaque().advanced(by: stateOffset)
                ptr.storeBytes(of: 5, as: Int.self)
            }
            let original = unsafeBitCast(originalIMP, to: (@convention(c) (AnyObject, Selector, Int, AnyObject?) -> AnyObject?).self)
            return original(self_, sendSyncSel, msg, args)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        NSLog("[Swizzle] Hooked CBManager.sendSyncMsg:args: to force Classic _state=5")
    }

    // Also hook state getter for good measure
    let stateSel = NSSelectorFromString("state")
    if let method = class_getInstanceMethod(cbManagerClass, stateSel) {
        let originalIMP = method_getImplementation(method)
        let block: @convention(block) (AnyObject) -> Int = { (self_) in
            let className = NSStringFromClass(type(of: self_ as AnyObject))
            if className.contains("ClassicManager") { return 5 }
            let original = unsafeBitCast(originalIMP, to: (@convention(c) (AnyObject, Selector) -> Int).self)
            return original(self_, stateSel)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // isMsgAllowedWhenOff bypass
    if let classicMgrClass = NSClassFromString("CBClassicManager") {
        let sel = NSSelectorFromString("isMsgAllowedWhenOff:")
        if let method = class_getInstanceMethod(classicMgrClass, sel) {
            let block: @convention(block) (AnyObject, Int) -> Bool = { (_, _) in true }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }
}

// === Swizzle 3b: Log ALL messages received by CBClassicManager from bluetoothd ===
if let cbManagerClass = NSClassFromString("CBManager") {
    let handleMsgSel = NSSelectorFromString("handleMsg:args:")
    if let method = class_getInstanceMethod(cbManagerClass, handleMsgSel) {
        let originalIMP = method_getImplementation(method)
        let block: @convention(block) (AnyObject, Int, AnyObject?) -> Void = { (self_, msg, args) in
            let original = unsafeBitCast(originalIMP, to: (@convention(c) (AnyObject, Selector, Int, AnyObject?) -> Void).self)
            original(self_, handleMsgSel, msg, args)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}

// === Swizzle 4: Intercept CBXpcConnection init to log and fix sessionType ===
if let xpcConnClass = NSClassFromString("CBXpcConnection") {
    let sel = NSSelectorFromString("initWithDelegate:queue:options:sessionType:")
    if let method = class_getInstanceMethod(xpcConnClass, sel) {
        let originalIMP = method_getImplementation(method)
        typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, Int) -> AnyObject?
        let original = unsafeBitCast(originalIMP, to: InitFn.self)

        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?, Int) -> AnyObject? = { (self_, delegate, queue, options, sessionType) in
            NSLog("[Swizzle] CBXpcConnection.init sessionType=%d (delegate=%@)", sessionType, String(describing: type(of: delegate)))
            // Call original with the same sessionType
            let result = original(self_, sel, delegate, queue, options, sessionType)
            NSLog("[Swizzle] CBXpcConnection.init returned: %@", String(describing: result))
            return result
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        NSLog("[Swizzle] Hooked CBXpcConnection.initWithDelegate:queue:options:sessionType:")
    }
}

// === Swizzle 5: Intercept CBXpcConnection.connect to log and potentially fix ===
if let xpcConnClass = NSClassFromString("CBXpcConnection") {
    let connectSel = NSSelectorFromString("connect")
    if let method = class_getInstanceMethod(xpcConnClass, connectSel) {
        let originalIMP = method_getImplementation(method)
        let block: @convention(block) (AnyObject) -> Void = { (self_) in
            let obj = self_ as! NSObject
            // Read _sessionType ivar
            let sessionTypeIvar = class_getInstanceVariable(type(of: obj), "_sessionType")
            var sessionType: Int = -1
            if let ivar = sessionTypeIvar {
                let offset = ivar_getOffset(ivar)
                let ptr = Unmanaged.passUnretained(obj).toOpaque().advanced(by: offset)
                sessionType = ptr.load(as: Int.self)
            }
            NSLog("[Swizzle] CBXpcConnection.connect() sessionType=%d", sessionType)

            // Call original
            let original = unsafeBitCast(originalIMP, to: (@convention(c) (AnyObject, Selector) -> Void).self)
            original(self_, connectSel)

            // After connect, check the _xpcConnection
            let xpcConnIvar = class_getInstanceVariable(type(of: obj), "_xpcConnection")
            if let ivar = xpcConnIvar {
                let offset = ivar_getOffset(ivar)
                let ptr = Unmanaged.passUnretained(obj).toOpaque().advanced(by: offset)
                let xpcConn = ptr.load(as: UnsafeRawPointer?.self)
                NSLog("[Swizzle] CBXpcConnection.connect() _xpcConnection=%@", String(describing: xpcConn))
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        NSLog("[Swizzle] Hooked CBXpcConnection.connect")
    }

    // Also hook _checkIn to see the XPC message
    let checkInSel = NSSelectorFromString("_checkIn")
    if let method = class_getInstanceMethod(xpcConnClass, checkInSel) {
        let originalIMP = method_getImplementation(method)
        let block: @convention(block) (AnyObject) -> Void = { (self_) in
            NSLog("[Swizzle] CBXpcConnection._checkIn called")
            let original = unsafeBitCast(originalIMP, to: (@convention(c) (AnyObject, Selector) -> Void).self)
            original(self_, checkInSel)
            NSLog("[Swizzle] CBXpcConnection._checkIn completed")
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        NSLog("[Swizzle] Hooked CBXpcConnection._checkIn")
    }
}

// === Swizzle 6: Log arrangeObjects to see what's being filtered ===
if let sortedArrayClass = NSClassFromString("IOBluetoothUISortedArrayController") {
    let sel = NSSelectorFromString("arrangeObjects:")
    if let originalMethod = class_getInstanceMethod(sortedArrayClass, sel) {
        let originalIMP = method_getImplementation(originalMethod)
        let swizzledBlock: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { (self_, objects) in
            if let arr = objects as? NSArray {
                NSLog("[Swizzle] arrangeObjects called with %d objects", arr.count)
                for (i, obj) in arr.enumerated() {
                    NSLog("[Swizzle]   [%d] %@ - %@", i, String(describing: type(of: obj)), String(describing: obj))
                }
            }
            let original = unsafeBitCast(originalIMP, to: (@convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?).self)
            let result = original(self_, sel, objects)
            if let resultArr = result as? NSArray {
                NSLog("[Swizzle] arrangeObjects returned %d objects", resultArr.count)
            }
            return result
        }
        method_setImplementation(originalMethod, imp_implementationWithBlock(swizzledBlock))
        NSLog("[Swizzle] Hooked arrangeObjects: on IOBluetoothUISortedArrayController")
    }
}

// === Swizzle 7: Route IOBluetoothDevice.openConnection through the coordinator's peer XPC ===
// KeyPad's log shows: openConnection → IOBluetoothCoreBluetoothCoordinator.connectPeer → CBClassicManager.connectPeer
// This goes through the PEER XPC connection and SUCCEEDS.
// Our openConnection goes through the MACH XPC connection and TIMES OUT.
// Swizzle openConnection to use the coordinator's connectPeer instead.
if let deviceClass = IOBluetoothDevice.self as? AnyClass {
    let openConnSel = NSSelectorFromString("openConnection")
    if let method = class_getInstanceMethod(deviceClass, openConnSel) {
        let originalIMP = method_getImplementation(method)
        let block: @convention(block) (AnyObject) -> Int32 = { (self_) in
            let device = self_ as! IOBluetoothDevice
            NSLog("[Swizzle] openConnection intercepted for %@", device.name ?? "?")

            let swizzleLogger: BTDiagnosticLogger = { message in
                NSLog("[Swizzle] %@", message)
            }

            if btConnectDeviceViaClassicPeer(device, log: swizzleLogger) {
                NSLog("[Swizzle] Peer-backed openConnection path succeeded")
                return 0
            }

            NSLog("[Swizzle] Falling back to original openConnection")
            let original = unsafeBitCast(originalIMP, to: (@convention(c) (AnyObject, Selector) -> Int32).self)
            return original(self_, openConnSel)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        NSLog("[Swizzle] Hooked IOBluetoothDevice.openConnection to use peer XPC")
    }
}

// === Swizzle 8: Inject CBClassicPeer into L2CAPChannel init ===
// The channel's initWithDevice:andClassicPeer:PSM: gets called with nil classicPeer
// because the IOBluetooth framework doesn't find it through the mach XPC path.
// We inject it from the coordinator.
if let channelClass = IOBluetoothL2CAPChannel.self as? AnyClass {
    let initSel = NSSelectorFromString("_initWithDevice:andClassicPeer:PSM:withServiceUUID:")
    if let method = class_getInstanceMethod(channelClass, initSel) {
        let originalIMP = method_getImplementation(method)
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?, BluetoothL2CAPPSM, AnyObject?) -> AnyObject? = {
            (self_, device, classicPeer, psm, serviceUUID) in

            var peer = classicPeer
            if peer == nil, let device = device as? IOBluetoothDevice {
                let swizzleLogger: BTDiagnosticLogger = { message in
                    NSLog("[Swizzle] %@", message)
                }

                if let coordinator = btClassicCoordinator(log: swizzleLogger),
                   let resolvedPeer = btResolveClassicPeer(for: device, coordinator: coordinator, log: swizzleLogger) {
                    peer = resolvedPeer
                    NSLog("[Swizzle] L2CAPChannel._init: injected peer for PSM:%d", psm)
                }
            }

            let original = unsafeBitCast(originalIMP, to: (@convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, BluetoothL2CAPPSM, AnyObject?) -> AnyObject?).self)
            return original(self_, initSel, device, peer, psm, serviceUUID)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        NSLog("[Swizzle] Hooked L2CAPChannel._initWithDevice:andClassicPeer:PSM:withServiceUUID:")
    }
}

// Also swizzle the non-underscore version
if let channelClass2 = IOBluetoothL2CAPChannel.self as? AnyClass {
    let initSel2 = NSSelectorFromString("initWithDevice:andClassicPeer:PSM:")
    if let method2 = class_getInstanceMethod(channelClass2, initSel2) {
        let originalIMP2 = method_getImplementation(method2)
        let block2: @convention(block) (AnyObject, AnyObject?, AnyObject?, BluetoothL2CAPPSM) -> AnyObject? = {
            (self_, device, classicPeer, psm) in

            var peer = classicPeer
            NSLog("[Swizzle] L2CAPChannel.initWithDevice:andClassicPeer:PSM:%d peer=%@", psm, String(describing: peer))

            if peer == nil, let device = device as? IOBluetoothDevice {
                let swizzleLogger: BTDiagnosticLogger = { message in
                    NSLog("[Swizzle] %@", message)
                }

                if let coordinator = btClassicCoordinator(log: swizzleLogger),
                   let resolvedPeer = btResolveClassicPeer(for: device, coordinator: coordinator, log: swizzleLogger) {
                    peer = resolvedPeer
                    NSLog("[Swizzle] INJECTED peer for L2CAPChannel PSM:%d!", psm)
                }
            }

            // Call the original initWithDevice:andClassicPeer:PSM:
            let original = unsafeBitCast(originalIMP2, to: (@convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, BluetoothL2CAPPSM) -> AnyObject?).self)
            let result = original(self_, initSel2, device, peer, psm)

            // The original init does NOT call _initWithDevice:andClassicPeer:PSM:withServiceUUID:
            // We must call it manually to set up the cbChannel and kernel IOService
            if let channel = result {
                let underscoreInitSel = NSSelectorFromString("_initWithDevice:andClassicPeer:PSM:withServiceUUID:")
                if channel.responds(to: underscoreInitSel) {
                    NSLog("[Swizzle] Manually calling _initWithDevice:andClassicPeer:PSM:%d:withServiceUUID:nil", psm)
                    typealias UnderscoreInitFn = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, BluetoothL2CAPPSM, AnyObject?) -> AnyObject?
                    let underscoreInitIMP = class_getMethodImplementation(type(of: channel), underscoreInitSel)!
                    let underscoreInit = unsafeBitCast(underscoreInitIMP, to: UnderscoreInitFn.self)
                    let _ = underscoreInit(channel, underscoreInitSel, device, peer, psm, nil)
                    NSLog("[Swizzle] _init called successfully for PSM:%d", psm)
                }
            }
            return result
        }
        method_setImplementation(method2, imp_implementationWithBlock(block2))
        NSLog("[Swizzle] Hooked L2CAPChannel.initWithDevice:andClassicPeer:PSM:")
    }
}

// === Swizzle 9: Route L2CAP sync open through async open on a live run loop ===
// The original sync implementation blocks waiting for open-complete, but the
// ClassicManager response can arrive only after the async callback path runs.
// We preserve the existing sync call sites by bridging them through the async
// API on a dedicated run-loop thread and then waiting with explicit logging.
if let deviceClass = IOBluetoothDevice.self as? AnyClass {
    let syncSel = NSSelectorFromString("openL2CAPChannelSync:withPSM:delegate:")
    let asyncSel = NSSelectorFromString("openL2CAPChannelAsync:withPSM:delegate:")
    if let syncMethod = class_getInstanceMethod(deviceClass, syncSel),
       let asyncMethod = class_getInstanceMethod(deviceClass, asyncSel) {
        let asyncIMP = method_getImplementation(asyncMethod)
        let block: @convention(block) (AnyObject, UnsafeMutablePointer<AnyObject?>, BluetoothL2CAPPSM, AnyObject?) -> IOReturn = {
            (self_, channelPtr, psm, delegate) in

            let device = self_ as! IOBluetoothDevice
            NSLog("[Swizzle] openL2CAPChannelSync:withPSM:delegate: intercepted for %@ PSM:%d delegate=%@", device.name ?? "?", psm, String(describing: delegate))

            return btOpenL2CAPChannelSyncViaAsync(
                device: device,
                channelPtr: channelPtr,
                psm: psm,
                channelConfiguration: nil,
                requestedDelegate: delegate
            ) { context in
                var provisionalChannel: AnyObject?
                let originalAsync = unsafeBitCast(asyncIMP, to: BTL2CAPAsyncOpenNoConfigFn.self)
                let startStatus = originalAsync(self_, asyncSel, &provisionalChannel, psm, context)
                context.recordAsyncStart(status: startStatus, provisionalChannel: provisionalChannel as? IOBluetoothL2CAPChannel)
            }
        }
        method_setImplementation(syncMethod, imp_implementationWithBlock(block))
        NSLog("[Swizzle] Hooked openL2CAPChannelSync:withPSM:delegate: to async-backed wait")
    } else {
        NSLog("[Swizzle] Failed to hook openL2CAPChannelSync:withPSM:delegate: because sync or async selector is missing")
    }

    let syncWithConfigSel = NSSelectorFromString("openL2CAPChannelSync:withPSM:withConfiguration:delegate:")
    let asyncWithConfigSel = NSSelectorFromString("openL2CAPChannelAsync:withPSM:withConfiguration:delegate:")
    if let syncWithConfigMethod = class_getInstanceMethod(deviceClass, syncWithConfigSel),
       let asyncWithConfigMethod = class_getInstanceMethod(deviceClass, asyncWithConfigSel) {
        let asyncWithConfigIMP = method_getImplementation(asyncWithConfigMethod)
        let block: @convention(block) (AnyObject, UnsafeMutablePointer<AnyObject?>, BluetoothL2CAPPSM, AnyObject?, AnyObject?) -> IOReturn = {
            (self_, channelPtr, psm, config, delegate) in

            let device = self_ as! IOBluetoothDevice
            NSLog(
                "[Swizzle] openL2CAPChannelSync:withPSM:withConfiguration:delegate: intercepted for %@ PSM:%d config=%@ delegate=%@",
                device.name ?? "?",
                psm,
                String(describing: config),
                String(describing: delegate)
            )

            return btOpenL2CAPChannelSyncViaAsync(
                device: device,
                channelPtr: channelPtr,
                psm: psm,
                channelConfiguration: config as? NSDictionary,
                requestedDelegate: delegate
            ) { context in
                var provisionalChannel: AnyObject?
                let originalAsync = unsafeBitCast(asyncWithConfigIMP, to: BTL2CAPAsyncOpenWithConfigFn.self)
                let startStatus = originalAsync(self_, asyncWithConfigSel, &provisionalChannel, psm, config, context)
                context.recordAsyncStart(status: startStatus, provisionalChannel: provisionalChannel as? IOBluetoothL2CAPChannel)
            }
        }
        method_setImplementation(syncWithConfigMethod, imp_implementationWithBlock(block))
        NSLog("[Swizzle] Hooked openL2CAPChannelSync:withPSM:withConfiguration:delegate: to async-backed wait")
    } else {
        NSLog("[Swizzle] Failed to hook openL2CAPChannelSync:withPSM:withConfiguration:delegate: because sync or async selector is missing")
    }
}
}
