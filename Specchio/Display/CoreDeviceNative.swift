// CoreDevice native decoder and input surface, validated by the feasibility viewer.
import AppKit
import SwiftUI
import CoreImage
import VideoToolbox
import ObjectiveC

/// Scope keyboard eligibility to a stream window without changing its class.
/// SwiftUI's window is a Swift class: object_setClass to an ObjC-created subclass
/// corrupts Swift dynamic casts (including NSApplication.windows) and AppKit state.
final class CoreDeviceKeyboardWindowLease {
    private static var leaseKey: UInt8 = 0
    private weak var window: NSWindow?

    // Hook the Objective-C base implementation once. Unleased windows retain
    // exactly their original behavior; the concrete SwiftUI class is untouched.
    private static let installKeyEligibility: Bool = {
        guard let method = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.canBecomeKey)) else {
            coreDeviceDiagnostic("keyboard eligibility unavailable: missing NSWindow getter")
            return false
        }
        typealias Getter = @convention(c) (NSWindow, Selector) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let getter: @convention(block) (NSWindow) -> Bool = { window in
            if (objc_getAssociatedObject(window, &leaseKey) as? NSNumber)?.intValue ?? 0 > 0 {
                return true
            }
            return original(window, #selector(getter: NSWindow.canBecomeKey))
        }
        method_setImplementation(method, imp_implementationWithBlock(getter))
        coreDeviceDiagnostic("keyboard eligibility installed: NSWindow getter, concrete window classes preserved")
        return true
    }()

    init?(window: NSWindow) {
        precondition(Thread.isMainThread)
        let existing = (objc_getAssociatedObject(window, &Self.leaseKey) as? NSNumber)?.intValue ?? 0
        guard existing > 0 || !window.canBecomeKey else {
            coreDeviceDiagnostic("keyboard eligibility unchanged: window already accepts keys")
            return nil
        }
        guard Self.installKeyEligibility else { return nil }
        objc_setAssociatedObject(window, &Self.leaseKey, NSNumber(value: existing + 1), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        guard window.canBecomeKey else {
            objc_setAssociatedObject(window, &Self.leaseKey, NSNumber(value: existing), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            coreDeviceDiagnostic("keyboard eligibility rejected by window override")
            return nil
        }
        self.window = window
        coreDeviceDiagnostic("keyboard eligibility acquired window=\(window.windowNumber) class=\(NSStringFromClass(type(of: window))) leases=\(existing + 1)")
    }

    deinit {
        precondition(Thread.isMainThread)
        guard let window else { return }
        let count = (objc_getAssociatedObject(window, &Self.leaseKey) as? NSNumber)?.intValue ?? 0
        objc_setAssociatedObject(window, &Self.leaseKey, NSNumber(value: max(0, count - 1)), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        coreDeviceDiagnostic("keyboard eligibility released window=\(window.windowNumber) leases=\(max(0, count - 1))")
    }
}

private func coreDeviceDiagnostic(_ text: String) {
    SpecchioLogger.easyMode.info("[CoreDevice] \(text, privacy: .public)")
}

final class CoreDeviceHEVCDecoder {
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onError: ((OSStatus) -> Void)?

    func close() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
    }

    deinit { close() }

    func consume(_ body: Data) throws {
        let payload = Data(body.dropFirst())
        switch body.first {
        case 1:
            guard let config = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let encoded = config["parameter_sets"] as? [String] else { throw NSError(domain:"CoreDeviceConfig",code:1) }
            try configure(encoded.compactMap { Data(base64Encoded: $0) })
        case 2: try decode(payload)
        case 3:
            if let status = String(data: payload, encoding: .utf8) { coreDeviceDiagnostic(status) }
        default: throw NSError(domain: "CoreDevicePacketKind", code: Int(body.first ?? 0))
        }
    }

    func configure(_ sets: [Data]) throws {
        close()
        guard sets.count == 3, sets.allSatisfy({ !$0.isEmpty }) else { throw NSError(domain: "HEVCParameters", code: -1) }
        let buffers = sets.map { data -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: p, count: data.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        var pointers = buffers.map { UnsafePointer($0) }
        var sizes = sets.map(\.count)
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
            parameterSetCount: 3, parameterSetPointers: &pointers, parameterSetSizes: &sizes,
            nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw NSError(domain: "HEVCFormat", code: Int(status)) }
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, _, status, _, image, _, _ in
            guard let ref else { return }
            let owner = Unmanaged<CoreDeviceHEVCDecoder>.fromOpaque(ref).takeUnretainedValue()
            if status == noErr, let image { owner.onFrame?(image) }
            else { owner.onError?(status) }
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        let result = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &session)
        guard result == noErr, let session else { throw NSError(domain: "HEVCSession", code: Int(result)) }
        let hardware = UnsafeMutablePointer<CFTypeRef?>.allocate(capacity: 1)
        hardware.initialize(to: nil)
        defer { hardware.deinitialize(count: 1); hardware.deallocate() }
        VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                              allocator: nil, valueOut: hardware)
        coreDeviceDiagnostic("decoder configured hardware=\(String(describing: hardware.pointee))")
    }

    func decode(_ annexB: Data) throws {
        guard let format, let session else { throw NSError(domain: "HEVCUnconfigured", code: -1) }
        // The pinned RTP adapter emits a four-byte Annex B prefix for every NAL.
        let bytes = [UInt8](annexB)
        var starts: [Int] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0 && bytes[index+1] == 0 && bytes[index+2] == 0 && bytes[index+3] == 1 {
                starts.append(index); index += 4
            } else { index += 1 }
        }
        var coded = Data()
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n+1] : bytes.count
            guard end > start + 4 else { continue }
            let nal = bytes[(start+4)..<end]
            let type = (nal.first! >> 1) & 63
            if [32, 33, 34].contains(type) { continue }
            var size = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &size) { coded.append(contentsOf: $0) }
            coded.append(contentsOf: nal)
        }
        guard !coded.isEmpty else { return }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: coded.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: coded.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw NSError(domain: "HEVCBlock", code: Int(status)) }
        status = coded.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                       offsetIntoDestination: 0, dataLength: coded.count) }
        guard status == noErr else { throw NSError(domain: "HEVCCopy", code: Int(status)) }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var size = coded.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw NSError(domain: "HEVCSample", code: Int(status)) }
        status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        guard status == noErr else { throw NSError(domain: "HEVCDecode", code: Int(status)) }
    }
}

