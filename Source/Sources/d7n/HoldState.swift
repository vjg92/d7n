import Foundation

/// Pure state machine: only the physical Fn key can begin/end a hold.
struct HoldState {
    enum Action: Equatable { case start, stop, cancel, none }
    private(set) var held = false
    private var cancelled = false
    mutating func flags(keyCode: Int, fnDown: Bool, otherModifiers: Bool) -> Action {
        guard keyCode == 63 else {
            if held && otherModifiers && !cancelled { cancelled = true; return .cancel }
            return .none
        }
        if fnDown {
            guard !held else { return .none }
            held = true
            cancelled = otherModifiers
            return cancelled ? .none : .start
        }
        guard held else { return .none }
        held = false
        let action: Action = cancelled ? .none : .stop
        cancelled = false
        return action
    }
    mutating func keyDown() -> Action {
        guard held && !cancelled else { return .none }
        cancelled = true
        return .cancel
    }
    mutating func reset() { held = false; cancelled = false }
}
