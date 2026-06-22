import SwiftUI

enum SpecchioLaunchMode {
    case easy
    case dev
}

struct ModeSelectionView: View {
    let onSelect: (SpecchioLaunchMode) -> Void

    @State private var mouseLocation: CGPoint = .zero
    @State private var viewSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 24) {
            SpecchioMirrorLogo(mouseLocation: mouseLocation, parentSize: viewSize)

            Text("Specchio")
                .font(.largeTitle.weight(.bold))
            Text("Choose a mode")
                .font(.title3)
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                ModeChoiceButton(
                    icon: "sparkles",
                    title: "Easy",
                    subtitle: "Companion iOS App and Bluetooth"
                ) {
                    SpecchioLogger.easyMode.info("[ModeSelection] Easy selected")
                    onSelect(.easy)
                }

                ModeChoiceButton(
                    icon: "hammer",
                    title: "Dev Mode",
                    subtitle: "Requires Xcode and iOS Simulator"
                ) {
                    SpecchioLogger.easyMode.info("[ModeSelection] Dev selected")
                    onSelect(.dev)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .topTrailing) {
            ModeSelectionEasySizeIndicator()
                .padding(8)
        }
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size) { _, newSize in
                SpecchioLogger.easyMode.info("[ModeSelection] geometry changed width=\(newSize.width) height=\(newSize.height) easyReservedHeight=\(EasyControlBarMetrics.windowReservedHeight)")
                viewSize = newSize
            }
            .onAppear {
                SpecchioLogger.easyMode.info("[ModeSelection] appeared width=\(geo.size.width) height=\(geo.size.height) easyReservedHeight=\(EasyControlBarMetrics.windowReservedHeight)")
                viewSize = geo.size
            }
        })
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                mouseLocation = location
            case .ended:
                mouseLocation = .zero
            }
        }
    }
}

private struct ModeSelectionEasySizeIndicator: View {
    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 8, height: 8)
            .help("Welcome geometry matched to Easy")
            .accessibilityLabel("Welcome geometry matched to Easy")
            .onAppear {
                SpecchioLogger.easyMode.info("[ModeSelection] easy-size indicator visible reservedHeight=\(EasyControlBarMetrics.windowReservedHeight)")
            }
    }
}

private struct ModeChoiceButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .center)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .background(.quaternary.opacity(0.3))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}
