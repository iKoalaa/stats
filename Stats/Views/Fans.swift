//
//  Fans.swift
//  Stats
//

import Cocoa
import Kit

internal final class FansSettings: NSStackView {
    private let controller: FanCurveController
    private let synchronize = NSSwitch()
    private let useLoad = NSSwitch()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let unavailable = NSTextField(wrappingLabelWithString: localizedString("No controllable fans are available on this Mac."))
    private var sections: [FanCurveProfileID: FanCurveSection] = [:]
    private var observers: [NSObjectProtocol] = []

    init(controller: FanCurveController = .shared) {
        precondition(Thread.isMainThread)
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Settings.width, height: Constants.Settings.height))
        self.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = ScrollableStackView(orientation: .vertical)
        scrollView.stackView.edgeInsets = NSEdgeInsets(
            top: 0, left: Constants.Settings.margin,
            bottom: Constants.Settings.margin, right: Constants.Settings.margin
        )
        scrollView.stackView.spacing = Constants.Settings.margin
        self.addArrangedSubview(scrollView)

        self.synchronize.controlSize = .mini
        self.synchronize.target = self
        self.synchronize.action = #selector(setSynchronized)
        self.synchronize.setAccessibilityLabel(localizedString("Synchronize fan's control"))
        self.synchronize.toolTip = localizedString("Use one temperature curve for all fans.")
        self.useLoad.controlSize = .mini
        self.useLoad.target = self
        self.useLoad.action = #selector(setUseLoad)
        self.useLoad.setAccessibilityLabel(localizedString("Use CPU/GPU load"))
        self.useLoad.toolTip = localizedString("CPU/GPU load can increase the speed required by the temperature curve.")
        self.status.font = .systemFont(ofSize: 12)
        self.status.textColor = .secondaryLabelColor
        self.status.setAccessibilityLabel(localizedString("Fan control status"))
        self.unavailable.font = .systemFont(ofSize: 12)
        self.unavailable.textColor = .secondaryLabelColor

        let controls = PreferencesSection([
            PreferencesRow(localizedString("Synchronize fan's control"), component: self.synchronize),
            PreferencesRow(localizedString("Use CPU/GPU load"), component: self.useLoad),
            self.status,
            self.unavailable
        ])
        scrollView.stackView.addArrangedSubview(controls)
        NSLayoutConstraint.activate([
            controls.widthAnchor.constraint(equalTo: scrollView.stackView.widthAnchor, constant: -2 * Constants.Settings.margin),
            self.status.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -2 * Constants.Settings.margin),
            self.unavailable.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -2 * Constants.Settings.margin)
        ])
        for id in [FanCurveProfileID.shared, .cpu, .gpu] {
            let section = FanCurveSection(id: id, controller: self.controller)
            self.sections[id] = section
            scrollView.stackView.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        }
        self.refreshConfiguration()
        self.observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name("FanCurveChanged"), object: self.controller, queue: .main
        ) { [weak self] _ in self?.refreshConfiguration() })
        self.observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name("FanCurveUpdated"), object: self.controller, queue: .main
        ) { [weak self] _ in self?.refreshReadings() })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    internal func viewWillAppear() {
        self.refreshConfiguration()
    }

    private func refreshConfiguration() {
        precondition(Thread.isMainThread)
        let controller = self.controller
        self.synchronize.state = controller.synchronized ? .on : .off
        self.useLoad.state = controller.configuration.useLoad ? .on : .off
        for (id, section) in self.sections {
            section.isHidden = controller.synchronized ? id != .shared : id == .shared
            section.setProfile(controller.configuration.profile(id))
        }
        self.refreshReadings()
    }

    private func refreshReadings() {
        precondition(Thread.isMainThread)
        let controller = self.controller
        self.status.stringValue = localizedString(controller.status)
        self.unavailable.isHidden = !controller.fans.isEmpty
        for section in self.sections.values {
            section.refreshReadings()
        }
    }

    @objc private func setSynchronized(_ sender: NSSwitch) {
        precondition(Thread.isMainThread)
        self.controller.setSynchronized(sender.state == .on)
        self.refreshConfiguration()
    }

    @objc private func setUseLoad(_ sender: NSSwitch) {
        precondition(Thread.isMainThread)
        self.controller.setUseLoad(sender.state == .on)
        self.refreshConfiguration()
    }
}

