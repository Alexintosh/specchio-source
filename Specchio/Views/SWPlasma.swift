//
//  SWPlasma.swift
//  Specchio
//
//  ShipSwift source observed: https://github.com/signerlabs/ShipSwift
//
//  MIT License
//
//  Copyright (c) 2026 SignerLabs
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//
//  ShipSwift's original SWPlasma is a SwiftUI Metal shader. This Specchio
//  version keeps the same public shape and button application pattern, but uses
//  Core Animation gradients so the compositor owns the motion instead of a
//  SwiftUI per-frame CPU renderer.
//

import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
import QuartzCore
#endif

extension Color {
    static func specchioPlasmaRGB(_ rgb: UInt32) -> Color {
        Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

enum SWPlasmaStyle: String, CaseIterable, Identifiable {
    case solar
    case prism
    case spectrum
    case ember
    case lilac

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .solar:
            return "Solar"
        case .prism:
            return "Prism"
        case .spectrum:
            return "Spectrum"
        case .ember:
            return "Ember"
        case .lilac:
            return "Lilac"
        }
    }

    var defaultPalette: [Color] {
        switch self {
        case .solar:
            return [
                Color(red: 0.102, green: 0.020, blue: 0.0),
                Color(red: 0.353, green: 0.071, blue: 0.031),
                Color(red: 0.769, green: 0.290, blue: 0.125),
                Color(red: 0.941, green: 0.541, blue: 0.227),
                Color(red: 1.0, green: 0.773, blue: 0.478),
            ]
        case .prism:
            return [
                Color(red: 0.102, green: 0.0, blue: 0.2),
                Color(red: 0.478, green: 0.122, blue: 0.722),
                Color(red: 1.0, green: 0.078, blue: 0.576),
                Color(red: 1.0, green: 0.839, blue: 0.0),
                Color(red: 0.0, green: 0.898, blue: 1.0),
            ]
        case .spectrum:
            return [
                Color(red: 0.0, green: 0.102, blue: 0.4),
                Color(red: 0.231, green: 0.0, blue: 0.510),
                Color(red: 0.416, green: 0.051, blue: 0.678),
                Color(red: 0.780, green: 0.082, blue: 0.522),
                Color(red: 1.0, green: 0.549, blue: 0.180),
            ]
        case .ember:
            return [
                Color(red: 0.020, green: 0.0, blue: 0.0),
                Color(red: 0.290, green: 0.055, blue: 0.0),
                Color(red: 0.769, green: 0.290, blue: 0.039),
                Color(red: 1.0, green: 0.659, blue: 0.180),
                Color(red: 1.0, green: 0.878, blue: 0.541),
            ]
        case .lilac:
            return [
                Color(red: 0.165, green: 0.039, blue: 0.290),
                Color(red: 0.420, green: 0.310, blue: 0.627),
                Color(red: 0.769, green: 0.600, blue: 0.851),
                Color(red: 0.961, green: 0.776, blue: 0.878),
                Color(red: 1.0, green: 0.933, blue: 0.933),
            ]
        }
    }

    var blobCount: Int {
        switch self {
        case .solar, .ember, .lilac:
            return 8
        case .prism:
            return 10
        case .spectrum:
            return 12
        }
    }

    var speed: Double {
        switch self {
        case .solar:
            return 0.42
        case .prism:
            return 0.62
        case .spectrum:
            return 0.55
        case .ember:
            return 0.35
        case .lilac:
            return 0.28
        }
    }
}

struct SWPlasma: View {
    var style: SWPlasmaStyle
    var c1: Color
    var c2: Color
    var c3: Color
    var c4: Color
    var c5: Color
    var scale: Float
    var intensity: Float
    var distortion: Float
    var showsControls: Bool
    var debugName: String

    init(
        style: SWPlasmaStyle = .solar,
        c1: Color? = nil,
        c2: Color? = nil,
        c3: Color? = nil,
        c4: Color? = nil,
        c5: Color? = nil,
        scale: Float = 1.0,
        intensity: Float = 1.0,
        distortion: Float = 1.0,
        showsControls: Bool = false,
        debugName: String = "SWPlasma"
    ) {
        self.style = style
        let palette = style.defaultPalette
        self.c1 = c1 ?? palette[0]
        self.c2 = c2 ?? palette[1]
        self.c3 = c3 ?? palette[2]
        self.c4 = c4 ?? palette[3]
        self.c5 = c5 ?? palette[4]
        self.scale = scale
        self.intensity = intensity
        self.distortion = distortion
        self.showsControls = showsControls
        self.debugName = debugName
    }

    var body: some View {
        Group {
            if showsControls {
                SWPlasmaControlled(initial: self)
                    .onAppear {
                        SpecchioLogger.easyMode.info("[SWPlasma] branch=controlled name=\(debugName, privacy: .public) style=\(style.rawValue, privacy: .public) renderer=CoreAnimation")
                    }
            } else {
                SWPlasmaRenderer(
                    style: style,
                    palette: [c1, c2, c3, c4, c5],
                    scale: scale,
                    intensity: intensity,
                    distortion: distortion,
                    debugName: debugName
                )
                .onAppear {
                    SpecchioLogger.easyMode.info("[SWPlasma] branch=renderer name=\(debugName, privacy: .public) style=\(style.rawValue, privacy: .public) renderer=CoreAnimation")
                }
            }
        }
    }
}

