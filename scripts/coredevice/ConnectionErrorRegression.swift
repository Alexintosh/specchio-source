import Foundation

@main struct ConnectionErrorRegression {
    static func main() {
        var collector = CoreDeviceDiagnosticBuffer()
        let primary = "{\"stage\":\"session.failed\",\"code\":\"wifi-device-not-found\"}"
        let cleanup = "{\"stage\":\"session.cleanup.failed\",\"code\":\"connection-lost\"}"
        // One-byte reads, then a final unterminated record simulate pipe framing.
        for byte in (primary + "\n" + cleanup).utf8 { _ = collector.append(Data([byte])) }
        _ = collector.finish()
        precondition(collector.failureCode == "wifi-device-not-found")
        precondition(CoreDeviceConnectionMessages.failure(collector.failureCode).contains("No iPhone was found"))
        var abrupt = CoreDeviceDiagnosticBuffer()
        _ = abrupt.append(Data(primary.utf8))
        precondition(abrupt.failureCode == nil)
        _ = abrupt.finish()
        precondition(abrupt.failureCode == "wifi-device-not-found")
        var older = CoreDeviceDiagnosticBuffer()
        _ = older.append(Data("{\"stage\":\"session.failed\",\"error_type\":\"RuntimeError\"}\n".utf8))
        precondition(older.failureCode == "connection-failed")
        var normal = CoreDeviceDiagnosticBuffer()
        _ = normal.append(Data("not json\n{\"stage\":\"session.closed\"}\n".utf8))
        precondition(normal.failureCode == nil)
        precondition(!CoreDeviceConnectionMessages.failure("unknown-secret").contains("unknown-secret"))
        precondition(CoreDeviceConnectionMessages.progress("tunnel.starting")?.contains("Searching") == true)
        precondition(CoreDeviceConnectionMessages.progress("pairing.usb-required")?.contains("USB") == true)
        precondition(CoreDeviceConnectionMessages.progress("pairing.repairing")?.contains("Restoring") == true)
        precondition(CoreDeviceConnectionMessages.progress("pairing.unlock-required")?.contains("Unlock") == true)
        precondition(CoreDeviceConnectionMessages.failure("network-pairing-repair-failed").contains("rejected"))
        precondition(CoreDeviceConnectionMessages.failure("developer-mode-disabled").contains("Enable Developer Mode"))
        precondition(CoreDeviceConnectionMessages.failure("developer-mode-status-unavailable").contains("could not check"))
        precondition(CoreDeviceConnectionMessages.progress("developer-mode.checking")?.contains("Checking") == true)
        print("PASS: fragmented diagnostics, EOF flush, primary error retention, fallback messages, readable progress")
    }
}