private final class FanCurveSection: NSStackView {
    private let controller: FanCurveController
    private let content: PreferencesSection
    private let profileID: FanCurveProfileID
    private let editor = FanCurveEditor()
    private let sensor = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fan = NSPopUpButton(frame: .zero, pullsDown: false)
    private let temperature = NSTextField(labelWithString: "")
    private let readings = NSTextField(wrappingLabelWithString: "")
    private let enable = NSButton()

    init(id: FanCurveProfileID, controller: FanCurveController) {
        self.controller = controller
        self.profileID = id
        let title: String
        switch id {
        case .shared: title = localizedString("Fans")
        case .cpu: title = localizedString("CPU")
        case .gpu: title = localizedString("GPU")
        }
        self.content = PreferencesSection(title: title)
        super.init(frame: .zero)
        self.orientation = .vertical
        self.translatesAutoresizingMaskIntoConstraints = false
        self.addArrangedSubview(self.content)
        self.content.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true

        self.sensor.target = self
        self.sensor.action = #selector(selectSensor)
        self.sensor.setAccessibilityLabel(localizedString("Temperature sensor"))
        self.sensor.toolTip = localizedString("Choose the temperature sensor used by this curve.")
        self.fan.target = self
        self.fan.action = #selector(assignFan)
        self.fan.setAccessibilityLabel(localizedString("Physical fan"))
        self.fan.toolTip = localizedString("Assign a physical fan to this profile. Fan order does not identify CPU or GPU cooling.")
        for popup in [self.sensor, self.fan] {
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 220).isActive = true
            popup.lineBreakMode = .byTruncatingMiddle
        }
        self.temperature.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        self.temperature.setAccessibilityLabel(localizedString("Temperature"))
        self.readings.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        self.readings.textColor = .secondaryLabelColor
        self.readings.setAccessibilityLabel(localizedString("Fan speed"))
        self.enable.bezelStyle = .rounded
        self.enable.target = self
        self.enable.action = #selector(toggleCurve)
        self.enable.toolTip = localizedString("Enable this curve or return its fans to automatic control.")

