#if FAN_CURVE_UI_TESTS
import Cocoa
import XCTest
@testable import Kit

final class FanCurveEditorTests: XCTestCase {
    private func onMain(_ body: () throws -> Void) rethrows {
        if Thread.isMainThread {
            try body()
        } else {
            try DispatchQueue.main.sync { try body() }
        }
    }

    private func withEditor(_ body: (FanCurveEditor) throws -> Void) rethrows {
        try onMain {
            precondition(Thread.isMainThread)
            _ = NSApplication.shared
            let editor = FanCurveEditor(frame: NSRect(x: 0, y: 0, width: 500, height: 250))
            XCTAssertNil(editor.window)
            try body(editor)
        }
    }

    private func mouse(_ type: NSEvent.EventType, at location: NSPoint, in editor: FanCurveEditor,
                       clicks: Int = 1, file: StaticString = #filePath, line: UInt = #line) throws {
        precondition(Thread.isMainThread)
        let windowLocation = editor.convert(location, to: nil)
        XCTAssertEqual(editor.convert(windowLocation, from: nil), location, file: file, line: line)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: windowLocation, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: clicks,
            pressure: type == .leftMouseUp ? 0 : 1
        ), file: file, line: line)
        switch type {
        case .leftMouseDown: editor.mouseDown(with: event)
        case .leftMouseDragged: editor.mouseDragged(with: event)
        case .leftMouseUp: editor.mouseUp(with: event)
        default: XCTFail("Unsupported test event", file: file, line: line)
        }
    }

    private func drag(_ index: Int, percent: Double, temperature: Double, in editor: FanCurveEditor,
                      file: StaticString = #filePath, line: UInt = #line) throws {
        let point = editor.profile.points[index]
        try mouse(.leftMouseDown,
                  at: editor.location(percent: Double(point.percent), temperature: Double(point.temperature)),
                  in: editor, file: file, line: line)
        XCTAssertEqual(editor.draggingPoint, index, file: file, line: line)
        try mouse(.leftMouseDragged, at: editor.location(percent: percent, temperature: temperature),
                  in: editor, file: file, line: line)
    }

    private func assertPoints(_ editor: FanCurveEditor, percentages: [Int], temperatures: [Int],
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(editor.profile.points.map { $0.percent }, percentages, file: file, line: line)
        XCTAssertEqual(editor.profile.points.map { $0.temperature }, temperatures, file: file, line: line)
        XCTAssertTrue(editor.profile.isValid, file: file, line: line)
    }

    func testDefaultPointsAreExactlyTheSpecifiedFivePoints() {
        withEditor { editor in
            let expected = [
                FanCurvePoint(percent: 0, temperature: 50),
                FanCurvePoint(percent: 10, temperature: 55),
                FanCurvePoint(percent: 25, temperature: 64),
                FanCurvePoint(percent: 50, temperature: 75),
                FanCurvePoint(percent: 100, temperature: 85)
            ]
            XCTAssertEqual(editor.profile.points, expected)
            XCTAssertEqual(editor.profile.sensorKey, "Hottest CPU")
            XCTAssertTrue(editor.profile.isValid)
            XCTAssertNil(editor.draggingPoint)
            XCTAssertTrue(editor.acceptsFirstResponder)
        }
    }

    func testGeometryMapsSpeedToXAndTemperatureToY() {
        withEditor { editor in
            XCTAssertEqual(editor.plotRect, NSRect(x: 54, y: 42, width: 424, height: 178))
            XCTAssertEqual(editor.location(percent: 0, temperature: 20), NSPoint(x: 54, y: 42))
            XCTAssertEqual(editor.location(percent: 100, temperature: 100), NSPoint(x: 478, y: 220))
            XCTAssertEqual(editor.location(percent: 50, temperature: 60), NSPoint(x: 266, y: 131))
            for percent in [0, 1, 25, 50, 99, 100] {
                for temperature in [20, 21, 50, 60, 99, 100] {
                    let value = editor.coordinates(at: editor.location(
                        percent: Double(percent), temperature: Double(temperature)
                    ))
                    XCTAssertEqual(value.percent, percent)
                    XCTAssertEqual(value.temperature, temperature)
                }
            }
        }
    }

    func testCoordinatesRoundToIntegersAndClampBothAxesIndependently() {
        withEditor { editor in
            let samples: [(Double, Double, Int, Int)] = [
                (25.49, 64.49, 25, 64), (25.51, 64.51, 26, 65),
                (12.5, 60, 13, 60), (50, 60.5, 50, 61),
                (-100, -100, 0, 20), (200, 200, 100, 100),
                (-100, 200, 0, 100), (200, -100, 100, 20)
            ]
            for (percent, temperature, expectedPercent, expectedTemperature) in samples {
                let value = editor.coordinates(at: editor.location(percent: percent, temperature: temperature))
                XCTAssertEqual(value.percent, expectedPercent)
                XCTAssertEqual(value.temperature, expectedTemperature)
            }
        }
    }

    func testHitRadiusIsEightPixelsAndUsesEuclideanDistance() {
        withEditor { editor in
            let center = editor.location(percent: 25, temperature: 64)
            XCTAssertEqual(editor.pointIndex(at: center), 2)
            for offset in [NSPoint(x: 8, y: 0), NSPoint(x: -8, y: 0),
                           NSPoint(x: 0, y: 8), NSPoint(x: 0, y: -8), NSPoint(x: 5, y: 5)] {
                XCTAssertEqual(editor.pointIndex(at: NSPoint(x: center.x + offset.x, y: center.y + offset.y)), 2)
            }
            for offset in [NSPoint(x: 8.01, y: 0), NSPoint(x: 0, y: -8.01), NSPoint(x: 6, y: 6)] {
                XCTAssertNil(editor.pointIndex(at: NSPoint(x: center.x + offset.x, y: center.y + offset.y)))
            }
        }
    }

    func testHitTestingChoosesTheNearestPointWhenRadiiOverlap() {
        withEditor { editor in
            editor.setProfile(FanCurveProfile(points: [
                FanCurvePoint(percent: 50, temperature: 60),
                FanCurvePoint(percent: 50, temperature: 61)
            ]))
            let lower = editor.location(percent: 50, temperature: 60)
            let upper = editor.location(percent: 50, temperature: 61)
            XCTAssertEqual(editor.pointIndex(at: NSPoint(x: lower.x, y: lower.y + 0.5)), 0)
            XCTAssertEqual(editor.pointIndex(at: NSPoint(x: upper.x, y: upper.y - 0.5)), 1)
        }
    }

    func testDoubleClickAddsRoundedPointAndRecordsOneChange() throws {
        try withEditor { editor in
            editor.setProfile(FanCurveProfile(sensorKey: "UI test sensor"))
            var changes: [FanCurveProfile] = []
            editor.onChange = { changes.append($0) }
            try mouse(.leftMouseDown, at: editor.location(percent: 17.6, temperature: 60.6),
                      in: editor, clicks: 2)
            assertPoints(editor, percentages: [0, 10, 18, 25, 50, 100], temperatures: [50, 55, 61, 64, 75, 85])
            XCTAssertEqual(editor.profile.sensorKey, "UI test sensor")
            XCTAssertEqual(changes, [editor.profile])
            XCTAssertNil(editor.draggingPoint)
        }
    }

    func testDoubleClickInsertionClampsSpeedBetweenNeighbors() throws {
        try withEditor { editor in
            for (percent, expected) in [(0.0, 10), (90.0, 25)] {
                editor.setProfile(FanCurveProfile())
                var changes: [FanCurveProfile] = []
                editor.onChange = { changes.append($0) }
                try mouse(.leftMouseDown, at: editor.location(percent: percent, temperature: 60),
                          in: editor, clicks: 2)
                assertPoints(editor, percentages: [0, 10, expected, 25, 50, 100],
                             temperatures: [50, 55, 60, 64, 75, 85])
                XCTAssertEqual(changes, [editor.profile])
            }
        }
    }

    func testDoubleClickRejectsOutsidePlotAndOccupiedTemperature() throws {
        try withEditor { editor in
            let original = editor.profile
            var changes: [FanCurveProfile] = []
            editor.onChange = { changes.append($0) }
            let rect = editor.plotRect
            let locations = [NSPoint(x: rect.minX - 1, y: rect.midY),
                             NSPoint(x: rect.maxX + 1, y: rect.midY),
                             NSPoint(x: rect.midX, y: rect.minY - 1),
                             NSPoint(x: rect.midX, y: rect.maxY + 1),
                             editor.location(percent: 70, temperature: 64)]
            for location in locations {
                XCTAssertNil(editor.pointIndex(at: location))
                try mouse(.leftMouseDown, at: location, in: editor, clicks: 2)
                XCTAssertEqual(editor.profile, original)
            }
            XCTAssertTrue(changes.isEmpty)
        }
    }

    func testDoubleClickDeletesPointWithinHitRadius() throws {
        try withEditor { editor in
            var changes: [FanCurveProfile] = []
            editor.onChange = { changes.append($0) }
            let center = editor.location(percent: 25, temperature: 64)
            try mouse(.leftMouseDown, at: NSPoint(x: center.x + 8, y: center.y), in: editor, clicks: 2)
            assertPoints(editor, percentages: [0, 10, 50, 100], temperatures: [50, 55, 75, 85])
            XCTAssertEqual(changes, [editor.profile])
            XCTAssertNil(editor.draggingPoint)
        }
    }

    func testDoubleClickCannotDeleteTheLastPoint() throws {
        try withEditor { editor in
            let single = FanCurveProfile(points: [FanCurvePoint(percent: 37, temperature: 60)])
            editor.setProfile(single)
            var changes: [FanCurveProfile] = []
            editor.onChange = { changes.append($0) }
            try mouse(.leftMouseDown, at: editor.location(percent: 37, temperature: 60), in: editor, clicks: 2)
            XCTAssertEqual(editor.profile, single)
            XCTAssertTrue(changes.isEmpty)
            XCTAssertTrue(editor.toolTip?.contains(localizedString("The last point cannot be removed.")) == true)
        }
    }

    func testTenPointLimitBlocksAdditionButStillAllowsDeletionAndReaddition() throws {
        try withEditor { editor in
            editor.setProfile(FanCurveProfile(points: (0..<9).map {
                FanCurvePoint(percent: $0 * 10, temperature: 25 + $0 * 7)
            }))
            var changes: [FanCurveProfile] = []
            editor.onChange = { changes.append($0) }
            let addedLocation = editor.location(percent: 90, temperature: 90)
            try mouse(.leftMouseDown, at: addedLocation, in: editor, clicks: 2)
            XCTAssertEqual(editor.profile.points.count, 10)
            XCTAssertEqual(changes, [editor.profile])
            let full = editor.profile
            XCTAssertTrue(editor.toolTip?.contains(localizedString(
                "Maximum of 10 points reached. Remove a point before adding another."
            )) == true)
            try mouse(.leftMouseDown, at: editor.location(percent: 95, temperature: 95), in: editor, clicks: 2)
            XCTAssertEqual(editor.profile, full)
            XCTAssertEqual(changes.count, 1)
            try mouse(.leftMouseDown, at: addedLocation, in: editor, clicks: 2)
            XCTAssertEqual(editor.profile.points.count, 9)
            XCTAssertEqual(changes.count, 2)
            try mouse(.leftMouseDown, at: addedLocation, in: editor, clicks: 2)
            XCTAssertEqual(editor.profile, full)
            XCTAssertEqual(changes.count, 3)
            XCTAssertEqual(changes.last, editor.profile)
        }
    }

    func testSingleClickSelectsPointWithoutChangingProfileAndEmptyClickClearsSelection() throws {
        try withEditor { editor in
            let original = editor.profile
            var changes: [FanCurveProfile] = []
            editor.onChange = { changes.append($0) }
            try mouse(.leftMouseDown, at: editor.location(percent: 25, temperature: 64), in: editor)
            XCTAssertEqual(editor.draggingPoint, 2)
            XCTAssertEqual(editor.profile, original)
            try mouse(.leftMouseDown, at: editor.location(percent: 80, temperature: 30), in: editor)
            XCTAssertNil(editor.draggingPoint)
            XCTAssertEqual(editor.profile, original)
            XCTAssertTrue(changes.isEmpty)
        }
    }

    func testDraggingRoundsCoordinatesAndRecordsEachCommittedProfile() throws {
        try withEditor { editor in
            editor.setProfile(FanCurveProfile(sensorKey: "UI test sensor"))
            var changes: [FanCurveProfile] = []
            editor.onChange = { changes.append($0) }
            try drag(2, percent: 31.6, temperature: 68.6, in: editor)
            assertPoints(editor, percentages: [0, 10, 32, 50, 100], temperatures: [50, 55, 69, 75, 85])
            let first = editor.profile
            XCTAssertEqual(changes, [first])
            XCTAssertEqual(editor.draggingPoint, 2)
            try mouse(.leftMouseDragged, at: editor.location(percent: 33.4, temperature: 70.4), in: editor)
            assertPoints(editor, percentages: [0, 10, 33, 50, 100], temperatures: [50, 55, 70, 75, 85])
            XCTAssertEqual(changes, [first, editor.profile])
            XCTAssertTrue(changes.allSatisfy { $0.sensorKey == "UI test sensor" && $0.isValid })
        }
    }

    func testDraggingSpeedPushesChainsInBothDirectionsWithoutChangingTemperatures() throws {
        try withEditor { editor in
            let samples: [(Int, Double, Double, [Int])] = [
                (3, 5, 75, [0, 5, 5, 5, 100]),
                (1, 80, 55, [0, 80, 80, 80, 100])
            ]
            for (index, percent, temperature, expected) in samples {
                editor.setProfile(FanCurveProfile())
                try drag(index, percent: percent, temperature: temperature, in: editor)
                assertPoints(editor, percentages: expected, temperatures: [50, 55, 64, 75, 85])
                XCTAssertEqual(editor.draggingPoint, index)
            }
        }
    }

    func testDraggingTemperaturePushesChainsInBothDirectionsWithoutChangingSpeeds() throws {
        try withEditor { editor in
            let samples: [(Int, Double, Double, [Int])] = [
                (3, 50, 45, [42, 43, 44, 45, 85]),
                (1, 10, 85, [50, 85, 86, 87, 88])
            ]
            for (index, percent, temperature, expected) in samples {
                editor.setProfile(FanCurveProfile())
                try drag(index, percent: percent, temperature: temperature, in: editor)
                assertPoints(editor, percentages: [0, 10, 25, 50, 100], temperatures: expected)
                XCTAssertEqual(editor.draggingPoint, index)
            }
        }
    }

    func testDraggingCanPushTheTwoAxesInOppositeDirections() throws {
        try withEditor { editor in
            try drag(2, percent: 90, temperature: 45, in: editor)
            assertPoints(editor, percentages: [0, 10, 90, 90, 100], temperatures: [43, 44, 45, 75, 85])
            editor.setProfile(FanCurveProfile())
            try drag(2, percent: 5, temperature: 90, in: editor)
            assertPoints(editor, percentages: [0, 5, 5, 50, 100], temperatures: [50, 55, 90, 91, 92])
        }
    }

    func testDraggingOutsidePlotClampsAndReservesRoomForTheWholeChain() throws {
        try withEditor { editor in
            try drag(2, percent: -100, temperature: -100, in: editor)
            assertPoints(editor, percentages: [0, 0, 0, 50, 100], temperatures: [20, 21, 22, 75, 85])
            XCTAssertEqual(editor.draggingPoint, 2)
            editor.setProfile(FanCurveProfile())
            try drag(2, percent: 200, temperature: 200, in: editor)
            assertPoints(editor, percentages: [0, 10, 100, 100, 100], temperatures: [50, 55, 98, 99, 100])
            XCTAssertEqual(editor.draggingPoint, 2)
        }
    }

    func testDraggingEndpointsPushesEveryNeighborWithoutReorderingPoints() throws {
        try withEditor { editor in
            try drag(0, percent: 200, temperature: 200, in: editor)
            assertPoints(editor, percentages: [100, 100, 100, 100, 100], temperatures: [96, 97, 98, 99, 100])
            XCTAssertEqual(editor.draggingPoint, 0)
            try drag(4, percent: -100, temperature: -100, in: editor)
            assertPoints(editor, percentages: [0, 0, 0, 0, 0], temperatures: [20, 21, 22, 23, 24])
            XCTAssertEqual(editor.draggingPoint, 4)
        }
    }

    func testSinglePointCanBeDraggedToAllAxisBoundaries() throws {
        try withEditor { editor in
            editor.setProfile(FanCurveProfile(points: [FanCurvePoint(percent: 37, temperature: 60)]))
            try drag(0, percent: 200, temperature: -100, in: editor)
            assertPoints(editor, percentages: [100], temperatures: [20])
            try drag(0, percent: -100, temperature: 200, in: editor)
            assertPoints(editor, percentages: [0], temperatures: [100])
        }
    }

    func testMouseUpEndsDraggingAndUnselectedDragDoesNothing() throws {
        try withEditor { editor in
            var changes: [FanCurveProfile] = []
            editor.onChange = { changes.append($0) }
            let original = editor.profile
            let destination = editor.location(percent: 35, temperature: 70)
            try mouse(.leftMouseDragged, at: destination, in: editor)
            XCTAssertEqual(editor.profile, original)
            XCTAssertTrue(changes.isEmpty)
            try drag(2, percent: 30, temperature: 68, in: editor)
            let committed = editor.profile
            try mouse(.leftMouseUp, at: destination, in: editor)
            XCTAssertNil(editor.draggingPoint)
            XCTAssertEqual(editor.profile, committed)
            try mouse(.leftMouseDragged, at: destination, in: editor)
            XCTAssertEqual(editor.profile, committed)
            XCTAssertEqual(changes, [committed])
        }
    }

    func testTemperatureTelemetryPreservesActiveDragAndDoesNotEmitChanges() throws {
        try withEditor { editor in
            var changes: [FanCurveProfile] = []
            editor.onChange = { changes.append($0) }
            try drag(2, percent: 30, temperature: 68, in: editor)
            let committed = editor.profile
            let readings: [Double?] = [75, 75, 120, -10, nil, .nan, .infinity, -.infinity, 80]
            for reading in readings {
                editor.setTemperature(reading)
                XCTAssertEqual(editor.draggingPoint, 2)
                XCTAssertEqual(editor.profile, committed)
                XCTAssertEqual(changes, [committed])
            }
            try mouse(.leftMouseDragged, at: editor.location(percent: 35, temperature: 70), in: editor)
            assertPoints(editor, percentages: [0, 10, 35, 50, 100], temperatures: [50, 55, 70, 75, 85])
            XCTAssertEqual(changes, [committed, editor.profile])
        }
    }

    func testIdenticalProfileRefreshAndSensorChangePreserveActiveDrag() throws {
        try withEditor { editor in
            var changes: [FanCurveProfile] = []
            editor.onChange = { changes.append($0) }
            try drag(2, percent: 30, temperature: 68, in: editor)
            let committed = editor.profile
            editor.setProfile(committed)
            XCTAssertEqual(editor.draggingPoint, 2)
            var refreshed = committed
            refreshed.sensorKey = "UI test sensor"
            editor.setProfile(refreshed)
            XCTAssertEqual(editor.profile, refreshed)
            XCTAssertEqual(editor.draggingPoint, 2)
            XCTAssertEqual(changes, [committed])
            try mouse(.leftMouseDragged, at: editor.location(percent: 35, temperature: 70), in: editor)
            assertPoints(editor, percentages: [0, 10, 35, 50, 100], temperatures: [50, 55, 70, 75, 85])
            XCTAssertEqual(editor.profile.sensorKey, "UI test sensor")
            XCTAssertEqual(changes, [committed, editor.profile])
        }
    }

    func testChangedProfileCancelsDragWithoutEmittingAnEdit() throws {
        try withEditor { editor in
            var changes: [FanCurveProfile] = []
            editor.onChange = { changes.append($0) }
            try mouse(.leftMouseDown, at: editor.location(percent: 25, temperature: 64), in: editor)
            XCTAssertEqual(editor.draggingPoint, 2)
            let replacement = FanCurveProfile(points: [FanCurvePoint(percent: 40, temperature: 65)],
                                              sensorKey: "UI test sensor")
            editor.setProfile(replacement)
            XCTAssertNil(editor.draggingPoint)
            XCTAssertEqual(editor.profile, replacement)
            try mouse(.leftMouseDragged, at: editor.location(percent: 80, temperature: 90), in: editor)
            XCTAssertEqual(editor.profile, replacement)
            XCTAssertTrue(changes.isEmpty)
        }
    }

    func testInvalidProfileRefreshLeavesProfileAndActiveDragUntouched() throws {
        try withEditor { editor in
            var changes: [FanCurveProfile] = []
            editor.onChange = { changes.append($0) }
            let original = editor.profile
            try mouse(.leftMouseDown, at: editor.location(percent: 25, temperature: 64), in: editor)
            let invalid = [FanCurveProfile(points: []),
                           FanCurveProfile(points: [FanCurvePoint(percent: 101, temperature: 60)]),
                           FanCurveProfile(points: [FanCurvePoint(percent: 50, temperature: 19)])]
            for profile in invalid {
                editor.setProfile(profile)
                XCTAssertEqual(editor.profile, original)
                XCTAssertEqual(editor.draggingPoint, 2)
            }
            XCTAssertTrue(changes.isEmpty)
        }
    }

    func testTargetTelemetryPreservesDraggingAndUsesTheEffectivePercent() throws {
        try withEditor { editor in
            var changes: [FanCurveProfile] = []
            editor.onChange = { changes.append($0) }
            try drag(2, percent: 30, temperature: 68, in: editor)
            let committed = editor.profile
            let help = editor.toolTip
            editor.setTemperature(50)
            editor.setTargetPercent(70)
            XCTAssertEqual(editor.markerLocation, editor.location(percent: 70, temperature: 50))
            editor.setTargetPercent(70)
            editor.setTargetPercent(nil)
            XCTAssertEqual(editor.markerLocation, editor.location(percent: 0, temperature: 50))
            XCTAssertEqual(editor.profile, committed)
            XCTAssertEqual(editor.draggingPoint, 2)
            XCTAssertEqual(editor.toolTip, help)
            XCTAssertEqual(changes, [committed])
            try mouse(.leftMouseDragged, at: editor.location(percent: 35, temperature: 70), in: editor)
            XCTAssertEqual(changes, [committed, editor.profile])
        }
    }

    func testTargetMarkerClampsFiniteValuesAndFallsBackForInvalidValues() {
        withEditor { editor in
            XCTAssertNil(editor.markerLocation)
            editor.setTemperature(80)
            for (input, expected) in [(-10.0, 0.0), (150, 100), (42.5, 42.5)] {
                editor.setTargetPercent(input)
                XCTAssertEqual(editor.markerLocation, editor.location(percent: expected, temperature: 80))
            }
            for input: Double? in [nil, .nan, .infinity, -.infinity] {
                editor.setTargetPercent(input)
                XCTAssertEqual(editor.markerLocation, editor.location(percent: 75, temperature: 80))
            }
            editor.setTemperature(120)
            XCTAssertEqual(editor.markerLocation, editor.location(percent: 100, temperature: 100))
            editor.setTemperature(nil)
            XCTAssertNil(editor.markerLocation)
        }
    }

}

