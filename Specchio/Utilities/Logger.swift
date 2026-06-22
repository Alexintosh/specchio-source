import os.log

enum SpecchioLogger {
    static let wda = Logger(subsystem: "com.alexintosh.Specchio", category: "WDA")
    static let usb = Logger(subsystem: "com.alexintosh.Specchio", category: "USB")
    static let ui = Logger(subsystem: "com.alexintosh.Specchio", category: "UI")
    static let input = Logger(subsystem: "com.alexintosh.Specchio", category: "Input")
    static let network = Logger(subsystem: "com.alexintosh.Specchio", category: "Network")
    static let autoLaunch = Logger(subsystem: "com.alexintosh.Specchio", category: "AutoLaunch")
    static let menuBar = Logger(subsystem: "com.alexintosh.Specchio", category: "MenuBar")
    static let unlock = Logger(subsystem: "com.alexintosh.Specchio", category: "Unlock")
    static let easyMode = Logger(subsystem: "com.alexintosh.Specchio", category: "EasyMode")
    static let replayKit = Logger(subsystem: "com.alexintosh.Specchio", category: "ReplayKit")
    static let airPlay = Logger(subsystem: "com.alexintosh.Specchio", category: "AirPlay")
    static let video = Logger(subsystem: "com.alexintosh.Specchio", category: "Video")
    static let iosScreenCapture = Logger(subsystem: "com.alexintosh.Specchio", category: "IOSScreenCapture")
    static let frameDiagnostics = Logger(subsystem: "com.alexintosh.Specchio", category: "FrameDiagnostics")
    static let agent = Logger(subsystem: "com.alexintosh.Specchio", category: "Agent")
    static let automation = Logger(subsystem: "com.alexintosh.Specchio", category: "Automation")
}
