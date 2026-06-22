import SwiftUI

struct AccessibilityDisplay: View {
    let rootElement: AccessibilityElement
    let screenSize: CGSize
    let scale: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            renderElement(rootElement)
        }
        .frame(width: screenSize.width * scale, height: screenSize.height * scale)
    }

    // Returns AnyView to allow recursive calls without violating opaque return type constraints.
    func renderElement(_ element: AccessibilityElement) -> AnyView {
        guard element.isVisible && element.frame.width > 0 else {
            return AnyView(EmptyView())
        }

        let scaledFrame = CGRect(
            x: element.frame.origin.x * scale,
            y: element.frame.origin.y * scale,
            width: element.frame.width * scale,
            height: element.frame.height * scale
        )

        let elementView: AnyView
        let type = element.type

        if type.contains("Button") {
            elementView = AnyView(
                RoundedRectangle(cornerRadius: 8 * scale)
                    .fill(Color.blue.opacity(0.15))
                    .overlay(
                        Text(element.label ?? "")
                            .font(.system(size: 14 * scale))
                            .foregroundColor(.blue)
                    )
                    .frame(width: scaledFrame.width, height: scaledFrame.height)
                    .position(x: scaledFrame.midX, y: scaledFrame.midY)
            )
        } else if type.contains("StaticText") {
            elementView = AnyView(
                Text(element.label ?? element.value ?? "")
                    .font(.system(size: 14 * scale))
                    .foregroundColor(.white)
                    .frame(width: scaledFrame.width, height: scaledFrame.height)
                    .position(x: scaledFrame.midX, y: scaledFrame.midY)
            )
        } else if type.contains("TextField") || type.contains("SecureTextField") {
            elementView = AnyView(
                RoundedRectangle(cornerRadius: 6 * scale)
                    .stroke(Color.gray, lineWidth: 1)
                    .overlay(
                        Text(element.value ?? element.label ?? "")
                            .font(.system(size: 14 * scale))
                            .foregroundColor(.gray)
                            .padding(.horizontal, 4 * scale),
                        alignment: .leading
                    )
                    .frame(width: scaledFrame.width, height: scaledFrame.height)
                    .position(x: scaledFrame.midX, y: scaledFrame.midY)
            )
        } else if type.contains("Image") {
            elementView = AnyView(
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.gray)
                    )
                    .frame(width: scaledFrame.width, height: scaledFrame.height)
                    .position(x: scaledFrame.midX, y: scaledFrame.midY)
            )
        } else if type.contains("NavigationBar") {
            elementView = AnyView(
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: scaledFrame.width, height: scaledFrame.height)
                    .position(x: scaledFrame.midX, y: scaledFrame.midY)
            )
        } else if type.contains("TabBar") {
            elementView = AnyView(
                Rectangle()
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: scaledFrame.width, height: scaledFrame.height)
                    .position(x: scaledFrame.midX, y: scaledFrame.midY)
            )
        } else if type.contains("Switch") || type.contains("Toggle") {
            elementView = AnyView(
                RoundedRectangle(cornerRadius: 16 * scale)
                    .fill(element.value == "1" ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 51 * scale, height: 31 * scale)
                    .position(x: scaledFrame.midX, y: scaledFrame.midY)
            )
        } else {
            elementView = AnyView(EmptyView())
        }

        if element.children.isEmpty {
            return elementView
        }

        return AnyView(
            ZStack(alignment: .topLeading) {
                elementView
                ForEach(0..<element.children.count, id: \.self) { index in
                    self.renderElement(element.children[index])
                }
            }
        )
    }
}
