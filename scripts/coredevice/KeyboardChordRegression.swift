import Foundation

@main struct KeyboardChordRegression {
    static func reports(_ keys: [Int]) -> [[Int]] {
        CoreDeviceKeyboardChord.steps(usages: keys, hold: 0.05).compactMap { $0["usages"] as? [Int] }
    }
    static func main() {
        precondition(reports([227, 44]) == [[227], [227, 44], [227], []])
        precondition(reports([227, 43]) == [[227], [227, 43], [227], []])
        precondition(reports([227, 225, 32]) == [[227, 225], [227, 225, 32], [227, 225], []])
        precondition(reports([30]) == [[30], []])
        precondition(reports([4, 225]) == [[225], [4, 225], [225], []])
        let held = CoreDeviceKeyboardChord.steps(usages: [227, 43], hold: 0.45)
        precondition(held.compactMap { $0["seconds"] as? Double } == [0.45])
        print("PASS: modifier ordering for Search, Switch Apps, screenshot, shifted text and unmodified PIN keys")
    }
}