private struct SWPlasmaRenderer: NSViewRepresentable {
    let style: SWPlasmaStyle
    let palette: [Color]
    let scale: Float
    let intensity: Float
    let distortion: Float
    let debugName: String

    func makeNSView(context: Context) -> SWPlasmaLayerView {
        SpecchioLogger.easyMode.info("[SWPlasmaRenderer] makeNSView name=\(debugName, privacy: .public) style=\(style.rawValue, privacy: .public) renderer=CoreAnimation reason=replace-cpu-canvas")
        let view = SWPlasmaLayerView()
        view.configure(configuration, reason: "makeNSView")
        return view
    }

    func updateNSView(_ nsView: SWPlasmaLayerView, context: Context) {
        nsView.configure(configuration, reason: "updateNSView")
    }

    static func dismantleNSView(_ nsView: SWPlasmaLayerView, coordinator: ()) {
        nsView.stopAnimations(reason: "dismantleNSView")
    }

    private var configuration: SWPlasmaLayerConfiguration {
        SWPlasmaLayerConfiguration(
            style: style,
            palette: palette.map(PlasmaRGB.init),
            scale: scale,
            intensity: intensity,
            distortion: distortion,
            debugName: debugName
        )
    }
}

private struct SWPlasmaLayerConfiguration: Equatable {
    let style: SWPlasmaStyle
    let palette: [PlasmaRGB]
    let scale: Float
    let intensity: Float
    let distortion: Float
    let debugName: String
}

private enum SWPlasmaLayerMetrics {
    static let baseAnimationSeconds: Double = 10
    static let radialAnimationSeconds: Double = 7
    static let radialDiameterMultiplier: CGFloat = 1.6
    static let secondaryRadialDiameterMultiplier: CGFloat = 1.15
    static let minimumDuration: Double = 2
    static let primaryGlowOpacity: Double = 0.72
    static let secondaryGlowOpacity: Double = 0.46
    static let backgroundOpacity: Double = 1.0
}

private final class SWPlasmaLayerView: NSView {
    private let backgroundLayer = CAGradientLayer()
    private let primaryGlowLayer = CAGradientLayer()
    private let secondaryGlowLayer = CAGradientLayer()

