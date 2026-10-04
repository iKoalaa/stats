import XCTest
@testable import Kit

final class FanCurveCommandGateTests: XCTestCase {
    func testCommandsWithoutPendingReleaseAreNotDeferredOrExecuted() {
        var gate = FanCurveCommandGate()
        var actions: [String] = []
        XCTAssertFalse(gate.deferCommand(0) { actions.append("manual") })
        XCTAssertTrue(gate.completeRelease(0, generation: 0, success: true).isEmpty)
        XCTAssertTrue(actions.isEmpty)
    }

    func testMultipleFansKeepIndependentReleaseGenerationsAndFIFOQueues() {
        var gate = FanCurveCommandGate()
        var actions: [String] = []
        let first = gate.beginRelease(0)
        let second = gate.beginRelease(1)
        XCTAssertTrue(gate.deferCommand(0) { actions.append("0-mode") })
        XCTAssertTrue(gate.deferCommand(1) { actions.append("1-mode") })
        XCTAssertTrue(gate.deferCommand(0) { actions.append("0-speed") })
        let retry = gate.beginRelease(0)

        let commands = gate.completeRelease(1, generation: second, success: true)
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(actions.isEmpty, "Acknowledgement must return closures, not execute them")
        commands.forEach { $0() }
        XCTAssertEqual(actions, ["1-mode"])
        XCTAssertFalse(gate.deferCommand(1) { actions.append("1-unexpected") })
        XCTAssertTrue(gate.completeRelease(0, generation: first, success: true).isEmpty)
        gate.completeRelease(0, generation: retry, success: true).forEach { $0() }
        XCTAssertEqual(actions, ["1-mode", "0-mode", "0-speed"])
    }

    func testStaleFirstReleaseCannotFlushManualCommandsUntilNewAcknowledgement() {
        var gate = FanCurveCommandGate()
        var actions: [String] = []
        let first = gate.beginRelease(0)
        XCTAssertTrue(gate.deferCommand(0) { actions.append("manual-mode") })
        let current = gate.beginRelease(0)
        XCTAssertGreaterThan(current, first)
        for success in [true, false] {
            XCTAssertTrue(gate.completeRelease(0, generation: first, success: success).isEmpty)
        }
        XCTAssertTrue(gate.deferCommand(0) { actions.append("manual-speed") })
        XCTAssertTrue(actions.isEmpty)
        let commands = gate.completeRelease(0, generation: current, success: true)
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(actions.isEmpty)
        commands.forEach { $0() }
        XCTAssertEqual(actions, ["manual-mode", "manual-speed"])
    }

    func testFailurePreservesCommandsAndBarrierUntilSuccessfulRetry() {
        var gate = FanCurveCommandGate()
        var actions: [String] = []
        let first = gate.beginRelease(0)
        XCTAssertTrue(gate.deferCommand(0) { actions.append("mode") })
        XCTAssertTrue(gate.completeRelease(0, generation: first, success: false).isEmpty)
        XCTAssertTrue(gate.deferCommand(0) { actions.append("speed") })
        let retry = gate.beginRelease(0)
        XCTAssertTrue(gate.completeRelease(0, generation: first, success: true).isEmpty)
        XCTAssertTrue(gate.completeRelease(0, generation: retry, success: false).isEmpty)
        XCTAssertTrue(gate.deferCommand(0) { actions.append("latest-speed") })
        XCTAssertTrue(actions.isEmpty)
        gate.completeRelease(0, generation: retry, success: true).forEach { $0() }
        XCTAssertEqual(actions, ["mode", "speed", "latest-speed"])
        XCTAssertFalse(gate.deferCommand(0) { actions.append("unexpected") })
    }

    func testCancellationRemovesOnlySelectedQueuesWithoutUnblockingRelease() {
        var gate = FanCurveCommandGate()
        var actions: [String] = []
        let first = gate.beginRelease(0)
        let second = gate.beginRelease(1)
        XCTAssertTrue(gate.deferCommand(0) { actions.append("old-forced") })
        XCTAssertTrue(gate.deferCommand(1) { actions.append("other-manual") })
        gate.cancelCommands(for: [])
        gate.cancelCommands(for: [0, 9])
        gate.cancelCommands(for: [0])
        XCTAssertTrue(gate.deferCommand(0) { actions.append("final-auto") })
        XCTAssertTrue(gate.completeRelease(0, generation: first, success: false).isEmpty)
        XCTAssertTrue(actions.isEmpty)
        gate.completeRelease(1, generation: second, success: true).forEach { $0() }
        gate.completeRelease(0, generation: first, success: true).forEach { $0() }
        XCTAssertEqual(actions, ["other-manual", "final-auto"])
    }

    func testCurveEnableSleepAndPauseCancelOldManualBeforeNewReleaseAcknowledgement() {
        for transition in ["curve-enable", "sleep", "pause"] {
            var gate = FanCurveCommandGate()
            var actions: [String] = []
            let old = gate.beginRelease(0)
            XCTAssertTrue(gate.deferCommand(0) { actions.append("old-forced") })
            XCTAssertTrue(gate.deferCommand(0) { actions.append("old-speed") })
            gate.cancelCommands(for: [0])
            // Cancellation preserves the existing barrier, even before a new release begins.
            XCTAssertTrue(gate.deferCommand(0) { actions.append("final-auto") }, transition)
            let current = gate.beginRelease(0)
            XCTAssertTrue(gate.completeRelease(0, generation: old, success: true).isEmpty, transition)
            XCTAssertTrue(actions.isEmpty, transition)
            gate.completeRelease(0, generation: current, success: true).forEach { $0() }
            XCTAssertEqual(actions, ["final-auto"], transition)
        }
    }

    func testSuccessfulAcknowledgementReturnsCommandsOnlyOnceIncludingAfterNewEnqueue() {
        var gate = FanCurveCommandGate()
        var actions: [String] = []
        let generation = gate.beginRelease(0)
        XCTAssertTrue(gate.deferCommand(0) { actions.append("first") })
        let commands = gate.completeRelease(0, generation: generation, success: true)
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(actions.isEmpty)
        commands.forEach { $0() }
        XCTAssertTrue(gate.completeRelease(0, generation: generation, success: true).isEmpty)
        let immediate = { actions.append("immediate") }
        let deferred = gate.deferCommand(0, command: immediate)
        XCTAssertFalse(deferred)
        if !deferred { immediate() }
        XCTAssertTrue(gate.completeRelease(0, generation: generation, success: true).isEmpty)

        let next = gate.beginRelease(0)
        XCTAssertTrue(gate.deferCommand(0) { actions.append("next") })
        XCTAssertTrue(gate.completeRelease(0, generation: generation, success: true).isEmpty)
        XCTAssertEqual(actions, ["first", "immediate"])
        gate.completeRelease(0, generation: next, success: true).forEach { $0() }
        XCTAssertTrue(gate.completeRelease(0, generation: next, success: true).isEmpty)
        XCTAssertEqual(actions, ["first", "immediate", "next"])
    }
}

// Optional standalone entry point; omit this flag in a hosted XCTest target.
#if FAN_CURVE_COMMAND_GATE_TESTS
@main
enum FanCurveCommandGateTestMain {
    static func main() {
        let suite = FanCurveCommandGateTests.defaultTestSuite
        suite.run()
        guard let result = suite.testRun, result.executionCount > 0 else { exit(1) }
        exit(result.hasSucceeded ? 0 : 1)
    }
}
#endif
