// Standalone safety tests. Compile with the helper sources and -D FAN_HELPER_TESTS
// plus Xcode's XCTest framework path; the real helper and SMC are never run.
// Define FAN_HELPER_MOCK_ONLY to exclude all subprocess tests.
#if FAN_HELPER_TESTS
import Foundation
import XCTest

final class FakeFanCLI {
    var clock: TimeInterval = 100
    var values: [String: Double] = ["FNum": 2, "Ftst": 0, "FS! ": 0]
    var unavailable: Set<String> = []
    var calls: [[String]] = []
    var overrides: [String: [SMCCommandResult]] = [:]
    var ignored: Set<String> = []
    var delays: [String: TimeInterval] = [:]
    var budgets: [TimeInterval] = []
    let intel: Bool

    init(count: Int = 2, intel: Bool = false) {
        self.intel = intel
        values["FNum"] = Double(count)
        for id in 0..<count {
            values["F\(id)\(intel ? "Md" : "md")"] = 0
            values["F\(id)Mn"] = 1200
            values["F\(id)Mx"] = 6000
            values["F\(id)Tg"] = 1200
        }
    }

    func mode(_ id: Int, _ value: Double) {
        values["F\(id)\(intel ? "Md" : "md")"] = value
        if intel {
            let mask = Int(values["FS! "]!)
            values["FS! "] = Double(value == 1 ? mask | (1 << id) : mask & ~(1 << id))
        }
    }

    func execute(_ args: [String], _ budget: TimeInterval) -> SMCCommandResult {
        calls.append(args)
        budgets.append(budget)
        let key = args.joined(separator: "/")
        clock += delays[key] ?? 0
        if var results = overrides[key], !results.isEmpty {
            let result = results.removeFirst()
            overrides[key] = results
            return result
        }
        if args == ["list", "-f", "--strict"] {
            // Omit stderr to verify that a marker alone cannot authorize a reset.
            return SMCCommandResult(output: "[INFO]: found \(values.count) keys\n" +
                values.keys.sorted().map {
                    "[\($0)]    \(unavailable.contains($0) ? "UNAVAILABLE" : String(values[$0]!))"
                }.joined(separator: "\n"))
        }
        if ignored.contains(key) { return SMCCommandResult() }
        if args == ["reset"] {
            values["Ftst"] = 0
            return SMCCommandResult(output: "[reset] fan control restored to automatic")
        }
        precondition(args.count == 4 && args[0] == "fan")
        let id = Int(args[1])!
        let value = Double(args[3])!
        if args[2] == "-m" {
            mode(id, value)
            if value == 0 && !intel { values["F\(id)Tg"] = 0 }
        } else {
            precondition(args[2] == "-v")
            values["F\(id)Tg"] = value
        }
        return SMCCommandResult()
    }

    func controller() -> FanLeaseController {
        FanLeaseController(usesIntelMask: intel, now: { self.clock }, command: execute)
    }

    var writes: [[String]] { calls.filter { $0.first != "list" } }
}

final class FanHelperTests: XCTestCase {
    func testLeaseExpiryIsIndependentAndExactlyEightSeconds() {
        var state = FanLeaseState()
        state.renew(id: 0, now: 100)
        state.renew(id: 1, now: 103)
        state.expire(now: 107.999)
        XCTAssertTrue(state.pendingAuto.isEmpty)
        state.expire(now: 108)
        XCTAssertEqual(state.pendingAuto, [0])
        XCTAssertEqual(state.deadlines, [1: 111])
        state.cancel(id: 0)
        state.expire(now: 111)
        XCTAssertEqual(state.pendingAuto, [1])
    }

    func testFailedUpdateDoesNotRenewLease() {
        var state = FanLeaseState()
        state.renew(id: 0, now: 100)
        state.beginUpdate(id: 0)
        XCTAssertEqual(state.deadlines[0], 108)
        state.release(id: 0)
        XCTAssertNil(state.deadlines[0])
        XCTAssertEqual(state.pendingAuto, [0])
        state.expire(now: 1000)
        XCTAssertEqual(state.pendingAuto, [0])
    }