final class CoreDevicePhoneView: NSView {
    private var keyboardWindowLease: CoreDeviceKeyboardWindowLease?
    private var keyMonitor: Any?
    private var focusObservers: [NSObjectProtocol] = []
    var image: CGImage? { didSet { needsDisplay = true } }
    var send: (([String: Any]) -> Void)?
    var keys = Set<Int>()
    var rotationDegrees = 0
    var contact = false
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeEventMonitoring()
        guard let window else { coreDeviceDiagnostic("input surface detached"); return }
        keyboardWindowLease = CoreDeviceKeyboardWindowLease(window: window)
        coreDeviceDiagnostic("input surface attached window=\(window.windowNumber) key=\(window.isKeyWindow)")
        // Match the existing Bluetooth keyboard scope: only this phone window,
        // never a native text editor or another app window. SwiftUI hosting can
        // retain first-responder ownership, so do not rely on keyDown dispatch.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, let host = self.window else { return event }
            guard host.isKeyWindow, event.window === host, self.image != nil else {
                coreDeviceDiagnostic("keyboard skipped key=\(host.isKeyWindow) canBecomeKey=\(host.canBecomeKey) matchingWindow=\(event.window === host) image=\(self.image != nil)")
                return event
            }
            guard !(host.firstResponder is NSTextView) else {
                coreDeviceDiagnostic("keyboard passed to native text editor")
                return event
            }
            coreDeviceDiagnostic("keyboard captured type=\(event.type.rawValue) responder=\(String(describing: type(of: host.firstResponder)))")
            switch event.type {
            case .keyDown: self.keyDown(with: event)
            case .keyUp: self.keyUp(with: event)
            case .flagsChanged: self.flagsChanged(with: event)
            default: return event
            }
            return nil
        }
        for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject),
                               (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                self?.release()
                coreDeviceDiagnostic("keyboard released on focus loss")
            })
        }
        if window.isKeyWindow && !(window.firstResponder is NSTextView) {
            coreDeviceDiagnostic("initial input focus accepted=\(window.makeFirstResponder(self))")
        }
    }
    func removeEventMonitoring() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        focusObservers.forEach(NotificationCenter.default.removeObserver)
        focusObservers.removeAll()
        release()
        keyboardWindowLease = nil
    }
    deinit { removeEventMonitoring() }
    var imageRect: NSRect {
        guard let image else { return .zero }
        let sideways = [90, 270].contains(InputSurfaceRotationMapping.normalizedRotation(rotationDegrees))
        let width = CGFloat(sideways ? image.height : image.width)
        let height = CGFloat(sideways ? image.width : image.height)
        let scale = min(bounds.width / width, bounds.height / height)
        let size = NSSize(width: width * scale, height: height * scale)
        return NSRect(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {} // The existing SwiftUI phone surface owns rendering.
    func touch(_ event: NSEvent, down: Bool) {
        guard image != nil else { coreDeviceDiagnostic("input ignored: no image"); return }
        let p = convert(event.locationInWindow, from: nil)
        let r = imageRect
        guard contact || r.contains(p) else { coreDeviceDiagnostic("input ignored: outside image"); return }
        contact = down
        let point = InputSurfaceRotationMapping.phoneNormalizedPoint(
            displayX: min(1, max(0, (p.x-r.minX)/r.width)),
            displayY: min(1, max(0, (p.y-r.minY)/r.height)), rotationDegrees: rotationDegrees)
        send?(["command": "touch", "down": down, "x": point.x, "y": point.y])
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        coreDeviceDiagnostic("pointer focus accepted=\(window?.makeFirstResponder(self) ?? false) key=\(window?.isKeyWindow ?? false) canBecomeKey=\(window?.canBecomeKey ?? false)")
        touch(event, down: true)
    }
    override func mouseDragged(with event: NSEvent) { if contact { touch(event, down: true) } }
    override func mouseUp(with event: NSEvent) { if contact { touch(event, down: false) } }
    override func resignFirstResponder() -> Bool { release(); return super.resignFirstResponder() }
    func release() { keys.removeAll(); contact = false; send?(["command": "release"]) }
    // Same ANSI virtual-key to USB HID mapping used by Specchio's Bluetooth controller.
    static let keyMap: [UInt16: Int] = [0:4,11:5,8:6,2:7,14:8,3:9,5:10,4:11,34:12,38:13,40:14,37:15,
        46:16,45:17,31:18,35:19,12:20,15:21,1:22,17:23,32:24,9:25,13:26,7:27,16:28,6:29,
        18:30,19:31,20:32,21:33,23:34,22:35,26:36,28:37,25:38,29:39,36:40,53:41,51:42,48:43,49:44,
        27:45,24:46,33:47,30:48,42:49,41:51,39:52,50:53,43:54,47:55,44:56,124:79,123:80,125:81,126:82]
    func report(_ flags: NSEvent.ModifierFlags) {
        var usages = keys
        for (flag, usage): (NSEvent.ModifierFlags, Int) in [(.control,224),(.shift,225),(.option,226),(.command,227)] {
            if flags.contains(flag) { usages.insert(usage) }
        }
        send?(["command": "keys", "usages": Array(usages).sorted()])
    }
    override func keyDown(with event: NSEvent) {
        guard let usage = Self.keyMap[event.keyCode] else { coreDeviceDiagnostic("unmapped key"); return }
        keys.insert(usage); report(event.modifierFlags)
    }
    override func keyUp(with event: NSEvent) {
        guard let usage = Self.keyMap[event.keyCode] else { return }
        keys.remove(usage); report(event.modifierFlags)
    }
    override func flagsChanged(with event: NSEvent) { report(event.modifierFlags) }
}


struct CoreDeviceInputSurface: NSViewRepresentable {
    let image: CGImage
    let rotationDegrees: Int
    let send: ([String: Any]) -> Void
    func makeNSView(context: Context) -> CoreDevicePhoneView {
        let view = CoreDevicePhoneView()
        view.send = send
        return view
    }
    func updateNSView(_ view: CoreDevicePhoneView, context: Context) {
        view.image = image
        if view.rotationDegrees != rotationDegrees { view.release() }
        view.rotationDegrees = rotationDegrees
        view.send = send
    }
    static func dismantleNSView(_ view: CoreDevicePhoneView, coordinator: ()) {
        view.removeEventMonitoring()
        view.send = nil
    }
}