    private var currentConfiguration: SWPlasmaLayerConfiguration?
    private var lastLayoutSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureRootLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureRootLayer()
    }

    func configure(_ configuration: SWPlasmaLayerConfiguration, reason: String) {
        SpecchioLogger.easyMode.info("[SWPlasmaLayer] configure requested reason=\(reason, privacy: .public) name=\(configuration.debugName, privacy: .public) style=\(configuration.style.rawValue, privacy: .public) renderer=CoreAnimation paletteCount=\(configuration.palette.count) hasWindow=\(self.window != nil)")

        installGradientLayersIfNeeded(reason: reason, configuration: configuration)

        guard self.currentConfiguration != configuration else {
            SpecchioLogger.easyMode.info("[SWPlasmaLayer] configure skipped reason=\(reason, privacy: .public) branch=unchanged name=\(configuration.debugName, privacy: .public)")
            return
        }

        SpecchioLogger.easyMode.info("[SWPlasmaLayer] configure branch=apply reason=\(reason, privacy: .public) name=\(configuration.debugName, privacy: .public) previousStyle=\(self.currentConfiguration?.style.rawValue ?? "none", privacy: .public) nextStyle=\(configuration.style.rawValue, privacy: .public)")
        self.currentConfiguration = configuration
        applyStaticGradientState(configuration: configuration, reason: reason)
        updateGradientFrames(reason: reason)
        restartAnimations(reason: reason)
    }

    func stopAnimations(reason: String) {
        SpecchioLogger.easyMode.info("[SWPlasmaLayer] stopAnimations reason=\(reason, privacy: .public) name=\(self.currentConfiguration?.debugName ?? "unknown", privacy: .public)")
        backgroundLayer.removeAllAnimations()
        primaryGlowLayer.removeAllAnimations()
        secondaryGlowLayer.removeAllAnimations()
    }

    override func layout() {
        super.layout()
        updateGradientFrames(reason: "layout")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard let configuration = self.currentConfiguration else {
            SpecchioLogger.easyMode.info("[SWPlasmaLayer] window move skipped branch=no-configuration hasWindow=\(self.window != nil)")
            return
        }

        if window == nil {
            SpecchioLogger.easyMode.info("[SWPlasmaLayer] window move branch=detached name=\(configuration.debugName, privacy: .public)")
            stopAnimations(reason: "window detached")
        } else {
            SpecchioLogger.easyMode.info("[SWPlasmaLayer] window move branch=attached name=\(configuration.debugName, privacy: .public)")
            restartAnimations(reason: "window attached")
        }
    }

    private func configureRootLayer() {
        wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.masksToBounds = false
        rootLayer.backgroundColor = NSColor.clear.cgColor
        layer = rootLayer
        SpecchioLogger.easyMode.info("[SWPlasmaLayer] root layer configured renderer=CoreAnimation")
    }

    private func installGradientLayersIfNeeded(reason: String, configuration: SWPlasmaLayerConfiguration) {
        guard backgroundLayer.superlayer == nil else {
            SpecchioLogger.easyMode.info("[SWPlasmaLayer] install skipped reason=\(reason, privacy: .public) branch=already-installed name=\(configuration.debugName, privacy: .public)")
            return
        }

        guard let layer else {
            SpecchioLogger.easyMode.error("[SWPlasmaLayer] install failed reason=\(reason, privacy: .public) branch=no-root-layer name=\(configuration.debugName, privacy: .public)")
            return
        }

        SpecchioLogger.easyMode.info("[SWPlasmaLayer] install branch=add-gradient-layers reason=\(reason, privacy: .public) name=\(configuration.debugName, privacy: .public)")
        backgroundLayer.type = .axial
        primaryGlowLayer.type = .radial
        secondaryGlowLayer.type = .radial

        backgroundLayer.opacity = Float(SWPlasmaLayerMetrics.backgroundOpacity)
        primaryGlowLayer.opacity = Float(SWPlasmaLayerMetrics.primaryGlowOpacity)
        secondaryGlowLayer.opacity = Float(SWPlasmaLayerMetrics.secondaryGlowOpacity)

        layer.addSublayer(backgroundLayer)
        layer.addSublayer(primaryGlowLayer)
        layer.addSublayer(secondaryGlowLayer)
    }

    private func applyStaticGradientState(configuration: SWPlasmaLayerConfiguration, reason: String) {
        let palette = sanitizedPalette(configuration.palette)
        let colors = palette.map { $0.cgColor(alpha: 1) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        backgroundLayer.colors = colors
        backgroundLayer.locations = evenlySpacedLocations(count: colors.count)
        backgroundLayer.startPoint = CGPoint(x: 0, y: 0.45)
        backgroundLayer.endPoint = CGPoint(x: 1, y: 0.55)

        primaryGlowLayer.colors = [
            palette[3].cgColor(alpha: clamped01(0.95 * Double(configuration.intensity))),
            palette[2].cgColor(alpha: clamped01(0.58 * Double(configuration.intensity))),
            palette[1].cgColor(alpha: 0)
        ]
        primaryGlowLayer.locations = [0, 0.42, 1]
        primaryGlowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        primaryGlowLayer.endPoint = CGPoint(x: 1, y: 1)

        secondaryGlowLayer.colors = [
            palette[4].cgColor(alpha: clamped01(0.66 * Double(configuration.intensity))),
            palette[0].cgColor(alpha: clamped01(0.32 * Double(configuration.intensity))),
            palette[0].cgColor(alpha: 0)
        ]
        secondaryGlowLayer.locations = [0, 0.48, 1]
        secondaryGlowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        secondaryGlowLayer.endPoint = CGPoint(x: 1, y: 1)

        CATransaction.commit()

        SpecchioLogger.easyMode.info("[SWPlasmaLayer] static state applied reason=\(reason, privacy: .public) name=\(configuration.debugName, privacy: .public) renderer=CoreAnimation colorCount=\(colors.count)")
    }

    private func updateGradientFrames(reason: String) {
        let size = bounds.size

        guard size.width > 0, size.height > 0 else {
            SpecchioLogger.easyMode.info("[SWPlasmaLayer] layout skipped reason=\(reason, privacy: .public) branch=empty-bounds width=\(size.width) height=\(size.height) name=\(self.currentConfiguration?.debugName ?? "unknown", privacy: .public)")
            return
        }

        guard size != lastLayoutSize else {
            return
        }

        lastLayoutSize = size
        let boundsRect = CGRect(origin: .zero, size: size)
        let primaryDiameter = max(size.width, size.height) * SWPlasmaLayerMetrics.radialDiameterMultiplier
        let secondaryDiameter = max(size.width, size.height) * SWPlasmaLayerMetrics.secondaryRadialDiameterMultiplier

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = boundsRect
        primaryGlowLayer.bounds = CGRect(x: 0, y: 0, width: primaryDiameter, height: primaryDiameter)
        primaryGlowLayer.position = CGPoint(x: boundsRect.midX, y: boundsRect.midY)
        secondaryGlowLayer.bounds = CGRect(x: 0, y: 0, width: secondaryDiameter, height: secondaryDiameter)
        secondaryGlowLayer.position = CGPoint(x: boundsRect.midX, y: boundsRect.midY)
        CATransaction.commit()

        SpecchioLogger.easyMode.info("[SWPlasmaLayer] layout branch=frames-applied reason=\(reason, privacy: .public) name=\(self.currentConfiguration?.debugName ?? "unknown", privacy: .public) width=\(size.width) height=\(size.height) primaryDiameter=\(primaryDiameter) secondaryDiameter=\(secondaryDiameter)")

        if self.currentConfiguration != nil {
            restartAnimations(reason: "bounds changed")
        }
    }

    private func restartAnimations(reason: String) {
        guard let configuration = self.currentConfiguration else {
            SpecchioLogger.easyMode.info("[SWPlasmaLayer] animation skipped reason=\(reason, privacy: .public) branch=no-configuration")
            return
        }

        let size = bounds.size
        guard size.width > 0, size.height > 0 else {
            SpecchioLogger.easyMode.info("[SWPlasmaLayer] animation skipped reason=\(reason, privacy: .public) branch=empty-bounds name=\(configuration.debugName, privacy: .public) width=\(size.width) height=\(size.height)")
            return
        }

        let palette = sanitizedPalette(configuration.palette)
        let speed = max(Double(configuration.style.speed) * Double(configuration.scale), 0.1)
        let baseDuration = max(SWPlasmaLayerMetrics.baseAnimationSeconds / speed, SWPlasmaLayerMetrics.minimumDuration)
        let radialDuration = max(SWPlasmaLayerMetrics.radialAnimationSeconds / speed, SWPlasmaLayerMetrics.minimumDuration)

        stopAnimations(reason: "restart \(reason)")
        addColorAnimation(to: backgroundLayer, palette: palette, duration: baseDuration)
        addPointAnimation(to: backgroundLayer, keyPath: "startPoint", values: [
            CGPoint(x: 0, y: 0.45),
            CGPoint(x: 0.18, y: 0),
            CGPoint(x: 0, y: 0.65),
            CGPoint(x: 0, y: 0.45)
        ], duration: baseDuration)
        addPointAnimation(to: backgroundLayer, keyPath: "endPoint", values: [
            CGPoint(x: 1, y: 0.55),
            CGPoint(x: 0.82, y: 1),
            CGPoint(x: 1, y: 0.35),
            CGPoint(x: 1, y: 0.55)
        ], duration: baseDuration)
        addPositionAnimation(to: primaryGlowLayer, values: primaryMotionPoints(in: bounds), duration: radialDuration)
        addPositionAnimation(to: secondaryGlowLayer, values: secondaryMotionPoints(in: bounds), duration: radialDuration * 1.3)
        addOpacityPulse(to: primaryGlowLayer, duration: radialDuration * 0.7, from: 0.42, to: SWPlasmaLayerMetrics.primaryGlowOpacity)
        addOpacityPulse(to: secondaryGlowLayer, duration: radialDuration * 0.9, from: 0.28, to: SWPlasmaLayerMetrics.secondaryGlowOpacity)

        SpecchioLogger.easyMode.info("[SWPlasmaLayer] animation branch=started reason=\(reason, privacy: .public) name=\(configuration.debugName, privacy: .public) renderer=CoreAnimation baseDuration=\(baseDuration) radialDuration=\(radialDuration)")
    }

    private func addColorAnimation(to layer: CAGradientLayer, palette: [PlasmaRGB], duration: Double) {
        let animation = CAKeyframeAnimation(keyPath: "colors")
        animation.values = rotatedPalettes(from: palette).map { colors in
            colors.map { $0.cgColor(alpha: 1) }
        }
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "specchio.plasma.colors")
    }

    private func addPointAnimation(to layer: CAGradientLayer, keyPath: String, values: [CGPoint], duration: Double) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values.map { NSValue(point: $0) }
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "specchio.plasma.\(keyPath)")
    }

    private func addPositionAnimation(to layer: CAGradientLayer, values: [CGPoint], duration: Double) {
        let animation = CAKeyframeAnimation(keyPath: "position")
        animation.values = values.map { NSValue(point: $0) }
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.calculationMode = .paced
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "specchio.plasma.position")
    }

    private func addOpacityPulse(to layer: CAGradientLayer, duration: Double, from: Double, to: Double) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "specchio.plasma.opacity")
    }

    private func primaryMotionPoints(in bounds: CGRect) -> [CGPoint] {
        [
            CGPoint(x: bounds.minX + bounds.width * 0.18, y: bounds.midY),
            CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.18),
            CGPoint(x: bounds.maxX - bounds.width * 0.12, y: bounds.midY),
            CGPoint(x: bounds.midX, y: bounds.maxY - bounds.height * 0.16),
            CGPoint(x: bounds.minX + bounds.width * 0.18, y: bounds.midY)
        ]
    }

    private func secondaryMotionPoints(in bounds: CGRect) -> [CGPoint] {
        [
            CGPoint(x: bounds.maxX - bounds.width * 0.22, y: bounds.maxY - bounds.height * 0.25),
            CGPoint(x: bounds.midX, y: bounds.midY),
            CGPoint(x: bounds.minX + bounds.width * 0.12, y: bounds.minY + bounds.height * 0.22),
            CGPoint(x: bounds.maxX - bounds.width * 0.22, y: bounds.maxY - bounds.height * 0.25)
        ]
    }

    private func rotatedPalettes(from palette: [PlasmaRGB]) -> [[PlasmaRGB]] {
        guard !palette.isEmpty else {
            return []
        }

        return palette.indices.map { index in
            Array(palette[index...]) + Array(palette[..<index])
        } + [palette]
    }

    private func sanitizedPalette(_ palette: [PlasmaRGB]) -> [PlasmaRGB] {
        if palette.count >= 5 {
            return Array(palette.prefix(5))
        }

        let fallback = SWPlasmaStyle.prism.defaultPalette.map(PlasmaRGB.init)
        let merged = palette + fallback
        return Array(merged.prefix(5))
    }

    private func evenlySpacedLocations(count: Int) -> [NSNumber] {
        guard count > 1 else {
            return [0]
        }

        return (0..<count).map { index in
            NSNumber(value: Double(index) / Double(count - 1))
        }
    }
}

