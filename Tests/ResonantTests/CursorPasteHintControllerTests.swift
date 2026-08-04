import XCTest
@testable import Resonant

@MainActor
final class CursorPasteHintControllerTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)
    private let hintSize = CGSize(width: 70, height: 32)

    func testHintSitsBelowRightOfPointer() {
        let origin = CursorPasteHintController.hintOrigin(
            mouseLocation: CGPoint(x: 400, y: 500),
            hintSize: hintSize,
            screenFrame: screen
        )

        XCTAssertEqual(origin.x, 400 + CursorPasteHintController.cursorOffset.x)
        XCTAssertEqual(origin.y, 500 + CursorPasteHintController.cursorOffset.y - hintSize.height)
    }

    func testHintFlipsLeftAtRightScreenEdge() {
        let origin = CursorPasteHintController.hintOrigin(
            mouseLocation: CGPoint(x: 1720, y: 500),
            hintSize: hintSize,
            screenFrame: screen
        )

        XCTAssertEqual(origin.x, 1720 - CursorPasteHintController.cursorOffset.x - hintSize.width)
        XCTAssertLessThanOrEqual(origin.x + hintSize.width, screen.maxX)
    }

    func testHintFlipsAbovePointerAtBottomScreenEdge() {
        let origin = CursorPasteHintController.hintOrigin(
            mouseLocation: CGPoint(x: 400, y: 4),
            hintSize: hintSize,
            screenFrame: screen
        )

        XCTAssertEqual(origin.y, 4 - CursorPasteHintController.cursorOffset.y)
        XCTAssertGreaterThanOrEqual(origin.y, screen.minY)
    }

    func testHintStaysOnScreenInCorner() {
        let origin = CursorPasteHintController.hintOrigin(
            mouseLocation: CGPoint(x: 1727, y: 1),
            hintSize: hintSize,
            screenFrame: screen
        )

        XCTAssertGreaterThanOrEqual(origin.x, screen.minX)
        XCTAssertGreaterThanOrEqual(origin.y, screen.minY)
        XCTAssertLessThanOrEqual(origin.x + hintSize.width, screen.maxX)
        XCTAssertLessThanOrEqual(origin.y + hintSize.height, screen.maxY)
    }
}
