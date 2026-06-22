import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var appState: AppState
    @State private var info: DiagnosticsInfo = .empty
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Specchio Diagnostics")
                    .font(.headline)
                Spacer()
                Button(action: copyToClipboard) {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(action: saveToFile) {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(action: { Task { await refresh() } }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshing)
                Button(action: {
                    NSApp.keyWindow?.close()
                }) {
                    Label("Close", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        sectionHeader("System")
                        row("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
                        row("Xcode", info.xcodeVersion)
                        row("CLI Path", info.xcodeCLIPath)
                        row("iOS SDK", info.iosSDKInstalled ? "Installed" : "NOT FOUND")
                    }

                    Group {
                        sectionHeader("Signing")
                        row("Persisted Team", info.persistedTeam.isEmpty ? "(none)" : info.persistedTeam)
                        row("Detected Teams", info.detectedTeams.isEmpty ? "NONE" : info.detectedTeams.joined(separator: ", "))
                        row("Xcode Account Team", info.xcodeAccountTeam ?? "(not resolved)")
                        row("Cert OU (openssl)", info.certSubject.isEmpty ? "(empty)" : info.certSubject)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Certificates (find-identity)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(info.certificates.isEmpty ? "NONE" : info.certificates)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if let projectPath = WDABuildCache.bundledWDAProjectPath {
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: projectPath))
                            } label: {
                                Label("Open WDA Project in Xcode", systemImage: "hammer")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Group {
                        sectionHeader("Device")
                        row("Connection", String(describing: appState.connectionState))
                        row("Video Source", appState.activeVideoSource.displayName)
                        row("Video Source ID", appState.activeVideoSource.diagnosticName)
                        row("Last Fallback", appState.lastVideoFallbackReason ?? "(none)")
                        row("Frame Diagnostics", FrameDropDiagnostics.latestLogPath)
                        row("Native Device", appState.iosScreenCaptureStream?.diagnosticDeviceName ?? "(none)")
                        row("Native Media", appState.iosScreenCaptureStream?.diagnosticMediaType ?? "(none)")
                        row("Native FPS", appState.iosScreenCaptureStream.map { String(format: "%.1f", $0.currentFPS) } ?? "0.0")
                        row("Native Target FPS", appState.iosScreenCaptureStream.map { "\(String(format: "%.0f", $0.effectiveTargetFramesPerSecond)) effective / \(String(format: "%.0f", $0.configuredTargetFramesPerSecond)) configured" } ?? "0 effective / 0 configured")
                        row("Native Capture Policy", appState.iosScreenCaptureStream?.capturePolicyMessage ?? "USB capture policy pending")
                        row("Native Health", appState.iosScreenCaptureStream?.streamHealth.diagnosticDescription ?? "idle")
                        row("Native Audio", appState.iosScreenCaptureStream?.audioState.diagnosticDescription ?? "off")
                        row("Native Audio Format", appState.iosScreenCaptureStream.map { "\(String(format: "%.0f", $0.audioSampleRate)) Hz / \($0.audioChannelCount) ch" } ?? "0 Hz / 0 ch")
                        row("Native Audio Buffers", appState.iosScreenCaptureStream.map { "received=\($0.receivedAudioSampleBufferCount) dropped=\($0.droppedAudioSampleBufferCount)" } ?? "received=0 dropped=0")
                        row("AirPlay Health", appState.airPlayStream?.streamHealth.diagnosticDescription ?? "idle")
                        row("AirPlay FPS", appState.airPlayStream.map { String(format: "%.1f", $0.currentFPS) } ?? "0.0")
                        row("AirPlay Max FPS", appState.airPlayStream.map { String($0.advertisedMaximumFPS) } ?? "0")
                        row("AirPlay Display", appState.airPlayStream.map { airPlayDisplayText($0) } ?? "(none)")
                        row("AirPlay Codec", appState.airPlayStream?.activeAirPlayVideoCodec ?? "unknown")
                        row("AirPlay Frame Size", appState.airPlayStream.map { airPlayFrameSizeText($0) } ?? "(none)")
                        row("AirPlay Mirror Packets", appState.airPlayStream.map { String($0.mirrorPacketCount) } ?? "0")
                        row("AirPlay Mirror Activity", relativeAgeText(appState.airPlayStream?.lastMirrorPacketReceivedAt))
                        row("AirPlay Control Port", appState.airPlayStream?.controlPort.map(String.init) ?? "(none)")
                        row("AirPlay Timing Port", appState.airPlayStream?.timingPort.map(String.init) ?? "(none)")
                        row("AirPlay Data Port", appState.airPlayStream?.mirrorDataPort.map(String.init) ?? "(none)")
                        row("AirPlay Audio Data Port", appState.airPlayStream?.audioDataPort.map(String.init) ?? "(none)")
                        row("AirPlay Audio Control Port", appState.airPlayStream?.audioControlPort.map(String.init) ?? "(none)")
                        row("AirPlay Audio Playback", appState.airPlayStream?.audioPlaybackStatus ?? "off")
                        row("AirPlay Media Playback", appState.airPlayStream?.mediaPlaybackStatus ?? "idle")
                        row("AirPlay Audio Packets", appState.airPlayStream.map { "received=\($0.audioPlaybackPacketCount) decoded=\($0.audioPlaybackDecodedPacketCount) dropped=\($0.audioPlaybackDroppedPacketCount)" } ?? "received=0 decoded=0 dropped=0")
                        row("AirPlay Audio Buffer", appState.airPlayStream.map { String(format: "%.1f ms", $0.audioPlaybackBufferedMilliseconds) } ?? "0.0 ms")
                        row("AirPlay Audio Last Drop", appState.airPlayStream?.audioPlaybackLastDropReason ?? "(none)")
                        row("AirPlay H.264 Dump Path", appState.airPlayStream?.h264DumpPath ?? "(disabled)")
                        row("AirPlay H.264 Dump Bytes", appState.airPlayStream.map { String($0.h264DumpBytes) } ?? "0")
                        row("AirPlay FairPlay Provider", appState.airPlayStream?.fairPlayProviderStatus ?? "missing")
                        row("AirPlay FairPlay Phase", appState.airPlayStream?.fairPlayPhaseStatus ?? "idle")
                        row("AirPlay Control Trace Lines", appState.airPlayStream.map { String($0.recentControlTrace.count) } ?? "0")
                        row("AirPlay PIN", appState.airPlayStream?.currentPairingPIN == nil ? "(none)" : "(visible in Easy Mode)")
                        row("AirPlay Error", appState.airPlayStream?.lastError ?? "(none)")
                        if info.devices.isEmpty {
                            row("USB Devices", "None detected")
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("USB Devices")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(info.devices, id: \.udid) { device in
                                    Text("\(device.name) — \(device.udid)")
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    Group {
                        sectionHeader("WDA Build")
                        row("Cache Valid", info.cacheValid ? "Yes" : "No")
                        row("Cache Key", info.cacheKey)
                        row("DerivedData", info.derivedDataPath)
                        row("WDA Version", info.wdaVersion)
                        row("Last Build Error", info.lastBuildError.isEmpty ? "(none)" : info.lastBuildError)
                    }

                    if !info.buildLog.isEmpty {
                        Group {
                            sectionHeader("Build Log (last 200 lines)")
                            Text(info.buildLog)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color(nsColor: .textBackgroundColor))
                                .cornerRadius(6)
                        }
                    }

                    if let controlTrace = appState.airPlayStream?.recentControlTrace, !controlTrace.isEmpty {
                        Group {
                            sectionHeader("AirPlay Control Trace")
                            Text(controlTrace.joined(separator: "\n"))
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color(nsColor: .textBackgroundColor))
                                .cornerRadius(6)
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 520, idealWidth: 520, minHeight: 400, idealHeight: 560)
        .task { await refresh() }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.bold())
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func relativeAgeText(_ date: Date?) -> String {
        guard let date else { return "(none)" }
        return "\(String(format: "%.1f", Date().timeIntervalSince(date)))s ago"
    }

    private func airPlayDisplayText(_ stream: AirPlayScreenStreamManager) -> String {
        let size = stream.advertisedDisplaySize
        let quality = AppSettings.EasyAirPlayQuality.label(for: stream.advertisedAirPlayQuality)
        return "\(quality) \(Int(size.width))x\(Int(size.height))"
    }

    private func airPlayFrameSizeText(_ stream: AirPlayScreenStreamManager) -> String {
        guard let size = stream.lastFrameSize else { return "(none)" }
        return "\(Int(size.width))x\(Int(size.height))"
    }

    // MARK: - Actions

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        // System
        info.xcodeVersion = Self.runCommand("/usr/bin/xcodebuild", args: ["-version"])
            .components(separatedBy: "\n").filter { !$0.isEmpty }.joined(separator: " ")
        info.xcodeCLIPath = Self.runCommand("/usr/bin/xcode-select", args: ["-p"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        info.iosSDKInstalled = Self.runCommand("/usr/bin/xcrun", args: ["xcodebuild", "-showsdks"])
            .contains("iphoneos")

        // Signing
        info.detectedTeams = WDALauncher.detectAllTeamIDs()
        info.xcodeAccountTeam = WDALauncher.detectXcodeAccountTeam()
        info.persistedTeam = UserDefaults.standard.string(forKey: "selectedTeamID") ?? ""
        info.certificates = Self.runCommand("/usr/bin/security", args: ["find-identity", "-v", "-p", "codesigning"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        info.certSubject = Self.runCommand("/usr/bin/security", args: ["find-certificate", "-a", "-c", "Apple Development", "-p"])
            .components(separatedBy: "-----END CERTIFICATE-----")
            .compactMap { chunk -> String? in
                let pem = chunk + "-----END CERTIFICATE-----"
                guard pem.contains("-----BEGIN CERTIFICATE-----") else { return nil }
                return Self.runCommand("/usr/bin/openssl", args: ["x509", "-noout", "-subject"], stdin: pem)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Devices
        do {
            info.devices = try await DeviceDetector.detectDevices()
        } catch {
            info.devices = []
        }

        // WDA Build
        info.cacheValid = WDABuildCache.isCacheValid()
        info.cacheKey = WDABuildCache.computeCacheKey() ?? "(unknown)"
        info.derivedDataPath = WDABuildCache.derivedDataPath.path
        info.buildLog = WDABuildCache.readBuildLog()
        info.wdaVersion = {
            guard let projectPath = WDABuildCache.bundledWDAProjectPath else { return "(unknown)" }
            let wdaRoot = (projectPath as NSString).deletingLastPathComponent
            let versionFile = (wdaRoot as NSString).appendingPathComponent(".wda_version")
            if let v = try? String(contentsOfFile: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return v
            }
            return "(no version file)"
        }()
        info.lastBuildError = {
            if case .failed(let msg) = appState.connectionState { return msg }
            return ""
        }()
    }

    private func copyToClipboard() {
        let text = generateReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveToFile() {
        let text = generateReport()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Specchio-Diagnostics.txt"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func generateReport() -> String {
        var lines: [String] = []
        lines.append("Specchio Diagnostics Report")
        lines.append("Generated: \(Date())")
        lines.append("")
        lines.append("=== System ===")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Xcode: \(info.xcodeVersion)")
        lines.append("CLI Path: \(info.xcodeCLIPath)")
        lines.append("iOS SDK: \(info.iosSDKInstalled ? "Installed" : "NOT FOUND")")
        lines.append("")
        lines.append("=== Signing ===")
        lines.append("Persisted Team: \(info.persistedTeam.isEmpty ? "(none)" : info.persistedTeam)")
        lines.append("Xcode Account Team: \(info.xcodeAccountTeam ?? "(not resolved)")")
        lines.append("Detected Teams: \(info.detectedTeams.isEmpty ? "NONE" : info.detectedTeams.joined(separator: ", "))")
        lines.append("Cert Subject (OU extraction):\n\(info.certSubject.isEmpty ? "(empty)" : info.certSubject)")
        lines.append("Certificates (find-identity):\n\(info.certificates)")
        lines.append("")
        lines.append("=== Device ===")
        lines.append("Connection: \(appState.connectionState)")
        lines.append("Video Source: \(appState.activeVideoSource.displayName) (\(appState.activeVideoSource.diagnosticName))")
        lines.append("Last Fallback: \(appState.lastVideoFallbackReason ?? "(none)")")
        lines.append("Frame Diagnostics: \(FrameDropDiagnostics.latestLogPath)")
        lines.append("Native Capture Device: \(appState.iosScreenCaptureStream?.diagnosticDeviceName ?? "(none)")")
        lines.append("Native Capture Media: \(appState.iosScreenCaptureStream?.diagnosticMediaType ?? "(none)")")
        lines.append("Native Capture FPS: \(appState.iosScreenCaptureStream.map { String(format: "%.1f", $0.currentFPS) } ?? "0.0")")
        lines.append("Native Capture Target FPS: \(appState.iosScreenCaptureStream.map { "\(String(format: "%.0f", $0.effectiveTargetFramesPerSecond)) effective / \(String(format: "%.0f", $0.configuredTargetFramesPerSecond)) configured" } ?? "0 effective / 0 configured")")
        lines.append("Native Capture Policy: \(appState.iosScreenCaptureStream?.capturePolicyMessage ?? "USB capture policy pending")")
        lines.append("Native Capture Health: \(appState.iosScreenCaptureStream?.streamHealth.diagnosticDescription ?? "idle")")
        lines.append("Native Capture Audio: \(appState.iosScreenCaptureStream?.audioState.diagnosticDescription ?? "off")")
        lines.append("Native Capture Audio Format: \(appState.iosScreenCaptureStream.map { "\(String(format: "%.0f", $0.audioSampleRate)) Hz / \($0.audioChannelCount) ch" } ?? "0 Hz / 0 ch")")
        lines.append("Native Capture Audio Buffers: \(appState.iosScreenCaptureStream.map { "received=\($0.receivedAudioSampleBufferCount) dropped=\($0.droppedAudioSampleBufferCount)" } ?? "received=0 dropped=0")")
        lines.append("AirPlay Health: \(appState.airPlayStream?.streamHealth.diagnosticDescription ?? "idle")")
        lines.append("AirPlay FPS: \(appState.airPlayStream.map { String(format: "%.1f", $0.currentFPS) } ?? "0.0")")
        lines.append("AirPlay Max FPS: \(appState.airPlayStream.map { String($0.advertisedMaximumFPS) } ?? "0")")
        lines.append("AirPlay Display: \(appState.airPlayStream.map { airPlayDisplayText($0) } ?? "(none)")")
        lines.append("AirPlay Mirror Packets: \(appState.airPlayStream.map { String($0.mirrorPacketCount) } ?? "0")")
        lines.append("AirPlay Mirror Activity: \(relativeAgeText(appState.airPlayStream?.lastMirrorPacketReceivedAt))")
        lines.append("AirPlay Control Port: \(appState.airPlayStream?.controlPort.map(String.init) ?? "(none)")")
        lines.append("AirPlay Timing Port: \(appState.airPlayStream?.timingPort.map(String.init) ?? "(none)")")
        lines.append("AirPlay Data Port: \(appState.airPlayStream?.mirrorDataPort.map(String.init) ?? "(none)")")
        lines.append("AirPlay Audio Data Port: \(appState.airPlayStream?.audioDataPort.map(String.init) ?? "(none)")")
        lines.append("AirPlay Audio Control Port: \(appState.airPlayStream?.audioControlPort.map(String.init) ?? "(none)")")
        lines.append("AirPlay Audio Playback: \(appState.airPlayStream?.audioPlaybackStatus ?? "off")")
        lines.append("AirPlay Media Playback: \(appState.airPlayStream?.mediaPlaybackStatus ?? "idle")")
        lines.append("AirPlay Audio Packets: \(appState.airPlayStream.map { "received=\($0.audioPlaybackPacketCount) decoded=\($0.audioPlaybackDecodedPacketCount) dropped=\($0.audioPlaybackDroppedPacketCount)" } ?? "received=0 decoded=0 dropped=0")")
        lines.append("AirPlay Audio Buffer: \(appState.airPlayStream.map { String(format: "%.1f ms", $0.audioPlaybackBufferedMilliseconds) } ?? "0.0 ms")")
        lines.append("AirPlay Audio Last Drop: \(appState.airPlayStream?.audioPlaybackLastDropReason ?? "(none)")")
        lines.append("AirPlay H.264 Dump Path: \(appState.airPlayStream?.h264DumpPath ?? "(disabled)")")
        lines.append("AirPlay H.264 Dump Bytes: \(appState.airPlayStream.map { String($0.h264DumpBytes) } ?? "0")")
        lines.append("AirPlay FairPlay Provider: \(appState.airPlayStream?.fairPlayProviderStatus ?? "missing")")
        lines.append("AirPlay FairPlay Phase: \(appState.airPlayStream?.fairPlayPhaseStatus ?? "idle")")
        lines.append("AirPlay Control Trace Lines: \(appState.airPlayStream.map { String($0.recentControlTrace.count) } ?? "0")")
        lines.append("AirPlay PIN: \(appState.airPlayStream?.currentPairingPIN == nil ? "(none)" : "(visible in Easy Mode)")")
        lines.append("AirPlay Error: \(appState.airPlayStream?.lastError ?? "(none)")")
        if let controlTrace = appState.airPlayStream?.recentControlTrace, !controlTrace.isEmpty {
            lines.append("AirPlay Control Trace:")
            lines.append(contentsOf: controlTrace)
        }
        if info.devices.isEmpty {
            lines.append("USB Devices: None detected")
        } else {
            lines.append("USB Devices:")
            for d in info.devices {
                lines.append("  - \(d.name) (\(d.udid))")
            }
        }
        lines.append("")
        lines.append("=== WDA Build ===")
        lines.append("Cache Valid: \(info.cacheValid)")
        lines.append("Cache Key: \(info.cacheKey)")
        lines.append("DerivedData: \(info.derivedDataPath)")
        lines.append("WDA Version: \(info.wdaVersion)")
        lines.append("Last Build Error: \(info.lastBuildError.isEmpty ? "(none)" : info.lastBuildError)")
        if !info.buildLog.isEmpty {
            lines.append("")
            lines.append("=== Build Log (last 200 lines) ===")
            lines.append(info.buildLog)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Process helper

    private static func runCommand(_ path: String, args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func runCommand(_ path: String, args: [String], stdin: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        try? proc.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        inPipe.fileHandleForWriting.closeFile()
        proc.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Data Model

struct DiagnosticsInfo {
    var xcodeVersion: String = ""
    var xcodeCLIPath: String = ""
    var iosSDKInstalled: Bool = false
    var detectedTeams: [String] = []
    var xcodeAccountTeam: String?
    var persistedTeam: String = ""
    var certificates: String = ""
    var certSubject: String = ""
    var devices: [DetectedDevice] = []
    var cacheValid: Bool = false
    var cacheKey: String = ""
    var derivedDataPath: String = ""
    var wdaVersion: String = ""
    var lastBuildError: String = ""
    var buildLog: String = ""

    static let empty = DiagnosticsInfo()
}
