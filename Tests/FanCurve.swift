import Foundation
import XCTest
import Kit

final class FanCurveTests: XCTestCase {
    func testDefaultPointsAndConfiguration() {
        let expected = [
            FanCurvePoint(percent: 0, temperature: 50),
            FanCurvePoint(percent: 10, temperature: 55),
            FanCurvePoint(percent: 25, temperature: 64),
            FanCurvePoint(percent: 50, temperature: 75),
            FanCurvePoint(percent: 100, temperature: 85)
        ]
        XCTAssertEqual(FanCurveProfile.defaultPoints, expected)
        let configuration = FanCurveConfiguration()
        XCTAssertEqual(configuration.shared.points, expected)
        XCTAssertEqual(configuration.shared.sensorKey, "Hottest CPU")
        XCTAssertNil(configuration.cpu)
        XCTAssertNil(configuration.gpu)
        XCTAssertNil(configuration.cpuFanID)
        XCTAssertNil(configuration.gpuFanID)
        XCTAssertTrue(configuration.useLoad)
        XCTAssertTrue(configuration.isValid)
    }

    func testPublicPointAndProfilePropertiesAreMutable() {
        var point = FanCurvePoint(percent: 1, temperature: 21)
        point.percent = 30
        point.temperature = 60
        var profile = FanCurveProfile()
        profile.points = [point]
        profile.sensorKey = "Hottest GPU"
        XCTAssertEqual(profile, FanCurveProfile(points: [FanCurvePoint(percent: 30, temperature: 60)],
                                               sensorKey: "Hottest GPU"))
        XCTAssertTrue(profile.isValid)
    }

    func testProfileIDsAndCodable() throws {
        XCTAssertEqual(FanCurveProfileID.allCases, [.shared, .cpu, .gpu])
        for id in FanCurveProfileID.allCases {
            XCTAssertEqual(id.rawValue, String(describing: id))
            let data = try JSONEncoder().encode(id)
            XCTAssertEqual(try JSONDecoder().decode(FanCurveProfileID.self, from: data), id)
            XCTAssertEqual(try JSONDecoder().decode(String.self, from: data), id.rawValue)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(FanCurveProfileID.self, from: Data("\"other\"".utf8)))
    }

    func testProfileValidationRejectsInvalidCountsCoordinatesAndOrdering() {
        let invalidPoints: [[FanCurvePoint]] = [
            [],
            (0...10).map { FanCurvePoint(percent: $0, temperature: 20 + $0) },
            [FanCurvePoint(percent: -1, temperature: 50)],
            [FanCurvePoint(percent: 101, temperature: 50)],
            [FanCurvePoint(percent: 50, temperature: 19)],
            [FanCurvePoint(percent: 50, temperature: 101)],
            [FanCurvePoint(percent: Int.min, temperature: Int.max)],
            [FanCurvePoint(percent: 0, temperature: 50), FanCurvePoint(percent: 10, temperature: 50)],
            [FanCurvePoint(percent: 0, temperature: 51), FanCurvePoint(percent: 10, temperature: 50)],
            [FanCurvePoint(percent: 20, temperature: 50), FanCurvePoint(percent: 10, temperature: 51)]
        ]
        for points in invalidPoints {
            let profile = FanCurveProfile(points: points)
            XCTAssertFalse(profile.isValid, "Unexpected valid points: \(points)")
            XCTAssertNil(profile.percentage(at: 60))
        }
    }

    func testProfileValidationAllowsBoundariesEqualPercentagesAndTenPoints() {
        XCTAssertTrue(FanCurveProfile(points: [FanCurvePoint(percent: 0, temperature: 20)]).isValid)
        XCTAssertTrue(FanCurveProfile(points: [FanCurvePoint(percent: 100, temperature: 100)]).isValid)
        let points = (0..<10).map { FanCurvePoint(percent: 100, temperature: 91 + $0) }
        XCTAssertTrue(FanCurveProfile(points: points).isValid)
    }

