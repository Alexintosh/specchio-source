import SwiftUI

struct OnboardingWelcomeView: View {
    let onGetStarted: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Specchio")
                .font(.title2.weight(.bold))

            Text("Specchio mirrors your iPhone screen to your Mac. To do this, it builds and installs a small helper app (WebDriverAgent) on your iPhone using your Apple developer certificate.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                requirementRow(icon: "hammer", text: "Xcode installed from the App Store")
                requirementRow(icon: "person.crop.circle", text: "Your Apple ID signed into Xcode")
                requirementRow(icon: "cable.connector", text: "Your iPhone connected via USB for the first setup")
            }
            .padding(.top, 4)

            SpecchioPrimaryButton(
                title: "Get Started",
                usesPremiumGradient: false
            ) {
                SpecchioLogger.easyMode.info("[OnboardingWelcomeView] get started tapped")
                onGetStarted()
            }
            .padding(.top, 4)
        }
        .onAppear {
            SpecchioLogger.easyMode.info("[OnboardingWelcomeView] appeared usingSharedPrimaryButton=true")
        }
    }

    private func requirementRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(text)
                .font(.callout)
        }
    }
}
