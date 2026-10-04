import Foundation

public struct FanCurvePoint: Codable, Equatable {
    public var percent: Int
    public var temperature: Int

    public init(percent: Int, temperature: Int) {
        self.percent = percent
        self.temperature = temperature
    }
}

public enum FanCurveProfileID: String, Codable, CaseIterable {
    case shared
    case cpu
    case gpu
}

public struct FanCurveProfile: Codable, Equatable {
    public var points: [FanCurvePoint]
    public var sensorKey: String

    public static let defaultPoints: [FanCurvePoint] = [
        FanCurvePoint(percent: 0, temperature: 50),
        FanCurvePoint(percent: 10, temperature: 55),
        FanCurvePoint(percent: 25, temperature: 64),
        FanCurvePoint(percent: 50, temperature: 75),
        FanCurvePoint(percent: 100, temperature: 85)
    ]

    public init(points: [FanCurvePoint] = defaultPoints, sensorKey: String = "Hottest CPU") {
        self.points = points
        self.sensorKey = sensorKey
    }

    public var isValid: Bool {
        guard (1...10).contains(points.count) else { return false }
        for index in points.indices {
            let point = points[index]
            guard (0...100).contains(point.percent), (20...100).contains(point.temperature) else {
                return false
            }
            if index > 0 {
                let previous = points[index - 1]
                guard previous.temperature < point.temperature, previous.percent <= point.percent else {
                    return false
                }
            }
        }
        return true
    }

    public func percentage(at temperature: Double) -> Double? {
        guard isValid, temperature.isFinite else { return nil }
        if temperature <= Double(points[0].temperature) { return Double(points[0].percent) }
        for index in 1..<points.count {
            let upper = points[index]
            if temperature <= Double(upper.temperature) {
                let lower = points[index - 1]
                let fraction = (temperature - Double(lower.temperature)) /
                    Double(upper.temperature - lower.temperature)
                return Double(lower.percent) + fraction * Double(upper.percent - lower.percent)
            }
        }
        return Double(points[points.count - 1].percent)
    }

    @discardableResult
    public mutating func movePoint(at index: Int, percent: Int, temperature: Int) -> Bool {
        guard isValid, points.indices.contains(index) else { return false }
        points[index].percent = min(100, max(0, percent))
        // Reserve one degree for every neighbor so the entire chain fits the axis.
        points[index].temperature = min(100 - (points.count - 1 - index), max(20 + index, temperature))

        for neighbor in stride(from: index - 1, through: 0, by: -1) {
            points[neighbor].percent = min(points[neighbor].percent, points[neighbor + 1].percent)
            points[neighbor].temperature = min(points[neighbor].temperature, points[neighbor + 1].temperature - 1)
        }
        for neighbor in (index + 1)..<points.count {
            points[neighbor].percent = max(points[neighbor].percent, points[neighbor - 1].percent)
            points[neighbor].temperature = max(points[neighbor].temperature, points[neighbor - 1].temperature + 1)
        }
        return true
    }

    @discardableResult
    public mutating func insertPoint(percent: Int, temperature: Int) -> Bool {
        guard isValid, points.count < 10 else { return false }
        let temperature = min(100, max(20, temperature))
        guard !points.contains(where: { $0.temperature == temperature }) else { return false }
        let index = points.firstIndex(where: { $0.temperature > temperature }) ?? points.count
        let lowerPercent = index > 0 ? points[index - 1].percent : 0
        let upperPercent = index < points.count ? points[index].percent : 100
        points.insert(FanCurvePoint(percent: min(upperPercent, max(lowerPercent, percent)),
                                    temperature: temperature), at: index)
        return true
    }

    @discardableResult
    public mutating func removePoint(at index: Int) -> Bool {
        guard isValid, points.count > 1, points.indices.contains(index) else { return false }
        points.remove(at: index)
        return true
    }
}

public struct FanCurveConfiguration: Codable, Equatable {
    public var shared: FanCurveProfile
    public var cpu: FanCurveProfile?
    public var gpu: FanCurveProfile?
    public var cpuFanID: Int?
    public var gpuFanID: Int?
    public var useLoad: Bool