    func testInterpolationIsContinuousAndClampsEndpoints() throws {
        let profile = FanCurveProfile()
        for point in profile.points {
            XCTAssertEqual(try XCTUnwrap(profile.percentage(at: Double(point.temperature))), Double(point.percent))
        }
        let samples: [(Double, Double)] = [(-200, 0), (52.5, 5), (59.5, 17.5), (69.5, 37.5),
                                           (80, 75), (80.25, 76.25), (101, 100), (1000, 100)]
        for (temperature, expected) in samples {
            XCTAssertEqual(try XCTUnwrap(profile.percentage(at: temperature)), expected, accuracy: 0.000001)
        }
        XCTAssertEqual(profile.percentage(at: -Double.greatestFiniteMagnitude), 0)
        XCTAssertEqual(profile.percentage(at: Double.greatestFiniteMagnitude), 100)
    }

    func testSinglePointIsConstantAndFlatSegmentsAreValid() {
        let profile = FanCurveProfile(points: [FanCurvePoint(percent: 37, temperature: 60)])
        for temperature in [-100.0, 20, 59.5, 60, 100, 1000] {
            XCTAssertEqual(profile.percentage(at: temperature), 37)
        }
        let flat = FanCurveProfile(points: [FanCurvePoint(percent: 25, temperature: 20),
                                           FanCurvePoint(percent: 25, temperature: 100)])
        XCTAssertEqual(flat.percentage(at: 56.5), 25)
    }

