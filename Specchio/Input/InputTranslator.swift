import Foundation
import os.log

private let log = Logger(subsystem: "com.specchio", category: "InputTranslator")

class InputTranslator {
    let wdaClient: WDAClient
    let coordinateMapper: CoordinateMapper
    let inputSocket: WDAInputSocket?
    let keyboardExtSocket: KeyboardExtSocket?
    private var loggedWSPath = false
    private var loggedKBPath = false

    init(wdaClient: WDAClient, coordinateMapper: CoordinateMapper, inputSocket: WDAInputSocket? = nil, keyboardExtSocket: KeyboardExtSocket? = nil) {
        self.wdaClient = wdaClient
        self.coordinateMapper = coordinateMapper
        self.inputSocket = inputSocket
        self.keyboardExtSocket = keyboardExtSocket
    }

    private var useSocket: Bool {
        guard let socket = inputSocket, socket.isConnected else { return false }
        if !loggedWSPath {
            log.info("Input routed via WebSocket")
            loggedWSPath = true
        }
        return true
    }

    private var useKeyboardExt: Bool {
        guard let socket = keyboardExtSocket, socket.isConnected else { return false }
        if !loggedKBPath {
            log.info("Text input routed via keyboard extension (~5ms path)")
            loggedKBPath = true
        }
        return true
    }

    func handleTap(viewPoint: CGPoint) async {
        guard let phonePoint = coordinateMapper.viewToPhone(viewPoint) else { return }
        if useSocket {
            inputSocket!.sendTap(x: phonePoint.x, y: phonePoint.y)
        } else {
            try? await wdaClient.tap(x: phonePoint.x, y: phonePoint.y)
        }
    }

    func handleDrag(from: CGPoint, to: CGPoint, duration: TimeInterval) async {
        guard let phoneFrom = coordinateMapper.viewToPhone(from),
              let phoneTo = coordinateMapper.viewToPhone(to) else { return }
        let durationMs = Int(max(duration * 1000, 100))
        if useSocket {
            inputSocket!.sendSwipe(
                fromX: phoneFrom.x, fromY: phoneFrom.y,
                toX: phoneTo.x, toY: phoneTo.y,
                duration: durationMs
            )
        } else {
            try? await wdaClient.swipe(
                fromX: phoneFrom.x, fromY: phoneFrom.y,
                toX: phoneTo.x, toY: phoneTo.y,
                duration: durationMs
            )
        }
    }

    func handleScroll(at viewPoint: CGPoint, deltaX: CGFloat, deltaY: CGFloat) async {
        guard let phonePoint = coordinateMapper.viewToPhone(viewPoint) else { return }
        let amplifiedY = deltaY * 8
        if useSocket {
            inputSocket!.sendSwipe(
                fromX: phonePoint.x, fromY: phonePoint.y,
                toX: phonePoint.x, toY: phonePoint.y + Double(amplifiedY),
                duration: 200
            )
        } else {
            try? await wdaClient.swipe(
                fromX: phonePoint.x, fromY: phonePoint.y,
                toX: phonePoint.x, toY: phonePoint.y + Double(amplifiedY),
                duration: 200
            )
        }
    }

    func handleKeyInput(_ text: String) async {
        // Cmd+key shortcuts (sent as "CMD_A", "CMD_C", etc.) — but not CMD_ARROW_*
        if text.hasPrefix("CMD_") && !text.contains("ARROW") {
            let key = String(text.dropFirst(4)).lowercased()
            await handleCmdShortcut(key)
            return
        }

        // Arrow keys with optional modifiers (e.g. "ARROW_LEFT", "SHIFT_ARROW_RIGHT", "CMD_OPT_ARROW_UP")
        if text.contains("ARROW_") {
            await handleArrowKey(text)
            return
        }

        if useKeyboardExt {
            // Route delete/backspace to deleteBackward() instead of insertText()
            if text == "\u{7F}" || text == "\u{08}" {
                keyboardExtSocket!.sendDelete()
            } else {
                keyboardExtSocket!.sendText(text)
            }
        } else if useSocket {
            inputSocket!.sendKeys(text)
        } else {
            try? await wdaClient.typeText(text)
        }
    }

