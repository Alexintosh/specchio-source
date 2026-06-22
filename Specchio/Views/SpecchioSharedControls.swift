import SwiftUI
import AppKit

struct SpecchioMirrorLogo: View {
    let mouseLocation: CGPoint
    var parentSize: CGSize = CGSize(width: 390, height: 844)

    private var rotation: (x: Double, y: Double) {
        guard mouseLocation != .zero, parentSize.width > 0 else {
            SpecchioLogger.easyMode.info("[SpecchioMirrorLogo] rotation branch=neutral mouseZero=\(mouseLocation == .zero) parentWidth=\(parentSize.width)")
            return (0, 0)
        }

        let nx = (mouseLocation.x / parentSize.width - 0.5) * 2
        let ny = (mouseLocation.y / parentSize.height - 0.5) * 2
        let maxTilt: Double = 30
        SpecchioLogger.easyMode.debug("[SpecchioMirrorLogo] rotation branch=tilted normalizedX=\(nx) normalizedY=\(ny) maxTilt=\(maxTilt)")
        return (x: -ny * maxTilt, y: nx * maxTilt)
    }

    var body: some View {
        Text("🪞")
            .font(.system(size: 128))
            .rotation3DEffect(
                .degrees(rotation.x),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.5
            )
            .rotation3DEffect(
                .degrees(rotation.y),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.5
            )
            .animation(.easeOut(duration: 0.15), value: mouseLocation.x)
            .animation(.easeOut(duration: 0.15), value: mouseLocation.y)
            .onAppear {
                SpecchioLogger.easyMode.info("[SpecchioMirrorLogo] appeared emoji=mirror fontSize=128 parentWidth=\(parentSize.width) parentHeight=\(parentSize.height)")
            }
    }
}