private struct PlasmaPoint {
    var x: Double
    var y: Double

    static func + (lhs: PlasmaPoint, rhs: PlasmaPoint) -> PlasmaPoint {
        PlasmaPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func * (lhs: PlasmaPoint, rhs: Double) -> PlasmaPoint {
        PlasmaPoint(x: lhs.x * rhs, y: lhs.y * rhs)
    }
}

private struct PlasmaRGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ color: Color) {
        #if canImport(AppKit)
        if let resolved = NSColor(color).usingColorSpace(.sRGB) {
            r = Double(resolved.redComponent)
            g = Double(resolved.greenComponent)
            b = Double(resolved.blueComponent)
            return
        }
        #endif

        r = 0.5
        g = 0.5
        b = 0.5
    }

    var swiftUIColor: Color {
        Color(red: clamped01(r), green: clamped01(g), blue: clamped01(b))
    }

    func cgColor(alpha: Double) -> CGColor {
        NSColor(
            srgbRed: clamped01(r),
            green: clamped01(g),
            blue: clamped01(b),
            alpha: clamped01(alpha)
        ).cgColor
    }

    func adding(_ value: Double) -> PlasmaRGB {
        PlasmaRGB(r: r + value, g: g + value, b: b + value)
    }

    func multiplied(by value: Double) -> PlasmaRGB {
        PlasmaRGB(r: r * value, g: g * value, b: b * value)
    }
}