        let reset = NSButton(title: localizedString("Reset"), target: self, action: #selector(resetCurve))
        reset.bezelStyle = .rounded
        reset.setAccessibilityLabel(localizedString("Reset fan curve"))
        reset.toolTip = localizedString("Restore the five default points without changing the selected sensor.")
        let controls = NSStackView(views: [reset, self.enable])
        controls.orientation = .horizontal
        controls.spacing = Constants.Settings.margin
        self.content.add(PreferencesRow(localizedString("Temperature sensor"), component: self.sensor))
        if id != .shared {
            self.content.add(PreferencesRow(localizedString("Physical fan"), component: self.fan))
        }
        self.content.add(self.editor)
        self.content.add(PreferencesRow(localizedString("Temperature"), component: self.temperature))
        self.content.add(self.readings)
        self.content.add(PreferencesRow(component: controls))
        NSLayoutConstraint.activate([
            self.editor.widthAnchor.constraint(equalTo: self.widthAnchor, constant: -2 * Constants.Settings.margin),
            self.readings.widthAnchor.constraint(equalTo: self.editor.widthAnchor)
        ])

        self.editor.onChange = { [weak self] profile in
            guard let self, profile.isValid else { return }
            precondition(Thread.isMainThread)
            self.controller.updateProfile(self.profileID, profile: profile)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setProfile(_ profile: FanCurveProfile) {
        self.editor.setProfile(profile)
    }

    func refreshReadings() {
        precondition(Thread.isMainThread)
        let controller = self.controller
        let configuration = controller.configuration
        let selectedKey = configuration.profile(self.profileID).sensorKey
        var sensorItems = controller.sensors.map { ($0.key, localizedString($0.name), true) }
        if !sensorItems.contains(where: { $0.0 == selectedKey }) {
            sensorItems.append((selectedKey, localizedString("Unavailable: %0", selectedKey), false))
        }
        self.updateMenu(self.sensor, items: sensorItems, selected: selectedKey)

        if self.profileID != .shared {
            let selectedID = self.profileID == .cpu ? configuration.cpuFanID : configuration.gpuFanID
            var fanItems = [("", localizedString("None"), true)]
            fanItems += controller.fans.map { (String($0.id), localizedString($0.name), true) }
            if let selectedID, !controller.fans.contains(where: { $0.id == selectedID }) {
                fanItems.append((String(selectedID), localizedString("Unavailable: %0", String(selectedID)), false))
            }
            self.updateMenu(self.fan, items: fanItems, selected: selectedID.map(String.init) ?? "")
        }

        let value = controller.sensors.first(where: { $0.key == selectedKey })?.value
        if let value, value.isFinite {
            self.temperature.stringValue = localizedString("%0 C", String(format: "%.0f", value))
            self.editor.setTemperature(value)
        } else {
            self.temperature.stringValue = localizedString("Unavailable")
            self.editor.setTemperature(nil)
        }
        let ids = self.assignedFanIDs()
        let fans = controller.fans.filter { ids.contains($0.id) }
        let targetPercent = fans.compactMap { fan -> Double? in
            guard controller.activeFans.contains(fan.id), let rpm = controller.targetRPM[fan.id],
                  fan.maxRPM.isFinite, fan.maxRPM > 0 else { return nil }
            return Double(rpm) / fan.maxRPM * 100
        }.max()
        self.editor.setTargetPercent(targetPercent)
        self.readings.stringValue = fans.map { fan in
            let actual = fan.rpm.isFinite ? String(format: "%.0f", fan.rpm) : localizedString("Unavailable")
            let target = controller.targetRPM[fan.id].map(String.init) ?? localizedString("Unavailable")
            let state = localizedString(controller.activeFans.contains(fan.id) ? "Curve active" : "Curve inactive")
            return localizedString("%0: %1 RPM / Target: %2 RPM (%3)", localizedString(fan.name), actual, target, state)
        }.joined(separator: "\n")
        if fans.isEmpty {
            self.readings.stringValue = localizedString(self.profileID == .shared
                ? "No controllable fans are available on this Mac."
                : "Select an available physical fan to enable this curve.")
        }
        let enabled = ids.contains { controller.isCurveEnabled(for: $0) }
        self.enable.title = localizedString(enabled ? "Stop curve" : "Enable curve")
        self.enable.setAccessibilityLabel(self.enable.title)
        // Stopping remains possible after a fan or sensor disappears.
        self.enable.isEnabled = enabled || !fans.isEmpty
    }

    private func assignedFanIDs() -> [Int] {
        precondition(Thread.isMainThread)
        let controller = self.controller
        if self.profileID == .shared {
            return Array(Set(controller.fans.map { $0.id }).union(controller.enabledFans)).sorted()
        }
        let id = self.profileID == .cpu ? controller.configuration.cpuFanID : controller.configuration.gpuFanID
        guard let id else { return [] }
        return [id]
    }

    private func updateMenu(_ popup: NSPopUpButton, items: [(String, String, Bool)], selected: String) {
        let current = popup.itemArray
        let unchanged = current.count == items.count && zip(current, items).allSatisfy {
            $0.0.representedObject as? String == $0.1.0 && $0.0.title == $0.1.1 && $0.0.isEnabled == $0.1.2
        }
        if !unchanged {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (key, title, enabled) in items {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.representedObject = key
                item.isEnabled = enabled
                menu.addItem(item)
            }
            popup.menu = menu
        }
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == selected }) {
            popup.select(item)
        }
    }

    @objc private func selectSensor(_ sender: NSPopUpButton) {
        precondition(Thread.isMainThread)
        guard let item = sender.selectedItem, item.isEnabled, let key = item.representedObject as? String else { return }
        let controller = self.controller
        var profile = controller.configuration.profile(self.profileID)
        profile.sensorKey = key
        guard profile.isValid else { return }
        controller.updateProfile(self.profileID, profile: profile)
        self.setProfile(profile)
        self.refreshReadings()
    }

    @objc private func assignFan(_ sender: NSPopUpButton) {
        precondition(Thread.isMainThread)
        guard self.profileID != .shared, let item = sender.selectedItem, item.isEnabled,
              let key = item.representedObject as? String else { return }
        self.controller.assignFan(Int(key), to: self.profileID)
        self.refreshReadings()
    }

    @objc private func resetCurve(_ sender: NSButton) {
        precondition(Thread.isMainThread)
        let controller = self.controller
        let profile = FanCurveProfile(sensorKey: controller.configuration.profile(self.profileID).sensorKey)
        guard profile.isValid else { return }
        controller.updateProfile(self.profileID, profile: profile)
        self.setProfile(profile)
        self.refreshReadings()
    }

