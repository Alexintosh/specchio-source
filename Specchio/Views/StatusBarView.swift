import SwiftUI

struct StatusBarView: View {
    let fps: Double
    let latency: Double
    let mode: DisplayMode
    var source: SpecchioVideoSourceKind = .none
    var inputWSConnected: Bool = false
    var keyboardExtConnected: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(source == .none ? .secondary : source.statusColor)
                .frame(width: 8, height: 8)
            Text(source == .none ? mode.rawValue : source.displayName)
                .font(.caption2)
            Text("\(Int(fps)) FPS")
                .font(.caption2.monospacedDigit())
            Text("\(Int(latency))ms")
                .font(.caption2.monospacedDigit())
            Text("WS")
                .font(.caption2.bold())
                .foregroundStyle(inputWSConnected ? .green : .red)
            Text("KB")
                .font(.caption2.bold())
                .foregroundStyle(keyboardExtConnected ? .green : .red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
        .padding(.bottom, 8)
    }
}
