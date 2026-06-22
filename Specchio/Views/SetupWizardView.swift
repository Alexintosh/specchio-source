import SwiftUI

struct SetupWizardView: View {
    @ObservedObject var setupChecker: SetupChecker
    @State private var isRechecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup Required")
                .font(.headline)

            Text("Complete these steps before connecting your iPhone.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                CheckRow(
                    title: "Xcode Installed",
                    status: setupChecker.xcodeInstalled,
                    helpURL: URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")
                )
                CheckRow(
                    title: "Xcode License Accepted",
                    status: setupChecker.xcodeCliReady,
                    helpURL: nil
                )
                CheckRow(
                    title: "iOS Platform Installed",
                    status: setupChecker.iosPlatformInstalled,
                    helpURL: nil
                )
                CheckRow(
                    title: "Signing Certificate",
                    status: setupChecker.signingCertificateFound,
                    helpURL: nil
                )
            }

            HStack {
                Spacer()
                Button {
                    isRechecking = true
                    Task {
                        await setupChecker.runAllChecks()
                        isRechecking = false
                    }
                } label: {
                    if isRechecking {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                        Text("Checking\u{2026}")
                    } else {
                        Text("Re-check")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isRechecking)
                Spacer()
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Check Row

private struct CheckRow: View {
    let title: String
    let status: SetupChecker.CheckStatus
    let helpURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                statusIcon
                    .frame(width: 16, height: 16)

                Text(title)
                    .font(.callout)
                    .foregroundColor(status == .passed ? .primary : statusColor)

                Spacer()

                if let helpURL, status.isFailed {
                    Link(destination: helpURL) {
                        Text("Open")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
            }

            if case .failed(let message) = status {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 24)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundColor(.secondary.opacity(0.3))
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }

    private var statusColor: Color {
        switch status {
        case .failed: return .primary
        default: return .primary
        }
    }
}
