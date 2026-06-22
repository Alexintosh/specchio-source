import SwiftUI

struct PremiumUpsellView: View {
    @ObservedObject private var licenseManager = LicenseManager.shared
    @Environment(\.dismiss) private var dismiss

    private let closeAction: (() -> Void)?
    private let completionAction: (() -> Void)?

    @State private var licenseKeyInput = ""
    @State private var showClose = false

    private static let checkoutURL = URL(string: "https://buy.polar.sh/polar_cl_VZWRggK5IVBZoMtYvIUQXWcF5rUeNwLqfqfxC0VbiVm")!
    private static let restorePortalURL = URL(string: "https://polar.sh/textware/portal/request")!

    init(
        closeAction: (() -> Void)? = nil,
        completionAction: (() -> Void)? = nil
    ) {
        self.closeAction = closeAction
        self.completionAction = completionAction
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            paywallSurface

            if showClose {
                Button { closePaywall() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: PremiumPaywallMetrics.closeButtonSize, height: PremiumPaywallMetrics.closeButtonSize)
                        .background(.white.opacity(0.12), in: Circle())
                        .overlay {
                            Circle()
                                .stroke(.white.opacity(0.2), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .padding(PremiumPaywallMetrics.closeButtonInset)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .accessibilityLabel("Close Premium paywall")
            }
        }
        .frame(width: PremiumPaywallMetrics.cardWidth)
        .animation(.easeIn(duration: 0.3), value: showClose)
        .onAppear {
            SpecchioLogger.ui.info("[PremiumUpsellView] appeared layout=rainbow-paywall closeDelaySeconds=\(PremiumPaywallMetrics.closeDelaySeconds) customClose=\(closeAction != nil) customCompletion=\(completionAction != nil) pricing=one-time")
            DispatchQueue.main.asyncAfter(deadline: .now() + PremiumPaywallMetrics.closeDelaySeconds) {
                showClose = true
                SpecchioLogger.ui.info("[PremiumUpsellView] close button visible layout=rainbow-paywall")
            }
        }
        .onChange(of: licenseManager.status) { _, newStatus in
            handleLicenseStatusChanged(newStatus)
        }
    }

    private var paywallSurface: some View {
        VStack(spacing: 0) {
            heroBackdrop

            VStack(alignment: .leading, spacing: PremiumPaywallMetrics.contentSpacing) {
                headerRow
                titleBlock
                benefitRows
                pricingCards
                licenseStatusContent
            }
            .padding(.horizontal, PremiumPaywallMetrics.contentHorizontalPadding)
            .padding(.top, PremiumPaywallMetrics.contentTopPadding)
            .padding(.bottom, PremiumPaywallMetrics.contentBottomPadding)
            .background(PremiumPaywallStyle.cardBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: PremiumPaywallMetrics.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PremiumPaywallMetrics.cardCornerRadius, style: .continuous)
                .stroke(PremiumPaywallStyle.rainbowLinear.opacity(PremiumPaywallStyle.rainbowFrameOpacity), lineWidth: 1.3)
        }
        .shadow(color: .black.opacity(0.42), radius: 28, x: 0, y: 18)
        .onAppear {
            SpecchioLogger.ui.info("[PremiumUpsellView] surface appeared layout=rainbow-paywall hero=conic-gradient-inspired featureCount=3 pricingCards=premium-only rainbowFrameOpacity=\(PremiumPaywallStyle.rainbowFrameOpacity)")
        }
    }

    private var heroBackdrop: some View {
        ZStack {
            Image("PremiumPaywallHero")
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFill()
                .accessibilityHidden(true)
        }
        .frame(height: PremiumPaywallMetrics.heroHeight)
        .clipped()
        .accessibilityHidden(true)
        .onAppear {
            SpecchioLogger.ui.info("[PremiumUpsellView] hero appeared asset=PremiumPaywallHero source=generated-paywall-banner width=\(PremiumPaywallMetrics.cardWidth) height=\(PremiumPaywallMetrics.heroHeight) aspectRatio=31:11 pixels=744x264")
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center) {
            Spacer()

            Link(destination: Self.restorePortalURL) {
                Label("Restore", systemImage: "arrow.clockwise")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.08), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    }
            }
            .simultaneousGesture(TapGesture().onEnded {
                SpecchioLogger.ui.info("[PremiumUpsellView] restore portal link tapped url=https://polar.sh/textware/portal/request")
            })
            .accessibilityLabel("Restore Premium license")
        }
        .onAppear {
            SpecchioLogger.ui.info("[PremiumUpsellView] header appeared restoreVisible=true brandTitleVisible=false")
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Control without limits.")
                .font(.largeTitle.weight(.bold))
                .swGlowSweep(
                    baseColor: .gray,
                    glowColor: .white,
                    duration: 2.0,
                    bandWidth: 150,
                    debugName: "premium-paywall-title"
                )
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(1)
                .minimumScaleFactor(0.68)

            Text("Unlock smoother, sharper wireless control.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.64))
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            SpecchioLogger.ui.info("[PremiumUpsellView] title appeared headline=Control_without_limits font=largeTitle.bold effect=swGlowSweep baseColor=gray glowColor=white duration=2.0 bandWidth=150")
        }
    }