// MARK: - Settings page integration
extension FanCurveEditorTests {
    private final class State {
        var now: TimeInterval = 100
        var helperChecks = 0
        var commands: [(id: Int, rpm: Int)] = []
        var releases: [Int] = []
        var cancellations: [Set<Int>] = []
    }

    private final class Runtime {
        private let state: State
        let controller: FanCurveController
        var commands: [(id: Int, rpm: Int)] { state.commands }
        var releases: [Int] { state.releases }
        var cancellations: [Set<Int>] { state.cancellations }
        var helperChecks: Int { state.helperChecks }

        init(configuration: FanCurveConfiguration, enabledFans: Set<Int>, synchronized: Bool) {
            precondition(Thread.isMainThread)
            let state = State()
            self.state = state
            // Every runtime dependency is explicit; no Store, timer or real helper is used.
            self.controller = FanCurveController(
                configuration: configuration, enabledFans: enabledFans,
                synchronized: synchronized, persists: false,
                clock: { state.now },
                helperAvailable: { state.helperChecks += 1; return true },
                cancelLegacy: { state.cancellations.append($0) },
                send: { id, rpm, completion in
                    state.commands.append((id, rpm))
                    completion(true)
                },
                release: { id, completion in
                    state.releases.append(id)
                    completion(true)
                }
            )
        }

