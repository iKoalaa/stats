import Foundation
import XCTest
@testable import Kit

final class FanCurveControllerTests: XCTestCase {
    private final class State {
        var now: TimeInterval = 100
        var helperAvailable = true
        var helperChecks = 0
        var sendResult: Bool? = true
        var sendResults: [Int: Bool] = [:]
        var releaseResult: Bool? = true
        var cancellations: [Set<Int>] = []
        var commands: [(id: Int, rpm: Int, at: TimeInterval, completion: (Bool) -> Void)] = []
        var releases: [(id: Int, at: TimeInterval, completion: (Bool) -> Void)] = []
    }

    private final class Runtime {
        private let state: State
        let controller: FanCurveController
        var now: TimeInterval {
            get { state.now }
            set { state.now = newValue }
        }
        var helperAvailable: Bool {
            get { state.helperAvailable }
            set { state.helperAvailable = newValue }
        }
        var sendResult: Bool? {
            get { state.sendResult }
            set { state.sendResult = newValue }
        }
        var sendResults: [Int: Bool] {
            get { state.sendResults }
            set { state.sendResults = newValue }
        }
        var releaseResult: Bool? {
            get { state.releaseResult }
            set { state.releaseResult = newValue }
        }
        var helperChecks: Int { state.helperChecks }
        var cancellations: [Set<Int>] { state.cancellations }
        var commands: [(id: Int, rpm: Int, at: TimeInterval, completion: (Bool) -> Void)] { state.commands }
        var releases: [(id: Int, at: TimeInterval, completion: (Bool) -> Void)] { state.releases }

        init(configuration: FanCurveConfiguration = FanCurveConfiguration(useLoad: false),
             enabledFans: Set<Int> = [], synchronized: Bool = true) {
            precondition(Thread.isMainThread)
            // Non-nil options and every runtime dependency avoid Store and SMCHelper.
            let state = State()
            self.state = state
            self.controller = FanCurveController(
                configuration: configuration, enabledFans: enabledFans,
                synchronized: synchronized, persists: false,
                clock: { state.now },
                helperAvailable: { state.helperChecks += 1; return state.helperAvailable },
                cancelLegacy: { ids in
                    precondition(Thread.isMainThread)
                    state.cancellations.append(ids)
                },
                send: { id, rpm, completion in
                    precondition(Thread.isMainThread)
                    state.commands.append((id, rpm, state.now, completion))
                    if let result = state.sendResults[id] ?? state.sendResult { completion(result) }
                },
                release: { id, completion in
                    precondition(Thread.isMainThread)
                    state.releases.append((id, state.now, completion))
                    if let result = state.releaseResult { completion(result) }
                }
            )
        }

        func tick() {
            controller.tick()
        }

        func sample(fans: [FanCurveFan]? = nil, temperature: Double = 75,
                    sensors: [FanCurveSensor]? = nil, hot: Double? = 75,
                    at: TimeInterval? = nil) {
            controller.updateSensors(
                fans: fans ?? [FanCurveFan(id: 0, name: "CPU fan", minRPM: 1200, maxRPM: 6000, rpm: 1800)],
                sensors: sensors ?? [FanCurveSensor(key: "Hottest CPU", name: "CPU", value: temperature)],
                hotTemperature: hot, at: at ?? now
            )
        }
    }

    private func onMain(_ body: () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.sync(execute: body)
        }
    }

    private func pump(file: StaticString = #filePath, line: UInt = #line) {
        precondition(Thread.isMainThread)
        // A failed send can enqueue a release acknowledgement from its own callback.
        for _ in 0..<2 {
            var drained = false
            DispatchQueue.main.async { drained = true }
            let deadline = Date(timeIntervalSinceNow: 1)
            while !drained && Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            }
            XCTAssertTrue(drained, "Main-queue callbacks did not drain", file: file, line: line)
        }
    }
}