    private var benefitRows: some View {
        VStack(spacing: 12) {
            PremiumBenefitRow(
                icon: "speedometer",
                title: "FPS unlock",
                subtitle: "Stream at the full frame rate"
            )
            PremiumBenefitRow(
                icon: "wifi",
                title: "Control phone over WiFi",
                subtitle: "Tap, type, and navigate wirelessly"
            )
            PremiumBenefitRow(
                icon: "display",
                title: "High quality video",
                subtitle: "Sharper mirroring with less compression"
            )
        }
        .onAppear {
            SpecchioLogger.ui.info("[PremiumUpsellView] benefits appeared features=fps_unlock,wifi_control,high_quality_video iconStyle=neutral-gray-white")
        }
    }

    private var pricingCards: some View {
        PremiumPlanCard(
            title: "Premium",
            listPrice: PremiumPaywallPricing.listPriceDisplay,
            currentPrice: PremiumPaywallPricing.currentPriceDisplay,
            caption: "Limited-time one-time purchase",
            badge: "Limited time",
            highlighted: true
        )
        .onAppear {
            SpecchioLogger.ui.info("[PremiumUpsellView] pricing appeared model=one-time listPrice=\(PremiumPaywallPricing.listPriceLog, privacy: .public) currentPrice=\(PremiumPaywallPricing.currentPriceLog, privacy: .public) discount=\(PremiumPaywallPricing.discountLog, privacy: .public) offer=limited-time planCards=premium-only freePlanVisible=false")
        }
    }

    @ViewBuilder
    private var licenseStatusContent: some View {
        switch licenseManager.status {
        case .licensed:
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Premium Activated")
                        .font(.headline)
                        .foregroundStyle(.green)
                }

                Button { completePaywall() } label: {
                    Text("Done")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
            .onAppear {
                SpecchioLogger.ui.info("[PremiumUpsellView] status content appeared branch=licensed")
            }

        case .validating:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Activating...")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.white.opacity(0.07), in: Capsule())
            .onAppear {
                SpecchioLogger.ui.info("[PremiumUpsellView] status content appeared branch=validating")
            }

        case .error(let message):
            VStack(spacing: 12) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(PremiumPaywallStyle.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                activationFields
            }
            .onAppear {
                SpecchioLogger.ui.info("[PremiumUpsellView] status content appeared branch=error message=\(message, privacy: .public)")
            }

        case .free:
            activationFields
                .onAppear {
                    SpecchioLogger.ui.info("[PremiumUpsellView] status content appeared branch=free")
                }
        }
    }

