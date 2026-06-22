import Foundation
import IOBluetooth
import IOBluetoothUI

// MARK: - KeyPadDevice (reconstructed from Ghidra decompilation of FUN_10000e7e0, FUN_10000af60)

class KeyPadDevice: NSObject, IOBluetoothL2CAPChannelDelegate {
    var device: IOBluetoothDevice
    var interruptChannel: IOBluetoothL2CAPChannel?
    var controlChannel: IOBluetoothL2CAPChannel?
    var connectionComplete: Bool = false
    weak var delegate: AnyObject?

    // Reconstructed from FUN_10000e7e0
    init(addressString: String, delegate: AnyObject?) {
        guard let dev = IOBluetoothDevice(addressString: addressString) else {
            fatalError("Cannot create IOBluetoothDevice from address: \(addressString)")
        }
        self.device = dev
        self.delegate = delegate
        super.init()
        debugPrint("KeyPadDevice.init(\(addressString))")
    }

    // Reconstructed from FUN_10000af60
    func connect() -> Bool {
        debugPrint("connect() \(device.nameOrAddress ?? "?")")

        // If already marked as connected, check actual state
        if connectionComplete {
            if device.isConnected() {
                return true
            }
        }

        // Check if already connected
        if !device.isConnected() {
            let result = device.openConnection()
            if result != kIOReturnSuccess {
                // openConnection failed — try L2CAP directly anyway
                // Fall through to L2CAP setup
            }
        }

        // At this point, either already connected or openConnection succeeded
        // Open control channel (PSM 0x11 = 17)
        let controlResult = device.openL2CAPChannelSync(
            &controlChannel,
            withPSM: BluetoothL2CAPPSM(kBluetoothL2CAPPSMHIDControl),
            delegate: self
        )

        if controlResult == kIOReturnSuccess {
            // Open interrupt channel (PSM 0x13 = 19)
            let interruptResult = device.openL2CAPChannelSync(
                &interruptChannel,
                withPSM: BluetoothL2CAPPSM(kBluetoothL2CAPPSMHIDInterrupt),
                delegate: self
            )

            if interruptResult == kIOReturnSuccess {
                connectionComplete = true
                return true
            }
        }

        // Connection failed
        debugPrint("connect() failed — disconnecting")
        disconnect()
        return false
    }

    func disconnect() {
        controlChannel?.setDelegate(nil)
        interruptChannel?.setDelegate(nil)
        controlChannel?.close()
        interruptChannel?.close()
        controlChannel = nil
        interruptChannel = nil
        device.closeConnection()
        connectionComplete = false
    }

    // Reconstructed from FUN_10000e550
    func sendData(_ data: [UInt8], on channel: IOBluetoothL2CAPChannel) {
        let length = data.count
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        buffer.initialize(from: data, count: length)

        let result = channel.writeAsync(buffer, length: UInt16(length), refcon: nil)
        if result != kIOReturnSuccess {
            debugPrint("Buff Data Failed \(channel.psm)")
        }
    }

    // Reconstructed from FUN_10000e970 — sends handshake on CONTROL channel only
    func sendHandshake(_ channel: IOBluetoothL2CAPChannel, status: UInt8) {
        guard channel.psm == BluetoothL2CAPPSM(kBluetoothL2CAPPSMHIDControl) else {
            debugPrint("FATAL: send handshake for control channel only")
            return
        }
        sendData([0x00 | status], on: channel)
    }

    // HID keyboard report — reconstructed from KeyPad strings
    func hidReport(keyCode: UInt8, modifier: UInt8) -> [UInt8] {
        return [
            0xA1,       // DATA | INPUT (HIDP Bluetooth)
            0x01,       // Report ID
            modifier,   // Modifier Keys
            0x00,       // Reserved
            keyCode,    // Key 1
            0x00,       // Key 2
            0x00,       // Key 3
            0x00,       // Key 4
            0x00,       // Key 5
            0x00,       // Key 6
            0x00        // Padding
        ]
    }

    // MARK: - IOBluetoothL2CAPChannelDelegate

    // Reconstructed from FUN_10000bc00 (l2capChannelData)
    @objc func l2capChannelData(
        _ channel: IOBluetoothL2CAPChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        guard dataLength > 0, let dataPointer else { return }
        let data = Array(UnsafeBufferPointer(
            start: dataPointer.assumingMemoryBound(to: UInt8.self),
            count: dataLength
        ))
        let header = data[0]
        let messageType = header >> 4
        let param = header & 0x0F

        if channel.psm == BluetoothL2CAPPSM(kBluetoothL2CAPPSMHIDControl) {
            // Control channel messages
            switch messageType {
            case 0: // Handshake
                return
            case 1: // HID_CONTROL
                channel.device?.closeConnection()
            case 5: // SET_REPORT
                sendHandshake(channel, status: 0) // Successful
            case 7: // SET_PROTOCOL
                sendHandshake(channel, status: 0) // Successful
            case 4: // GET_REPORT
                sendHandshake(channel, status: 0) // Successful
            default:
                return
            }
        } else if channel.psm == BluetoothL2CAPPSM(kBluetoothL2CAPPSMHIDInterrupt) {
            // Interrupt channel — log data
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            debugPrint("Interrupt Message: \(hex)")
        }
    }

