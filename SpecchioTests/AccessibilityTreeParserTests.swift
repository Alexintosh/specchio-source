import XCTest
@testable import Specchio

final class AccessibilityTreeParserTests: XCTestCase {
    let parser = AccessibilityTreeParser()

    func testParseSimpleElement() {
        let xml = """
        <XCUIElementTypeApplication type="XCUIElementTypeApplication" name="Settings" label="Settings" x="0" y="0" width="390" height="844" enabled="true" visible="true">
        </XCUIElementTypeApplication>
        """
        let root = parser.parse(xml: xml)
        XCTAssertNotNil(root)
        XCTAssertEqual(root?.type, "XCUIElementTypeApplication")
        XCTAssertEqual(root?.label, "Settings")
        XCTAssertEqual(root?.frame, CGRect(x: 0, y: 0, width: 390, height: 844))
        XCTAssertTrue(root?.isEnabled ?? false)
        XCTAssertTrue(root?.isVisible ?? false)
        XCTAssertTrue(root?.children.isEmpty ?? false)
    }

    func testParseNestedElements() {
        let xml = """
        <XCUIElementTypeApplication type="XCUIElementTypeApplication" name="App" x="0" y="0" width="390" height="844" enabled="true" visible="true">
            <XCUIElementTypeButton type="XCUIElementTypeButton" name="Back" label="Back" x="10" y="52" width="44" height="44" enabled="true" visible="true"/>
            <XCUIElementTypeStaticText type="XCUIElementTypeStaticText" label="Hello World" x="20" y="100" width="350" height="20" enabled="true" visible="true"/>
        </XCUIElementTypeApplication>
        """
        let root = parser.parse(xml: xml)
        XCTAssertNotNil(root)
        XCTAssertEqual(root?.children.count, 2)

        let button = root?.children[0]
        XCTAssertEqual(button?.type, "XCUIElementTypeButton")
        XCTAssertEqual(button?.label, "Back")
        XCTAssertEqual(button?.frame.origin.x, 10)

        let text = root?.children[1]
        XCTAssertEqual(text?.type, "XCUIElementTypeStaticText")
        XCTAssertEqual(text?.label, "Hello World")
    }

    func testParseDeeplyNestedTree() {
        let xml = """
        <XCUIElementTypeApplication type="XCUIElementTypeApplication" name="App" x="0" y="0" width="390" height="844" enabled="true" visible="true">
            <XCUIElementTypeWindow type="XCUIElementTypeWindow" x="0" y="0" width="390" height="844" enabled="true" visible="true">
                <XCUIElementTypeNavigationBar type="XCUIElementTypeNavigationBar" x="0" y="0" width="390" height="44" enabled="true" visible="true">
                    <XCUIElementTypeButton type="XCUIElementTypeButton" label="Back" x="0" y="0" width="44" height="44" enabled="true" visible="true"/>
                </XCUIElementTypeNavigationBar>
            </XCUIElementTypeWindow>
        </XCUIElementTypeApplication>
        """
        let root = parser.parse(xml: xml)
        XCTAssertNotNil(root)
        XCTAssertEqual(root?.children.count, 1) // Window
        let window = root?.children[0]
        XCTAssertEqual(window?.children.count, 1) // NavBar
        let navBar = window?.children[0]
        XCTAssertEqual(navBar?.children.count, 1) // Button
        let button = navBar?.children[0]
        XCTAssertEqual(button?.label, "Back")
    }

    func testParseInvalidXML() {
        let result = parser.parse(xml: "not xml at all")
        // XMLParser may return nil or a partial result; should not crash
        // The important thing is it doesn't crash
        _ = result
    }

    func testParseEmptyString() {
        let result = parser.parse(xml: "")
        XCTAssertNil(result)
    }

    func testParseElementWithValue() {
        let xml = """
        <XCUIElementTypeTextField type="XCUIElementTypeTextField" label="Username" value="john@example.com" x="20" y="200" width="350" height="44" enabled="true" visible="true"/>
        """
        let root = parser.parse(xml: xml)
        XCTAssertNotNil(root)
        XCTAssertEqual(root?.value, "john@example.com")
        XCTAssertEqual(root?.label, "Username")
    }

    func testParseDisabledInvisibleElement() {
        let xml = """
        <XCUIElementTypeButton type="XCUIElementTypeButton" label="Hidden" x="0" y="0" width="100" height="44" enabled="false" visible="false"/>
        """
        let root = parser.parse(xml: xml)
        XCTAssertNotNil(root)
        XCTAssertFalse(root?.isEnabled ?? true)
        XCTAssertFalse(root?.isVisible ?? true)
    }
}