    func testNonfiniteTemperaturesAreRejected() {
        for temperature in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(FanCurveProfile().percentage(at: temperature))
            XCTAssertNil(FanCurveProfile(points: [FanCurvePoint(percent: 42, temperature: 60)])
                .percentage(at: temperature))
        }
    }

    func testMovingPercentPushesBackwardMinimallyWithoutChangingTemperatures() {
        var profile = FanCurveProfile()
        XCTAssertTrue(profile.movePoint(at: 3, percent: 5, temperature: 75))
        XCTAssertEqual(profile.points.map { $0.percent }, [0, 5, 5, 5, 100])
        XCTAssertEqual(profile.points.map { $0.temperature }, [50, 55, 64, 75, 85])
        XCTAssertTrue(profile.isValid)
    }

    func testMovingPercentPushesForwardMinimallyWithoutChangingTemperatures() {
        var profile = FanCurveProfile()
        XCTAssertTrue(profile.movePoint(at: 1, percent: 80, temperature: 55))
        XCTAssertEqual(profile.points.map { $0.percent }, [0, 80, 80, 80, 100])
        XCTAssertEqual(profile.points.map { $0.temperature }, [50, 55, 64, 75, 85])
        XCTAssertTrue(profile.isValid)
    }

    func testMovingTemperaturePushesBackwardMinimallyWithoutChangingPercentages() {
        var profile = FanCurveProfile()
        XCTAssertTrue(profile.movePoint(at: 3, percent: 50, temperature: 45))
        XCTAssertEqual(profile.points.map { $0.temperature }, [42, 43, 44, 45, 85])
        XCTAssertEqual(profile.points.map { $0.percent }, [0, 10, 25, 50, 100])
        XCTAssertTrue(profile.isValid)
    }

    func testMovingTemperaturePushesForwardMinimallyWithoutChangingPercentages() {
        var profile = FanCurveProfile()
        XCTAssertTrue(profile.movePoint(at: 1, percent: 10, temperature: 85))
        XCTAssertEqual(profile.points.map { $0.temperature }, [50, 85, 86, 87, 88])
        XCTAssertEqual(profile.points.map { $0.percent }, [0, 10, 25, 50, 100])
        XCTAssertTrue(profile.isValid)
    }

    func testMovingAxesCanPushInOppositeDirections() {
        var profile = FanCurveProfile()
        XCTAssertTrue(profile.movePoint(at: 2, percent: 90, temperature: 45))
        XCTAssertEqual(profile.points.map { $0.percent }, [0, 10, 90, 90, 100])
        XCTAssertEqual(profile.points.map { $0.temperature }, [43, 44, 45, 75, 85])
        profile = FanCurveProfile()
        XCTAssertTrue(profile.movePoint(at: 2, percent: 5, temperature: 90))
        XCTAssertEqual(profile.points.map { $0.percent }, [0, 5, 5, 50, 100])
        XCTAssertEqual(profile.points.map { $0.temperature }, [50, 55, 90, 91, 92])
    }

    func testMovingOntoNeighborAllowsEqualPercentButNotEqualTemperature() {
        var profile = FanCurveProfile()
        XCTAssertTrue(profile.movePoint(at: 2, percent: 10, temperature: 55))
        XCTAssertEqual(profile.points.map { $0.percent }, [0, 10, 10, 50, 100])
        XCTAssertEqual(profile.points.map { $0.temperature }, [50, 54, 55, 75, 85])
    }

    func testMovementClampsIntegerExtremesAndReservesSpaceForNeighbors() {
        var profile = FanCurveProfile()
        XCTAssertTrue(profile.movePoint(at: 2, percent: Int.min, temperature: Int.min))
        XCTAssertEqual(profile.points.map { $0.percent }, [0, 0, 0, 50, 100])
        XCTAssertEqual(profile.points.map { $0.temperature }, [20, 21, 22, 75, 85])
        profile = FanCurveProfile()
        XCTAssertTrue(profile.movePoint(at: 2, percent: Int.max, temperature: Int.max))
        XCTAssertEqual(profile.points.map { $0.percent }, [0, 10, 100, 100, 100])
        XCTAssertEqual(profile.points.map { $0.temperature }, [50, 55, 98, 99, 100])
    }

    func testMovingEndpointsAndSinglePoint() {
        var profile = FanCurveProfile()
        XCTAssertTrue(profile.movePoint(at: 0, percent: 100, temperature: 100))
        XCTAssertEqual(profile.points.map { $0.temperature }, [96, 97, 98, 99, 100])
        XCTAssertEqual(profile.points.map { $0.percent }, [100, 100, 100, 100, 100])
        XCTAssertTrue(profile.movePoint(at: 4, percent: 0, temperature: 20))
        XCTAssertEqual(profile.points.map { $0.temperature }, [20, 21, 22, 23, 24])
        XCTAssertEqual(profile.points.map { $0.percent }, [0, 0, 0, 0, 0])
        profile = FanCurveProfile(points: [FanCurvePoint(percent: 25, temperature: 50)])
        XCTAssertTrue(profile.movePoint(at: 0, percent: Int.max, temperature: Int.min))
        XCTAssertEqual(profile.points, [FanCurvePoint(percent: 100, temperature: 20)])
        XCTAssertTrue(profile.movePoint(at: 0, percent: Int.min, temperature: Int.max))
        XCTAssertEqual(profile.points, [FanCurvePoint(percent: 0, temperature: 100)])
    }

    func testDeterministicMovementGridPreservesValidityAndMinimalAxisPushes() {
        let percentages = [Int.min, -1, 0, 17, 50, 100, 101, Int.max]
        let temperatures = [Int.min, 19, 20, 45, 60, 100, 101, Int.max]
        for count in 1...10 {
            let original = (0..<count).map { FanCurvePoint(percent: $0 * 10, temperature: 30 + $0 * 5) }
            for index in original.indices {
                for percent in percentages {
                    for temperature in temperatures {
                        var profile = FanCurveProfile(points: original)
                        XCTAssertTrue(profile.movePoint(at: index, percent: percent, temperature: temperature))
                        XCTAssertTrue(profile.isValid)
                        let movedPercent = min(100, max(0, percent))
                        let movedTemperature = min(100 - (count - 1 - index), max(20 + index, temperature))
                        for neighbor in original.indices {
                            let expectedPercent: Int
                            let expectedTemperature: Int
                            if neighbor < index {
                                expectedPercent = min(original[neighbor].percent, movedPercent)
                                expectedTemperature = min(original[neighbor].temperature, movedTemperature - (index - neighbor))
                            } else if neighbor > index {
                                expectedPercent = max(original[neighbor].percent, movedPercent)
                                expectedTemperature = max(original[neighbor].temperature, movedTemperature + (neighbor - index))
                            } else {
                                expectedPercent = movedPercent
                                expectedTemperature = movedTemperature
                            }
                            XCTAssertEqual(profile.points[neighbor], FanCurvePoint(percent: expectedPercent,
                                                                                  temperature: expectedTemperature))
                        }
                    }
                }
            }
        }
    }

    func testInvalidIndicesAndInvalidProfilesCannotBeEdited() {
        let original = FanCurveProfile()
        for index in [Int.min, -1, original.points.count, Int.max] {
            var profile = original
            XCTAssertFalse(profile.movePoint(at: index, percent: 30, temperature: 60))
            XCTAssertFalse(profile.removePoint(at: index))
            XCTAssertEqual(profile, original)
        }
        let invalidProfiles = [FanCurveProfile(points: []),
                               FanCurveProfile(points: [FanCurvePoint(percent: -1, temperature: 50)]),
                               FanCurveProfile(points: (0...10).map { FanCurvePoint(percent: $0, temperature: 20 + $0) })]
        for original in invalidProfiles {
            var profile = original
            XCTAssertFalse(profile.movePoint(at: 0, percent: 50, temperature: 60))
            XCTAssertFalse(profile.insertPoint(percent: 50, temperature: 60))
            XCTAssertFalse(profile.removePoint(at: 0))
            XCTAssertEqual(profile, original)
        }
    }

    func testInsertionSortsAndClampsPercentBetweenNeighborsWithoutPushing() {
        var profile = FanCurveProfile()
        XCTAssertTrue(profile.insertPoint(percent: Int.min, temperature: 60))
        XCTAssertEqual(profile.points, [
            FanCurvePoint(percent: 0, temperature: 50),
            FanCurvePoint(percent: 10, temperature: 55),
            FanCurvePoint(percent: 10, temperature: 60),
            FanCurvePoint(percent: 25, temperature: 64),
            FanCurvePoint(percent: 50, temperature: 75),
            FanCurvePoint(percent: 100, temperature: 85)
        ])
        profile = FanCurveProfile()
        XCTAssertTrue(profile.insertPoint(percent: Int.max, temperature: 60))
        XCTAssertEqual(profile.points[2], FanCurvePoint(percent: 25, temperature: 60))
        XCTAssertTrue(profile.isValid)
        profile = FanCurveProfile()
        XCTAssertTrue(profile.insertPoint(percent: 17, temperature: 60))
        XCTAssertEqual(profile.points[2], FanCurvePoint(percent: 17, temperature: 60))
    }

    func testInsertionClampsEndpointCoordinatesAndRejectsOccupiedTemperature() {
        var profile = FanCurveProfile(points: [FanCurvePoint(percent: 30, temperature: 50),
                                              FanCurvePoint(percent: 70, temperature: 80)])
        XCTAssertTrue(profile.insertPoint(percent: Int.max, temperature: Int.min))
        XCTAssertEqual(profile.points.first, FanCurvePoint(percent: 30, temperature: 20))
        XCTAssertTrue(profile.insertPoint(percent: Int.min, temperature: Int.max))
        XCTAssertEqual(profile.points.last, FanCurvePoint(percent: 70, temperature: 100))
        let original = profile
        for temperature in [Int.min, 20, 50, 80, 100, Int.max] {
            XCTAssertFalse(profile.insertPoint(percent: 50, temperature: temperature))
            XCTAssertEqual(profile, original)
        }
        XCTAssertTrue(profile.isValid)
    }

    func testInsertionLimitAndRemovalAllowOneThroughTenPoints() {
        var profile = FanCurveProfile(points: [FanCurvePoint(percent: 0, temperature: 20)])
        for temperature in 21...29 {
            XCTAssertTrue(profile.insertPoint(percent: 50, temperature: temperature))
        }
        XCTAssertEqual(profile.points.count, 10)
        let full = profile
        XCTAssertFalse(profile.insertPoint(percent: 50, temperature: 30))
        XCTAssertEqual(profile, full)
        for count in stride(from: 10, through: 2, by: -1) {
            XCTAssertTrue(profile.removePoint(at: count / 2))
            XCTAssertEqual(profile.points.count, count - 1)
            XCTAssertTrue(profile.isValid)
        }
        let single = profile
        XCTAssertFalse(profile.removePoint(at: 0))
        XCTAssertEqual(profile, single)
        XCTAssertTrue(profile.insertPoint(percent: 100, temperature: 100))
        XCTAssertTrue(profile.removePoint(at: 0))
        XCTAssertEqual(profile.points, [FanCurvePoint(percent: 100, temperature: 100)])
    }

    func testNoOpMovementSucceedsAndEditingPreservesSensorKey() {
        var profile = FanCurveProfile(sensorKey: "Hottest GPU")
        let original = profile
        XCTAssertTrue(profile.movePoint(at: 2, percent: 25, temperature: 64))
        XCTAssertEqual(profile, original)
        XCTAssertTrue(profile.insertPoint(percent: 40, temperature: 70))
        XCTAssertTrue(profile.removePoint(at: 3))
        XCTAssertEqual(profile, original)
    }

    func testConfigurationFallbackDoesNotCreateOrAliasIndependentProfiles() {
        var configuration = FanCurveConfiguration()
        XCTAssertEqual(configuration.profile(.shared), configuration.shared)
        var cpu = configuration.profile(.cpu)
        XCTAssertEqual(cpu, configuration.shared)
        XCTAssertEqual(configuration.profile(.gpu), configuration.shared)
        cpu.sensorKey = "CPU proximity"
        XCTAssertTrue(cpu.movePoint(at: 0, percent: 5, temperature: 40))
        XCTAssertNil(configuration.cpu)
        XCTAssertEqual(configuration.shared, FanCurveProfile())
        configuration.setProfile(cpu, for: .cpu)
        let gpu = FanCurveProfile(points: [FanCurvePoint(percent: 60, temperature: 70)], sensorKey: "Hottest GPU")
        configuration.setProfile(gpu, for: .gpu)
        let shared = FanCurveProfile(points: [FanCurvePoint(percent: 40, temperature: 60)], sensorKey: "Shared sensor")
        configuration.setProfile(shared, for: .shared)
        XCTAssertEqual(configuration.profile(.shared), shared)
        XCTAssertEqual(configuration.profile(.cpu), cpu)
        XCTAssertEqual(configuration.profile(.gpu), gpu)
        configuration.cpu = nil
        XCTAssertEqual(configuration.profile(.cpu), shared)
        XCTAssertEqual(configuration.profile(.gpu), gpu)
    }

    func testConfigurationValidatesEveryPresentProfile() {
        let invalid = FanCurveProfile(points: [])
        XCTAssertFalse(FanCurveConfiguration(shared: invalid).isValid)
        XCTAssertFalse(FanCurveConfiguration(cpu: invalid).isValid)
        XCTAssertFalse(FanCurveConfiguration(gpu: invalid).isValid)
        XCTAssertTrue(FanCurveConfiguration(cpu: FanCurveProfile(), gpu: FanCurveProfile()).isValid)
    }

    func testFanMappingMustBeNonnegativeAndDistinctOnlyWhenBothAreSet() {
        let ids: [Int?] = [nil, -1, 0, 1, Int.max]
        for cpu in ids {
            for gpu in ids {
                let expected = (cpu == nil || cpu! >= 0) && (gpu == nil || gpu! >= 0) &&
                    (cpu == nil || gpu == nil || cpu != gpu)
                XCTAssertEqual(FanCurveConfiguration(cpuFanID: cpu, gpuFanID: gpu).isValid, expected)
            }
        }
    }

    func testCodableRoundTripsPreserveAllProfilesMappingsAndLoadSetting() throws {
        let point = FanCurvePoint(percent: 23, temperature: 57)
        XCTAssertEqual(try JSONDecoder().decode(FanCurvePoint.self, from: JSONEncoder().encode(point)), point)
        var shared = FanCurveProfile(sensorKey: "CPU proximity")
        XCTAssertTrue(shared.movePoint(at: 2, percent: 30, temperature: 65))
        let cpu = FanCurveProfile(points: [point], sensorKey: "Hottest CPU")
        let gpu = FanCurveProfile(points: [FanCurvePoint(percent: 60, temperature: 70)], sensorKey: "Hottest GPU")
        let configurations = [FanCurveConfiguration(),
                              FanCurveConfiguration(shared: shared, cpu: cpu, gpu: gpu,
                                                    cpuFanID: 1, gpuFanID: 0, useLoad: false),
                              FanCurveConfiguration(shared: shared, cpu: cpu, gpuFanID: 2)]
        for configuration in configurations {
            let data = try JSONEncoder().encode(configuration)
            XCTAssertEqual(try JSONDecoder().decode(FanCurveConfiguration.self, from: data), configuration)
        }
        XCTAssertEqual(try JSONDecoder().decode(FanCurveProfile.self, from: JSONEncoder().encode(shared)), shared)
    }

    func testDecodedInvalidDataIsNotSilentlyNormalized() throws {
        let data = Data("{\"points\":[{\"percent\":101,\"temperature\":50}],\"sensorKey\":\"saved\"}".utf8)
        let profile = try JSONDecoder().decode(FanCurveProfile.self, from: data)
        XCTAssertEqual(profile.points[0].percent, 101)
        XCTAssertEqual(profile.sensorKey, "saved")
        XCTAssertFalse(profile.isValid)
        XCTAssertNil(profile.percentage(at: 60))
    }

    func testDisabledLoadUsesTemperatureOnlyEvenWithInvalidOrMissingLoads() {
        for load: Double? in [nil, .nan, .infinity, -1, 2] {
            XCTAssertEqual(FanCurvePolicy.targetPercent(profile: FanCurveProfile(), temperature: 80,
                                                       cpuLoad: load, gpuLoad: load, useLoad: false,
                                                       emergency: false), 75)
        }
    }

    func testLoadFloorUsesMaximumCpuOrGpuAndNeverReducesCooling() throws {
        let profile = FanCurveProfile()
        XCTAssertEqual(FanCurvePolicy.targetPercent(profile: profile, temperature: 50, cpuLoad: 0, gpuLoad: 0,
                                                   useLoad: true, emergency: false), 0)
        XCTAssertEqual(FanCurvePolicy.targetPercent(profile: profile, temperature: 50, cpuLoad: 1, gpuLoad: 0,
                                                   useLoad: true, emergency: false), 70)
        XCTAssertEqual(FanCurvePolicy.targetPercent(profile: profile, temperature: 50, cpuLoad: 0, gpuLoad: 1,
                                                   useLoad: true, emergency: false), 70)
        XCTAssertEqual(try XCTUnwrap(FanCurvePolicy.targetPercent(profile: profile, temperature: 50,
                                                               cpuLoad: 0.6, gpuLoad: 0.8,
                                                               useLoad: true, emergency: false)), 56, accuracy: 0.000001)
        for temperature in stride(from: 20.0, through: 120.0, by: 0.5) {
            let baseline = try XCTUnwrap(profile.percentage(at: temperature))
            for load in [0.0, 0.25, 0.5, 0.75, 1] {
                let result = try XCTUnwrap(FanCurvePolicy.targetPercent(profile: profile, temperature: temperature,
                                                                     cpuLoad: load, gpuLoad: 1 - load,
                                                                     useLoad: true, emergency: false))
                XCTAssertGreaterThanOrEqual(result, baseline)
                XCTAssertEqual(result, max(baseline, max(load, 1 - load) * 70))
            }
        }
    }

    func testEnabledLoadRejectsEitherMissingNonfiniteOrOutOfRangeMetric() {
        let invalidLoads: [Double?] = [nil, .nan, .infinity, -.infinity, -0.001, 1.001]
        for load in invalidLoads {
            XCTAssertNil(FanCurvePolicy.targetPercent(profile: FanCurveProfile(), temperature: 85,
                                                     cpuLoad: load, gpuLoad: 0.5, useLoad: true, emergency: false))
            XCTAssertNil(FanCurvePolicy.targetPercent(profile: FanCurveProfile(), temperature: 85,
                                                     cpuLoad: 0.5, gpuLoad: load, useLoad: true, emergency: false))
        }
        XCTAssertNil(FanCurvePolicy.targetPercent(profile: FanCurveProfile(), temperature: 85,
                                                 cpuLoad: nil, gpuLoad: nil, useLoad: true, emergency: false))
    }

    func testTargetRejectsInvalidProfileAndTemperatureRegardlessOfLoadOption() {
        for useLoad in [false, true] {
            XCTAssertNil(FanCurvePolicy.targetPercent(profile: FanCurveProfile(points: []), temperature: 60,
                                                     cpuLoad: 1, gpuLoad: 1, useLoad: useLoad, emergency: false))
            for temperature in [Double.nan, .infinity, -.infinity] {
                XCTAssertNil(FanCurvePolicy.targetPercent(profile: FanCurveProfile(), temperature: temperature,
                                                         cpuLoad: 1, gpuLoad: 1, useLoad: useLoad, emergency: false))
            }
        }
    }

    func testEmergencyBypassesInvalidCurveTemperatureAndLoads() {
        for useLoad in [false, true] {
            XCTAssertEqual(FanCurvePolicy.targetPercent(profile: FanCurveProfile(points: []), temperature: .nan,
                                                       cpuLoad: nil, gpuLoad: nil, useLoad: useLoad, emergency: true), 100)
            XCTAssertEqual(FanCurvePolicy.targetPercent(profile: FanCurveProfile(), temperature: 20,
                                                       cpuLoad: .infinity, gpuLoad: -1, useLoad: useLoad, emergency: true), 100)
        }
    }

    func testRPMUsesPercentOfMaximumNotMinMaxRangeAndClamps() {
        let samples: [(Double, Int)] = [(-100, 1200), (0, 1200), (10, 1200), (20, 1200),
                                       (25, 1500), (50, 3000), (100, 6000), (200, 6000)]
        for (percent, expected) in samples {
            XCTAssertEqual(FanCurvePolicy.rpm(percent: percent, minRPM: 1200, maxRPM: 6000), expected)
        }
        XCTAssertEqual(FanCurvePolicy.rpm(percent: 0, minRPM: 0, maxRPM: 6000), 0)
        XCTAssertEqual(FanCurvePolicy.rpm(percent: 25, minRPM: 1200, maxRPM: 6002), 1501)
        XCTAssertEqual(FanCurvePolicy.rpm(percent: -Double.greatestFiniteMagnitude, minRPM: 1200, maxRPM: 6000), 1200)
        XCTAssertEqual(FanCurvePolicy.rpm(percent: Double.greatestFiniteMagnitude, minRPM: 1200, maxRPM: 6000), 6000)
    }

    func testRPMRoundingStaysWithinFractionalHardwareLimits() {
        XCTAssertEqual(FanCurvePolicy.rpm(percent: 0, minRPM: 1200.1, maxRPM: 6000.9), 1201)
        XCTAssertEqual(FanCurvePolicy.rpm(percent: 100, minRPM: 1200.1, maxRPM: 6000.9), 6000)
        XCTAssertEqual(FanCurvePolicy.rpm(percent: 100, minRPM: 0, maxRPM: 1.9), 1)
        XCTAssertNil(FanCurvePolicy.rpm(percent: 50, minRPM: 1200.1, maxRPM: 1200.9))
    }

    func testRPMRejectsNonfiniteInputsAndInvalidBoundsWithoutIntegerTraps() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(FanCurvePolicy.rpm(percent: value, minRPM: 1200, maxRPM: 6000))
            XCTAssertNil(FanCurvePolicy.rpm(percent: 50, minRPM: value, maxRPM: 6000))
            XCTAssertNil(FanCurvePolicy.rpm(percent: 50, minRPM: 1200, maxRPM: value))
        }
        for (minimum, maximum) in [(-1.0, 6000.0), (0, 0), (0, 1), (0, -1), (1200, 1200), (6000, 1200)] {
            XCTAssertNil(FanCurvePolicy.rpm(percent: 50, minRPM: minimum, maxRPM: maximum))
        }
        XCTAssertNil(FanCurvePolicy.rpm(percent: 100, minRPM: 0, maxRPM: Double.greatestFiniteMagnitude))
        XCTAssertNil(FanCurvePolicy.rpm(percent: 100, minRPM: 0, maxRPM: Double(Int.max)))
    }

    func testSmoothingInitializesAndClampsPercentages() {
        XCTAssertEqual(FanCurvePolicy.smooth(target: 35, previous: nil, elapsed: 0, emergency: false), 35)
        XCTAssertEqual(FanCurvePolicy.smooth(target: -10, previous: nil, elapsed: 1, emergency: false), 0)
        XCTAssertEqual(FanCurvePolicy.smooth(target: 150, previous: nil, elapsed: 1, emergency: false), 100)
        XCTAssertEqual(FanCurvePolicy.smooth(target: 50, previous: -100, elapsed: 1, emergency: false), 20)
        XCTAssertEqual(FanCurvePolicy.smooth(target: 50, previous: 200, elapsed: 1, emergency: false), 95)
    }

    func testSmoothingDeadbandIncludesExactlyTwoPercentInBothDirections() {
        for target in [48.0, 49, 50, 51, 52] {
            XCTAssertEqual(FanCurvePolicy.smooth(target: target, previous: 50, elapsed: 10, emergency: false), 50)
        }
        XCTAssertEqual(FanCurvePolicy.smooth(target: 52.01, previous: 50, elapsed: 1, emergency: false), 52.01)
        XCTAssertEqual(FanCurvePolicy.smooth(target: 47.99, previous: 50, elapsed: 1, emergency: false), 47.99)
    }

    func testSmoothingRisesAtTwentyAndFallsAtFivePercentPerSecondWithoutOvershoot() {
        XCTAssertEqual(FanCurvePolicy.smooth(target: 90, previous: 30, elapsed: 1, emergency: false), 50)
        XCTAssertEqual(FanCurvePolicy.smooth(target: 90, previous: 30, elapsed: 0.25, emergency: false), 35)
        XCTAssertEqual(FanCurvePolicy.smooth(target: 90, previous: 30, elapsed: 10, emergency: false), 90)
        XCTAssertEqual(FanCurvePolicy.smooth(target: 10, previous: 90, elapsed: 1, emergency: false), 85)
        XCTAssertEqual(FanCurvePolicy.smooth(target: 10, previous: 90, elapsed: 0.5, emergency: false), 87.5)
        XCTAssertEqual(FanCurvePolicy.smooth(target: 10, previous: 90, elapsed: 100, emergency: false), 10)
        XCTAssertEqual(FanCurvePolicy.smooth(target: 100, previous: 0,
                                           elapsed: Double.greatestFiniteMagnitude, emergency: false), 100)
        XCTAssertEqual(FanCurvePolicy.smooth(target: 0, previous: 100,
                                           elapsed: Double.greatestFiniteMagnitude, emergency: false), 0)
    }

    func testSmoothingDeterministicSequence() {
        var previous: Double? = nil
        let targets = [20.0, 80, 80, 80, 10, 10, 71, 70]
        let expected = [20.0, 40, 60, 80, 75, 70, 70, 70]
        for index in targets.indices {
            let result = FanCurvePolicy.smooth(target: targets[index], previous: previous, elapsed: 1, emergency: false)
            XCTAssertEqual(result, expected[index])
            previous = result
        }
    }

    func testSmoothingHandlesNonfiniteValuesAndInvalidElapsedDeterministically() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(FanCurvePolicy.smooth(target: value, previous: 50, elapsed: 1, emergency: false), 100)
            XCTAssertEqual(FanCurvePolicy.smooth(target: 40, previous: value, elapsed: 1, emergency: false), 40)
        }
        for elapsed in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertEqual(FanCurvePolicy.smooth(target: 80, previous: 50, elapsed: elapsed, emergency: false), 50)
            XCTAssertEqual(FanCurvePolicy.smooth(target: 20, previous: 50, elapsed: elapsed, emergency: false), 50)
        }
    }

    func testSmoothingEmergencyAlwaysReturnsFullSpeed() {
        XCTAssertEqual(FanCurvePolicy.smooth(target: 0, previous: 0, elapsed: 0, emergency: true), 100)
        XCTAssertEqual(FanCurvePolicy.smooth(target: .nan, previous: nil, elapsed: .nan, emergency: true), 100)
        XCTAssertEqual(FanCurvePolicy.smooth(target: -1, previous: .infinity, elapsed: -1, emergency: true), 100)
    }
}