struct SpecchioPrimaryButton: View {
    let title: String
    let usesPremiumGradient: Bool
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)

    var body: some View {
        Button {
            SpecchioLogger.easyMode.info("[SpecchioPrimaryButton] tapped title=\(title) style=\(usesPremiumGradient ? "premium-gradient" : "accent")")
            action()
        } label: {
            Text(title)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background {
                    if usesPremiumGradient {
                        shape.fill(LinearGradient(
                            colors: [.purple, .blue, .pink, .orange],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                    } else {
                        shape.fill(Color.accentColor)
                    }
                }
        }
        .buttonStyle(.plain)
        .onAppear {
            SpecchioLogger.easyMode.info("[SpecchioPrimaryButton] appeared title=\(title) style=\(usesPremiumGradient ? "premium-gradient" : "accent") minHeight=28 cornerRadius=15")
        }
    }
}

enum SpecchioPhoneWindowMetrics {
    static let defaultPhoneScreenSize = CGSize(width: 390, height: 844)
}

enum SpecchioWindowAspectPolicy: Equatable {
    case disabled
    case contentAspect(CGSize)
    case visibleContentPhoneSurface(phoneSize: CGSize, reservedTopHeight: CGFloat)

    var idealWidth: CGFloat? {
        switch self {
        case .disabled:
            return nil
        case .contentAspect(let size):
            return size.width
        case .visibleContentPhoneSurface(let phoneSize, _):
            return phoneSize.width
        }
    }

    var logDescription: String {
        switch self {
        case .disabled:
            return "disabled"
        case .contentAspect(let size):
            return "contentAspect(width:\(size.width),height:\(size.height))"
        case .visibleContentPhoneSurface(let phoneSize, let reservedTopHeight):
            return "visibleContentPhoneSurface(phoneWidth:\(phoneSize.width),phoneHeight:\(phoneSize.height),reservedTopHeight:\(reservedTopHeight))"
        }
    }
}

enum SpecchioWindowChromeStyle: Equatable {
    case standard
    case iPhoneMirroringPresentation

    var logName: String {
        switch self {
        case .standard:
            return "standard"
        case .iPhoneMirroringPresentation:
            return "iPhoneMirroringPresentation"
        }
    }
}

enum SpecchioPresentationWindowChrome {
    static func reapplyAfterSystemChromeUpdate(
        to window: NSWindow,
        reason: String,
        alwaysOnTop: Bool = currentAlwaysOnTopSetting(),
        standardControlsVisible: Bool = false
    ) {
        apply(
            to: window,
            reason: "\(reason)-immediate",
            alwaysOnTop: alwaysOnTop,
            standardControlsVisible: standardControlsVisible
        )
        DispatchQueue.main.async { [weak window] in
            guard let window else {
                SpecchioLogger.easyMode.info("[SpecchioPresentationWindowChrome] deferred apply skipped reason=\(reason, privacy: .public) phase=next-runloop branch=no-window")
                return
            }
            apply(
                to: window,
                reason: "\(reason)-next-runloop",
                alwaysOnTop: currentAlwaysOnTopSetting(),
                standardControlsVisible: standardControlsVisible
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak window] in
            guard let window else {
                SpecchioLogger.easyMode.info("[SpecchioPresentationWindowChrome] deferred apply skipped reason=\(reason, privacy: .public) phase=after-focus-paint branch=no-window")
                return
            }
            apply(
                to: window,
                reason: "\(reason)-after-focus-paint",
                alwaysOnTop: currentAlwaysOnTopSetting(),
                standardControlsVisible: standardControlsVisible
            )
        }
    }

    static func apply(
        to window: NSWindow,
        reason: String,
        alwaysOnTop: Bool = currentAlwaysOnTopSetting(),
        standardControlsVisible: Bool = false
    ) {
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = alwaysOnTop ? .floating : .normal
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar?.isVisible = false
        window.toolbar?.showsBaselineSeparator = false
        window.standardWindowButton(.closeButton)?.isHidden = !standardControlsVisible
        window.standardWindowButton(.miniaturizeButton)?.isHidden = !standardControlsVisible
        window.standardWindowButton(.zoomButton)?.isHidden = !standardControlsVisible
        window.isMovableByWindowBackground = false

        applyTransparentBacking(to: window.contentView, reason: reason, source: "contentView")
        applyTransparentBacking(to: window.contentView?.superview, reason: reason, source: "contentSuperview")
        applyTransparentFrameSubviews(for: window, reason: reason)

        SpecchioLogger.easyMode.info("[SpecchioPresentationWindowChrome] applied reason=\(reason, privacy: .public) alwaysOnTop=\(alwaysOnTop) standardControlsVisible=\(standardControlsVisible) titled=\(window.styleMask.contains(.titled)) fullSizeContent=\(window.styleMask.contains(.fullSizeContentView)) toolbarHidden=\(!(window.toolbar?.isVisible ?? true)) closeHidden=\(window.standardWindowButton(.closeButton)?.isHidden ?? true) miniaturizeHidden=\(window.standardWindowButton(.miniaturizeButton)?.isHidden ?? true) zoomHidden=\(window.standardWindowButton(.zoomButton)?.isHidden ?? true) titlebarTransparent=\(window.titlebarAppearsTransparent) separatorStyle=\(String(describing: window.titlebarSeparatorStyle), privacy: .public) windowOpaque=\(window.isOpaque) windowLevel=\(window.level.rawValue) contentLayer=\(window.contentView?.layer != nil) frameLayer=\(window.contentView?.superview?.layer != nil)")
    }

    private static func currentAlwaysOnTopSetting() -> Bool {
        UserDefaults.standard.bool(forKey: AppSettings.Keys.alwaysOnTop)
    }

    private static func applyTransparentFrameSubviews(for window: NSWindow, reason: String) {
        guard let frameView = window.contentView?.superview else {
            SpecchioLogger.easyMode.info("[SpecchioPresentationWindowChrome] frame subviews skipped reason=\(reason, privacy: .public) branch=no-frame-view")
            return
        }

        for (index, subview) in frameView.subviews.enumerated() where subview !== window.contentView {
            applyTransparentBacking(
                to: subview,
                reason: reason,
                source: "frameSubview\(index)-\(String(describing: type(of: subview)))"
            )
        }
    }

    private static func applyTransparentBacking(to view: NSView?, reason: String, source: String) {
        guard let view else {
            SpecchioLogger.easyMode.info("[SpecchioPresentationWindowChrome] backing skipped reason=\(reason, privacy: .public) source=\(source, privacy: .public) branch=no-view")
            return
        }

        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.isOpaque = false
        SpecchioLogger.easyMode.debug("[SpecchioPresentationWindowChrome] backing clear reason=\(reason, privacy: .public) source=\(source, privacy: .public) viewClass=\(String(describing: type(of: view)), privacy: .public) wantsLayer=\(view.wantsLayer) hasLayer=\(view.layer != nil)")
    }
}

struct SpecchioWindowChromeModifier: ViewModifier {
    let aspectPolicy: SpecchioWindowAspectPolicy
    var chromeStyle: SpecchioWindowChromeStyle = .standard
    var alwaysOnTop = false
    var presentationStandardControlsVisible = false

    func body(content: Content) -> some View {
        toolbarStyledContent(content)
            .frame(minWidth: 300, idealWidth: aspectPolicy.idealWidth)
            .background(SpecchioWindowAccessor(
                aspectPolicy: aspectPolicy,
                chromeStyle: chromeStyle,
                alwaysOnTop: alwaysOnTop,
                presentationStandardControlsVisible: presentationStandardControlsVisible
            ))
    }

    @ViewBuilder
    private func toolbarStyledContent(_ content: Content) -> some View {
        switch chromeStyle {
        case .standard:
            content.modifier(SpecchioToolbarBackgroundModifier())
        case .iPhoneMirroringPresentation:
            content
        }
    }
}

struct SpecchioToolbarBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
                .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
        } else if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        } else {
            content
        }
    }
}

