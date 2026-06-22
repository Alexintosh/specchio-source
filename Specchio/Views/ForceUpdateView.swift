import SwiftUI
import Sparkle

struct ForceUpdateView: View {
    let message: String
    let updater: SPUUpdater

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("SpecchioLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
                .onAppear {
                    SpecchioLogger.ui.info("[ForceUpdateView] app logo appeared asset=SpecchioLogo width=80 height=80")
                }

            Text("Update Required")
                .font(.largeTitle.weight(.bold))

            Text(message)
                .font(.title3)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                updater.checkForUpdates()
            } label: {
                Text("Update Now")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .interactiveDismissDisabled()
    }
}
