import Foundation

class AccessibilityTreeParser: NSObject, XMLParserDelegate {
    private var elementStack: [AccessibilityElement] = []
    private var rootElement: AccessibilityElement?

    func parse(xml: String) -> AccessibilityElement? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let parser = XMLParser(data: data)
        parser.delegate = self
        elementStack = []
        rootElement = nil
        parser.parse()
        return rootElement
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        let frame = CGRect(
            x: Double(attributes["x"] ?? "0") ?? 0,
            y: Double(attributes["y"] ?? "0") ?? 0,
            width: Double(attributes["width"] ?? "0") ?? 0,
            height: Double(attributes["height"] ?? "0") ?? 0
        )

        let element = AccessibilityElement(
            type: attributes["type"] ?? elementName,
            label: attributes["label"] ?? attributes["name"],
            value: attributes["value"],
            frame: frame,
            isEnabled: attributes["enabled"] == "true",
            isVisible: attributes["visible"] == "true",
            identifier: attributes["name"],
            children: []
        )

        elementStack.append(element)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        guard let completed = elementStack.popLast() else { return }

        if elementStack.isEmpty {
            rootElement = completed
        } else {
            var parent = elementStack.removeLast()
            var updatedChildren = parent.children
            updatedChildren.append(completed)
            parent = AccessibilityElement(
                type: parent.type,
                label: parent.label,
                value: parent.value,
                frame: parent.frame,
                isEnabled: parent.isEnabled,
                isVisible: parent.isVisible,
                identifier: parent.identifier,
                children: updatedChildren
            )
            elementStack.append(parent)
        }
    }
}
