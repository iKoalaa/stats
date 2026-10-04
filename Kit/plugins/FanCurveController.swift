import Cocoa

public struct FanCurveFan: Equatable {
    public let id: Int
    public let name: String
    public let minRPM: Double
    public let maxRPM: Double
    public let rpm: Double

    public init(id: Int, name: String, minRPM: Double, maxRPM: Double, rpm: Double) {
        self.id = id
        self.name = name
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.rpm = rpm
    }
}

public struct FanCurveSensor: Equatable {
    public let key: String
    public let name: String
    public let value: Double?

    public init(key: String, name: String, value: Double?) {
        self.key = key
        self.name = name
        self.value = value
    }
}

// State, UI notifications and command ownership are confined to the main queue.
public final class FanCurveController {
    public static let shared = FanCurveController(cancelLegacy: { SMCHelper.shared.cancelDeferredFanCommands(for: $0) })
    public private(set) var configuration: FanCurveConfiguration
    public private(set) var synchronized: Bool
    public private(set) var fans: [FanCurveFan] = []
    public private(set) var sensors: [FanCurveSensor] = []
    public private(set) var activeFans: Set<Int> = []
    public var enabledFans: Set<Int> { self.requestedFans }
    public private(set) var targetRPM: [Int: Int] = [:]
    public private(set) var status = "Curve inactive"

    private var requestedFans: Set<Int>
    private var configurationValid = true
    private var sensorsAt: TimeInterval = 0
    private var hotTemperature: Double?
    private var loads: [FanCurveProfileID: (value: Double, at: TimeInterval)] = [:]
    private var previousPercent: [Int: Double] = [:]
    private var previousAt: [Int: TimeInterval] = [:]
    private var sharedPercent: Double?
    private var sharedAt: TimeInterval?
    private var epochs: [Int: Int] = [:]
    private var pendingCommands: [Int: TimeInterval] = [:]
    private var pendingReleases: [Int: TimeInterval] = [:]
    private var releaseEpochs: [Int: Int] = [:]
    private var settingsVisible = false
    private var paused = false
    private var sleeping = false
    private var terminated = false
    private var requiredSensors = false
    private var requiredLoad = false
    private var freshAfter: TimeInterval = 0
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var metricDemand: ((Bool, Bool) -> Void)?
    private let clock: () -> TimeInterval
    private let send: (Int, Int, @escaping (Bool) -> Void) -> Void
    private let release: (Int, @escaping (Bool) -> Void) -> Void
    private let helperAvailable: () -> Bool
    private let cancelLegacy: (Set<Int>) -> Void
    private let persists: Bool

    internal init(configuration: FanCurveConfiguration? = nil, enabledFans: Set<Int>? = nil,
                  synchronized: Bool? = nil, persists: Bool = true,
                  clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                  helperAvailable: @escaping () -> Bool = { SMCHelper.shared.isInstalled },
                  cancelLegacy: @escaping (Set<Int>) -> Void = { _ in },
                  send: @escaping (Int, Int, @escaping (Bool) -> Void) -> Void = {
                      SMCHelper.shared.setCurveFanSpeed($0, speed: $1, completion: $2)
                  },
                  release: @escaping (Int, @escaping (Bool) -> Void) -> Void = {
                      SMCHelper.shared.releaseCurveFan($0, completion: $1)
                  }) {
        self.clock = clock
        self.send = send
        self.release = release
        self.helperAvailable = helperAvailable
        self.cancelLegacy = cancelLegacy
        self.persists = persists
        self.configuration = configuration ?? FanCurveConfiguration()
        if configuration == nil, let data = Store.shared.data(key: "FanCurve_configuration") {
            if let decoded = try? JSONDecoder().decode(FanCurveConfiguration.self, from: data), decoded.isValid {
                self.configuration = decoded
            } else {
                self.configurationValid = false
                self.status = "Fan curve configuration invalid"
            }
        }
        self.synchronized = synchronized ?? Store.shared.bool(key: "Sensors_fansSync", defaultValue: false)
        self.requestedFans = enabledFans ?? Set(Store.shared.array(key: "FanCurve_enabledFans", defaultValue: [])
            .compactMap { $0 as? Int }.filter { (0...9).contains($0) })
    }