    func testSuccessfulRenewalReplacesPendingRecovery() {
        let fake = FakeFanCLI()
        let controller = fake.controller()
        XCTAssertTrue(controller.setCurveFanSpeed(id: 0, value: 2400))
        fake.overrides["fan/0/-m/0"] = [SMCCommandResult(error: "temporarily unavailable")]
        XCTAssertFalse(controller.releaseCurveFan(id: 0))
        XCTAssertEqual(controller.state.pendingAuto, [0])
        fake.clock = 102
        XCTAssertTrue(controller.setCurveFanSpeed(id: 0, value: 2500))
        XCTAssertTrue(controller.state.pendingAuto.isEmpty)
        XCTAssertEqual(controller.state.deadlines[0], 110)
        fake.clock = 109
        controller.watchdog()
        XCTAssertEqual(fake.values["F0md"], 1)
    }

    func testUppercaseAndAuto3ModesAreReadWithoutDefaults() {
        let snapshot = FanSMCSnapshot(SMCCommandResult(output: "[FNum] 2\n[F0Md] 0\n[F1Md] 3"), usesIntelMask: false)
        XCTAssertEqual(snapshot?.mode(id: 0), 0)
        XCTAssertEqual(snapshot?.mode(id: 1), 3)
        XCTAssertTrue(snapshot?.allAutomatic == true)
        let missing = FanSMCSnapshot(SMCCommandResult(output: "[FNum] 2\n[F0Md] 0"), usesIntelMask: false)
        XCTAssertNil(missing)
        XCTAssertNil(missing?.mode(id: 1))
        XCTAssertFalse(missing?.allAutomatic == true)
    }

    func testCurveWritesForcedThenSpeedAndReadsBack() {
        let fake = FakeFanCLI()
        let controller = fake.controller()
        XCTAssertTrue(controller.setCurveFanSpeed(id: 0, value: 2400))
        XCTAssertEqual(fake.calls, [["list", "-f", "--strict"], ["fan", "0", "-m", "1"],
                                   ["fan", "0", "-v", "2400"], ["list", "-f", "--strict"]])
        XCTAssertEqual(controller.state.deadlines, [0: 108])
        XCTAssertTrue(controller.state.pendingAuto.isEmpty)
        fake.clock = 103
        XCTAssertTrue(controller.setCurveFanSpeed(id: 0, value: 2500))
        XCTAssertEqual(controller.state.deadlines[0], 111)
    }

    func testStdoutErrorWithExitZeroFailsBeforeSpeed() {
        let fake = FakeFanCLI()
        fake.overrides["fan/0/-m/1"] = [SMCCommandResult(output: "Error write: denied")]
        let controller = fake.controller()
        XCTAssertFalse(controller.setCurveFanSpeed(id: 0, value: 2400))
        XCTAssertFalse(fake.calls.contains(["fan", "0", "-v", "2400"]))
        XCTAssertTrue(fake.calls.contains(["fan", "0", "-m", "0"]))
        XCTAssertTrue(controller.state.deadlines.isEmpty)
    }

    func testSpeedFailureCancelsOldLeaseAndRetriesRecovery() {
        let fake = FakeFanCLI()
        let controller = fake.controller()
        XCTAssertTrue(controller.setCurveFanSpeed(id: 0, value: 2400))
        fake.clock = 103
        fake.overrides["fan/0/-v/2500"] = [SMCCommandResult(error: "denied")]
        fake.overrides["fan/0/-m/0"] = [SMCCommandResult(output: "[F0md] write failed")]
        XCTAssertFalse(controller.setCurveFanSpeed(id: 0, value: 2500))
        XCTAssertNil(controller.state.deadlines[0])
        XCTAssertEqual(controller.state.pendingAuto, [0])
        controller.watchdog()
        XCTAssertEqual(fake.values["F0md"], 0)
        XCTAssertFalse(controller.state.needsRecovery)
    }

    func testSilentModeWriteFailureIsDetectedByReadback() {
        let fake = FakeFanCLI()
        fake.ignored.insert("fan/0/-m/1")
        let controller = fake.controller()
        XCTAssertFalse(controller.setCurveFanSpeed(id: 0, value: 2400))
        XCTAssertTrue(controller.state.deadlines.isEmpty)
        XCTAssertEqual(fake.values["F0md"], 0)
    }