struct SpecchioWindowAccessor: NSViewRepresentable {
    let aspectPolicy: SpecchioWindowAspectPolicy
    let chromeStyle: SpecchioWindowChromeStyle
    let alwaysOnTop: Bool
    let presentationStandardControlsVisible: Bool

    final class AspectRatioView: NSView {
        var aspectPolicy: SpecchioWindowAspectPolicy = .disabled {
            didSet {
                if aspectPolicy == .disabled {
                    cancelScheduledResize(reason: "policy-disabled")
                }
            }
        }
        var chromeStyle: SpecchioWindowChromeStyle = .standard
        var alwaysOnTop = false
        var presentationStandardControlsVisible = false
        private var isAdjusting = false
        private var pendingContentWidth: CGFloat?
        private var isResizeScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow(reason: "viewDidMoveToWindow")
        }

        override func layout() {
            super.layout()
            enforceAspectRatio(for: window, reason: "layout")
        }

        func configureWindow(reason: String) {
            guard let window else {
                SpecchioLogger.easyMode.info("[SpecchioWindowChrome] configure skipped reason=\(reason) branch=no-window")
                return
            }

            window.backgroundColor = .clear
            window.isOpaque = false
            window.titlebarAppearsTransparent = true
            window.hasShadow = true
            applyChromeStyle(to: window, reason: reason)
            SpecchioLogger.easyMode.info("[SpecchioWindowChrome] configured reason=\(reason) policy=\(self.aspectPolicy.logDescription, privacy: .public) chromeStyle=\(self.chromeStyle.logName, privacy: .public) alwaysOnTop=\(self.alwaysOnTop) presentationStandardControlsVisible=\(self.presentationStandardControlsVisible) toolbarPresent=\(window.toolbar != nil) toolbarVisible=\(window.toolbar?.isVisible ?? false) boundsWidth=\(self.bounds.width) boundsHeight=\(self.bounds.height)")

            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResizeNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResize(_:)),
                name: NSWindow.didResizeNotification,
                object: window
            )
            enforceAspectRatio(for: window, reason: reason)
        }

        @objc private func windowDidResize(_ note: Notification) {
            guard let window = note.object as? NSWindow else { return }
            enforceAspectRatio(for: window, reason: "windowDidResize")
        }

        func enforceAspectRatio(for window: NSWindow?, reason: String) {
            guard !isAdjusting, let window else {
                SpecchioLogger.easyMode.info("[SpecchioWindowChrome] aspect skipped reason=\(reason) adjusting=\(self.isAdjusting) hasWindow=\(window != nil)")
                return
            }

            let contentRect = window.contentRect(forFrameRect: window.frame)
            let rawExpectedWidth: CGFloat
            let driverHeight: CGFloat
            let ratio: CGFloat
            let policyName: String

            switch aspectPolicy {
            case .disabled:
                cancelScheduledResize(reason: reason)
                SpecchioLogger.easyMode.debug("[SpecchioWindowChrome] aspect skipped reason=\(reason) branch=disabled boundsWidth=\(self.bounds.width) boundsHeight=\(self.bounds.height) contentWidth=\(contentRect.width) contentHeight=\(contentRect.height)")
                return
            case .contentAspect(let aspectSize):
                guard aspectSize.height > 0 else {
                    SpecchioLogger.easyMode.info("[SpecchioWindowChrome] aspect skipped reason=\(reason) branch=invalid-height height=\(aspectSize.height)")
                    return
                }

                policyName = "contentAspect"
                ratio = aspectSize.width / aspectSize.height
                driverHeight = contentRect.height
                rawExpectedWidth = driverHeight * ratio
            case .visibleContentPhoneSurface(let phoneSize, let reservedTopHeight):
                guard phoneSize.height > 0 else {
                    SpecchioLogger.easyMode.info("[SpecchioWindowChrome] aspect skipped reason=\(reason) branch=invalid-phone-height phoneHeight=\(phoneSize.height)")
                    return
                }

                let visibleHeight = bounds.height > 0 ? bounds.height : contentRect.height
                policyName = "visibleContentPhoneSurface"
                ratio = phoneSize.width / phoneSize.height
                driverHeight = max(visibleHeight - reservedTopHeight, 0)
                rawExpectedWidth = driverHeight * ratio
            }

            let minimumContentWidth = minimumContentWidth(for: window)
            let expectedWidth = max(rawExpectedWidth, minimumContentWidth)
            guard abs(contentRect.width - expectedWidth) > 1 else {
                SpecchioLogger.easyMode.debug("[SpecchioWindowChrome] aspect unchanged reason=\(reason) policy=\(policyName, privacy: .public) ratio=\(ratio) driverHeight=\(driverHeight) contentWidth=\(contentRect.width) contentHeight=\(contentRect.height) boundsWidth=\(self.bounds.width) boundsHeight=\(self.bounds.height) rawExpectedWidth=\(rawExpectedWidth) minimumContentWidth=\(minimumContentWidth) expectedWidth=\(expectedWidth)")
                return
            }

            SpecchioLogger.easyMode.info("[SpecchioWindowChrome] scheduling aspect reason=\(reason) policy=\(policyName, privacy: .public) ratio=\(ratio) driverHeight=\(driverHeight) contentWidth=\(contentRect.width) contentHeight=\(contentRect.height) boundsWidth=\(self.bounds.width) boundsHeight=\(self.bounds.height) rawExpectedWidth=\(rawExpectedWidth) minimumContentWidth=\(minimumContentWidth) expectedWidth=\(expectedWidth)")
            scheduleContentWidth(expectedWidth, contentHeight: contentRect.height, reason: reason, policyName: policyName)
        }

        private func minimumContentWidth(for window: NSWindow) -> CGFloat {
            let contentMinWidth = window.contentMinSize.width.isFinite ? window.contentMinSize.width : 0
            let frameMinWidth = window.minSize.width.isFinite ? window.minSize.width : 0
            let frameDerivedContentWidth = frameMinWidth > 0
                ? window.contentRect(forFrameRect: CGRect(origin: .zero, size: window.minSize)).width
                : 0
            let minimumWidth = max(contentMinWidth, frameDerivedContentWidth, 0)
            SpecchioLogger.easyMode.debug("[SpecchioWindowChrome] minimum content width contentMinWidth=\(contentMinWidth) frameMinWidth=\(frameMinWidth) frameDerivedContentWidth=\(frameDerivedContentWidth) minimumWidth=\(minimumWidth)")
            return minimumWidth
        }

        private func scheduleContentWidth(_ expectedWidth: CGFloat, contentHeight: CGFloat, reason: String, policyName: String) {
            pendingContentWidth = expectedWidth
            guard !isResizeScheduled else {
                SpecchioLogger.easyMode.debug("[SpecchioWindowChrome] resize coalesced reason=\(reason) policy=\(policyName, privacy: .public) expectedWidth=\(expectedWidth)")
                return
            }

            isResizeScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isResizeScheduled = false
                guard self.aspectPolicy != .disabled else {
                    self.pendingContentWidth = nil
                    SpecchioLogger.easyMode.info("[SpecchioWindowChrome] resize skipped reason=\(reason) policy=\(policyName, privacy: .public) branch=policy-disabled")
                    return
                }
                guard let expectedWidth = self.pendingContentWidth else {
                    SpecchioLogger.easyMode.info("[SpecchioWindowChrome] resize skipped reason=\(reason) policy=\(policyName, privacy: .public) branch=no-pending-width")
                    return
                }
                self.pendingContentWidth = nil
                guard !self.isAdjusting, let window = self.window else {
                    SpecchioLogger.easyMode.info("[SpecchioWindowChrome] resize skipped reason=\(reason) policy=\(policyName, privacy: .public) adjusting=\(self.isAdjusting) hasWindow=\(self.window != nil)")
                    return
                }

                let contentRect = window.contentRect(forFrameRect: window.frame)
                guard abs(contentRect.width - expectedWidth) > 1 else {
                    SpecchioLogger.easyMode.debug("[SpecchioWindowChrome] resize skipped reason=\(reason) policy=\(policyName, privacy: .public) branch=already-matched contentWidth=\(contentRect.width) contentHeight=\(contentRect.height) expectedWidth=\(expectedWidth)")
                    return
                }

                SpecchioLogger.easyMode.info("[SpecchioWindowChrome] applying aspect reason=\(reason) policy=\(policyName, privacy: .public) contentWidth=\(contentRect.width) contentHeight=\(contentRect.height) expectedWidth=\(expectedWidth)")
                let targetHeight = contentRect.height > 0 ? contentRect.height : contentHeight
                self.isAdjusting = true
                defer { self.isAdjusting = false }
                window.setContentSize(NSSize(width: expectedWidth, height: targetHeight))
                let immediateContentRect = window.contentRect(forFrameRect: window.frame)
                SpecchioLogger.easyMode.info("[SpecchioWindowChrome] postResizeImmediate reason=\(reason) policy=\(policyName, privacy: .public) contentWidth=\(immediateContentRect.width) contentHeight=\(immediateContentRect.height) expectedWidth=\(expectedWidth) accepted=\(abs(immediateContentRect.width - expectedWidth) <= 1)")
            }
        }

        private func cancelScheduledResize(reason: String) {
            guard pendingContentWidth != nil || isResizeScheduled else { return }
            pendingContentWidth = nil
            SpecchioLogger.easyMode.info("[SpecchioWindowChrome] pending aspect resize cancelled reason=\(reason)")
        }

        private func applyChromeStyle(to window: NSWindow, reason: String) {
            let targetLevel: NSWindow.Level = alwaysOnTop ? .floating : .normal
            switch chromeStyle {
            case .standard:
                window.level = targetLevel
                window.toolbar?.isVisible = true
                window.toolbar?.sizeMode = .small
                window.standardWindowButton(.closeButton)?.isHidden = false
                window.standardWindowButton(.miniaturizeButton)?.isHidden = false
                window.standardWindowButton(.zoomButton)?.isHidden = false
                window.isMovableByWindowBackground = false
                SpecchioLogger.easyMode.info("[SpecchioWindowChrome] style branch=standard reason=\(reason, privacy: .public) alwaysOnTop=\(self.alwaysOnTop) titled=\(window.styleMask.contains(.titled)) toolbarVisible=\(window.toolbar?.isVisible ?? false) closeHidden=\(window.standardWindowButton(.closeButton)?.isHidden ?? true) miniaturizeHidden=\(window.standardWindowButton(.miniaturizeButton)?.isHidden ?? true) zoomHidden=\(window.standardWindowButton(.zoomButton)?.isHidden ?? true) fullSizeContent=\(window.styleMask.contains(.fullSizeContentView)) windowLevel=\(window.level.rawValue)")
            case .iPhoneMirroringPresentation:
                SpecchioPresentationWindowChrome.apply(
                    to: window,
                    reason: "SpecchioWindowChrome-\(reason)",
                    alwaysOnTop: alwaysOnTop,
                    standardControlsVisible: presentationStandardControlsVisible
                )
                SpecchioLogger.easyMode.info("[SpecchioWindowChrome] style branch=iPhoneMirroringPresentation reason=\(reason, privacy: .public) alwaysOnTop=\(self.alwaysOnTop) presentationStandardControlsVisible=\(self.presentationStandardControlsVisible) titled=\(window.styleMask.contains(.titled)) toolbarHidden=\(!(window.toolbar?.isVisible ?? true)) fullSizeContent=\(window.styleMask.contains(.fullSizeContentView)) closeHidden=\(window.standardWindowButton(.closeButton)?.isHidden ?? true) miniaturizeHidden=\(window.standardWindowButton(.miniaturizeButton)?.isHidden ?? true) zoomHidden=\(window.standardWindowButton(.zoomButton)?.isHidden ?? true) hasShadow=\(window.hasShadow) transparentPanelBacking=\(!window.isOpaque) windowLevel=\(window.level.rawValue)")
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }

    func makeNSView(context: Context) -> AspectRatioView {
        let view = AspectRatioView()
        view.aspectPolicy = aspectPolicy
        view.chromeStyle = chromeStyle
        view.alwaysOnTop = alwaysOnTop
        view.presentationStandardControlsVisible = presentationStandardControlsVisible
        return view
    }

    func updateNSView(_ nsView: AspectRatioView, context: Context) {
        nsView.aspectPolicy = aspectPolicy
        nsView.chromeStyle = chromeStyle
        nsView.alwaysOnTop = alwaysOnTop
        nsView.presentationStandardControlsVisible = presentationStandardControlsVisible
        nsView.configureWindow(reason: "updateNSView")
    }
}
