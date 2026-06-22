import AppKit
import QuartzCore

class InputOverlayNSView: NSView {
    var onTap: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint, CGPoint, TimeInterval) -> Void)?
    var onScroll: ((CGPoint, CGFloat, CGFloat) -> Void)?
    var onKeyDown: ((String) -> Void)?
    var onKeyCommand: ((String) -> Void)?
    var onPinch: ((CGPoint, CGFloat) -> Void)?

    private var dragPoints: [CGPoint] = []
    private var dragStartTime: Date?
    private var isPinchDrag = false

    // Scroll accumulation
    private var scrollAccumulator = CGPoint.zero
    private var scrollOrigin: CGPoint?
    private var scrollTimer: Timer?

    // Tap indicator
    private var tapIndicatorLayer: CALayer?
    private var dragTrailLayer: CAShapeLayer?

    override var acceptsFirstResponder: Bool { true }
    override var wantsLayer: Bool { get { true } set {} }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let flipped = flippedPoint(event)
        isPinchDrag = event.modifierFlags.contains(.option)
        dragPoints = [flipped]
        dragStartTime = Date()
        showPressIndicator(at: flipped)
    }

    override func mouseDragged(with event: NSEvent) {
        let flipped = flippedPoint(event)

        // Downsample: only record if moved enough from last point
        if let last = dragPoints.last {
            let dist = hypot(flipped.x - last.x, flipped.y - last.y)
            if dist < 3 { return }
        }

        dragPoints.append(flipped)
        updateDragTrail()
        movePressIndicator(to: flipped)
    }

    override func mouseUp(with event: NSEvent) {
        let flipped = flippedPoint(event)
        guard let startTime = dragStartTime else { return }
        let duration = Date().timeIntervalSince(startTime)

        // Ensure the final point is included
        if let last = dragPoints.last, hypot(flipped.x - last.x, flipped.y - last.y) > 1 {
            dragPoints.append(flipped)
        }

        let start = dragPoints[0]
        let distance = hypot(flipped.x - start.x, flipped.y - start.y)

        if isPinchDrag && distance > 5 {
            let scale = CGFloat(distance / 50.0)
            onPinch?(start, scale)
        } else if distance < 5 {
            showTapRipple(at: flipped)
            onTap?(flipped)
        } else {
            onDrag?(start, flipped, duration)
        }

        hidePressIndicator()
        hideDragTrail()

        dragPoints = []
        dragStartTime = nil
        isPinchDrag = false
    }

    // MARK: - Scroll (with accumulation)

    override func scrollWheel(with event: NSEvent) {
        let flipped = flippedPoint(event)

        // Set or update scroll origin
        if scrollOrigin == nil {
            scrollOrigin = flipped
        }
        scrollAccumulator.x += event.scrollingDeltaX
        scrollAccumulator.y += event.scrollingDeltaY

        // Reset the debounce timer
        scrollTimer?.invalidate()
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            self?.flushScroll()
        }
    }

    private func flushScroll() {
        guard let origin = scrollOrigin else { return }
        let dx = scrollAccumulator.x
        let dy = scrollAccumulator.y
        if abs(dx) > 1 || abs(dy) > 1 {
            onScroll?(origin, dx, dy)
        }
        scrollAccumulator = .zero
        scrollOrigin = nil
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modPrefix = Self.modifierPrefix(mods)

        switch event.keyCode {
        case 123: onKeyDown?("\(modPrefix)ARROW_LEFT"); return
        case 124: onKeyDown?("\(modPrefix)ARROW_RIGHT"); return
        case 126: onKeyDown?("\(modPrefix)ARROW_UP"); return
        case 125: onKeyDown?("\(modPrefix)ARROW_DOWN"); return
        default: break
        }

        if let chars = event.characters {
            onKeyDown?(chars)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains([.command, .shift]) && event.characters == "h" {
            onKeyCommand?("home")
            return true
        }
        // Cmd+key shortcuts
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers {
            switch chars {
            case "a", "c", "x", "v", "z":
                onKeyDown?("CMD_\(chars.uppercased())")
                return true
            default:
                break
            }
        }
        // Cmd+Arrow and Option+Arrow (performKeyEquivalent intercepts these)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.option) {
            let modPrefix = Self.modifierPrefix(mods)
            switch event.keyCode {
            case 123: onKeyDown?("\(modPrefix)ARROW_LEFT"); return true
            case 124: onKeyDown?("\(modPrefix)ARROW_RIGHT"); return true
            case 126: onKeyDown?("\(modPrefix)ARROW_UP"); return true
            case 125: onKeyDown?("\(modPrefix)ARROW_DOWN"); return true
            default: break
            }
        }
        return false
    }

    private static func modifierPrefix(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.shift) { parts.append("SHIFT") }
        if flags.contains(.option) { parts.append("OPT") }
        if flags.contains(.command) { parts.append("CMD") }
        if parts.isEmpty { return "" }
        return parts.joined(separator: "_") + "_"
    }

    // MARK: - Helpers

    private func flippedPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    // Note: visual indicators use non-flipped coordinates (origin bottom-left)
    private func displayPoint(_ flipped: CGPoint) -> CGPoint {
        CGPoint(x: flipped.x, y: bounds.height - flipped.y)
    }

    // MARK: - Visual Feedback

    private func showPressIndicator(at flipped: CGPoint) {
        let pt = displayPoint(flipped)
        let size: CGFloat = 24
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        dot.position = pt
        dot.cornerRadius = size / 2
        dot.backgroundColor = NSColor.white.withAlphaComponent(0.4).cgColor
        dot.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        dot.borderWidth = 1.5
        layer?.addSublayer(dot)
        tapIndicatorLayer = dot
    }

    private func movePressIndicator(to flipped: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tapIndicatorLayer?.position = displayPoint(flipped)
        CATransaction.commit()
    }

    private func hidePressIndicator() {
        tapIndicatorLayer?.removeFromSuperlayer()
        tapIndicatorLayer = nil
    }

    private func showTapRipple(at flipped: CGPoint) {
        let pt = displayPoint(flipped)
        let ripple = CALayer()
        let size: CGFloat = 30
        ripple.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        ripple.position = pt
        ripple.cornerRadius = size / 2
        ripple.backgroundColor = NSColor.clear.cgColor
        ripple.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
        ripple.borderWidth = 2
        layer?.addSublayer(ripple)

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = 2.5

        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 1.0
        opacityAnim.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, opacityAnim]
        group.duration = 0.35
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards

        CATransaction.begin()
        CATransaction.setCompletionBlock { ripple.removeFromSuperlayer() }
        ripple.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    private func updateDragTrail() {
        guard dragPoints.count >= 2 else { return }

        let trail: CAShapeLayer
        if let existing = dragTrailLayer {
            trail = existing
        } else {
            trail = CAShapeLayer()
            trail.fillColor = nil
            trail.strokeColor = NSColor.white.withAlphaComponent(0.4).cgColor
            trail.lineWidth = 2
            trail.lineCap = .round
            trail.lineJoin = .round
            layer?.addSublayer(trail)
            dragTrailLayer = trail
        }

        let path = CGMutablePath()
        let first = displayPoint(dragPoints[0])
        path.move(to: first)
        for pt in dragPoints.dropFirst() {
            path.addLine(to: displayPoint(pt))
        }
        trail.path = path
    }

    private func hideDragTrail() {
        dragTrailLayer?.removeFromSuperlayer()
        dragTrailLayer = nil
    }
}