private enum SWPlasmaShaderSampler {
    static func sample(
        style: SWPlasmaStyle,
        position: CGPoint,
        size: CGSize,
        time: TimeInterval,
        palette: [PlasmaRGB],
        scale: Double,
        intensity: Double,
        distortion: Double
    ) -> PlasmaRGB {
        let p = shaderPoint(position: position, size: size, scale: scale)

        switch style {
        case .solar:
            return solar(p: p, time: time, palette: palette, intensity: intensity, distortion: distortion)
        case .prism:
            return prism(p: p, time: time, palette: palette, intensity: intensity, distortion: distortion)
        case .spectrum:
            return spectrum(p: p, time: time, palette: palette, intensity: intensity, distortion: distortion)
        case .ember:
            return ember(p: shaderPoint(position: position, size: size, scale: scale * 1.3), time: time, palette: palette, intensity: intensity, distortion: distortion)
        case .lilac:
            return lilac(p: p, time: time, palette: palette, intensity: intensity, distortion: distortion)
        }
    }

    private static func shaderPoint(position: CGPoint, size: CGSize, scale: Double) -> PlasmaPoint {
        let width = max(1, Double(size.width))
        let height = max(1, Double(size.height))
        let aspect = width / height
        var point = PlasmaPoint(
            x: Double(position.x) / width - 0.5,
            y: Double(position.y) / height - 0.5
        )
        point.x *= aspect
        return point * scale
    }

    private static func solar(
        p: PlasmaPoint,
        time: TimeInterval,
        palette: [PlasmaRGB],
        intensity: Double,
        distortion: Double
    ) -> PlasmaRGB {
        var v = 0.0
        v += sin(p.x * 2.1 + time * 0.7)
        v += sin(p.y * 2.5 + time * 0.9)
        v += sin((p.x + p.y) * 1.4 + time * 0.5)
        v += fbm3(p * 2.0 + PlasmaPoint(x: time * 0.18, y: time * 0.18)) * distortion * 2.0
        v = clamped01((v + 4.0) * 0.125 * intensity)
        return paletteColor(v, palette).adding(pow(v, 4.0) * 0.4)
    }

    private static func prism(
        p: PlasmaPoint,
        time: TimeInterval,
        palette: [PlasmaRGB],
        intensity: Double,
        distortion: Double
    ) -> PlasmaRGB {
        let a = time * 0.3
        let d = PlasmaPoint(x: cos(a), y: sin(a))
        let v1 = prismValue(p: p + PlasmaPoint(x: 0.025, y: 0), direction: d, time: time, distortion: distortion)
        let v2 = prismValue(p: p, direction: d, time: time, distortion: distortion)
        let v3 = prismValue(p: p + PlasmaPoint(x: -0.025, y: 0), direction: d, time: time, distortion: distortion)
        let ca = paletteColor(v1 * 0.5 + 0.5, palette)
        let cb = paletteColor(v2 * 0.5 + 0.5, palette)
        let cc = paletteColor(v3 * 0.5 + 0.5, palette)
        return PlasmaRGB(r: ca.r, g: cb.g, b: cc.b).multiplied(by: intensity)
    }