    @objc func l2capChannelOpenComplete(
        _ channel: IOBluetoothL2CAPChannel!,
        status error: IOReturn
    ) {
        debugPrint("channelOpenComplete PSM \(channel.psm) status=\(error)")
        if error == kIOReturnSuccess {
            channel.setDelegate(self)
            // Store channel based on PSM
            if channel.psm == BluetoothL2CAPPSM(kBluetoothL2CAPPSMHIDControl) {
                controlChannel = channel
            } else if channel.psm == BluetoothL2CAPPSM(kBluetoothL2CAPPSMHIDInterrupt) {
                interruptChannel = channel
            }
        }
    }

    @objc func l2capChannelClosed(_ channel: IOBluetoothL2CAPChannel!) {
        debugPrint("channelClosed PSM \(channel.psm)")
    }

    @objc func l2capChannelReconfigured(_ channel: IOBluetoothL2CAPChannel!) {
        debugPrint("channelReconfigured PSM \(channel.psm)")
    }

    @objc func l2capChannelWriteComplete(
        _ channel: IOBluetoothL2CAPChannel!,
        refcon: UnsafeMutableRawPointer!,
        status error: IOReturn
    ) {
        // Empty — matches KeyPad's implementation
    }

    @objc func l2capChannelQueueSpaceAvailable(_ channel: IOBluetoothL2CAPChannel!) {
        // Empty — matches KeyPad's implementation
    }
}

// MARK: - KeyPadController (reconstructed from Ghidra decompilation of FUN_10000d780, FUN_1000184a0)

class KeyPadController {
    var bluetoothHost: IOBluetoothHostController?
    var service: IOBluetoothSDPServiceRecord?
    var sdpDict: [AnyHashable: Any]?
    var devices: [KeyPadDevice] = []
    var curDevice: KeyPadDevice?

    init() {
        // Load SDP dictionary from plist
        if let path = Bundle.main.path(forResource: "HIDServiceRecord", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path) as? [AnyHashable: Any] {
            sdpDict = dict
        } else {
            // Fallback
            let devPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("HIDServiceRecord.plist").path
            sdpDict = NSDictionary(contentsOfFile: devPath) as? [AnyHashable: Any]
        }
        debugPrint("KeyPadController.init() sdpDict=\(sdpDict?.count ?? 0) keys")
    }

    // Reconstructed from FUN_10000d780
    func publishSDP() -> Bool {
        // If already published, return true
        if service != nil {
            return true
        }

        // Get host controller
        bluetoothHost = IOBluetoothHostController.default()

        guard let dict = sdpDict else {
            return false
        }

        // Check macOS version — KeyPad checks for >= 14 and >= 13
        if #available(macOS 14, *) {
            // Use the dict directly
        } else if #available(macOS 13, *) {
            // Also fine
        }

        // Publish service record
        service = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict)

        return service != nil
    }

    // Reconstructed from FUN_1000184a0 — the main flow
    func launchBluetooth() {
        // Step 1: Create device selector
        guard let selector = IOBluetoothDeviceSelectorController.deviceSelector() else {
            return
        }

        // Step 2: Publish SDP
        let published = publishSDP()

        // Step 3: Check user preference
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "enableBluetoothOnStart") {
            defaults.set(true, forKey: "enableBluetoothOnStart")
        }

        // Step 4: Set class of device (only if host controller exists)
        if let host = bluetoothHost {
            host.setClassOfDevice(0x2540, forTimeInterval: 120.0)
        }

        // Step 5: Check if SDP was published
        guard published, service != nil else {
            // Show alert — Bluetooth not available
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Bluetooth Required"
            alert.informativeText = "Please enable Bluetooth to use KeyPad."
            alert.runModal()
            return
        }

        // Step 6: Set title and run modal
        selector.setTitle("Connect before pressing the Select Button")
        let result = selector.runModal()

        // Step 7: Check result
        guard result == -1000 else { // kIOBluetoothUISuccess
            debugPrint("User cancelled selector")
            return
        }

        // Step 8: Get results
        guard let results = selector.getResults() as? [IOBluetoothDevice] else {
            debugPrint("No results from selector")
            return
        }

        // Step 9: Process each result — only paired devices
        for device in results {
            guard device.isPaired() else { continue }

            let address = device.addressString ?? ""
            let name = device.nameOrAddress ?? "unknown"

            debugPrint("\(name) isPaired=true")

            // Check if device already exists in our list
            let alreadyExists = devices.contains { existingDevice in
                existingDevice.device.addressString == address
            }

            if !alreadyExists {
                // Create new KeyPadDevice
                let kpDevice = KeyPadDevice(addressString: address, delegate: nil)
                devices.append(kpDevice)
                debugPrint("Device name not set: \(name) \(address)")
            }
        }

        debugPrint("listForDevices reloadData")
    }
}