    public init(shared: FanCurveProfile = FanCurveProfile(), cpu: FanCurveProfile? = nil,
                gpu: FanCurveProfile? = nil, cpuFanID: Int? = nil, gpuFanID: Int? = nil,
                useLoad: Bool = true) {
        self.shared = shared
        self.cpu = cpu
        self.gpu = gpu
        self.cpuFanID = cpuFanID
        self.gpuFanID = gpuFanID
        self.useLoad = useLoad
    }

    public func profile(_ id: FanCurveProfileID) -> FanCurveProfile {
        switch id {
        case .shared: return shared
        case .cpu: return cpu ?? shared
        case .gpu: return gpu ?? shared
        }
    }

    public mutating func setProfile(_ profile: FanCurveProfile, for id: FanCurveProfileID) {
        switch id {
        case .shared: shared = profile
        case .cpu: cpu = profile
        case .gpu: gpu = profile
        }
    }

    public var isValid: Bool {
        guard shared.isValid, cpu?.isValid ?? true, gpu?.isValid ?? true else { return false }
        if let id = cpuFanID, id < 0 { return false }
        if let id = gpuFanID, id < 0 { return false }
        if let cpuFanID = cpuFanID, let gpuFanID = gpuFanID, cpuFanID == gpuFanID { return false }
        return true
    }
}

public enum FanCurvePolicy {
    public static func targetPercent(profile: FanCurveProfile, temperature: Double,
                                     cpuLoad: Double?, gpuLoad: Double?, useLoad: Bool,
                                     emergency: Bool) -> Double? {
        if emergency { return 100 }
        guard let baseline = profile.percentage(at: temperature) else { return nil }
        guard useLoad else { return baseline }
        guard let cpuLoad = cpuLoad, let gpuLoad = gpuLoad,
              cpuLoad.isFinite, gpuLoad.isFinite,
              (0...1).contains(cpuLoad), (0...1).contains(gpuLoad) else { return nil }
        return max(baseline, max(cpuLoad, gpuLoad) * 70)
    }

    public static func rpm(percent: Double, minRPM: Double, maxRPM: Double) -> Int? {
        guard percent.isFinite, minRPM.isFinite, maxRPM.isFinite,
              minRPM >= 0, maxRPM > 1, maxRPM > minRPM else { return nil }
        let minimum = minRPM.rounded(.up)
        let maximum = maxRPM.rounded(.down)
        guard minimum <= maximum else { return nil }
        let speed = min(maxRPM, max(minRPM, min(100, max(0, percent)) / 100 * maxRPM))
        // Exact conversion rejects finite RPM values outside Int's range without trapping.
        return Int(exactly: min(maximum, max(minimum, speed.rounded())))
    }

    public static func smooth(target: Double, previous: Double?, elapsed: Double, emergency: Bool) -> Double {
        if emergency { return 100 }
        guard target.isFinite else { return 100 }
        let target = min(100, max(0, target))
        guard let previous = previous, previous.isFinite else { return target }
        let current = min(100, max(0, previous))
        let difference = target - current
        if abs(difference) <= 2 { return current }
        guard elapsed.isFinite, elapsed > 0 else { return current }
        let limit = elapsed * (difference > 0 ? 20 : 5)
        return difference > 0 ? min(target, current + limit) : max(target, current - limit)
    }
}

// A late acknowledgement cannot transfer ownership across a newer release.
internal struct FanCurveCommandGate {
    private var generations: [Int: Int] = [:]
    private var pending: Set<Int> = []
    private var commands: [Int: [() -> Void]] = [:]

    mutating func beginRelease(_ id: Int) -> Int {
        self.generations[id, default: 0] += 1
        self.pending.insert(id)
        return self.generations[id, default: 0]
    }

    mutating func completeRelease(_ id: Int, generation: Int, success: Bool) -> [() -> Void] {
        guard self.generations[id] == generation, success else { return [] }
        self.pending.remove(id)
        return self.commands.removeValue(forKey: id) ?? []
    }

    mutating func deferCommand(_ id: Int, command: @escaping () -> Void) -> Bool {
        guard self.pending.contains(id) else { return false }
        self.commands[id, default: []].append(command)
        return true
    }

    mutating func cancelCommands(for ids: Set<Int>) {
        ids.forEach { self.commands.removeValue(forKey: $0) }
    }
}
