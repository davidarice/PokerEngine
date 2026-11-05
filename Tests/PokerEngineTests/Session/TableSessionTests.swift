import Foundation
import Observation
import PokerEngine
import PokerEngineObservation
import Testing

@MainActor
@Suite("Table session")
struct TableSessionTests {
    private static let config = HandConfig.test(stacks: [100, 100])

    /// `onChange` runs on the thread that makes the change, here the main actor.
    private final class ChangeCounter: @unchecked Sendable {
        var count = 0
    }

    private func dealt() throws -> TableSession {
        let session = TableSession(config: Self.config)
        for (player, text) in [(0, "As"), (1, "Ks"), (0, "Ah"), (1, "Kh")] {
            try session.apply(.dealHole(player: player, card: card(text)))
        }
        return session
    }

    @Test("a new session is the hand after its start-of-hand automation, with nothing to undo")
    func newSession() {
        let session = TableSession(config: Self.config)
        #expect(session.state == HandState(config: Self.config))
        #expect(!session.canUndo)
    }

    @Test("a refused operation throws its error and changes nothing")
    func refusedOperation() throws {
        let session = try dealt()
        let before = session.state
        #expect(throws: EngineError.notYourTurn(player: 0, actor: 1)) { try session.apply(.fold(player: 0)) }
        #expect(session.state == before)
    }

    @Test("undo takes back one dealer operation with everything it set off")
    func undoTakesBackTheCascade() throws {
        let session = try dealt()
        let before = session.state
        try session.apply(.fold(player: 1))
        #expect(session.state.isHandComplete)
        #expect(session.state.log.count > before.log.count + 1)
        session.undo()
        #expect(session.state == before)
    }

    @Test("undo goes all the way back, and then does nothing")
    func undoToTheStart() throws {
        let session = try dealt()
        for _ in 0..<4 {
            #expect(session.canUndo)
            session.undo()
        }
        #expect(session.state == HandState(config: Self.config))
        #expect(!session.canUndo)
        session.undo()
        #expect(session.state == HandState(config: Self.config))
    }

    @Test("a session restored from a state can undo what came before it")
    func restoredSession() throws {
        let state = try dealt().state
        let session = TableSession(state: state)
        #expect(session.state == state)
        #expect(session.canUndo)
        session.undo()
        #expect(session.state.operations == Array(state.operations.dropLast()))
    }

    @Test("a misread is corrected in place, and undo puts the misread back (C19)")
    func replaceOperation() throws {
        let session = try dealt()
        let before = session.state
        try session.replaceOperation(at: 1, with: .dealHole(player: 1, card: card("Qs")))
        #expect(session.state.holeCards[1].map(\.card) == cards("QsKh"))
        #expect(session.canUndo)
        session.undo()
        #expect(session.state == before)
    }

    @Test("undo takes back what was entered after a correction, then the correction, then the operations before it")
    func undoAfterACorrection() throws {
        let session = try dealt()
        let before = session.state
        try session.replaceOperation(at: 1, with: .dealHole(player: 1, card: card("Qs")))
        let corrected = session.state
        try session.apply(.checkOrCall(player: 1))
        session.undo()
        #expect(session.state == corrected)
        session.undo()
        #expect(session.state == before)
        session.undo()
        #expect(session.state.operations == Array(before.operations.dropLast()))
    }

    @Test("undo reverses corrections newest first, a corrected config included (C19)")
    func undoCorrectionsInOrder() throws {
        let session = try dealt()
        let before = session.state
        try session.replaceConfig(with: .test(stacks: [100, 150]))
        let correctedConfig = session.state
        var operations = correctedConfig.operations
        operations[0] = .dealHole(player: 0, card: card("Qs"))
        try session.replaceOperations(with: operations)
        session.undo()
        #expect(session.state == correctedConfig)
        session.undo()
        #expect(session.state == before)
    }

    @Test("a correction before any operation can be undone, and a refused one leaves nothing to undo (C19)")
    func undoWithNoOperations() throws {
        let session = TableSession(config: Self.config)
        #expect(throws: ReplayError.self) { try session.replaceOperations(with: [.fold(player: 0)]) }
        #expect(!session.canUndo)
        try session.replaceConfig(with: .test(stacks: [100, 150]))
        #expect(session.canUndo)
        session.undo()
        #expect(session.state == HandState(config: Self.config))
        #expect(!session.canUndo)
    }