    private static func spectrum(
        p: PlasmaPoint,
        time: TimeInterval,
        palette: [PlasmaRGB],
        intensity: Double,
        distortion: Double
    ) -> PlasmaRGB {
        let a = time * 0.22 + 1.57
        let d = PlasmaPoint(x: cos(a), y: sin(a))
        let v1 = spectrumValue(p: p + PlasmaPoint(x: 0, y: 0.045), direction: d, time: time, distortion: distortion)
        let v2 = spectrumValue(p: p, direction: d, time: time, distortion: distortion)
        let v3 = spectrumValue(p: p + PlasmaPoint(x: 0, y: -0.045), direction: d, time: time, distortion: distortion)
        let ca = paletteColor(v1 * 0.5 + 0.5, palette)
        let cb = paletteColor(v2 * 0.5 + 0.5, palette)
        let cc = paletteColor(v3 * 0.5 + 0.5, palette)
        return PlasmaRGB(r: ca.r, g: cb.g, b: cc.b).multiplied(by: intensity * 1.15)
    }

    private static func ember(
        p: PlasmaPoint,
        time: TimeInterval,
        palette: [PlasmaRGB],
        intensity: Double,
        distortion: Double
    ) -> PlasmaRGB {
        var v = 0.0
        v += sin(p.x * 2.5 + time * 0.6)
        v += sin(p.y * 3.0 + time * 0.8)
        v += sin(length(p) * 2.0 - time * 0.5)
        v += fbm3(p * 2.0 + PlasmaPoint(x: time * 0.18, y: time * 0.18)) * distortion * 3.0
        v = pow(clamped01((v + 4.0) * 0.125), 1.6) * intensity
        return paletteColor(v, palette).adding(pow(v, 6.0) * 0.55)
    }

    private static func lilac(
        p: PlasmaPoint,
        time: TimeInterval,
        palette: [PlasmaRGB],
        intensity: Double,
        distortion: Double
    ) -> PlasmaRGB {
        let t = time * 0.7
        let breath = 0.5 + 0.5 * sin(time * 0.5)
        var v = 0.0
        v += sin(p.x * 1.8 + t)
        v += sin(p.y * 2.2 + t * 1.1)
        v += sin((p.x + p.y) * 1.0 + t * 0.8)
        v += fbm3(p * 1.5 + PlasmaPoint(x: t * 0.15, y: t * 0.15)) * distortion * 2.0
        v = clamped01((v + 3.5) * 0.143 * intensity * (0.7 + 0.6 * breath))
        return paletteColor(v, palette).adding(pow(v, 4.0) * 0.35 * breath)
    }

    private static func prismValue(p: PlasmaPoint, direction: PlasmaPoint, time: TimeInterval, distortion: Double) -> Double {
        sin(dot(p, direction) * 3.0 + fbm2(p * 1.5) * distortion * 3.0 + time * 0.4)
    }

    private static func spectrumValue(p: PlasmaPoint, direction: PlasmaPoint, time: TimeInterval, distortion: Double) -> Double {
        sin(dot(p, direction) * 2.4 + fbm3(p * 1.3 + PlasmaPoint(x: time * 0.07, y: time * 0.07)) * distortion * 4.0 + time * 0.45)
    }

    private static func paletteColor(_ t: Double, _ palette: [PlasmaRGB]) -> PlasmaRGB {
        let c1 = palette[safe: 0] ?? PlasmaRGB(r: 0, g: 0, b: 0)
        let c2 = palette[safe: 1] ?? c1
        let c3 = palette[safe: 2] ?? c2
        let c4 = palette[safe: 3] ?? c3
        let c5 = palette[safe: 4] ?? c4
        let t = clamped01(t)

        if t < 0.25 {
            return mix(c1, c2, smoothstep(0.0, 0.25, t))
        }
        if t < 0.5 {
            return mix(c2, c3, smoothstep(0.25, 0.5, t))
        }
        if t < 0.75 {
            return mix(c3, c4, smoothstep(0.5, 0.75, t))
        }
        return mix(c4, c5, smoothstep(0.75, 1.0, t))
    }

    private static func fbm2(_ p: PlasmaPoint) -> Double {
        vNoise(p) * 0.6 + vNoise(p * 2.0) * 0.4 - 0.5
    }

    private static func fbm3(_ p: PlasmaPoint) -> Double {
        vNoise(p) * 0.5 + vNoise(p * 2.0) * 0.3 + vNoise(p * 4.0) * 0.2 - 0.5
    }