    public func start(metricDemand: @escaping (Bool, Bool) -> Void) {
        precondition(Thread.isMainThread)
        guard self.timer == nil, !self.terminated else { return }
        self.metricDemand = metricDemand
        self.paused = Store.shared.bool(key: "pause", defaultValue: false)
        self.freshAfter = self.clock()
        self.cancelLegacy(self.requestedFans)
        self.releaseControl(self.requestedFans, force: true)
        self.observers.append(NotificationCenter.default.addObserver(forName: .pause, object: nil, queue: .main) { [weak self] note in
            self?.setPaused(note.userInfo?["state"] as? Bool ?? true)
        })
        let workspace = NSWorkspace.shared.notificationCenter
        self.workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setSleeping(true)
        })
        self.workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setSleeping(false)
        })
        self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        if let timer = self.timer { RunLoop.main.add(timer, forMode: .common) }
        self.updateDemand()
    }

    deinit {
        self.timer?.invalidate()
        self.observers.forEach { NotificationCenter.default.removeObserver($0) }
        self.workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    public func setSettingsVisible(_ visible: Bool) {
        precondition(Thread.isMainThread)
        self.settingsVisible = visible
        self.updateDemand()
    }

    public func updateLoad(_ profile: FanCurveProfileID, value: Double?, at: TimeInterval) {
        precondition(Thread.isMainThread)
        guard profile != .shared else { return }
        if let value, value.isFinite, (0...1).contains(value), at > 0, at >= self.freshAfter {
            self.loads[profile] = (value, at)
        } else {
            self.loads.removeValue(forKey: profile)
        }
    }

    public func updateSensors(fans: [FanCurveFan], sensors: [FanCurveSensor], hotTemperature: Double?, at: TimeInterval) {
        precondition(Thread.isMainThread)
        // Initial discovery describes hardware, never authorizes a write.
        self.fans = fans.filter { (0...9).contains($0.id) && FanCurvePolicy.rpm(percent: 0, minRPM: $0.minRPM, maxRPM: $0.maxRPM) != nil }
        self.sensors = sensors
        self.sensorsAt = at >= self.freshAfter ? at : 0
        self.hotTemperature = hotTemperature.flatMap { $0.isFinite && $0 > 0 && $0 <= 150 ? $0 : nil }
        self.notify()
    }

    public func updateProfile(_ id: FanCurveProfileID, profile: FanCurveProfile) {
        precondition(Thread.isMainThread)
        guard profile.isValid else { return }
        self.configuration.setProfile(profile, for: id)
        self.configurationValid = self.configuration.isValid
        self.changed()
    }

    public func setUseLoad(_ enabled: Bool) {
        precondition(Thread.isMainThread)
        self.configuration.useLoad = enabled
        self.changed()
    }

    public func setSynchronized(_ enabled: Bool) {
        precondition(Thread.isMainThread)
        guard self.synchronized != enabled else { return }
        let wasEnabled = !self.requestedFans.isEmpty
        self.cancelLegacy(self.requestedFans.union(self.activeFans).union(self.pendingReleases.keys))
        self.releaseControl(self.requestedFans.union(self.activeFans))
        self.synchronized = enabled
        if !enabled {
            if self.configuration.cpu == nil { self.configuration.cpu = self.configuration.shared }
            if self.configuration.gpu == nil { self.configuration.gpu = self.configuration.shared }
        }
        if wasEnabled {
            self.requestedFans = enabled ? Set(self.fans.map { $0.id }) : Set([self.configuration.cpuFanID, self.configuration.gpuFanID].compactMap { $0 })
        }
        self.changed()
    }

    public func assignFan(_ fanID: Int?, to profile: FanCurveProfileID) {
        precondition(Thread.isMainThread)
        guard profile != .shared, fanID == nil || self.fans.contains(where: { $0.id == fanID }) else { return }
        self.cancelLegacy(self.requestedFans.union(self.activeFans).union(self.pendingReleases.keys))
        self.releaseControl(self.requestedFans.union(self.activeFans))
        // Explicit reassignment never silently enables a different physical fan.
        self.requestedFans.removeAll()
        if profile == .cpu {
            self.configuration.cpuFanID = fanID
            if self.configuration.gpuFanID == fanID { self.configuration.gpuFanID = nil }
        } else {
            self.configuration.gpuFanID = fanID
            if self.configuration.cpuFanID == fanID { self.configuration.cpuFanID = nil }
        }
        self.configurationValid = self.configuration.isValid
        self.changed()
    }

    public func isCurveEnabled(for fanID: Int) -> Bool {
        precondition(Thread.isMainThread)
        return self.requestedFans.contains(fanID)
    }

    public func enableCurve(for fanID: Int) {
        precondition(Thread.isMainThread)
        guard self.fans.contains(where: { $0.id == fanID }), self.configurationValid else { return }
        guard self.synchronized || self.profileID(for: fanID) != nil else {
            self.status = "Select physical fans for CPU and GPU"
            self.notify()
            return
        }
        let ids = self.synchronized ? Set(self.fans.map { $0.id }) : [fanID]
        self.cancelLegacy(ids)
        // Hand off legacy manual ownership before waiting for the first fresh sample.
        self.releaseControl(ids, force: true)
        self.requestedFans.formUnion(ids)
        self.freshAfter = self.clock()
        self.loads.removeAll()
        self.sensorsAt = 0
        self.changed()
    }

    public func stopCurve(for fanID: Int) {
        precondition(Thread.isMainThread)
        let ids = self.synchronized ? self.requestedFans.union(self.activeFans) : Set([fanID])
        self.cancelLegacy(ids)
        self.requestedFans.subtract(ids)
        self.releaseControl(ids, force: true)
        self.status = "Curve inactive"
        self.changed()
    }

    public func setPaused(_ paused: Bool) {
        precondition(Thread.isMainThread)
        self.paused = paused
        self.suspendOrResume()
    }

    internal func setSleeping(_ sleeping: Bool) {
        precondition(Thread.isMainThread)
        self.sleeping = sleeping
        self.suspendOrResume()
    }

    public func terminate() {
        precondition(Thread.isMainThread)
        self.terminated = true
        self.timer?.invalidate()
        self.timer = nil
        self.cancelLegacy(self.requestedFans.union(self.activeFans).union(self.pendingReleases.keys))
        self.releaseControl(self.requestedFans.union(self.activeFans))
        self.updateDemand()
    }

    private func suspendOrResume() {
        self.cancelLegacy(self.requestedFans.union(self.activeFans).union(self.pendingReleases.keys))
        self.releaseControl(self.requestedFans.union(self.activeFans))
        self.freshAfter = self.clock()
        self.sensorsAt = 0
        self.loads.removeAll()
        self.status = self.paused || self.sleeping ? "Fan curve paused" : "Waiting for fresh temperature data"
        self.updateDemand()
        self.notify()
    }

    private func profileID(for fanID: Int) -> FanCurveProfileID? {
        if self.synchronized { return .shared }
        if self.configuration.cpuFanID == fanID { return .cpu }
        if self.configuration.gpuFanID == fanID { return .gpu }
        return nil
    }

    private func changed() {
        if self.persists {
            if let data = try? JSONEncoder().encode(self.configuration) { Store.shared.set(key: "FanCurve_configuration", value: data) }
            Store.shared.set(key: "Sensors_fansSync", value: self.synchronized)
            Store.shared.set(key: "FanCurve_enabledFans", value: self.requestedFans.sorted())
        }
        self.updateDemand()
        NotificationCenter.default.post(name: Notification.Name("FanCurveChanged"), object: self)
    }

    private func updateDemand() {
        let running = !self.paused && !self.sleeping && !self.terminated
        let sensors = running && (self.settingsVisible || !self.requestedFans.isEmpty)
        let load = running && !self.requestedFans.isEmpty && self.configuration.useLoad
        guard sensors != self.requiredSensors || load != self.requiredLoad else { return }
        self.requiredSensors = sensors
        self.requiredLoad = load
        self.metricDemand?(sensors, load)
    }

    private func notify() {
        NotificationCenter.default.post(name: Notification.Name("FanCurveUpdated"), object: self)
    }

    private func releaseControl(_ ids: Set<Int>, force: Bool = false) {
        if self.synchronized && !ids.isEmpty {
            self.sharedPercent = nil
            self.sharedAt = nil
        }
        for id in ids.sorted() where force || self.activeFans.contains(id) || self.pendingCommands[id] != nil {
            self.epochs[id, default: 0] += 1
            self.pendingCommands.removeValue(forKey: id)
            self.activeFans.remove(id)
            self.targetRPM.removeValue(forKey: id)
            self.previousPercent.removeValue(forKey: id)
            self.previousAt.removeValue(forKey: id)
            self.releaseFan(id)
        }
    }

    private func releaseFan(_ id: Int) {
        self.pendingReleases[id] = self.clock()
        self.releaseEpochs[id, default: 0] += 1
        let epoch = self.releaseEpochs[id, default: 0]
        self.release(id) { [weak self] success in
            DispatchQueue.main.async {
                guard let self, self.releaseEpochs[id] == epoch else { return }
                if success { self.pendingReleases.removeValue(forKey: id) }
            }
        }
    }

    internal func tick() {
        precondition(Thread.isMainThread)
        let now = self.clock()
        for (id, at) in self.pendingReleases where now - at >= 5 { self.releaseFan(id) }
        guard !self.terminated, !self.paused, !self.sleeping, !self.requestedFans.isEmpty else {
            if !self.paused && !self.sleeping { self.status = "Curve inactive" }
            self.notify()
            return
        }
        guard self.configurationValid && self.configuration.isValid else {
            self.releaseControl(self.requestedFans)
            self.status = "Fan curve configuration invalid"
            self.notify()
            return
        }
        guard self.helperAvailable() else {
            self.releaseControl(self.requestedFans)
            self.status = "Fan helper unavailable"
            self.notify()
            return
        }
        guard self.sensorsAt > 0, now >= self.sensorsAt, now - self.sensorsAt <= 4, let hotTemperature = self.hotTemperature else {
            self.releaseControl(self.requestedFans)
            self.status = "Waiting for fresh temperature data"
            self.notify()
            return
        }
        let emergency = hotTemperature >= 95
        let freshLoad: (FanCurveProfileID) -> Double? = { id in
            guard let sample = self.loads[id], now >= sample.at, now - sample.at <= 4 else { return nil }
            return sample.value
        }
        self.status = emergency ? "Emergency cooling" : "Curve active"
        var synchronizedPercent: Double?
        func regulated(_ percent: Double) -> Double {
            guard self.synchronized else { return percent }
            if let existing = synchronizedPercent { return existing }
            let value = FanCurvePolicy.smooth(target: percent, previous: self.sharedPercent,
                                             elapsed: min(2, now - (self.sharedAt ?? now)), emergency: emergency)
            synchronizedPercent = value
            self.sharedPercent = value
            self.sharedAt = now
            return value
        }
        for id in self.requestedFans.sorted() {
            guard let fan = self.fans.first(where: { $0.id == id }), let profileID = self.profileID(for: id) else {
                self.releaseControl([id])
                self.status = "Select physical fans for CPU and GPU"
                continue
            }
            let profile = self.configuration.profile(profileID)
            guard let temperature = self.sensors.first(where: { $0.key == profile.sensorKey })?.value,
                  temperature.isFinite, temperature > 0, temperature <= 150 else {
                // Thermal emergency can still use known hot CPU/GPU data if the selected source vanished.
                if !emergency {
                    self.releaseControl([id])
                    self.status = "Waiting for fresh temperature data"
                    continue
                }
                self.apply(fan: fan, percent: regulated(100), emergency: true, now: now)
                continue
            }
            let cpu = profileID == .gpu ? 0 : freshLoad(.cpu)
            let gpu = profileID == .cpu ? 0 : freshLoad(.gpu)
            guard let percent = FanCurvePolicy.targetPercent(profile: profile, temperature: temperature,
                                                             cpuLoad: cpu, gpuLoad: gpu,
                                                             useLoad: self.configuration.useLoad, emergency: emergency) else {
                self.releaseControl([id])
                self.status = "Waiting for fresh CPU/GPU load"
                continue
            }
            self.apply(fan: fan, percent: regulated(percent), emergency: emergency, now: now)
        }
        self.notify()
    }

    private func apply(fan: FanCurveFan, percent: Double, emergency: Bool, now: TimeInterval) {
        if let pending = self.pendingCommands[fan.id] {
            if now - pending >= 5 {
                self.releaseControl([fan.id])
                self.status = "Fan curve command failed"
            }
            return
        }
        guard self.pendingReleases[fan.id] == nil else { return }
        let smoothed = self.synchronized ? percent : FanCurvePolicy.smooth(target: percent, previous: self.previousPercent[fan.id],
                                                                         elapsed: min(2, now - (self.previousAt[fan.id] ?? now)), emergency: emergency)
        guard let rpm = FanCurvePolicy.rpm(percent: smoothed, minRPM: fan.minRPM, maxRPM: fan.maxRPM) else { return }
        let epoch = self.epochs[fan.id, default: 0]
        self.pendingCommands[fan.id] = now
        self.send(fan.id, rpm) { [weak self] success in
            DispatchQueue.main.async {
                guard let self, self.epochs[fan.id, default: 0] == epoch else { return }
                self.pendingCommands.removeValue(forKey: fan.id)
                if success {
                    self.activeFans.insert(fan.id)
                    self.targetRPM[fan.id] = rpm
                    self.previousPercent[fan.id] = smoothed
                    self.previousAt[fan.id] = now
                } else {
                    self.epochs[fan.id, default: 0] += 1
                    self.activeFans.remove(fan.id)
                    self.targetRPM.removeValue(forKey: fan.id)
                    self.previousPercent.removeValue(forKey: fan.id)
                    self.previousAt.removeValue(forKey: fan.id)
                    self.sharedPercent = nil
                    self.sharedAt = nil
                    self.releaseFan(fan.id)
                    self.status = "Fan curve command failed"
                }
                self.notify()
            }
        }
    }
}
