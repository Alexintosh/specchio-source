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

struct SWGlowSweep<Content: View>: View {
    @State private var animate = false

    var baseColor: Color = .gray
    var glowColor: Color = .white
    var duration: Double = 2.0
    var bandWidth: CGFloat = 150
    var debugName: String = "SWGlowSweep"

    @ViewBuilder let content: () -> Content

    init(
        baseColor: Color = .gray,
        glowColor: Color = .white,
        duration: Double = 2.0,
        bandWidth: CGFloat = 150,
        debugName: String = "SWGlowSweep",
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.baseColor = baseColor
        self.glowColor = glowColor
        self.duration = duration
        self.bandWidth = bandWidth
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
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: bandWidth)
                            .offset(x: animate ? totalWidth / 2 + bandWidth : -totalWidth / 2 - bandWidth)
                        }
                        .animation(
                            .linear(duration: duration)
                            .repeatForever(autoreverses: false),
                            value: animate
                        )
                        .mask { inner }
                        .onAppear {
                            SpecchioLogger.easyMode.info("[SWGlowSweep] geometry appeared name=\(debugName, privacy: .public) width=\(totalWidth) height=\(geo.size.height) duration=\(duration) bandWidth=\(bandWidth)")
                        }
                        .onChange(of: geo.size) { _, newSize in
                            SpecchioLogger.easyMode.info("[SWGlowSweep] geometry changed name=\(debugName, privacy: .public) width=\(newSize.width) height=\(newSize.height) duration=\(duration) bandWidth=\(bandWidth)")
                        }
                }
            }
            .onAppear {
                SpecchioLogger.easyMode.info("[SWGlowSweep] appeared name=\(debugName, privacy: .public) duration=\(duration) bandWidth=\(bandWidth) source=ShipSwift")
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
        debugName: String = "SWGlowSweep"
    ) -> some View {
        SWGlowSweep(
            baseColor: baseColor,
            glowColor: glowColor,
            duration: duration,
            bandWidth: bandWidth,
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