// MARK: - Input validation and curve calculation
extension FanCurveControllerTests {
    func testMetadataAtZeroNeverAuthorizesCommandsEvenInEmergency() {
        onMain {
            let runtime = Runtime(enabledFans: [0])
            runtime.sample(temperature: 100, hot: 100, at: 0)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.controller.fans.map { $0.id }, [0])
            XCTAssertTrue(runtime.controller.isCurveEnabled(for: 0))
            XCTAssertTrue(runtime.commands.isEmpty)
            XCTAssertTrue(runtime.releases.isEmpty)
            XCTAssertTrue(runtime.controller.activeFans.isEmpty)
            XCTAssertTrue(runtime.controller.targetRPM.isEmpty)
        }
    }

    func testEnablingDiscardsSamplesAndRequiresFreshTemperatureAndBothLoads() {
        onMain {
            let runtime = Runtime(configuration: FanCurveConfiguration(useLoad: true))
            runtime.sample()
            runtime.controller.updateLoad(.cpu, value: 1, at: 100)
            runtime.controller.updateLoad(.gpu, value: 1, at: 100)
            runtime.now = 101
            runtime.controller.enableCurve(for: 0)
            XCTAssertEqual(runtime.releases.map { $0.id }, [0])
            pump()
            runtime.tick()
            XCTAssertTrue(runtime.commands.isEmpty)
            runtime.sample(at: 100)
            runtime.tick()
            XCTAssertTrue(runtime.commands.isEmpty)
            runtime.sample(temperature: 50)
            runtime.tick()
            XCTAssertTrue(runtime.commands.isEmpty)
            runtime.controller.updateLoad(.cpu, value: 1, at: 101)
            runtime.tick()
            XCTAssertTrue(runtime.commands.isEmpty)
            runtime.controller.updateLoad(.gpu, value: 0, at: 100)
            runtime.tick()
            XCTAssertTrue(runtime.commands.isEmpty)
            runtime.controller.updateLoad(.gpu, value: 0, at: 101)
            runtime.tick()
            XCTAssertEqual(runtime.commands.map { $0.rpm }, [4200])
            XCTAssertTrue(runtime.controller.activeFans.isEmpty)
            pump()
            XCTAssertEqual(runtime.controller.activeFans, [0])
            XCTAssertEqual(runtime.controller.targetRPM, [0: 4200])
        }
    }

    func testChosenSensorControlsCurveNotHottestOrUnrelatedSensor() {
        onMain {
            let profile = FanCurveProfile(sensorKey: "chosen")
            let runtime = Runtime(configuration: FanCurveConfiguration(shared: profile, useLoad: false), enabledFans: [0])
            runtime.sample(sensors: [FanCurveSensor(key: "other", name: "Other", value: 90),
                                     FanCurveSensor(key: "chosen", name: "Chosen", value: 55)], hot: 90)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.commands.map { $0.rpm }, [1200])
            XCTAssertEqual(runtime.controller.targetRPM, [0: 1200])
        }
    }

    func testMissingOrInvalidChosenSensorReleasesActiveFan() {
        onMain {
            let sources: [[FanCurveSensor]] = [[]] + [nil, Double.nan, .infinity, 0, -1, 151].map {
                [FanCurveSensor(key: "Hottest CPU", name: "CPU", value: $0)]
            }
            for sensors in sources {
                let runtime = Runtime(enabledFans: [0])
                runtime.sample()
                runtime.tick()
                pump()
                runtime.sample(sensors: sensors)
                runtime.tick()
                pump()
                XCTAssertEqual(runtime.commands.count, 1)
                XCTAssertEqual(runtime.releases.map { $0.id }, [0])
                XCTAssertTrue(runtime.controller.activeFans.isEmpty)
                XCTAssertTrue(runtime.controller.targetRPM.isEmpty)
                XCTAssertTrue(runtime.controller.isCurveEnabled(for: 0))
            }
        }
    }

    func testInvalidOrFutureTemperatureSnapshotNeverAuthorizesCommands() {
        onMain {
            for hot: Double? in [nil, .nan, .infinity, 0, -1, 151] {
                let runtime = Runtime(enabledFans: [0])
                runtime.sample(hot: hot)
                runtime.tick()
                XCTAssertTrue(runtime.commands.isEmpty)
            }
            let runtime = Runtime(enabledFans: [0])
            runtime.sample(at: 101)
            runtime.tick()
            XCTAssertTrue(runtime.commands.isEmpty)
        }
    }

    func testInvalidConfigurationNeverSendsEvenInEmergencyAndInvalidEditsAreIgnored() {
        onMain {
            let invalid = FanCurveProfile(points: [])
            let configurations = [FanCurveConfiguration(shared: invalid), FanCurveConfiguration(cpu: invalid),
                                  FanCurveConfiguration(gpu: invalid), FanCurveConfiguration(cpuFanID: -1),
                                  FanCurveConfiguration(cpuFanID: 0, gpuFanID: 0)]
            for configuration in configurations {
                let runtime = Runtime(configuration: configuration, enabledFans: [0])
                runtime.sample(temperature: 100, hot: 100)
                runtime.tick()
                XCTAssertTrue(runtime.commands.isEmpty)
                XCTAssertEqual(runtime.controller.status, "Fan curve configuration invalid")
            }
            let runtime = Runtime(enabledFans: [0])
            let original = runtime.controller.configuration
            runtime.controller.updateProfile(.shared, profile: invalid)
            XCTAssertEqual(runtime.controller.configuration, original)
            runtime.sample()
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.controller.targetRPM, [0: 3000])
        }
    }

    func testRPMUsesEachFansMinimumAndMaximumIncludingFractionalBounds() {
        onMain {
            for (temperature, expected) in [(20.0, 1201), (75, 3000), (90, 6000)] {
                let runtime = Runtime(enabledFans: [0])
                runtime.sample(fans: [FanCurveFan(id: 0, name: "Fractional", minRPM: 1200.1,
                                                maxRPM: 6000.9, rpm: 2000)], temperature: temperature)
                runtime.tick()
                pump()
                XCTAssertEqual(runtime.commands.map { $0.rpm }, [expected])
                XCTAssertEqual(runtime.controller.targetRPM, [0: expected])
            }
        }
    }

    func testInvalidHardwareMetadataIsFilteredAndCannotBeEnabled() {
        onMain {
            let runtime = Runtime()
            let fans = [FanCurveFan(id: -1, name: "Negative ID", minRPM: 1200, maxRPM: 6000, rpm: 0),
                        FanCurveFan(id: 10, name: "Invalid ID", minRPM: 1200, maxRPM: 6000, rpm: 0),
                        FanCurveFan(id: 0, name: "NaN", minRPM: .nan, maxRPM: 6000, rpm: 0),
                        FanCurveFan(id: 1, name: "Reversed", minRPM: 6000, maxRPM: 1200, rpm: 0),
                        FanCurveFan(id: 2, name: "No integer RPM", minRPM: 1200.1, maxRPM: 1200.9, rpm: 0)]
            runtime.sample(fans: fans)
            for fan in fans { runtime.controller.enableCurve(for: fan.id) }
            runtime.tick()
            XCTAssertTrue(runtime.controller.fans.isEmpty)
            XCTAssertTrue(runtime.commands.isEmpty)
            for fan in fans { XCTAssertFalse(runtime.controller.isCurveEnabled(for: fan.id)) }
        }
    }

    func testEmergencyAt95BypassesMissingLoadsAndMissingOrInvalidChosenSource() {
        onMain {
            for hot in [94.999, 95.0] {
                for sources in [[], [FanCurveSensor(key: "Hottest CPU", name: "CPU", value: .nan)],
                                [FanCurveSensor(key: "Hottest CPU", name: "CPU", value: 20)]] {
                    let runtime = Runtime(configuration: FanCurveConfiguration(useLoad: true), enabledFans: [0])
                    runtime.sample(sensors: sources, hot: hot)
                    runtime.tick()
                    pump()
                    if hot < 95 {
                        XCTAssertTrue(runtime.commands.isEmpty)
                    } else {
                        XCTAssertEqual(runtime.commands.map { $0.rpm }, [6000])
                        XCTAssertEqual(runtime.controller.targetRPM, [0: 6000])
                        XCTAssertEqual(runtime.controller.status, "Emergency cooling")
                    }
                }
            }
            let runtime = Runtime(enabledFans: [0])
            runtime.sample(temperature: 20)
            runtime.tick()
            pump()
            runtime.sample(sensors: [], hot: 95)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.commands.map { $0.rpm }, [1200, 6000])
        }
    }

    func testOnePointProfileIsConstantOnBothSidesOfItsTemperature() {
        onMain {
            let profile = FanCurveProfile(points: [FanCurvePoint(percent: 37, temperature: 60)])
            for temperature in [20.0, 60, 90] {
                let runtime = Runtime(configuration: FanCurveConfiguration(shared: profile, useLoad: false), enabledFans: [0])
                runtime.sample(temperature: temperature)
                runtime.tick()
                pump()
                XCTAssertEqual(runtime.commands.map { $0.rpm }, [2220])
            }
        }
    }

    func testSynchronizedFansSharePercentNotAbsoluteRPMAndStopTogether() {
        onMain {
            let runtime = Runtime()
            let fans = [FanCurveFan(id: 0, name: "CPU", minRPM: 1200, maxRPM: 6000, rpm: 1800),
                        FanCurveFan(id: 1, name: "GPU", minRPM: 800, maxRPM: 4000, rpm: 1000)]
            runtime.sample(fans: fans, at: 0)
            runtime.controller.enableCurve(for: 1)
            XCTAssertTrue(runtime.controller.isCurveEnabled(for: 0))
            XCTAssertTrue(runtime.controller.isCurveEnabled(for: 1))
            XCTAssertEqual(runtime.controller.enabledFans, [0, 1])
            XCTAssertEqual(Set(runtime.releases.map { $0.id }), [0, 1])
            XCTAssertEqual(runtime.releases.count, 2)
            pump()
            runtime.sample(fans: fans)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.commands.map { $0.id }, [0, 1])
            XCTAssertEqual(runtime.commands.map { $0.rpm }, [3000, 2000])
            XCTAssertEqual(runtime.controller.targetRPM, [0: 3000, 1: 2000])
            runtime.controller.stopCurve(for: 1)
            pump()
            XCTAssertEqual(Set(runtime.releases.map { $0.id }), [0, 1])
            XCTAssertEqual(runtime.releases.count, 4)
            XCTAssertTrue(runtime.controller.enabledFans.isEmpty)
            XCTAssertFalse(runtime.controller.isCurveEnabled(for: 0))
            XCTAssertFalse(runtime.controller.isCurveEnabled(for: 1))
            XCTAssertTrue(runtime.controller.activeFans.isEmpty)
        }
    }

    func testIndependentProfilesUsePhysicalMappingOwnSensorsAndOwnLoadOnly() {
        onMain {
            let configuration = FanCurveConfiguration(cpu: FanCurveProfile(sensorKey: "cpu"),
                                                     gpu: FanCurveProfile(sensorKey: "gpu"),
                                                     cpuFanID: 1, gpuFanID: 0, useLoad: true)
            let runtime = Runtime(configuration: configuration, enabledFans: [0, 1], synchronized: false)
            let fans = [FanCurveFan(id: 0, name: "GPU", minRPM: 1200, maxRPM: 6000, rpm: 1800),
                        FanCurveFan(id: 1, name: "CPU", minRPM: 800, maxRPM: 4000, rpm: 1000)]
            runtime.sample(fans: fans, sensors: [FanCurveSensor(key: "cpu", name: "CPU", value: 50),
                                               FanCurveSensor(key: "gpu", name: "GPU", value: 75)])
            runtime.controller.updateLoad(.cpu, value: 1, at: 100)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.commands.map { $0.id }, [1])
            XCTAssertEqual(runtime.commands.map { $0.rpm }, [2800])
            runtime.controller.updateLoad(.gpu, value: 0, at: 100)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.controller.targetRPM, [0: 3000, 1: 2800])
            runtime.controller.stopCurve(for: 0)
            pump()
            XCTAssertEqual(runtime.releases.map { $0.id }, [0])
            XCTAssertEqual(runtime.controller.activeFans, [1])
            XCTAssertTrue(runtime.controller.isCurveEnabled(for: 1))
        }
    }

    func testUnassignedFanCannotBeEnabledInIndependentMode() {
        onMain {
            let runtime = Runtime(synchronized: false)
            runtime.sample()
            runtime.controller.enableCurve(for: 0)
            runtime.tick()
            XCTAssertFalse(runtime.controller.isCurveEnabled(for: 0))
            XCTAssertTrue(runtime.commands.isEmpty)
        }
    }

    func testTemperatureAndLoadStayFreshAtFourSecondsButReleaseBeyondFour() {
        onMain {
            for staleTemperature in [true, false] {
                let runtime = Runtime(configuration: FanCurveConfiguration(useLoad: true), enabledFans: [0])
                runtime.sample()
                runtime.controller.updateLoad(.cpu, value: 0, at: 100)
                runtime.controller.updateLoad(.gpu, value: 0, at: 100)
                runtime.tick()
                pump()
                runtime.now = 104
                runtime.tick()
                pump()
                XCTAssertEqual(runtime.commands.count, 2)
                XCTAssertTrue(runtime.releases.isEmpty)
                runtime.now = 104.001
                if !staleTemperature { runtime.sample() }
                runtime.tick()
                pump()
                XCTAssertEqual(runtime.commands.count, 2)
                XCTAssertEqual(runtime.releases.map { $0.id }, [0])
                XCTAssertTrue(runtime.controller.activeFans.isEmpty)
                XCTAssertTrue(runtime.controller.targetRPM.isEmpty)
                XCTAssertTrue(runtime.controller.isCurveEnabled(for: 0))
            }
        }
    }

    func testInvalidLoadSamplesClearPreviouslyFreshLoadAndSharedLoadIsIgnored() {
        onMain {
            let samples: [(Double?, TimeInterval)] = [(nil, 100), (.nan, 100), (.infinity, 100),
                                                     (-0.1, 100), (1.1, 100), (0.5, 0), (0.5, 101)]
            for (value, at) in samples {
                let runtime = Runtime(configuration: FanCurveConfiguration(useLoad: true), enabledFans: [0])
                runtime.sample()
                runtime.controller.updateLoad(.cpu, value: 0, at: 100)
                runtime.controller.updateLoad(.gpu, value: 0, at: 100)
                runtime.tick()
                pump()
                runtime.controller.updateLoad(.cpu, value: value, at: at)
                runtime.controller.updateLoad(.shared, value: 1, at: 100)
                runtime.tick()
                pump()
                XCTAssertEqual(runtime.commands.count, 1)
                XCTAssertEqual(runtime.releases.map { $0.id }, [0])
            }
        }
    }

    func testSleepAndPausePreserveRequestButRequireFreshDataAfterResume() {
        onMain {
            for sleeping in [false, true] {
                let runtime = Runtime(configuration: FanCurveConfiguration(useLoad: true), enabledFans: [0])
                runtime.sample()
                runtime.controller.updateLoad(.cpu, value: 0, at: 100)
                runtime.controller.updateLoad(.gpu, value: 0, at: 100)
                runtime.tick()
                pump()
                runtime.now = 101
                if sleeping { runtime.controller.setSleeping(true) } else { runtime.controller.setPaused(true) }
                pump()
                XCTAssertEqual(runtime.releases.map { $0.id }, [0])
                XCTAssertTrue(runtime.controller.isCurveEnabled(for: 0))
                XCTAssertTrue(runtime.controller.activeFans.isEmpty)
                XCTAssertTrue(runtime.controller.targetRPM.isEmpty)
                runtime.sample()
                runtime.controller.updateLoad(.cpu, value: 0, at: 101)
                runtime.controller.updateLoad(.gpu, value: 0, at: 101)
                runtime.tick()
                XCTAssertEqual(runtime.commands.count, 1)
                runtime.now = 102
                if sleeping { runtime.controller.setSleeping(false) } else { runtime.controller.setPaused(false) }
                runtime.tick()
                XCTAssertEqual(runtime.commands.count, 1)
                runtime.sample(at: 101)
                runtime.controller.updateLoad(.cpu, value: 0, at: 101)
                runtime.controller.updateLoad(.gpu, value: 0, at: 101)
                runtime.tick()
                XCTAssertEqual(runtime.commands.count, 1)
                runtime.sample()
                runtime.tick()
                XCTAssertEqual(runtime.commands.count, 1)
                runtime.controller.updateLoad(.cpu, value: 0, at: 102)
                runtime.controller.updateLoad(.gpu, value: 0, at: 102)
                runtime.tick()
                pump()
                XCTAssertEqual(runtime.commands.count, 2)
                XCTAssertEqual(runtime.controller.activeFans, [0])
            }
        }
    }

}