    private static func vNoise(_ p: PlasmaPoint) -> Double {
        let i = PlasmaPoint(x: floor(p.x), y: floor(p.y))
        let f = PlasmaPoint(x: fract(p.x), y: fract(p.y))
        let u = PlasmaPoint(
            x: f.x * f.x * (3.0 - 2.0 * f.x),
            y: f.y * f.y * (3.0 - 2.0 * f.y)
        )
        let a = hash(i)
        let b = hash(i + PlasmaPoint(x: 1.0, y: 0.0))
        let c = hash(i + PlasmaPoint(x: 0.0, y: 1.0))
        let d = hash(i + PlasmaPoint(x: 1.0, y: 1.0))
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y)
    }

    private static func hash(_ p: PlasmaPoint) -> Double {
        let px = dot(p, PlasmaPoint(x: 91.31, y: 47.79))
        let py = dot(p, PlasmaPoint(x: 31.07, y: 73.13))
        return fract(sin(px + py) * 19357.713)
    }

    private static func length(_ p: PlasmaPoint) -> Double {
        sqrt(p.x * p.x + p.y * p.y)
    }

    private static func dot(_ lhs: PlasmaPoint, _ rhs: PlasmaPoint) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private func mix(_ lhs: Double, _ rhs: Double, _ t: Double) -> Double {
    lhs + (rhs - lhs) * t
}

private func mix(_ lhs: PlasmaRGB, _ rhs: PlasmaRGB, _ t: Double) -> PlasmaRGB {
    PlasmaRGB(
        r: mix(lhs.r, rhs.r, t),
        g: mix(lhs.g, rhs.g, t),
        b: mix(lhs.b, rhs.b, t)
    )
}

private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = clamped01((x - edge0) / (edge1 - edge0))
    return t * t * (3.0 - 2.0 * t)
}

private func fract(_ value: Double) -> Double {
    value - floor(value)
}

private func clamped01(_ value: Double) -> Double {
    min(1.0, max(0.0, value))
}

private struct SWPlasmaControlled: View {
    @State private var style: SWPlasmaStyle
    @State private var c1: Color
    @State private var c2: Color
    @State private var c3: Color
    @State private var c4: Color
    @State private var c5: Color
    @State private var scale: Float
    @State private var intensity: Float
    @State private var distortion: Float
    @State private var showSheet = false

    let debugName: String

    init(initial: SWPlasma) {
        _style = State(initialValue: initial.style)
        _c1 = State(initialValue: initial.c1)
        _c2 = State(initialValue: initial.c2)
        _c3 = State(initialValue: initial.c3)
        _c4 = State(initialValue: initial.c4)
        _c5 = State(initialValue: initial.c5)
        _scale = State(initialValue: initial.scale)
        _intensity = State(initialValue: initial.intensity)
        _distortion = State(initialValue: initial.distortion)
        debugName = initial.debugName
    }

    private func makePlasma() -> SWPlasma {
        SWPlasma(
            style: style,
            c1: c1,
            c2: c2,
            c3: c3,
            c4: c4,
            c5: c5,
            scale: scale,
            intensity: intensity,
            distortion: distortion,
            debugName: "\(debugName)-button"
        )
    }

    var body: some View {
        ZStack {
            SWPlasmaRenderer(
                style: style,
                palette: [c1, c2, c3, c4, c5],
                scale: scale,
                intensity: intensity,
                distortion: distortion,
                debugName: "\(debugName)-background"
            )
            .ignoresSafeArea()

            VStack {
                Spacer()
                VStack(spacing: 14) {
                    Text("Plasma as button border")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                    HStack(spacing: 22) {
                        PlasmaRingCircleButton(icon: "arrow.up") { makePlasma() }
                        PlasmaRingPillButton(title: "Upgrade to Pro") { makePlasma() }
                    }
                }
                .padding(.vertical, 22)
                .padding(.horizontal, 28)
                .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.bottom, 60)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    SpecchioLogger.easyMode.info("[SWPlasma] controls requested name=\(debugName, privacy: .public) style=\(style.rawValue, privacy: .public)")
                    showSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Plasma Controls")
            }
        }
        .sheet(isPresented: $showSheet) {
            SWPlasmaControlsSheet(
                style: $style,
                c1: $c1,
                c2: $c2,
                c3: $c3,
                c4: $c4,
                c5: $c5,
                scale: $scale,
                intensity: $intensity,
                distortion: $distortion,
                debugName: debugName
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            SpecchioLogger.easyMode.info("[SWPlasmaControlled] appeared name=\(debugName, privacy: .public) style=\(style.rawValue, privacy: .public)")
        }
    }
}

private struct SWPlasmaControlsSheet: View {
    @Binding var style: SWPlasmaStyle
    @Binding var c1: Color
    @Binding var c2: Color
    @Binding var c3: Color
    @Binding var c4: Color
    @Binding var c5: Color
    @Binding var scale: Float
    @Binding var intensity: Float
    @Binding var distortion: Float

    let debugName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Style") {
                    Picker("Style", selection: $style) {
                        ForEach(SWPlasmaStyle.allCases) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                }

                Section("Palette") {
                    ColorPicker("Color 1", selection: $c1, supportsOpacity: false)
                    ColorPicker("Color 2", selection: $c2, supportsOpacity: false)
                    ColorPicker("Color 3", selection: $c3, supportsOpacity: false)
                    ColorPicker("Color 4", selection: $c4, supportsOpacity: false)
                    ColorPicker("Color 5", selection: $c5, supportsOpacity: false)
                }