    @Test("a session restored from a state has no correction to reverse, so undo takes back operations (C19)")
    func restoredSessionAfterACorrection() throws {
        let corrected = try dealt()
        try corrected.replaceOperation(at: 1, with: .dealHole(player: 1, card: card("Qs")))
        let session = TableSession(state: corrected.state)
        session.undo()
        #expect(session.state.operations == Array(corrected.state.operations.dropLast()))
    }

    @Test("a correction that no longer fits throws, naming the operation, and changes nothing")
    func replaceOperationRefused() throws {
        let session = try dealt()
        let before = session.state
        let error = #expect(throws: ReplayError.self) {
            try session.replaceOperation(at: 1, with: .dealHole(player: 1, card: card("As")))
        }
        #expect(error?.operationIndex == 1)
        #expect(session.state == before)
    }

    @Test("several operations can be corrected together")
    func replaceOperations() throws {
        let session = try dealt()
        var operations = session.state.operations
        operations[0] = .dealHole(player: 0, card: card("Ks"))
        operations[1] = .dealHole(player: 1, card: card("As"))
        try session.replaceOperations(with: operations)
        #expect(session.state.operations == operations)
        let error = #expect(throws: ReplayError.self) {
            try session.replaceOperations(with: operations + [.fold(player: 0)])
        }
        #expect(error?.operationIndex == 4)
        #expect(session.state.operations == operations)
    }

    @Test("a stack entered wrong is corrected in place, and undo puts the old config back (C19)")
    func replaceConfig() throws {
        let session = try dealt()
        let before = session.state
        let corrected = HandConfig.test(stacks: [100, 150])
        try session.replaceConfig(with: corrected)
        #expect(session.state.config == corrected)
        #expect(session.state.operations == before.operations)
        #expect(session.state.stacks == [98, 149])
        #expect(session.state.maxRaiseTo == 150)
        session.undo()
        #expect(session.state == before)
    }

    @Test("a corrected config that no longer fits throws, naming the operation, and changes nothing")
    func replaceConfigRefused() throws {
        let session = try dealt()
        try session.apply(.betOrRaise(player: 1, to: 80))
        let before = session.state
        let error = #expect(throws: ReplayError.self) {
            try session.replaceConfig(with: .test(stacks: [100, 50]))
        }
        #expect(error?.operationIndex == 4)
        #expect(error?.operation == .betOrRaise(player: 1, to: 80))
        #expect(error?.error == .betAboveMaximum(amount: 80, maximum: 50))
        #expect(session.state == before)
    }

    @Test("an all-in entered at the wrong stack is corrected together with the stack")
    func replaceConfigAndOperations() throws {
        let session = try dealt()
        try session.apply(.betOrRaise(player: 1, to: 100))
        let corrected = HandConfig.test(stacks: [100, 150])
        var operations = session.state.operations
        operations[4] = .betOrRaise(player: 1, to: 150)

        // Neither half does it alone: the new bet is too big for the old stack, and the old bet leaves chips behind.
        #expect(throws: ReplayError.self) { try session.replaceOperations(with: operations) }
        #expect(try HandState.replay(config: corrected, operations: session.state.operations).stacks == [98, 50])

        try session.replaceConfig(with: corrected, operations: operations)
        #expect(session.state.config == corrected)
        #expect(session.state.operations == operations)
        #expect(session.state.stacks == [98, 0])
    }

    @Test("observers hear about every change to the state")
    func observation() throws {
        let session = try dealt()
        let changes = ChangeCounter()
        func track() {
            withObservationTracking { _ = session.state } onChange: { changes.count += 1 }
        }
        track()
        try session.apply(.checkOrCall(player: 1))
        #expect(changes.count == 1)
        track()
        session.undo()
        #expect(changes.count == 2)
        track()
        try session.replaceOperation(at: 0, with: .dealHole(player: 0, card: card("Qs")))
        #expect(changes.count == 3)
        var operations = session.state.operations
        operations[0] = .dealHole(player: 0, card: card("Js"))
        track()
        try session.replaceOperations(with: operations)
        #expect(changes.count == 4)
        track()
        try session.replaceConfig(with: .test(stacks: [100, 150]))
        #expect(changes.count == 5)
        track()
        session.undo()
        #expect(changes.count == 6)
        #expect(session.state.config == Self.config)
    }
}
