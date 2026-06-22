import SwiftUI

struct InputOverlay: NSViewRepresentable {
    let phoneScreenSize: CGSize
    let viewSize: CGSize
    let wdaClient: WDAClient
    var inputSocket: WDAInputSocket?
    var keyboardExtSocket: KeyboardExtSocket?

    func makeNSView(context: Context) -> InputOverlayNSView {
        let view = InputOverlayNSView()
        configureCallbacks(view)
        return view
    }

    func updateNSView(_ nsView: InputOverlayNSView, context: Context) {
        configureCallbacks(nsView)
    }

    private func configureCallbacks(_ view: InputOverlayNSView) {
        let mapper = CoordinateMapper(phoneScreenSize: phoneScreenSize, viewSize: viewSize)
        let translator = InputTranslator(wdaClient: wdaClient, coordinateMapper: mapper, inputSocket: inputSocket, keyboardExtSocket: keyboardExtSocket)

        view.onTap = { point in
            Task { await translator.handleTap(viewPoint: point) }
        }
        view.onDrag = { from, to, duration in
            Task { await translator.handleDrag(from: from, to: to, duration: duration) }
        }
        view.onScroll = { point, dx, dy in
            Task { await translator.handleScroll(at: point, deltaX: dx, deltaY: dy) }
        }
        view.onKeyDown = { text in
            Task { await translator.handleKeyInput(text) }
        }
        view.onKeyCommand = { command in
            Task { await translator.handleCommand(command) }
        }
        view.onPinch = { center, scale in
            Task { await translator.handlePinch(center: center, scale: scale) }
        }
    }
}