                Section("Field") {
                    SliderRow(label: "Scale", value: $scale, range: 0.2...3, step: 0.05)
                    SliderRow(label: "Intensity", value: $intensity, range: 0...2.5, step: 0.05)
                    SliderRow(label: "Distortion", value: $distortion, range: 0...3, step: 0.05)
                }
            }
            .navigationTitle("Plasma")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        SpecchioLogger.easyMode.info("[SWPlasma] controls dismissed name=\(debugName, privacy: .public) style=\(style.rawValue, privacy: .public)")
                        dismiss()
                    }
                }
            }
            .onChange(of: style) { _, newStyle in
                let palette = newStyle.defaultPalette
                c1 = palette[0]
                c2 = palette[1]
                c3 = palette[2]
                c4 = palette[3]
                c5 = palette[4]
                SpecchioLogger.easyMode.info("[SWPlasma] controls style changed name=\(debugName, privacy: .public) style=\(newStyle.rawValue, privacy: .public) paletteReset=true")
            }
            .onAppear {
                SpecchioLogger.easyMode.info("[SWPlasma] controls sheet appeared name=\(debugName, privacy: .public) style=\(style.rawValue, privacy: .public)")
            }
        }
    }
}

private struct SliderRow: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let step: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.2f", value))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

struct SWPlasmaActionButton: View {
    let title: String
    let systemImage: String
    let foregroundColor: Color
    let style: SWPlasmaStyle
    let c1: Color?
    let c2: Color?
    let c3: Color?
    let c4: Color?
    let c5: Color?
    let scale: Float
    let intensity: Float
    let distortion: Float
    let accessibilityLabel: String
    let debugName: String
    let action: () -> Void

    private enum Layout {
        static let height: CGFloat = 52
        static let horizontalPadding: CGFloat = 28
    }

    static var visualHeight: CGFloat {
        Layout.height
    }

    private var hasCustomPalette: Bool {
        c1 != nil || c2 != nil || c3 != nil || c4 != nil || c5 != nil
    }

    init(
        title: String,
        systemImage: String = "sparkles",
        foregroundColor: Color = .white,
        style: SWPlasmaStyle = .prism,
        c1: Color? = nil,
        c2: Color? = nil,
        c3: Color? = nil,
        c4: Color? = nil,
        c5: Color? = nil,
        scale: Float = 1.25,
        intensity: Float = 1.1,
        distortion: Float = 1.0,
        accessibilityLabel: String? = nil,
        debugName: String = "SWPlasmaActionButton",
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.foregroundColor = foregroundColor
        self.style = style
        self.c1 = c1
        self.c2 = c2
        self.c3 = c3
        self.c4 = c4
        self.c5 = c5
        self.scale = scale
        self.intensity = intensity
        self.distortion = distortion
        self.accessibilityLabel = accessibilityLabel ?? title
        self.debugName = debugName
        self.action = action
    }

    var body: some View {
        Button {
            SpecchioLogger.easyMode.info("[SWPlasmaActionButton] tapped name=\(debugName, privacy: .public) title=\(title, privacy: .public) style=\(style.rawValue, privacy: .public) customPalette=\(hasCustomPalette)")
            action()
        } label: {
            ZStack {
                SWPlasma(
                    style: style,
                    c1: c1,
                    c2: c2,
                    c3: c3,
                    c4: c4,
                    c5: c5,
                    scale: scale,
                    intensity: intensity,
                    distortion: distortion,
                    debugName: debugName
                )
                .clipShape(Capsule())

                Label(title, systemImage: systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(foregroundColor)
                    .padding(.horizontal, Layout.horizontalPadding)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Layout.height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .onAppear {
            SpecchioLogger.easyMode.info("[SWPlasmaActionButton] appeared name=\(debugName, privacy: .public) title=\(title, privacy: .public) icon=\(systemImage, privacy: .public) style=\(style.rawValue, privacy: .public) customPalette=\(hasCustomPalette) height=\(Layout.height) horizontalPadding=\(Layout.horizontalPadding)")
        }
    }
}

private let plasmaButtonInk = Color(red: 0.07, green: 0.07, blue: 0.08)
private let plasmaRingWidth: CGFloat = 2.5

private struct PlasmaRingCircleButton<Plasma: View>: View {
    let icon: String
    @ViewBuilder let plasma: () -> Plasma

    var body: some View {
        ZStack {
            plasma()
                .clipShape(Circle())
            Circle()
                .fill(plasmaButtonInk)
                .padding(plasmaRingWidth)
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 64, height: 64)
    }
}

private struct PlasmaRingPillButton<Plasma: View>: View {
    let title: String
    @ViewBuilder let plasma: () -> Plasma

    var body: some View {
        ZStack {
            plasma()
                .clipShape(Capsule())
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 28)
        }
        .frame(height: 56)
        .fixedSize(horizontal: true, vertical: false)
    }
}

#Preview {
    NavigationStack {
        SWPlasma(showsControls: true)
    }
}