    private var activationFields: some View {
        VStack(spacing: 12) {
            Link(destination: Self.checkoutURL) {
                Text("Buy Premium for \(PremiumPaywallPricing.currentPriceDisplay)")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background {
                        SWPlasma(
                            style: .prism,
                            scale: 1.25,
                            intensity: 1.1,
                            distortion: 1.0,
                            debugName: "premium-paywall-buy-button"
                        )
                        .clipShape(Capsule())
                    }
            }
            .simultaneousGesture(TapGesture().onEnded {
                SpecchioLogger.ui.info("[PremiumUpsellView] checkout link tapped layout=rainbow-paywall currentPrice=\(PremiumPaywallPricing.currentPriceLog, privacy: .public) listPrice=\(PremiumPaywallPricing.listPriceLog, privacy: .public) offer=limited-time")
            })
            .accessibilityLabel("Buy Premium for \(PremiumPaywallPricing.currentPriceDisplay)")
            .onAppear {
                SpecchioLogger.ui.info("[PremiumUpsellView] checkout link appeared background=setup-tutorial-prism-plasma style=prism scale=1.25 intensity=1.1 distortion=1.0 debugName=premium-paywall-buy-button")
            }

            Text("One-time payment. No subscription.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 7) {
                Text("Already have a key?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))

                HStack(spacing: 8) {
                    TextField("SPECCHIO-XXXX-XXXX", text: $licenseKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))

                    Button("Activate") {
                        activateLicense()
                    }
                    .buttonStyle(.bordered)
                    .disabled(licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            SpecchioLogger.ui.info("[PremiumUpsellView] activation fields appeared hasInput=\(!licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)")
        }
    }

    private func activateLicense() {
        let trimmedKey = licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        SpecchioLogger.ui.info("[PremiumUpsellView] activate requested hasKey=\(!trimmedKey.isEmpty)")
        Task { await licenseManager.activate(key: trimmedKey) }
    }

    private func closePaywall() {
        SpecchioLogger.ui.info("[PremiumUpsellView] close requested customClose=\(closeAction != nil)")
        if let closeAction {
            closeAction()
        } else {
            dismiss()
        }
    }

    private func completePaywall() {
        SpecchioLogger.ui.info("[PremiumUpsellView] completion requested customCompletion=\(completionAction != nil)")
        if let completionAction {
            completionAction()
        } else {
            dismiss()
        }
    }

    private func handleLicenseStatusChanged(_ newStatus: LicenseManager.LicenseStatus) {
        switch newStatus {
        case .licensed:
            SpecchioLogger.ui.info("[PremiumUpsellView] premium activated; scheduling completion layout=rainbow-paywall")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                completePaywall()
            }
        case .validating:
            SpecchioLogger.ui.info("[PremiumUpsellView] license status changed branch=validating")
        case .error(let message):
            SpecchioLogger.ui.info("[PremiumUpsellView] license status changed branch=error message=\(message, privacy: .public)")
        case .free:
            SpecchioLogger.ui.info("[PremiumUpsellView] license status changed branch=free")
        }
    }
}

private enum PremiumPaywallMetrics {
    static let cardWidth: CGFloat = 372
    static let cardCornerRadius: CGFloat = 34
    static let heroHeight: CGFloat = 132
    static let contentHorizontalPadding: CGFloat = 22
    static let contentTopPadding: CGFloat = 20
    static let contentBottomPadding: CGFloat = 18
    static let contentSpacing: CGFloat = 14
    static let closeDelaySeconds: Double = 10
    static let closeButtonSize: CGFloat = 34
    static let closeButtonInset: CGFloat = 12
}

private enum PremiumPaywallPricing {
    static let listPriceDisplay = "€49"
    static let currentPriceDisplay = "€29"
    static let discountDisplay = "Save €20"

    static let listPriceLog = "EUR_49"
    static let currentPriceLog = "EUR_29"
    static let discountLog = "EUR_20"
}

private enum PremiumPaywallStyle {
    static let red = Color(red: 1.0, green: 0.18, blue: 0.35)
    static let orange = Color(red: 1.0, green: 0.55, blue: 0.16)
    static let olive = Color(red: 0.72, green: 0.75, blue: 0.22)
    static let lime = Color(red: 0.68, green: 0.95, blue: 0.24)
    static let teal = Color(red: 0.0, green: 0.78, blue: 0.58)
    static let tealer = Color(red: 0.0, green: 0.72, blue: 0.86)
    static let blue = Color(red: 0.16, green: 0.49, blue: 1.0)
    static let purple = Color(red: 0.45, green: 0.34, blue: 1.0)
    static let purpler = Color(red: 0.67, green: 0.28, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.16, blue: 0.58)

    static let cardBackground = Color(red: 0.035, green: 0.036, blue: 0.04)
    static let rainbowFrameOpacity = 0.58
    static let rainbowHeroOpacity = 0.78
    static let rainbowHeroSaturation = 0.82

    static let rainbowStops: [Gradient.Stop] = [
        .init(color: red, location: 0.0),
        .init(color: orange, location: 0.1),
        .init(color: olive, location: 0.2),
        .init(color: lime, location: 0.3),
        .init(color: teal, location: 0.4),
        .init(color: tealer, location: 0.5),
        .init(color: blue, location: 0.6),
        .init(color: purple, location: 0.7),
        .init(color: purpler, location: 0.8),
        .init(color: pink, location: 0.9),
        .init(color: red, location: 1.0)
    ]

    static let rainbowAngular = AngularGradient(
        gradient: Gradient(stops: rainbowStops),
        center: .center,
        angle: .degrees(180)
    )

    static let rainbowLinear = LinearGradient(
        colors: [red, orange, lime, teal, blue, purple, pink],
        startPoint: .leading,
        endPoint: .trailing
    )
}

private struct PremiumHeroChip: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(PremiumPaywallStyle.rainbowLinear)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 8)
    }
}

private struct PremiumBenefitRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.12))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.2), lineWidth: 1)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white.opacity(0.86))
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .onAppear {
            SpecchioLogger.ui.info("[PremiumBenefitRow] appeared title=\(title, privacy: .public) icon=\(icon, privacy: .public) style=neutral-gray-white fillOpacity=0.12 strokeOpacity=0.2 iconOpacity=0.86")
        }
    }
}

private struct PremiumPlanCard: View {
    let title: String
    let listPrice: String
    let currentPrice: String
    let caption: String
    let badge: String?
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))

                Spacer(minLength: 8)

                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(PremiumPaywallStyle.pink, in: Capsule())
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(listPrice)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
                    .strikethrough(true, color: .white.opacity(0.72))
                    .accessibilityLabel("Original price \(listPrice)")

                Text(currentPrice)
                    .font(.system(size: highlighted ? 28 : 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .accessibilityLabel("Current price \(currentPrice)")

                Text(PremiumPaywallPricing.discountDisplay)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PremiumPaywallStyle.lime)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.68)

            Text(caption)
                .font(.caption)
                .foregroundStyle(highlighted ? PremiumPaywallStyle.pink : .white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 98, alignment: .topLeading)
        .padding(12)
        .background(.white.opacity(highlighted ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white, lineWidth: 1)
        }
        .onAppear {
            SpecchioLogger.ui.info("[PremiumPlanCard] appeared title=\(title, privacy: .public) highlighted=\(highlighted) border=simple-white borderOpacity=1 borderWidth=1")
        }
    }
}