    @objc private func toggleCurve(_ sender: NSButton) {
        precondition(Thread.isMainThread)
        let controller = self.controller
        let ids = self.assignedFanIDs()
        guard !ids.isEmpty else { return }
        if ids.contains(where: { controller.isCurveEnabled(for: $0) }) {
            ids.forEach { controller.stopCurve(for: $0) }
        } else if let id = ids.first(where: { id in controller.fans.contains(where: { $0.id == id }) }) {
            controller.enableCurve(for: id)
        }
        self.refreshReadings()
    }
}

// Internal so UI tests can exercise geometry and edits without a controller or SMC.
internal final class FanCurveEditor: NSView {
    internal private(set) var profile = FanCurveProfile()
    internal var onChange: ((FanCurveProfile) -> Void)?
    internal private(set) var draggingPoint: Int?
    private var temperature: Double?
    private var targetPercent: Double?
    private let hitRadius: CGFloat = 8

    internal var plotRect: NSRect {
        NSRect(x: 54, y: 42, width: max(1, self.bounds.width - 76), height: max(1, self.bounds.height - 72))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            self.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            self.heightAnchor.constraint(equalToConstant: 250)
        ])
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.image)
        self.setAccessibilityLabel(localizedString("Fan curve editor"))
        self.updateHelp()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    internal func setProfile(_ profile: FanCurveProfile) {
        guard profile.isValid else { return }
        let samePoints = self.profile.points.count == profile.points.count && zip(self.profile.points, profile.points).allSatisfy {
            $0.0.percent == $0.1.percent && $0.0.temperature == $0.1.temperature
        }
        guard !samePoints || self.profile.sensorKey != profile.sensorKey else { return }
        if !samePoints { self.draggingPoint = nil }
        self.profile = profile
        self.updateHelp()
        self.needsDisplay = true
    }

    internal func setTemperature(_ value: Double?) {
        let value = value.flatMap { $0.isFinite ? $0 : nil }
        guard self.temperature != value else { return }
        self.temperature = value
        self.needsDisplay = true
    }

    internal func setTargetPercent(_ value: Double?) {
        let value = value.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        guard self.targetPercent != value else { return }
        self.targetPercent = value
        self.needsDisplay = true
    }

    internal var markerLocation: NSPoint? {
        guard let temperature = self.temperature,
              let percent = self.targetPercent ?? self.profile.percentage(at: temperature) else { return nil }
        return self.location(percent: percent, temperature: min(100, max(20, temperature)))
    }

    internal func location(percent: Double, temperature: Double) -> NSPoint {
        let rect = self.plotRect
        return NSPoint(x: rect.minX + CGFloat(percent / 100) * rect.width,
                       y: rect.minY + CGFloat((temperature - 20) / 80) * rect.height)
    }

    internal func coordinates(at location: NSPoint) -> (percent: Int, temperature: Int) {
        let rect = self.plotRect
        let percent = (Double((location.x - rect.minX) / rect.width) * 100).rounded()
        let temperature = (20 + Double((location.y - rect.minY) / rect.height) * 80).rounded()
        return (Int(min(100, max(0, percent))), Int(min(100, max(20, temperature))))
    }

    internal func pointIndex(at location: NSPoint) -> Int? {
        self.profile.points.indices.min { a, b in
            let p = self.profile.points[a]
            let q = self.profile.points[b]
            let left = self.location(percent: Double(p.percent), temperature: Double(p.temperature))
            let right = self.location(percent: Double(q.percent), temperature: Double(q.temperature))
            return hypot(left.x - location.x, left.y - location.y) < hypot(right.x - location.x, right.y - location.y)
        }.flatMap { index in
            let point = self.profile.points[index]
            let center = self.location(percent: Double(point.percent), temperature: Double(point.temperature))
            return hypot(center.x - location.x, center.y - location.y) <= self.hitRadius ? index : nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        self.window?.makeFirstResponder(self)
        let location = self.convert(event.locationInWindow, from: nil)
        let index = self.pointIndex(at: location)
        self.draggingPoint = nil
        if event.clickCount == 2 {
            var profile = self.profile
            if let index {
                guard profile.points.count > 1, profile.removePoint(at: index) else { return }
            } else {
                guard self.plotRect.contains(location), profile.points.count < 10 else { return }
                let value = self.coordinates(at: location)
                guard profile.insertPoint(percent: value.percent, temperature: value.temperature) else { return }
            }
            self.commit(profile)
        } else if event.clickCount == 1 {
            self.draggingPoint = index
        }
        self.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = self.draggingPoint else { return }
        let value = self.coordinates(at: self.convert(event.locationInWindow, from: nil))
        var profile = self.profile
        guard profile.movePoint(at: index, percent: value.percent, temperature: value.temperature) else { return }
        self.commit(profile)
    }

    override func mouseUp(with event: NSEvent) {
        self.draggingPoint = nil
        self.needsDisplay = true
    }

    private func commit(_ profile: FanCurveProfile) {
        guard profile.isValid else { return }
        self.profile = profile
        self.updateHelp()
        self.needsDisplay = true
        self.onChange?(profile)
    }

    private func updateHelp() {
        let instructions = localizedString("Drag points to edit. Double-click empty space to add a point; double-click a point to remove it.")
        let limit: String
        if self.profile.points.count == 10 {
            limit = localizedString("Maximum of 10 points reached. Remove a point before adding another.")
        } else if self.profile.points.count == 1 {
            limit = localizedString("The last point cannot be removed.")
        } else {
            limit = localizedString("Use 1 to 10 points, in steps of 1% and 1 C.")
        }
        self.toolTip = instructions + "\n" + limit
        self.setAccessibilityHelp(self.toolTip)
        self.setAccessibilityValue(self.profile.points.map {
            localizedString("%0% at %1 C", String($0.percent), String($0.temperature))
        }.joined(separator: ", "))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = self.plotRect
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor
        ]
        for percent in stride(from: 0, through: 100, by: 20) {
            let point = self.location(percent: Double(percent), temperature: 20)
            let line = NSBezierPath()
            line.move(to: point)
            line.line(to: NSPoint(x: point.x, y: rect.maxY))
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
            line.stroke()
            let text = "\(percent)%" as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: point.x - size.width / 2, y: rect.minY - 18), withAttributes: attributes)
        }
        for temperature in stride(from: 20, through: 100, by: 20) {
            let point = self.location(percent: 0, temperature: Double(temperature))
            let line = NSBezierPath()
            line.move(to: point)
            line.line(to: NSPoint(x: rect.maxX, y: point.y))
            NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
            line.stroke()
            let text = "\(temperature)" as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: rect.minX - size.width - 8, y: point.y - size.height / 2), withAttributes: attributes)
        }
        let speed = localizedString("Speed (%)") as NSString
        let speedSize = speed.size(withAttributes: attributes)
        speed.draw(at: NSPoint(x: rect.midX - speedSize.width / 2, y: 4), withAttributes: attributes)
        (localizedString("Temperature (C)") as NSString).draw(at: NSPoint(x: rect.minX, y: rect.maxY + 10), withAttributes: attributes)

        guard let first = self.profile.points.first, let last = self.profile.points.last else { return }
        let curve = NSBezierPath()
        curve.move(to: self.location(percent: Double(first.percent), temperature: 20))
        for point in self.profile.points {
            curve.line(to: self.location(percent: Double(point.percent), temperature: Double(point.temperature)))
        }
        curve.line(to: self.location(percent: Double(last.percent), temperature: 100))
        curve.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        curve.stroke()

        if let point = self.markerLocation {
            let guide = NSBezierPath()
            guide.move(to: NSPoint(x: rect.minX, y: point.y))
            guide.line(to: point)
            guide.line(to: NSPoint(x: point.x, y: rect.minY))
            guide.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.secondaryLabelColor.setStroke()
            guide.stroke()
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)).fill()
        }
        for (index, point) in self.profile.points.enumerated() {
            let center = self.location(percent: Double(point.percent), temperature: Double(point.temperature))
            let radius: CGFloat = self.draggingPoint == index ? 6 : 4
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            NSColor.controlBackgroundColor.setFill()
            dot.fill()
            NSColor.controlAccentColor.setStroke()
            dot.lineWidth = 2
            dot.stroke()
            if self.draggingPoint == index {
                let text = localizedString("%0% at %1 C", String(point.percent), String(point.temperature)) as NSString
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: min(rect.maxX - size.width, max(rect.minX, center.x + 10)),
                                      y: min(rect.maxY - size.height, center.y + 10)), withAttributes: attributes)
            }
        }
    }
}
