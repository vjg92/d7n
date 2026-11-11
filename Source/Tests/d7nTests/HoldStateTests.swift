import XCTest
@testable import d7n
final class HoldStateTests: XCTestCase {
    func testHoldReleaseAndDuplicates() {
        var state = HoldState()
        XCTAssertEqual(state.flags(keyCode: 63, fnDown: true, otherModifiers: false), .start)
        XCTAssertEqual(state.flags(keyCode: 63, fnDown: true, otherModifiers: false), .none)
        XCTAssertEqual(state.flags(keyCode: 63, fnDown: false, otherModifiers: false), .stop)
        XCTAssertEqual(state.flags(keyCode: 63, fnDown: false, otherModifiers: false), .none)
    }
    func testArrowFunctionFlagsDoNotStartRecording() {
        var state = HoldState()
        XCTAssertEqual(state.flags(keyCode: 126, fnDown: true, otherModifiers: false), .none)
    }
    func testFnShortcutCancelsWithoutTranscribing() {
        var state = HoldState()
        _ = state.flags(keyCode: 63, fnDown: true, otherModifiers: false)
        XCTAssertEqual(state.keyDown(), .cancel)
        XCTAssertEqual(state.flags(keyCode: 63, fnDown: false, otherModifiers: false), .none)
    }
    func testModifierChordDoesNotRecord() {
        var state = HoldState()
        XCTAssertEqual(state.flags(keyCode: 63, fnDown: true, otherModifiers: true), .none)
        XCTAssertEqual(state.flags(keyCode: 63, fnDown: false, otherModifiers: false), .none)
    }
    func testSleepResetDiscardsHold() {
        var state = HoldState()
        _ = state.flags(keyCode: 63, fnDown: true, otherModifiers: false)
        state.reset()
        XCTAssertEqual(state.flags(keyCode: 63, fnDown: false, otherModifiers: false), .none)
        XCTAssertEqual(state.flags(keyCode: 63, fnDown: true, otherModifiers: false), .start)
    }
}
