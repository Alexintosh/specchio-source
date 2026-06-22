import AppKit

struct KeyboardMapper {
    static let commandMappings: [String: String] = [
        "h": "home",
    ]

    static func iosKeySequence(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36: return "\n"    // Return
        case 51: return "\u{8}" // Delete (backspace)
        case 53: return nil     // Escape
        case 48: return "\t"    // Tab
        default: return event.characters
        }
    }
}