        func sample(_ fans: [FanCurveFan], temperature: Double = 75) {
            controller.updateSensors(
                fans: fans,
                sensors: [FanCurveSensor(key: "Hottest CPU", name: "Hottest CPU", value: temperature),
                          FanCurveSensor(key: "Hottest GPU", name: "Hottest GPU", value: temperature)],
                hotTemperature: temperature, at: state.now
            )
        }
    }

    private func withPage(configuration: FanCurveConfiguration = FanCurveConfiguration(useLoad: false),
                          enabledFans: Set<Int> = [], synchronized: Bool = true,
                          _ body: (Runtime, FansSettings, NSView) throws -> Void) rethrows {
        try onMain {
            _ = NSApplication.shared
            let runtime = Runtime(configuration: configuration, enabledFans: enabledFans, synchronized: synchronized)
            let page = FansSettings(controller: runtime.controller)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 480))
            container.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                page.topAnchor.constraint(equalTo: container.topAnchor),
                page.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            container.layoutSubtreeIfNeeded()
            XCTAssertNil(page.window)
            XCTAssertTrue(runtime.commands.isEmpty)
            XCTAssertTrue(runtime.releases.isEmpty)
            XCTAssertTrue(runtime.cancellations.isEmpty)
            XCTAssertEqual(runtime.helperChecks, 0)
            try body(runtime, page, container)
        }
    }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var result = (root as? T).map { [$0] } ?? []
        for child in root.subviews { result += views(type, in: child) }
        return result
    }

    private func control<T: NSControl>(_ type: T.Type, label: String, in root: NSView) throws -> T {
        try XCTUnwrap(views(type, in: root).first { $0.accessibilityLabel() == localizedString(label) })
    }

    private func sendAction(_ control: NSControl) throws {
        let action = try XCTUnwrap(control.action)
        XCTAssertNotNil(control.target)
        XCTAssertTrue(control.sendAction(action, to: control.target))
    }

    private func drainCallbacks(file: StaticString = #filePath, line: UInt = #line) {
        precondition(Thread.isMainThread)
        var drained = false
        DispatchQueue.main.async { drained = true }
        let deadline = Date(timeIntervalSinceNow: 1)
        while !drained && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
        XCTAssertTrue(drained, "Mock acknowledgements did not drain", file: file, line: line)
    }

    private var sampleFans: [FanCurveFan] {
        [FanCurveFan(id: 0, name: "CPU fan", minRPM: 1200, maxRPM: 6000, rpm: 1500),
         FanCurveFan(id: 1, name: "GPU fan", minRPM: 1800, maxRPM: 3000, rpm: 1900)]
    }

    func testPageSynchronizationShowsOneOrTwoGraphsAndRoutesSwitchesToInjectedController() throws {
        try withPage { runtime, page, container in
            let sync = try control(NSSwitch.self, label: "Synchronize fan's control", in: page)
            XCTAssertEqual(views(FanCurveEditor.self, in: page).filter { !$0.isHiddenOrHasHiddenAncestor }.count, 1)
            sync.state = .off
            try sendAction(sync)
            container.layoutSubtreeIfNeeded()
            XCTAssertFalse(runtime.controller.synchronized)
            XCTAssertEqual(views(FanCurveEditor.self, in: page).filter { !$0.isHiddenOrHasHiddenAncestor }.count, 2)
            XCTAssertEqual(runtime.controller.configuration.cpu, runtime.controller.configuration.shared)
            XCTAssertEqual(runtime.controller.configuration.gpu, runtime.controller.configuration.shared)
            let load = try control(NSSwitch.self, label: "Use CPU/GPU load", in: page)
            load.state = .on
            try sendAction(load)
            XCTAssertTrue(runtime.controller.configuration.useLoad)
            sync.state = .on
            try sendAction(sync)
            container.layoutSubtreeIfNeeded()
            XCTAssertTrue(runtime.controller.synchronized)
            XCTAssertEqual(views(FanCurveEditor.self, in: page).filter { !$0.isHiddenOrHasHiddenAncestor }.count, 1)
            XCTAssertTrue(runtime.commands.isEmpty)
            XCTAssertTrue(runtime.releases.isEmpty)
        }
    }

    func testPageProfileLimitsAreIndependentAndResetPreservesTheSensor() throws {
        let full = FanCurveProfile(points: (0..<10).map {
            FanCurvePoint(percent: $0 * 10, temperature: 25 + $0 * 6)
        }, sensorKey: "shared sensor")
        let cpu = FanCurveProfile(points: [FanCurvePoint(percent: 37, temperature: 60)], sensorKey: "CPU sensor")
        let gpu = FanCurveProfile(points: Array(full.points.prefix(9)), sensorKey: "GPU sensor")
        try withPage(configuration: FanCurveConfiguration(shared: full, cpu: cpu, gpu: gpu, useLoad: false),
                     synchronized: false) { runtime, page, container in
            let editors = views(FanCurveEditor.self, in: page).filter { !$0.isHiddenOrHasHiddenAncestor }
            let cpuEditor = try XCTUnwrap(editors.first { $0.profile.sensorKey == "CPU sensor" })
            let gpuEditor = try XCTUnwrap(editors.first { $0.profile.sensorKey == "GPU sensor" })
            try mouse(.leftMouseDown, at: cpuEditor.location(percent: 37, temperature: 60), in: cpuEditor, clicks: 2)
            XCTAssertEqual(runtime.controller.configuration.cpu, cpu)
            try mouse(.leftMouseDown, at: gpuEditor.location(percent: 90, temperature: 90), in: gpuEditor, clicks: 2)
            XCTAssertEqual(runtime.controller.configuration.gpu?.points.count, 10)
            try mouse(.leftMouseDown, at: gpuEditor.location(percent: 95, temperature: 95), in: gpuEditor, clicks: 2)
            XCTAssertEqual(runtime.controller.configuration.gpu?.points.count, 10)
            XCTAssertEqual(runtime.controller.configuration.cpu, cpu)
            XCTAssertEqual(runtime.controller.configuration.shared, full)
            let section = try XCTUnwrap(gpuEditor.superview?.superview?.superview)
            try sendAction(control(NSButton.self, label: "Reset fan curve", in: section))
            XCTAssertEqual(runtime.controller.configuration.gpu,
                           FanCurveProfile(sensorKey: "GPU sensor"))
            let sync = try control(NSSwitch.self, label: "Synchronize fan's control", in: page)
            sync.state = .on
            try sendAction(sync)
            container.layoutSubtreeIfNeeded()
            let shared = try XCTUnwrap(views(FanCurveEditor.self, in: page).first { !$0.isHiddenOrHasHiddenAncestor })
            try mouse(.leftMouseDown, at: shared.location(percent: 95, temperature: 95), in: shared, clicks: 2)
            XCTAssertEqual(runtime.controller.configuration.shared, full)
            XCTAssertEqual(runtime.controller.configuration.cpu, cpu)
        }
    }

    func testIndependentAssignedButtonsWaitForAvailableFansAndRouteEnableToMocks() throws {
        let configuration = FanCurveConfiguration(cpu: FanCurveProfile(),
                                                 gpu: FanCurveProfile(sensorKey: "Hottest GPU"),
                                                 cpuFanID: 0, gpuFanID: 1, useLoad: false)
        try withPage(configuration: configuration, synchronized: false) { runtime, page, _ in
            var buttons = views(NSButton.self, in: page).filter {
                !$0.isHiddenOrHasHiddenAncestor && $0.title == localizedString("Enable curve")
            }
            XCTAssertEqual(buttons.count, 2)
            XCTAssertTrue(buttons.allSatisfy { !$0.isEnabled })
            runtime.sample([sampleFans[0]])
            buttons = views(NSButton.self, in: page).filter {
                !$0.isHiddenOrHasHiddenAncestor && $0.title == localizedString("Enable curve")
            }
            XCTAssertEqual(buttons.filter { $0.isEnabled }.count, 1)
            try sendAction(XCTUnwrap(buttons.first { $0.isEnabled }))
            XCTAssertEqual(runtime.controller.enabledFans, [0])
            XCTAssertEqual(runtime.cancellations.last, [0])
            XCTAssertEqual(runtime.releases, [0])
            XCTAssertTrue(runtime.commands.isEmpty)
            drainCallbacks()
            runtime.sample([sampleFans[0]])
            runtime.controller.tick()
            drainCallbacks()
            XCTAssertEqual(runtime.commands.map { $0.id }, [0])
            XCTAssertEqual(runtime.commands.map { $0.rpm }, [3000])
            XCTAssertEqual(runtime.controller.activeFans, [0])
        }
    }

    func testSharedRequestedCurveCanBeStoppedWhenNoFansWereDiscovered() throws {
        try withPage(enabledFans: [0, 1]) { runtime, page, _ in
            XCTAssertTrue(runtime.controller.fans.isEmpty)
            XCTAssertTrue(runtime.controller.activeFans.isEmpty)
            let stop = try control(NSButton.self, label: "Stop curve", in: page)
            XCTAssertTrue(stop.isEnabled)
            try sendAction(stop)
            XCTAssertTrue(runtime.controller.enabledFans.isEmpty)
            XCTAssertEqual(runtime.releases.sorted(), [0, 1])
            XCTAssertEqual(runtime.cancellations.first, [0, 1])
            XCTAssertTrue(runtime.commands.isEmpty)
            XCTAssertEqual(stop.title, localizedString("Enable curve"))
            XCTAssertFalse(stop.isEnabled)
            drainCallbacks()
        }
    }

    func testPageMarkerUsesMaximumActiveTargetRatioAndFallsBackAfterStopping() throws {
        try withPage(enabledFans: [0, 1]) { runtime, page, container in
            runtime.sample(sampleFans, temperature: 50)
            let editor = try XCTUnwrap(views(FanCurveEditor.self, in: page).first)
            XCTAssertEqual(editor.markerLocation, editor.location(percent: 0, temperature: 50))
            runtime.controller.tick()
            drainCallbacks()
            XCTAssertEqual(runtime.commands.map { $0.rpm }, [1200, 1800])
            XCTAssertEqual(runtime.controller.activeFans, [0, 1])
            XCTAssertEqual(editor.markerLocation, editor.location(percent: 60, temperature: 50))
            let readings = try control(NSTextField.self, label: "Fan speed", in: page)
            XCTAssertEqual(readings.stringValue, [
                localizedString("%0: %1 RPM / Target: %2 RPM (%3)", "CPU fan", "1500", "1200", localizedString("Curve active")),
                localizedString("%0: %1 RPM / Target: %2 RPM (%3)", "GPU fan", "1900", "1800", localizedString("Curve active"))
            ].joined(separator: "\n"))
            container.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
            editor.cacheDisplay(in: editor.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
            try sendAction(control(NSButton.self, label: "Stop curve", in: page))
            XCTAssertEqual(editor.markerLocation, editor.location(percent: 0, temperature: 50))
            drainCallbacks()
        }
    }

    func testPageIgnoresNotificationsFromAnotherInjectedController() throws {
        try withPage { runtime, page, _ in
            let other = Runtime(configuration: FanCurveConfiguration(useLoad: false), enabledFans: [], synchronized: false)
            other.controller.setUseLoad(true)
            other.sample(sampleFans)
            XCTAssertFalse(runtime.controller.configuration.useLoad)
            XCTAssertEqual(try control(NSSwitch.self, label: "Use CPU/GPU load", in: page).state, .off)
            XCTAssertFalse(try control(NSButton.self, label: "Enable curve", in: page).isEnabled)
        }
    }

    func testPageLayoutAt540By480KeepsGraphsAndControlsInsideTheScrollableWidth() throws {
        try withPage { _, page, container in
            let sync = try control(NSSwitch.self, label: "Synchronize fan's control", in: page)
            for synchronized in [true, false] {
                sync.state = synchronized ? .on : .off
                try sendAction(sync)
                container.layoutSubtreeIfNeeded()
                XCTAssertEqual(page.frame, container.bounds)
                XCTAssertFalse(page.hasAmbiguousLayout)
                let scroll = try XCTUnwrap(views(NSScrollView.self, in: page).first)
                let document = try XCTUnwrap(scroll.documentView)
                XCTAssertEqual(scroll.frame.size, container.bounds.size)
                XCTAssertFalse(scroll.hasAmbiguousLayout)
                XCTAssertFalse(document.hasAmbiguousLayout)
                XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height)
                let editors = views(FanCurveEditor.self, in: page).filter { !$0.isHiddenOrHasHiddenAncestor }
                XCTAssertEqual(editors.count, synchronized ? 1 : 2)
                for editor in editors {
                    XCTAssertFalse(editor.hasAmbiguousLayout)
                    XCTAssertGreaterThanOrEqual(editor.frame.width, 320)
                    XCTAssertEqual(editor.frame.height, 250)
                    let frame = editor.convert(editor.bounds, to: document)
                    XCTAssertGreaterThanOrEqual(frame.minX, 0)
                    XCTAssertLessThanOrEqual(frame.maxX, document.bounds.width)
                }
                for control in views(NSControl.self, in: document) where !control.isHiddenOrHasHiddenAncestor {
                    let frame = control.convert(control.bounds, to: document)
                    XCTAssertGreaterThan(frame.height, 0)
                    XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
                    XCTAssertLessThanOrEqual(frame.maxX, document.bounds.width + 0.5)
                }
            }
        }
    }
}

@main
enum FanCurveEditorTestMain {
    static func main() {
        precondition(Thread.isMainThread)
        _ = NSApplication.shared
        let suite = FanCurveEditorTests.defaultTestSuite
        suite.run()
        guard let result = suite.testRun, result.executionCount > 0 else { exit(1) }
        exit(result.hasSucceeded ? 0 : 1)
    }
}
#endif
