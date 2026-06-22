import AVFoundation
import CoreMediaIO

class USBDeviceMonitor: ObservableObject {
    @Published var availableDevices: [AVCaptureDevice] = []

    init() {
        enableDALDevices()
        startMonitoring()
    }

    private func enableDALDevices() {
        IOSScreenCaptureDeviceMonitor.enableCoreMediaIOScreenCaptureDevices(trigger: "legacy USBDeviceMonitor")
    }

    private func startMonitoring() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceConnected),
            name: .AVCaptureDeviceWasConnected,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceDisconnected),
            name: .AVCaptureDeviceWasDisconnected,
            object: nil
        )
        refreshDevices()
    }

    @objc private func deviceConnected(_ notification: Notification) {
        DispatchQueue.main.async { self.refreshDevices() }
    }

    @objc private func deviceDisconnected(_ notification: Notification) {
        DispatchQueue.main.async { self.refreshDevices() }
    }

    func refreshDevices() {
        let descriptors = IOSScreenCaptureDeviceMonitor.discoverDevices(trigger: "legacy USBDeviceMonitor")
        availableDevices = descriptors
            .filter(\.isLikelyIOSScreenCapture)
            .map(\.device)
    }
}
