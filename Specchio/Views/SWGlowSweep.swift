//
//  SWGlowSweep.swift
//  ShipSwift
//
//  Source: https://github.com/signerlabs/ShipSwift
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
//  View wrapper that replaces the content's appearance with a base color and sweeps
//  a glowing highlight band across it. The original content shape is used as a mask,
//  making it ideal for text, icons, SF Symbols, and button labels.
//

import SwiftUI

enum SWGlowSweepDirection: String {
    case leftToRight
    case rightToLeft

    func offset(isActive: Bool, width: CGFloat, bandWidth: CGFloat) -> CGFloat {
        switch self {
        case .leftToRight:
            return isActive ? width / 2 + bandWidth : -width / 2 - bandWidth
        case .rightToLeft:
            return isActive ? -width / 2 - bandWidth : width / 2 + bandWidth
        }
    }
}

struct SWGlowSweep<Content: View>: View {
    @State private var animate = false

    var baseColor: Color = .gray
    var glowColor: Color = .white
    var duration: Double = 2.0
    var bandWidth: CGFloat = 150
    var direction: SWGlowSweepDirection = .leftToRight
    var debugName: String = "SWGlowSweep"

    @ViewBuilder let content: () -> Content

    init(
        baseColor: Color = .gray,
        glowColor: Color = .white,
        duration: Double = 2.0,
        bandWidth: CGFloat = 150,
        direction: SWGlowSweepDirection = .leftToRight,
        debugName: String = "SWGlowSweep",
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.baseColor = baseColor
        self.glowColor = glowColor
        self.duration = duration
        self.bandWidth = bandWidth
        self.direction = direction
        self.debugName = debugName
        self.content = content
    }

    var body: some View {
        let inner = content()
        inner
            .hidden()
            .overlay {
                GeometryReader { geo in
                    let totalWidth = geo.size.width

                    Rectangle()
                        .fill(baseColor)
                        .overlay {
                            LinearGradient(
                                colors: [.clear, glowColor, .clear],
                                startPoint: UnitPoint(x: 0, y: 0.5),
                                endPoint: UnitPoint(x: 1, y: 0.5)
                            )
                            .frame(width: bandWidth)
                            .offset(x: direction.offset(isActive: animate, width: totalWidth, bandWidth: bandWidth))
                        }
                        .animation(
                            .linear(duration: duration)
                            .repeatForever(autoreverses: false),
                            value: animate
                        )
                        .mask { inner }
                        .onAppear {
                            SpecchioLogger.easyMode.info("[SWGlowSweep] geometry appeared name=\(debugName, privacy: .public) width=\(totalWidth) height=\(geo.size.height) duration=\(duration) bandWidth=\(bandWidth) direction=\(direction.rawValue, privacy: .public)")
                        }
                        .onChange(of: geo.size) { _, newSize in
                            SpecchioLogger.easyMode.info("[SWGlowSweep] geometry changed name=\(debugName, privacy: .public) width=\(newSize.width) height=\(newSize.height) duration=\(duration) bandWidth=\(bandWidth) direction=\(direction.rawValue, privacy: .public)")
                        }
                }
            }
            .onAppear {
                SpecchioLogger.easyMode.info("[SWGlowSweep] appeared name=\(debugName, privacy: .public) duration=\(duration) bandWidth=\(bandWidth) direction=\(direction.rawValue, privacy: .public) source=ShipSwift")
                animate = true
            }
            .onDisappear {
                SpecchioLogger.easyMode.info("[SWGlowSweep] disappeared name=\(debugName, privacy: .public)")
            }
    }
}

extension View {
    func swGlowSweep(
        baseColor: Color = .gray,
        glowColor: Color = .white,
        duration: Double = 2.0,
        bandWidth: CGFloat = 150,
        direction: SWGlowSweepDirection = .leftToRight,
        debugName: String = "SWGlowSweep"
    ) -> some View {
        SWGlowSweep(
            baseColor: baseColor,
            glowColor: glowColor,
            duration: duration,
            bandWidth: bandWidth,
            direction: direction,
            debugName: debugName
        ) {
            self
        }
    }
}

#Preview {
    VStack(spacing: 26) {
        SWGlowSweep {
            Text("Start Scan Today")
                .font(.largeTitle.bold())
        }

        SWGlowSweep(baseColor: .accentColor, glowColor: .white, duration: 1.5) {
            Text("Analyzing...")
                .font(.title2.bold())
        }

        Button {
        } label: {
            Label("Connect Bluetooth", systemImage: "keyboard")
                .swGlowSweep(baseColor: .accentColor, glowColor: .white)
        }
        .buttonStyle(.borderedProminent)
    }
    .padding()
}