// MARK: - Control lifecycle and ownership transitions
extension FanCurveControllerTests {
    func testDelayedCommandCallbacksAfterStopOrTerminateDoNotReactivate() {
        onMain {
            for terminating in [false, true] {
                for success in [false, true] {
                    let runtime = Runtime(enabledFans: [0])
                    runtime.sendResult = nil
                    runtime.sample()
                    runtime.tick()
                    XCTAssertEqual(runtime.commands.count, 1)
                    if terminating { runtime.controller.terminate() } else { runtime.controller.stopCurve(for: 0) }
                    pump()
                    XCTAssertEqual(runtime.releases.map { $0.id }, [0])
                    runtime.commands[0].completion(success)
                    pump()
                    runtime.tick()
                    XCTAssertEqual(runtime.commands.count, 1)
                    XCTAssertEqual(runtime.releases.count, 1)
                    XCTAssertTrue(runtime.controller.activeFans.isEmpty)
                    XCTAssertTrue(runtime.controller.targetRPM.isEmpty)
                    if !terminating { XCTAssertFalse(runtime.controller.isCurveEnabled(for: 0)) }
                }
            }
        }
    }

    func testFailedCommandReleasesFanAndWaitsForAutomaticAcknowledgement() {
        onMain {
            let runtime = Runtime(enabledFans: [0])
            runtime.sendResult = false
            runtime.releaseResult = nil
            runtime.sample()
            runtime.tick()
            pump()
            XCTAssertTrue(runtime.controller.activeFans.isEmpty)
            XCTAssertTrue(runtime.controller.targetRPM.isEmpty)
            XCTAssertEqual(runtime.controller.status, "Fan curve command failed")
            XCTAssertEqual(runtime.releases.map { $0.id }, [0])
            runtime.sendResult = true
            runtime.tick()
            XCTAssertEqual(runtime.commands.count, 1)
            runtime.releases[0].completion(true)
            pump()
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.commands.count, 2)
            XCTAssertEqual(runtime.controller.activeFans, [0])
        }
    }

    func testPendingCommandTimesOutAtFiveSecondsAndLateSuccessIsIgnored() {
        onMain {
            let runtime = Runtime(enabledFans: [0])
            runtime.sendResult = nil
            runtime.sample()
            runtime.tick()
            runtime.now = 104.999
            runtime.sample()
            runtime.tick()
            XCTAssertEqual(runtime.commands.count, 1)
            XCTAssertTrue(runtime.releases.isEmpty)
            runtime.now = 105
            runtime.sample()
            runtime.tick()
            XCTAssertEqual(runtime.releases.map { $0.id }, [0])
            XCTAssertEqual(runtime.controller.status, "Fan curve command failed")
            runtime.commands[0].completion(true)
            pump()
            XCTAssertTrue(runtime.controller.activeFans.isEmpty)
            XCTAssertTrue(runtime.controller.targetRPM.isEmpty)
        }
    }

    func testFailedOrTimedOutReleaseRetriesAtFiveSecondsAndBlocksCommands() {
        onMain {
            for result: Bool? in [false, nil] {
                let runtime = Runtime(enabledFans: [0])
                runtime.releaseResult = result
                runtime.sample()
                runtime.tick()
                pump()
                runtime.controller.setPaused(true)
                pump()
                runtime.controller.setPaused(false)
                runtime.sample()
                runtime.tick()
                XCTAssertEqual(runtime.commands.count, 1)
                runtime.now = 104.999
                runtime.sample()
                runtime.tick()
                XCTAssertEqual(runtime.releases.count, 1)
                runtime.now = 105
                runtime.sample()
                runtime.tick()
                XCTAssertEqual(runtime.releases.count, 2)
                XCTAssertEqual(runtime.releases.map { $0.at }, [100, 105])
                XCTAssertEqual(runtime.commands.count, 1)
                runtime.releases[1].completion(true)
                pump()
                runtime.tick()
                pump()
                XCTAssertEqual(runtime.commands.count, 2)
                XCTAssertEqual(runtime.controller.activeFans, [0])
            }
        }
    }

    func testUnavailableHelperReleasesActiveFanWithoutSendingAnotherCommand() {
        onMain {
            let runtime = Runtime(enabledFans: [0])
            runtime.sample()
            runtime.tick()
            pump()
            runtime.helperAvailable = false
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.helperChecks, 2)
            XCTAssertEqual(runtime.commands.count, 1)
            XCTAssertEqual(runtime.releases.map { $0.id }, [0])
            XCTAssertTrue(runtime.controller.activeFans.isEmpty)
            XCTAssertEqual(runtime.controller.status, "Fan helper unavailable")
        }
    }

    func testDisablingSynchronizationClonesMissingProfilesWithoutAliasingOrOverwriting() {
        onMain {
            let shared = FanCurveProfile(sensorKey: "shared")
            let runtime = Runtime(configuration: FanCurveConfiguration(shared: shared, cpuFanID: 0,
                                                                        gpuFanID: 1, useLoad: false))
            runtime.controller.setSynchronized(false)
            XCTAssertEqual(runtime.controller.configuration.cpu, shared)
            XCTAssertEqual(runtime.controller.configuration.gpu, shared)
            let changedCPU = FanCurveProfile(points: [FanCurvePoint(percent: 80, temperature: 70)], sensorKey: "cpu")
            runtime.controller.updateProfile(.cpu, profile: changedCPU)
            XCTAssertEqual(runtime.controller.configuration.shared, shared)
            XCTAssertEqual(runtime.controller.configuration.gpu, shared)
            runtime.controller.setSynchronized(true)
            runtime.controller.setSynchronized(false)
            XCTAssertEqual(runtime.controller.configuration.cpu, changedCPU)
            XCTAssertEqual(runtime.controller.configuration.gpu, shared)
            XCTAssertTrue(runtime.commands.isEmpty)
        }
    }

    func testSynchronizationChangesReleaseControlAndLimitRequestsToMappedFans() {
        onMain {
            let configuration = FanCurveConfiguration(cpuFanID: 1, useLoad: false)
            let runtime = Runtime(configuration: configuration, enabledFans: [0, 1])
            let fans = [FanCurveFan(id: 0, name: "Unmapped", minRPM: 1200, maxRPM: 6000, rpm: 1800),
                        FanCurveFan(id: 1, name: "CPU", minRPM: 800, maxRPM: 4000, rpm: 1000)]
            runtime.sample(fans: fans)
            runtime.tick()
            pump()
            runtime.controller.setSynchronized(false)
            pump()
            XCTAssertEqual(Set(runtime.releases.map { $0.id }), [0, 1])
            XCTAssertFalse(runtime.controller.isCurveEnabled(for: 0))
            XCTAssertTrue(runtime.controller.isCurveEnabled(for: 1))
            XCTAssertTrue(runtime.controller.activeFans.isEmpty)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.controller.activeFans, [1])
            runtime.controller.setSynchronized(true)
            pump()
            XCTAssertTrue(runtime.controller.isCurveEnabled(for: 0))
            XCTAssertTrue(runtime.controller.isCurveEnabled(for: 1))
        }
    }

    func testReassignmentAndUnassignmentDropAllDesiredFansAndResolveMappingCollision() {
        onMain {
            for assignment: Int? in [1, nil] {
                let runtime = Runtime(configuration: FanCurveConfiguration(cpuFanID: 0, gpuFanID: 1, useLoad: false),
                                      enabledFans: [0, 1], synchronized: false)
                let fans = [FanCurveFan(id: 0, name: "CPU", minRPM: 1200, maxRPM: 6000, rpm: 1800),
                            FanCurveFan(id: 1, name: "GPU", minRPM: 800, maxRPM: 4000, rpm: 1000)]
                runtime.sample(fans: fans)
                runtime.tick()
                pump()
                runtime.controller.assignFan(assignment, to: .cpu)
                pump()
                XCTAssertEqual(runtime.controller.configuration.cpuFanID, assignment)
                XCTAssertEqual(runtime.controller.configuration.gpuFanID, assignment == 1 ? nil : 1)
                XCTAssertEqual(Set(runtime.releases.map { $0.id }), [0, 1])
                XCTAssertFalse(runtime.controller.isCurveEnabled(for: 0))
                XCTAssertFalse(runtime.controller.isCurveEnabled(for: 1))
                XCTAssertTrue(runtime.controller.activeFans.isEmpty)
                XCTAssertTrue(runtime.controller.targetRPM.isEmpty)
                runtime.tick()
                XCTAssertEqual(runtime.commands.count, 2)
            }
        }
    }

    func testInvalidReassignmentAndSharedAssignmentLeaveRequestsAndMappingUntouched() {
        onMain {
            let runtime = Runtime(configuration: FanCurveConfiguration(cpuFanID: 0, useLoad: false),
                                  enabledFans: [0], synchronized: false)
            runtime.sample()
            let original = runtime.controller.configuration
            runtime.controller.assignFan(9, to: .cpu)
            runtime.controller.assignFan(nil, to: .shared)
            XCTAssertEqual(runtime.controller.configuration, original)
            XCTAssertTrue(runtime.controller.isCurveEnabled(for: 0))
            XCTAssertTrue(runtime.releases.isEmpty)
        }
    }

    // A callback can acknowledge only the release generation that issued it.
    func testOldReleaseSuccessDoesNotUnblockCommandsWhileRetryIsStillPending() {
        onMain {
            let runtime = Runtime(enabledFans: [0])
            runtime.releaseResult = nil
            runtime.sample()
            runtime.tick()
            pump()
            runtime.controller.setPaused(true)
            runtime.controller.setPaused(false)
            runtime.now = 105
            runtime.sample()
            runtime.tick()
            XCTAssertEqual(runtime.releases.count, 2)
            runtime.releases[0].completion(true)
            pump()
            runtime.tick()
            XCTAssertEqual(runtime.commands.count, 1, "Old release callback cleared the pending retry")
            XCTAssertTrue(runtime.controller.activeFans.isEmpty)
            XCTAssertTrue(runtime.controller.targetRPM.isEmpty)
            runtime.releases[0].completion(false)
            pump()
            runtime.tick()
            XCTAssertEqual(runtime.commands.count, 1)
            runtime.releases[1].completion(true)
            pump()
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.commands.count, 2)
            XCTAssertEqual(runtime.controller.targetRPM, [0: 3000])
        }
    }

    // Reacquisition starts without smoothing history from the released control session.
    func testFailedRenewalResetsSmoothingBeforeControlIsReacquired() {
        onMain {
            let runtime = Runtime(enabledFans: [0])
            runtime.sample(temperature: 20)
            runtime.tick()
            pump()
            runtime.now = 101
            runtime.sendResult = false
            runtime.sample(temperature: 90)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.releases.map { $0.id }, [0])
            XCTAssertTrue(runtime.controller.targetRPM.isEmpty)
            runtime.now = 102
            runtime.sendResult = true
            runtime.sample(temperature: 90)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.commands.last?.rpm, 6000, "Reacquisition must not reuse pre-release smoothing")
            XCTAssertEqual(runtime.controller.targetRPM, [0: 6000])
        }
    }

    func testEnableReleasesLegacyControlBeforeFirstMeasurementAndWaitsForAcknowledgement() {
        onMain {
            let runtime = Runtime()
            runtime.releaseResult = nil
            runtime.sample(at: 0)
            runtime.controller.enableCurve(for: 0)
            XCTAssertEqual(runtime.releases.map { $0.id }, [0])
            XCTAssertEqual(runtime.releases.map { $0.at }, [100])
            XCTAssertEqual(runtime.controller.enabledFans, [0])
            XCTAssertTrue(runtime.commands.isEmpty)
            XCTAssertTrue(runtime.controller.activeFans.isEmpty)
            runtime.sample()
            runtime.tick()
            pump()
            XCTAssertTrue(runtime.commands.isEmpty, "Fresh data cannot bypass the auto handoff")
            runtime.releases[0].completion(true)
            runtime.tick()
            XCTAssertTrue(runtime.commands.isEmpty, "The acknowledgement is processed asynchronously")
            pump()
            runtime.tick()
            XCTAssertEqual(runtime.commands.map { $0.rpm }, [3000])
            pump()
            XCTAssertEqual(runtime.controller.targetRPM, [0: 3000])
        }
    }

    func testEnableHandsOffLegacyControlEvenWhenChosenSensorOrLoadIsMissing() {
        onMain {
            for missingSensor in [true, false] {
                let configuration = FanCurveConfiguration(shared: FanCurveProfile(sensorKey: "chosen"), useLoad: true)
                let runtime = Runtime(configuration: configuration)
                runtime.sample(sensors: [], at: 0)
                runtime.controller.enableCurve(for: 0)
                XCTAssertEqual(runtime.releases.map { $0.id }, [0])
                XCTAssertTrue(runtime.commands.isEmpty)
                pump()
                let chosen = FanCurveSensor(key: "chosen", name: "Chosen", value: 75)
                runtime.sample(sensors: missingSensor ? [] : [chosen])
                if missingSensor {
                    runtime.controller.updateLoad(.cpu, value: 0, at: 100)
                    runtime.controller.updateLoad(.gpu, value: 0, at: 100)
                }
                runtime.tick()
                pump()
                XCTAssertTrue(runtime.commands.isEmpty)
                XCTAssertEqual(runtime.releases.count, 1, "Missing metrics must not defer the initial handoff")
                XCTAssertEqual(runtime.controller.enabledFans, [0])
                runtime.sample(sensors: [chosen])
                runtime.controller.updateLoad(.cpu, value: 0, at: 100)
                runtime.controller.updateLoad(.gpu, value: 0, at: 100)
                runtime.tick()
                pump()
                XCTAssertEqual(runtime.commands.map { $0.rpm }, [3000])
                XCTAssertEqual(runtime.controller.targetRPM, [0: 3000])
            }
        }
    }

    func testFailedInitialHandoffBlocksWritesUntilSuccessfulRetry() {
        onMain {
            for result: Bool? in [false, nil] {
                let runtime = Runtime()
                runtime.releaseResult = result
                runtime.sample(at: 0)
                runtime.controller.enableCurve(for: 0)
                pump()
                runtime.sample()
                runtime.tick()
                XCTAssertTrue(runtime.commands.isEmpty)
                XCTAssertEqual(runtime.releases.count, 1)
                runtime.now = 104.999
                runtime.sample()
                runtime.tick()
                XCTAssertTrue(runtime.commands.isEmpty)
                XCTAssertEqual(runtime.releases.count, 1)
                runtime.now = 105
                runtime.releaseResult = true
                runtime.sample()
                runtime.tick()
                XCTAssertEqual(runtime.releases.map { $0.at }, [100, 105])
                XCTAssertTrue(runtime.commands.isEmpty, "The retry has not been acknowledged on the main queue yet")
                pump()
                runtime.tick()
                pump()
                XCTAssertEqual(runtime.commands.map { $0.rpm }, [3000])
                XCTAssertEqual(runtime.controller.activeFans, [0])
                XCTAssertEqual(runtime.controller.enabledFans, [0])
            }
        }
    }

    func testOldHandoffAndStopCallbacksCannotUnlockNewEnableHandoff() {
        onMain {
            let runtime = Runtime()
            runtime.releaseResult = nil
            runtime.sample(at: 0)
            runtime.controller.enableCurve(for: 0)
            runtime.controller.stopCurve(for: 0)
            runtime.controller.enableCurve(for: 0)
            XCTAssertEqual(runtime.releases.map { $0.id }, [0, 0, 0])
            XCTAssertEqual(runtime.controller.enabledFans, [0])
            runtime.sample()
            for index in 0..<2 {
                runtime.releases[index].completion(true)
                pump()
                runtime.tick()
                XCTAssertTrue(runtime.commands.isEmpty, "A previous control session must not clear the new barrier")
                XCTAssertTrue(runtime.controller.activeFans.isEmpty)
            }
            runtime.releases[2].completion(true)
            pump()
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.commands.map { $0.rpm }, [3000])
            XCTAssertEqual(runtime.controller.targetRPM, [0: 3000])
        }
    }

    func testSynchronizedSmoothingRemainsCommonAfterOneFanCommandFails() {
        onMain {
            let runtime = Runtime()
            let fans = [FanCurveFan(id: 0, name: "CPU", minRPM: 0, maxRPM: 6000, rpm: 1000),
                        FanCurveFan(id: 1, name: "GPU", minRPM: 0, maxRPM: 4000, rpm: 1000)]
            runtime.sample(fans: fans, at: 0)
            runtime.controller.enableCurve(for: 0)
            pump()
            runtime.sample(fans: fans, temperature: 64)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.controller.targetRPM, [0: 1500, 1: 1000])
            runtime.now = 101
            runtime.sendResults = [0: false]
            runtime.releaseResult = nil
            runtime.sample(fans: fans, temperature: 85)
            runtime.tick()
            pump()
            XCTAssertEqual(Array(runtime.commands.suffix(2)).map { $0.rpm }, [2700, 1800])
            XCTAssertEqual(runtime.controller.activeFans, [1])
            XCTAssertEqual(runtime.controller.targetRPM, [1: 1800])
            XCTAssertEqual(runtime.releases.map { $0.id }, [0, 1, 0])
            runtime.sendResults = [:]
            runtime.now = 102
            runtime.sample(fans: fans, temperature: 85)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.commands.count, 5, "Only the fan without a release barrier can write")
            XCTAssertEqual(runtime.controller.targetRPM, [1: 4000])
            runtime.releases[2].completion(true)
            pump()
            runtime.now = 103
            runtime.sample(fans: fans, temperature: 75)
            runtime.tick()
            pump()
            // One shared fall step: 100% - 5%/s, converted using each fan's maximum.
            XCTAssertEqual(Array(runtime.commands.suffix(2)).map { $0.id }, [0, 1])
            XCTAssertEqual(Array(runtime.commands.suffix(2)).map { $0.rpm }, [5700, 3800])
            XCTAssertEqual(runtime.controller.targetRPM, [0: 5700, 1: 3800])
            XCTAssertEqual(Double(runtime.commands[runtime.commands.count - 2].rpm) / 6000,
                           Double(runtime.commands[runtime.commands.count - 1].rpm) / 4000,
                           accuracy: 0.000001)
            runtime.now = 104
            runtime.sample(fans: fans, temperature: 75)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.controller.targetRPM, [0: 5400, 1: 3600])
        }
    }

    func testSynchronizedSmoothingAdvancesOncePerTickNotOncePerFan() {
        onMain {
            let runtime = Runtime()
            let fans = [FanCurveFan(id: 0, name: "CPU", minRPM: 0, maxRPM: 6000, rpm: 1000),
                        FanCurveFan(id: 1, name: "GPU", minRPM: 0, maxRPM: 4000, rpm: 1000)]
            runtime.sample(fans: fans, at: 0)
            runtime.controller.enableCurve(for: 1)
            pump()
            runtime.sample(fans: fans, temperature: 64)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.controller.targetRPM, [0: 1500, 1: 1000])
            runtime.now = 101
            runtime.sample(fans: fans, temperature: 85)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.controller.targetRPM, [0: 2700, 1: 1800])
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.controller.targetRPM, [0: 2700, 1: 1800])
            runtime.now = 102
            runtime.sample(fans: fans, temperature: 85)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.controller.targetRPM, [0: 3900, 1: 2600])
        }
    }

    func testStopEnabledFanWithoutActiveCommandReleasesAfterSensorOrFanDisappears() {
        onMain {
            for synchronized in [false, true] {
                for missingFan in [false, true] {
                    for pendingHandoff in [false, true] {
                        let runtime = Runtime(configuration: FanCurveConfiguration(cpuFanID: 0, useLoad: false),
                                              synchronized: synchronized)
                        runtime.releaseResult = pendingHandoff ? nil : true
                        runtime.sample(at: 0)
                        runtime.controller.enableCurve(for: 0)
                        pump()
                        runtime.sample(fans: missingFan ? [] : nil, sensors: [])
                        runtime.tick()
                        XCTAssertEqual(runtime.controller.enabledFans, [0])
                        XCTAssertTrue(runtime.controller.isCurveEnabled(for: 0))
                        XCTAssertTrue(runtime.controller.activeFans.isEmpty)
                        XCTAssertTrue(runtime.commands.isEmpty)
                        runtime.controller.stopCurve(for: 0)
                        XCTAssertEqual(runtime.releases.map { $0.id }, [0, 0])
                        XCTAssertTrue(runtime.controller.enabledFans.isEmpty)
                        XCTAssertFalse(runtime.controller.isCurveEnabled(for: 0))
                        runtime.releases[0].completion(true)
                        pump()
                        runtime.tick()
                        XCTAssertTrue(runtime.commands.isEmpty)
                        runtime.releases[1].completion(true)
                        pump()
                        runtime.tick()
                        XCTAssertTrue(runtime.controller.activeFans.isEmpty)
                        XCTAssertTrue(runtime.controller.targetRPM.isEmpty)
                        XCTAssertTrue(runtime.commands.isEmpty)
                    }
                }
            }
        }
    }

    func testStopPendingCommandAfterFanDisappearsIgnoresLateSuccess() {
        onMain {
            let runtime = Runtime()
            runtime.sendResult = nil
            runtime.sample(at: 0)
            runtime.controller.enableCurve(for: 0)
            pump()
            runtime.sample()
            runtime.tick()
            XCTAssertEqual(runtime.commands.count, 1)
            XCTAssertTrue(runtime.controller.activeFans.isEmpty)
            runtime.sample(fans: [], sensors: [])
            XCTAssertEqual(runtime.controller.enabledFans, [0])
            runtime.controller.stopCurve(for: 0)
            XCTAssertEqual(runtime.releases.map { $0.id }, [0, 0])
            XCTAssertTrue(runtime.controller.enabledFans.isEmpty)
            runtime.commands[0].completion(true)
            pump()
            runtime.tick()
            XCTAssertTrue(runtime.controller.activeFans.isEmpty)
            XCTAssertTrue(runtime.controller.targetRPM.isEmpty)
            XCTAssertEqual(runtime.commands.count, 1)
        }
    }

    func testEnableCancelsEverySelectedLegacyFanBeforeInitialHandoff() {
        onMain {
            for synchronized in [false, true] {
                let runtime = Runtime(configuration: FanCurveConfiguration(cpuFanID: 0, gpuFanID: 1, useLoad: false),
                                      synchronized: synchronized)
                runtime.releaseResult = nil
                let fans = [FanCurveFan(id: 0, name: "CPU", minRPM: 1200, maxRPM: 6000, rpm: 1800),
                            FanCurveFan(id: 1, name: "GPU", minRPM: 800, maxRPM: 4000, rpm: 1000)]
                runtime.sample(fans: fans, at: 0)
                runtime.controller.enableCurve(for: 0)
                let expected: Set<Int> = synchronized ? [0, 1] : [0]
                XCTAssertEqual(runtime.cancellations, [expected])
                XCTAssertEqual(Set(runtime.releases.map { $0.id }), expected)
                XCTAssertEqual(runtime.releases.count, expected.count)
                XCTAssertEqual(runtime.controller.enabledFans, expected)
                runtime.sample(fans: fans)
                runtime.tick()
                XCTAssertTrue(runtime.commands.isEmpty)
                for release in runtime.releases { release.completion(true) }
                pump()
                runtime.tick()
                pump()
                XCTAssertEqual(Set(runtime.commands.map { $0.id }), expected)
                XCTAssertEqual(runtime.cancellations, [expected], "Acknowledgement must not issue another cancellation")
            }
        }
    }

    func testOwnershipTransitionsCancelAllRequestedAndPendingLegacyFansEvenWhenRequestsAreEmpty() {
        onMain {
            let transitions: [(String, (FanCurveController) -> Void)] = [
                ("synchronize", { $0.setSynchronized(true) }),
                ("assign", { $0.assignFan(1, to: .cpu) }),
                ("unassign", { $0.assignFan(nil, to: .cpu) }),
                ("pause", { $0.setPaused(true) }),
                ("sleep", { $0.setSleeping(true) }),
                ("terminate", { $0.terminate() })
            ]
            for (name, transition) in transitions {
                for hasRequestedFans in [false, true] {
                    let runtime = Runtime(configuration: FanCurveConfiguration(cpuFanID: 0, gpuFanID: 1, useLoad: false),
                                          enabledFans: hasRequestedFans ? [0, 1, 2] : [], synchronized: false)
                    runtime.releaseResult = nil
                    runtime.sample(fans: (0...2).map {
                        FanCurveFan(id: $0, name: "Fan \($0)", minRPM: 1200, maxRPM: 6000, rpm: 1800)
                    }, at: 0)
                    // A stopped fan can have a pending release and waiting manual commands without any curve request.
                    runtime.controller.stopCurve(for: 0)
                    XCTAssertEqual(runtime.controller.enabledFans, hasRequestedFans ? [1, 2] : [], name)
                    XCTAssertEqual(runtime.cancellations, [[0]], name)
                    XCTAssertEqual(runtime.releases.map { $0.id }, [0], name)
                    XCTAssertTrue(runtime.controller.activeFans.isEmpty, name)
                    transition(runtime.controller)
                    let expected: Set<Int> = hasRequestedFans ? [0, 1, 2] : [0]
                    XCTAssertEqual(runtime.cancellations, [[0], expected], name)
                    XCTAssertEqual(runtime.releases.count, 1, "\(name): cancellation must not start a redundant release")
                    XCTAssertTrue(runtime.commands.isEmpty, name)
                    runtime.releases[0].completion(true)
                    pump()
                    XCTAssertEqual(runtime.cancellations, [[0], expected], name)
                    XCTAssertTrue(runtime.controller.activeFans.isEmpty, name)
                    XCTAssertTrue(runtime.controller.targetRPM.isEmpty, name)
                }
            }
        }
    }

    func testPauseAndSleepResumeRecordEachCancellationIncludingPendingManualOnlyFan() {
        onMain {
            for sleeping in [false, true] {
                for hasRequestedFans in [false, true] {
                    let runtime = Runtime(configuration: FanCurveConfiguration(cpuFanID: 0, gpuFanID: 1, useLoad: false),
                                          enabledFans: hasRequestedFans ? [0, 1] : [], synchronized: false)
                    runtime.releaseResult = nil
                    runtime.sample(at: 0)
                    runtime.controller.stopCurve(for: 0)
                    let expected: Set<Int> = hasRequestedFans ? [0, 1] : [0]
                    if sleeping { runtime.controller.setSleeping(true) } else { runtime.controller.setPaused(true) }
                    if sleeping { runtime.controller.setSleeping(false) } else { runtime.controller.setPaused(false) }
                    XCTAssertEqual(runtime.cancellations, [[0], expected, expected])
                    XCTAssertEqual(runtime.releases.map { $0.id }, [0])
                    XCTAssertEqual(runtime.controller.enabledFans, hasRequestedFans ? [1] : [])
                    runtime.tick()
                    XCTAssertTrue(runtime.commands.isEmpty)
                    XCTAssertTrue(runtime.controller.activeFans.isEmpty)
                    XCTAssertTrue(runtime.controller.targetRPM.isEmpty)
                }
            }
        }
    }

    func testSnapshotsBeforeFreshAfterAreRejectedEvenWithinFourSecondWindow() {
        onMain {
            let runtime = Runtime(configuration: FanCurveConfiguration(useLoad: true))
            runtime.sample(at: 0)
            runtime.now = 102
            runtime.controller.enableCurve(for: 0)
            pump()
            runtime.sample()
            runtime.controller.updateLoad(.cpu, value: 0, at: 102)
            runtime.controller.updateLoad(.gpu, value: 0, at: 102)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.controller.targetRPM, [0: 3000])
            runtime.now = 103
            runtime.sample(temperature: 85, hot: 95, at: 101.999)
            runtime.controller.updateLoad(.cpu, value: 0, at: 103)
            runtime.controller.updateLoad(.gpu, value: 0, at: 103)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.commands.count, 1, "Even emergency data predating enable must be rejected")
            XCTAssertEqual(runtime.releases.map { $0.id }, [0, 0])
            XCTAssertEqual(runtime.controller.enabledFans, [0])
            XCTAssertTrue(runtime.controller.activeFans.isEmpty)
            runtime.sample()
            runtime.controller.updateLoad(.cpu, value: 1, at: 101.999)
            runtime.tick()
            XCTAssertEqual(runtime.commands.count, 1)
            runtime.controller.updateLoad(.cpu, value: 0, at: 103)
            runtime.controller.updateLoad(.gpu, value: 1, at: 101.999)
            runtime.tick()
            XCTAssertEqual(runtime.commands.count, 1)
            runtime.controller.updateLoad(.gpu, value: 0, at: 103)
            runtime.tick()
            pump()
            XCTAssertEqual(runtime.commands.map { $0.rpm }, [3000, 3000])
            XCTAssertEqual(runtime.controller.targetRPM, [0: 3000])
        }
    }
}

// Optional standalone entry point; omit this flag in a hosted XCTest target.
#if FAN_CURVE_CONTROLLER_TESTS
@main
enum FanCurveControllerTestMain {
    static func main() {
        precondition(Thread.isMainThread)
        let suite = FanCurveControllerTests.defaultTestSuite
        suite.run()
        guard let result = suite.testRun, result.executionCount > 0 else { exit(1) }
        exit(result.hasSucceeded ? 0 : 1)
    }
}
#endif
