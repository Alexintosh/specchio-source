import SwiftUI

private struct GlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content
        }
    }
}

struct ToolbarView: ToolbarContent {
    @ObservedObject var appState: AppState
    @ObservedObject var deviceManager: DeviceManager

    private var streamColor: Color {
        if let h264 = appState.h264Stream, h264.isStreaming {
            return .blue
        } else if let mjpeg = appState.mjpegStream, mjpeg.isStreaming {
            return .green
        } else if let ss = appState.screenshotStream, ss.isStreaming {
            return .yellow
        } else {
            return .red
        }
    }

    var body: some ToolbarContent {
        statusDot

        ToolbarItem(placement: .primaryAction) {
            Button("Home", systemImage: "house") {
                Task {
                    try? await appState.wdaClient?.pressButton("home")
                    if AppSettings().autoUnlock,
                       let passcode = PasscodeManager().load(),
                       let client = appState.wdaClient,
                       let socket = appState.inputSocket {
                        await MainWindow.performAutoUnlock(client: client, socket: socket, passcode: passcode)
                    }
                }
            }
            .modifier(GlassButtonModifier())
        }

        ToolbarItem(placement: .primaryAction) {
            Button("Disconnect", systemImage: "xmark.circle") {
                SpecchioLogger.ui.info("[ToolbarDisconnect] requested source=native-toolbar activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public) connectionState=\(String(describing: appState.connectionState), privacy: .public) deviceConnectionState=\(String(describing: deviceManager.connectionState), privacy: .public)")
                appState.disconnect()
                SpecchioLogger.ui.info("[ToolbarDisconnect] appState disconnect completed source=native-toolbar activeSource=\(appState.activeVideoSource.diagnosticName, privacy: .public)")
                deviceManager.disconnect()
                SpecchioLogger.ui.info("[ToolbarDisconnect] deviceManager disconnect completed source=native-toolbar deviceConnectionState=\(String(describing: deviceManager.connectionState), privacy: .public)")
            }
            .modifier(GlassButtonModifier())
        }
    }

    @ToolbarContentBuilder
    private var statusDot: some ToolbarContent {
        SpecchioChromeStatusDot(color: streamColor)
    }
}

struct SpecchioChromeStatusDot: ToolbarContent {
    let color: Color

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
                PulsingDot(color: color)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) {
                PulsingDot(color: color)
            }
        }
    }
}