    /// Routes arrow keys (with optional Shift/Option/Command modifiers) via WDA typeKey.
    private func handleArrowKey(_ text: String) async {
        // Parse modifier flags from prefix
        var modifierFlags = 0
        if text.contains("SHIFT") { modifierFlags |= 2 }   // XCUIKeyModifierShift
        if text.contains("OPT")   { modifierFlags |= 8 }   // XCUIKeyModifierOption
        if text.contains("CMD")   { modifierFlags |= 16 }  // XCUIKeyModifierCommand

        // Parse arrow direction from suffix
        let direction: String
        if text.hasSuffix("ARROW_LEFT")       { direction = "Left" }
        else if text.hasSuffix("ARROW_RIGHT") { direction = "Right" }
        else if text.hasSuffix("ARROW_UP")    { direction = "Up" }
        else if text.hasSuffix("ARROW_DOWN")  { direction = "Down" }
        else { return }

        let keyName = "XCUIKeyboardKey\(direction)Arrow"
        log.info("Arrow key: \(keyName) mod=\(modifierFlags)")

        if useSocket {
            inputSocket!.sendTypeKey(keyName, modifierFlags: modifierFlags)
        } else {
            try? await wdaClient.typeKeyWithModifiers(key: keyName, modifierFlags: modifierFlags)
        }
    }

    /// Handles Cmd+key shortcuts via WDA typeKey (not sendKeys which ignores modifiers).
    /// Cmd+V (paste) goes through keyboard extension when available.
    private func handleCmdShortcut(_ key: String) async {
        let cmdModifier = 16  // XCUIKeyModifierCommand = 1 << 4

        if key == "v" && useKeyboardExt {
            // Paste: keyboard extension can read pasteboard and insert directly (~5ms)
            keyboardExtSocket!.sendPaste()
            return
        }

        if useSocket {
            inputSocket!.sendTypeKey(key, modifierFlags: cmdModifier)
        } else {
            try? await wdaClient.typeKeyWithModifiers(key: key, modifierFlags: cmdModifier)
        }
    }

    func handleCommand(_ command: String) async {
        if useSocket {
            inputSocket!.sendButton(command)
        } else {
            switch command {
            case "home":
                try? await wdaClient.pressButton("home")
            case "volumeUp":
                try? await wdaClient.pressButton("volumeUp")
            case "volumeDown":
                try? await wdaClient.pressButton("volumeDown")
            default:
                break
            }
        }

        if command == "home" {
            log.info("[AutoUnlock] home command detected — checking auto-unlock")
            await autoUnlockIfNeeded()
        }
    }

    private func autoUnlockIfNeeded() async {
        let autoUnlockEnabled = AppSettings().autoUnlock
        let hasPasscode = PasscodeManager().hasSavedPasscode
        let hasSocket = inputSocket != nil
        let socketConnected = inputSocket?.isConnected ?? false
        log.info("[AutoUnlock] guard check: enabled=\(autoUnlockEnabled) hasPasscode=\(hasPasscode) hasSocket=\(hasSocket) socketConnected=\(socketConnected)")

        guard autoUnlockEnabled,
              let passcode = PasscodeManager().load(),
              let socket = inputSocket else {
            log.info("[AutoUnlock] guard failed — aborting")
            return
        }

        log.info("[AutoUnlock] waiting 1s for lock screen to settle...")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        do {
            log.info("[AutoUnlock] calling isLocked()...")
            let locked = try await wdaClient.isLocked()
            log.info("[AutoUnlock] isLocked returned: \(locked)")
            guard locked else {
                log.info("[AutoUnlock] not locked — nothing to do")
                return
            }
            log.info("[AutoUnlock] device IS locked — pressing home for passcode UI")
            try? await wdaClient.pressButton("home")
            log.info("[AutoUnlock] home pressed, waiting 500ms...")
            try? await Task.sleep(nanoseconds: 500_000_000)
            log.info("[AutoUnlock] sending passcode digits...")
            socket.sendKeys(passcode)
            log.info("[AutoUnlock] passcode sent, waiting 1s...")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let stillLocked = try await wdaClient.isLocked()
            if stillLocked {
                log.warning("[AutoUnlock] STILL LOCKED — not retrying")
            } else {
                log.info("[AutoUnlock] SUCCESS — device unlocked")
            }
        } catch {
            log.error("[AutoUnlock] ERROR: \(error.localizedDescription)")
        }
    }

    func handlePinch(center: CGPoint, scale: CGFloat) async {
        guard let phoneCenter = coordinateMapper.viewToPhone(center) else { return }
        let distance = 100.0 * Double(scale)
        let finger1Start = CGPoint(x: phoneCenter.x - 50, y: phoneCenter.y)
        let finger1End = CGPoint(x: phoneCenter.x - distance, y: phoneCenter.y)
        let finger2Start = CGPoint(x: phoneCenter.x + 50, y: phoneCenter.y)
        let finger2End = CGPoint(x: phoneCenter.x + distance, y: phoneCenter.y)

        // Pinch is not supported over WebSocket — use HTTP
        try? await wdaClient.pinch(
            finger1Start: finger1Start, finger1End: finger1End,
            finger2Start: finger2Start, finger2End: finger2End,
            duration: 300
        )
    }
}