    func testSilentTargetWriteFailureIsDetectedByReadback() {
        let fake = FakeFanCLI()
        fake.ignored.insert("fan/0/-v/2400")
        let controller = fake.controller()
        XCTAssertFalse(controller.setCurveFanSpeed(id: 0, value: 2400))
        XCTAssertTrue(controller.state.deadlines.isEmpty)
        XCTAssertEqual(fake.values["F0md"], 0)
    }

    func testInvalidArgumentsAndHardwareLimitsNeverWrite() {
        let fake = FakeFanCLI()
        let controller = fake.controller()
        for id in [Int.min, -1, 10, Int.max] {
            XCTAssertFalse(controller.setCurveFanSpeed(id: id, value: 2400))
        }
        for speed in [Int.min, -1, 0, 1199, 6001, 16384, Int.max] {
            XCTAssertFalse(controller.setCurveFanSpeed(id: 0, value: speed))
        }
        XCTAssertFalse(controller.setCurveFanSpeed(id: 2, value: 2400))
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testMissingOrNonfiniteReadbackIsRejected() {
        let fake = FakeFanCLI()
        let controller = fake.controller()
        fake.values.removeValue(forKey: "F0md")
        XCTAssertFalse(controller.setCurveFanSpeed(id: 0, value: 2400))
        fake.values["F0md"] = 0
        fake.values["F0Mx"] = .nan
        XCTAssertFalse(controller.setCurveFanSpeed(id: 0, value: 2400))
        fake.values["F0Mx"] = 6000
        fake.values.removeValue(forKey: "F0Mn")
        XCTAssertFalse(controller.setCurveFanSpeed(id: 0, value: 2400))
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testWatchdogPreservesUnrelatedManualFan() {
        let fake = FakeFanCLI(count: 3)
        fake.mode(2, 1)
        let controller = fake.controller()
        XCTAssertTrue(controller.setCurveFanSpeed(id: 0, value: 2400))
        fake.clock = 107.999
        controller.watchdog()
        XCTAssertEqual(fake.values["F0md"], 1)
        fake.clock = 108
        controller.watchdog()
        XCTAssertEqual(fake.values["F0md"], 0)
        XCTAssertEqual(fake.values["F2md"], 1)
        XCTAssertFalse(fake.calls.contains(["reset"]))
        XCTAssertTrue(controller.state.pendingReset)
        fake.mode(2, 3)
        controller.watchdog()
        XCTAssertTrue(fake.calls.contains(["reset"]))
        XCTAssertFalse(controller.state.needsRecovery)
    }

    func testReleaseWithoutLeaseStillReturnsAutomatic() {
        let fake = FakeFanCLI()
        fake.mode(0, 1)
        fake.mode(1, 1)
        let controller = fake.controller()
        XCTAssertTrue(controller.releaseCurveFan(id: 0))
        XCTAssertEqual(fake.values["F0md"], 0)
        XCTAssertEqual(fake.values["F1md"], 1)
        XCTAssertEqual(fake.writes, [["fan", "0", "-m", "0"]])
    }

    func testReleaseErrorsAreRetriedWithoutAnActiveLease() {
        let fake = FakeFanCLI()
        fake.mode(0, 1)
        fake.overrides["fan/0/-m/0"] = Array(repeating: SMCCommandResult(timedOut: true), count: 3)
        let controller = fake.controller()
        XCTAssertFalse(controller.releaseCurveFan(id: 0))
        for _ in 0..<2 {
            controller.watchdog()
            XCTAssertEqual(controller.state.pendingAuto, [0])
            XCTAssertTrue(controller.state.deadlines.isEmpty)
        }
        controller.watchdog()
        XCTAssertFalse(controller.state.needsRecovery)
        XCTAssertEqual(fake.values["F0md"], 0)
    }

    func testSilentAutomaticWriteFailureStaysPending() {
        let fake = FakeFanCLI()
        fake.mode(0, 1)
        fake.ignored.insert("fan/0/-m/0")
        let controller = fake.controller()
        XCTAssertFalse(controller.releaseCurveFan(id: 0))
        XCTAssertEqual(controller.state.pendingAuto, [0])
        XCTAssertFalse(fake.calls.contains(["reset"]))
        fake.ignored.remove("fan/0/-m/0")
        controller.watchdog()
        XCTAssertFalse(controller.state.needsRecovery)
    }

    func testResetFailureRemainsPendingAndIsRetried() {
        let fake = FakeFanCLI()
        fake.overrides["reset"] = [SMCCommandResult(output: "[reset] fan control reset FAILED")]
        let controller = fake.controller()
        XCTAssertFalse(controller.releaseCurveFan(id: 0))
        XCTAssertTrue(controller.state.pendingAuto.isEmpty)
        XCTAssertTrue(controller.state.pendingReset)
        controller.watchdog()
        XCTAssertFalse(controller.state.needsRecovery)
        XCTAssertEqual(fake.calls.filter { $0 == ["reset"] }.count, 2)
    }

    func testDisconnectRecoversAllCurveFansWithoutStarvation() {
        let fake = FakeFanCLI()
        let controller = fake.controller()
        XCTAssertTrue(controller.setCurveFanSpeed(id: 0, value: 2400))
        XCTAssertTrue(controller.setCurveFanSpeed(id: 1, value: 2500))
        fake.overrides["fan/0/-m/0"] = [SMCCommandResult(error: "temporarily unavailable")]
        controller.disconnected()
        XCTAssertTrue(controller.state.deadlines.isEmpty)
        controller.watchdog()
        XCTAssertEqual(controller.state.pendingAuto, [0, 1])
        controller.watchdog()
        XCTAssertEqual(controller.state.pendingAuto, [0])
        XCTAssertEqual(fake.values["F1md"], 0)
        XCTAssertFalse(fake.calls.contains(["reset"]))
        controller.watchdog()
        XCTAssertFalse(controller.state.needsRecovery)
        XCTAssertEqual(fake.values["F0md"], 0)
    }

    func testManualTakeoverCancelsBothLeaseAndPendingRecovery() {
        let fake = FakeFanCLI()
        let controller = fake.controller()
        XCTAssertTrue(controller.setCurveFanSpeed(id: 0, value: 2400))
        controller.disconnected()
        controller.cancelForManualCommand(id: 0)
        _ = fake.execute(["fan", "0", "-m", "1"], 4)
        fake.clock = 1000
        controller.watchdog()
        XCTAssertNil(controller.state.deadlines[0])
        XCTAssertFalse(controller.state.pendingAuto.contains(0))
        XCTAssertFalse(fake.calls.contains(["fan", "0", "-m", "0"]))
        XCTAssertFalse(fake.calls.contains(["reset"]))
    }

    func testUnknownOtherModePreventsGlobalReset() {
        let fake = FakeFanCLI()
        fake.values.removeValue(forKey: "F1md")
        let controller = fake.controller()
        XCTAssertFalse(controller.releaseCurveFan(id: 0))
        controller.watchdog()
        XCTAssertFalse(fake.calls.contains(["reset"]))
        XCTAssertTrue(controller.state.pendingReset)
    }

    func testStrictSnapshotRejectsUnavailableInAnyFieldWithExitZero() {
        for intel in [false, true] {
            let fake = FakeFanCLI(intel: intel)
            for key in fake.values.keys.sorted() {
                fake.unavailable = [key]
                let result = fake.execute(["list", "-f", "--strict"], 4)
                XCTAssertTrue(result.succeeded)
                XCTAssertTrue(result.output.contains("[\(key)]    UNAVAILABLE"))
                XCTAssertEqual(result.output.components(separatedBy: .newlines).count, fake.values.count + 1)
                XCTAssertNil(FanSMCSnapshot(result, usesIntelMask: intel), key)
            }
        }
    }

    func testStrictSnapshotAcceptsGenuineZeroModes() {
        for intel in [false, true] {
            let fake = FakeFanCLI(intel: intel)
            fake.values["F0Tg"] = 0
            let result = fake.execute(["list", "-f", "--strict"], 4)
            let snapshot = FanSMCSnapshot(result, usesIntelMask: intel)
            XCTAssertEqual(snapshot?.mode(id: 0), 0)
            XCTAssertEqual(snapshot?.values["F0Tg"], 0)
            XCTAssertTrue(snapshot?.allAutomatic == true)
        }
    }

    func testUnavailableOtherFanModeNeverAuthorizesGlobalReset() {
        for intel in [false, true] {
            let fake = FakeFanCLI(intel: intel)
            fake.mode(1, 1)
            fake.unavailable = [intel ? "F1Md" : "F1md"]
            let controller = fake.controller()
            XCTAssertFalse(controller.releaseCurveFan(id: 0))
            controller.watchdog()
            XCTAssertEqual(controller.state.pendingAuto, [0])
            XCTAssertEqual(fake.values[intel ? "F1Md" : "F1md"], 1)
            XCTAssertFalse(fake.calls.contains(["reset"]))
            fake.unavailable = []
            controller.watchdog()
            XCTAssertTrue(controller.state.pendingAuto.isEmpty)
            XCTAssertFalse(fake.calls.contains(["reset"]))
            fake.mode(1, 0)
            controller.watchdog()
            XCTAssertTrue(fake.calls.contains(["reset"]))
            XCTAssertFalse(controller.state.needsRecovery)
        }
    }

    func testUnavailableOwnModeCannotConfirmAutomaticRecovery() {
        let fake = FakeFanCLI()
        let controller = fake.controller()
        XCTAssertTrue(controller.setCurveFanSpeed(id: 0, value: 2400))
        fake.unavailable = ["F0md"]
        fake.ignored.insert("fan/0/-m/0")
        XCTAssertFalse(controller.releaseCurveFan(id: 0))
        controller.watchdog()
        XCTAssertEqual(fake.values["F0md"], 1)
        XCTAssertEqual(controller.state.pendingAuto, [0])
        XCTAssertFalse(fake.calls.contains(["reset"]))
        fake.unavailable = []
        fake.ignored.remove("fan/0/-m/0")
        controller.watchdog()
        XCTAssertFalse(controller.state.needsRecovery)
    }

    func testUnavailableFanModeBlocksLegacyGlobalReset() {
        let fake = FakeFanCLI()
        fake.mode(1, 1)
        fake.unavailable = ["F1md"]
        let controller = fake.controller()
        XCTAssertFalse(controller.resetFanControl().succeeded)
        XCTAssertEqual(fake.calls, [["list", "-f", "--strict"]])
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testIntelMaskPreservesOtherManualFan() {
        let fake = FakeFanCLI(intel: true)
        fake.mode(1, 1)
        let controller = fake.controller()
        XCTAssertTrue(controller.setCurveFanSpeed(id: 0, value: 2400))
        XCTAssertEqual(fake.values["FS! "], 3)
        XCTAssertTrue(controller.releaseCurveFan(id: 0))
        XCTAssertEqual(fake.values["FS! "], 2)
        XCTAssertEqual(fake.values["F1Md"], 1)
        XCTAssertFalse(fake.calls.contains(["reset"]))
    }

    func testInconsistentIntelMaskIsNotAConfirmedMode() {
        let fake = FakeFanCLI(intel: true)
        fake.values["F0Md"] = 1
        let controller = fake.controller()
        XCTAssertFalse(controller.setCurveFanSpeed(id: 0, value: 2400))
        XCTAssertTrue(fake.writes.isEmpty)
    }

    func testEntireUpdateUsesOneBoundedCommandBudget() {
        let fake = FakeFanCLI()
        fake.delays["fan/0/-m/1"] = 4
        let controller = fake.controller()
        XCTAssertFalse(controller.setCurveFanSpeed(id: 0, value: 2400))
        XCTAssertFalse(fake.calls.contains(["fan", "0", "-v", "2400"]))
        XCTAssertEqual(controller.state.pendingAuto, [0])
        XCTAssertTrue(fake.budgets.allSatisfy { $0 > 0 && $0 <= 4 })
        controller.watchdog()
        XCTAssertFalse(controller.state.needsRecovery)
    }

    func testLegacyResetDoesNotOverrideOtherManualOwnership() {
        let fake = FakeFanCLI()
        fake.mode(1, 1)
        let controller = fake.controller()
        XCTAssertTrue(controller.setCurveFanSpeed(id: 0, value: 2400))
        XCTAssertFalse(controller.resetFanControl().succeeded)
        XCTAssertEqual(fake.values["F0md"], 0)
        XCTAssertEqual(fake.values["F1md"], 1)
        XCTAssertFalse(fake.calls.contains(["reset"]))
    }

    func testLegacyResetSharesOneBudgetAcrossAllCurveFans() {
        let fake = FakeFanCLI()
        let controller = fake.controller()
        XCTAssertTrue(controller.setCurveFanSpeed(id: 0, value: 2400))
        XCTAssertTrue(controller.setCurveFanSpeed(id: 1, value: 2500))
        fake.delays["fan/0/-m/0"] = 4
        XCTAssertFalse(controller.resetFanControl().succeeded)
        XCTAssertFalse(fake.calls.contains(["fan", "1", "-m", "0"]))
        XCTAssertEqual(controller.state.pendingAuto, [0, 1])
        fake.delays.removeValue(forKey: "fan/0/-m/0")
        controller.watchdog()
        controller.watchdog()
        XCTAssertFalse(controller.state.needsRecovery)
    }

    func testResetReadbackMustConfirmFtstCleared() {
        let fake = FakeFanCLI()
        fake.values["Ftst"] = 1
        fake.ignored.insert("reset")
        let controller = fake.controller()
        XCTAssertFalse(controller.releaseCurveFan(id: 0))
        XCTAssertTrue(controller.state.pendingReset)
        fake.ignored.remove("reset")
        controller.watchdog()
        XCTAssertFalse(controller.state.needsRecovery)
    }

    #if !FAN_HELPER_MOCK_ONLY
    func testProcessStdoutErrorExitZeroIsNotSuccess() {
        let result = SMCProcessRunner().run(path: "/usr/bin/perl", arguments: ["-e", "print 'Error write: denied';"])
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.succeeded)
        XCTAssertNotNil(result.failure)
    }

    func testProcessDrainsBothPipesLargerThanPipeCapacity() {
        let result = SMCProcessRunner().run(path: "/usr/bin/perl", arguments: ["-e",
            "print STDERR 'e' x 100000; print STDOUT 'o' x 100000;"])
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.output.count, 100000)
        XCTAssertEqual(result.error?.count, 100000)
    }

    func testProcessOutputIsBoundedAndOverflowFails() {
        let result = SMCProcessRunner().run(path: "/usr/bin/perl", arguments: ["-e",
            "print STDERR 'e' x 1100000; print STDOUT 'o' x 1100000;"])
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.output.count, 1_048_576)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.error?.contains("exceeded limit") == true)
    }

    func testProcessNonzeroExitIsRejected() {
        let result = SMCProcessRunner().run(path: "/usr/bin/perl", arguments: ["-e", "exit 7;"])
        XCTAssertEqual(result.status, 7)
        XCTAssertFalse(result.succeeded)
    }

    func testProcessTimeoutKillsTermIgnoringProcessAndAllowsNextCommand() {
        let runner = SMCProcessRunner()
        let start = ProcessInfo.processInfo.systemUptime
        let result = runner.run(path: "/usr/bin/perl", arguments: ["-e", "$SIG{TERM} = 'IGNORE'; sleep 30;"], timeout: 0.2)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.5)
        XCTAssertTrue(runner.run(path: "/usr/bin/perl", arguments: ["-e", "print 'ok';"]).succeeded)
    }

    func testProcessTimeoutCannotExceedFiveSeconds() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = SMCProcessRunner().run(path: "/usr/bin/perl", arguments: ["-e", "$SIG{TERM} = 'IGNORE'; sleep 30;"], timeout: 30)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 5)
    }

    func testProcessContinuousOutputCannotDefeatTimeout() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = SMCProcessRunner().run(path: "/usr/bin/perl", arguments: ["-e",
            "$| = 1; while (1) { print STDOUT 'o' x 16384; print STDERR 'e' x 16384; }"], timeout: 0.2)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThanOrEqual(result.output.count, 1_048_576)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.5)
    }

    func testProcessInheritedPipesHaveBoundedDrainWait() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = SMCProcessRunner().run(path: "/usr/bin/perl", arguments: ["-e",
            "if (fork() == 0) { sleep 1; exit 0; } exit 0;"])
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.5)
    }

    func testProcessLaunchFailureIsReported() {
        let result = SMCProcessRunner().run(path: "/no-such-fan-helper-test-tool", arguments: [])
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.error?.contains("runSMC") == true)
    }
    #endif
}

enum FanHelperTestMain {
    static func main() {
        let suite = FanHelperTests.defaultTestSuite
        suite.run()
        guard let result = suite.testRun, result.executionCount > 0 else { exit(1) }
        exit(result.hasSucceeded ? 0 : 1)
    }
}
#endif
