//
//  main.swift
//  Helper
//
//  Created by Serhiy Mytrovtsiy on 17/11/2022
//  Using Swift 5.0
//  Running on macOS 13.0
//
//  Copyright © 2022 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation
import Security

#if FAN_HELPER_TESTS
FanHelperTestMain.main()
#else
let helper = Helper()
helper.run()
#endif

struct FanLeaseState {
    private(set) var deadlines: [Int: TimeInterval] = [:]
    private(set) var pendingAuto: Set<Int> = []
    var pendingReset = false

    var needsRecovery: Bool { !deadlines.isEmpty || !pendingAuto.isEmpty || pendingReset }

    mutating func beginUpdate(id: Int) {
        // A failed/partial forced-mode write must still be recovered.
        pendingAuto.insert(id)
    }

    mutating func renew(id: Int, now: TimeInterval) {
        deadlines[id] = now + 8
        pendingAuto.remove(id)
    }

    mutating func cancel(id: Int) {
        deadlines.removeValue(forKey: id)
        pendingAuto.remove(id)
    }

    mutating func release(id: Int) {
        cancel(id: id)
        pendingAuto.insert(id)
        pendingReset = true
    }

    mutating func expire(now: TimeInterval, disconnected: Bool = false) {
        let expired = deadlines.filter { disconnected || $0.value <= now }.map { $0.key }
        for id in expired { release(id: id) }
    }

    mutating func recovered(id: Int) {
        deadlines.removeValue(forKey: id)
        pendingAuto.remove(id)
        pendingReset = true
    }
}

struct SMCCommandResult {
    var output = ""
    var error: String? = nil
    var status: Int32 = 0
    var timedOut = false

    var succeeded: Bool {
        let text = output.lowercased()
        return !timedOut && status == 0 && (error ?? "").isEmpty &&
            !text.contains("error") && !text.contains("failed")
    }

    var failure: String? {
        guard !succeeded else { return nil }
        if let error = error, !error.isEmpty { return error }
        return timedOut ? "smc command timed out" : "smc command failed (\(status)): \(output)"
    }
}

// Strict listing preserves unavailable reads instead of fabricating numeric modes.
struct FanSMCSnapshot {
    let values: [String: Double]
    let count: Int
    let usesIntelMask: Bool

    static var nativeIntelMask: Bool {
        #if arch(arm64)
        return false
        #else
        return true
        #endif
    }

    init?(_ result: SMCCommandResult, usesIntelMask: Bool) {
        guard result.succeeded else { return nil }
        var values: [String: Double] = [:]
        for line in result.output.components(separatedBy: .newlines) {
            guard line.hasPrefix("["), let end = line.firstIndex(of: "]") else { continue }
            let key = String(line[line.index(after: line.startIndex)..<end])
            if key == "INFO" { continue }
            guard key.utf8.count == 4, values[key] == nil,
                  let value = Double(line[line.index(after: end)...].trimmingCharacters(in: .whitespaces)),
                  value.isFinite else { return nil }
            values[key] = value
        }
        guard let count = values["FNum"], count.rounded() == count, (1...10).contains(count) else { return nil }
        self.values = values
        self.count = Int(count)
        self.usesIntelMask = usesIntelMask
        guard (0..<self.count).allSatisfy({ self.mode(id: $0) != nil }) else { return nil }
    }

    func mode(id: Int) -> Int? {
        guard (0..<count).contains(id) else { return nil }
        let key = !usesIntelMask && values["F0md"] != nil ? "F\(id)md" : "F\(id)Md"
        let raw = values[key]
        if usesIntelMask {
            guard let mask = values["FS! "], mask.rounded() == mask, (0...65535).contains(mask) else { return nil }
            let forced = (Int(mask) & (1 << id)) != 0
            if let raw = raw {
                guard [0.0, 1.0, 3.0].contains(raw), (raw == 1) == forced else { return nil }
            }
            return forced ? 1 : 0
        }
        guard let raw = raw, [0.0, 1.0, 3.0].contains(raw) else { return nil }
        return Int(raw)
    }

    var allAutomatic: Bool {
        (0..<count).allSatisfy { mode(id: $0) == 0 || mode(id: $0) == 3 }
    }
}

// All methods are confined to Helper.smcQueue; tests inject a clock and CLI results.
final class FanLeaseController {
    private(set) var state = FanLeaseState()
    private let command: ([String], TimeInterval) -> SMCCommandResult
    private let now: () -> TimeInterval
    private let usesIntelMask: Bool
    private var lastRecoveryID = -1
    private var operationDeadline: TimeInterval = 0

    init(usesIntelMask: Bool = FanSMCSnapshot.nativeIntelMask,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         command: @escaping ([String], TimeInterval) -> SMCCommandResult) {
        self.usesIntelMask = usesIntelMask
        self.now = now
        self.command = command
    }

    private func startOperation() { operationDeadline = now() + 4 }

    private func run(_ args: [String]) -> SMCCommandResult {
        let remaining = operationDeadline - now()
        guard remaining > 0 else { return SMCCommandResult(timedOut: true) }
        return command(args, remaining)
    }

    private func snapshot() -> FanSMCSnapshot? {
        FanSMCSnapshot(run(["list", "-f", "--strict"]), usesIntelMask: usesIntelMask)
    }

    func setCurveFanSpeed(id: Int, value: Int) -> Bool {
        startOperation()
        guard (0...9).contains(id), (0...16383).contains(value),
              let before = snapshot(), id < before.count, before.mode(id: id) != nil,
              let minimum = before.values["F\(id)Mn"], let maximum = before.values["F\(id)Mx"],
              minimum >= 0, maximum > 0, minimum <= maximum,
              Double(value) >= minimum, Double(value) <= maximum else { return false }

        state.beginUpdate(id: id)
        guard run(["fan", "\(id)", "-m", "1"]).succeeded,
              run(["fan", "\(id)", "-v", "\(value)"]).succeeded,
              let after = snapshot(), after.mode(id: id) == 1,
              let target = after.values["F\(id)Tg"], abs(target - Double(value)) <= 0.5 else {
            state.release(id: id)
            _ = restoreAutomatic(id: id)
            return false
        }
        state.renew(id: id, now: now())
        return true
    }

    func cancelForManualCommand(id: Int) { state.cancel(id: id) }

    func releaseCurveFan(id: Int) -> Bool {
        guard (0...9).contains(id) else { return false }
        startOperation()
        state.release(id: id)
        return restoreAutomatic(id: id)
    }

    private func restoreAutomatic(id: Int) -> Bool {
        guard run(["fan", "\(id)", "-m", "0"]).succeeded,
              let after = snapshot(), after.mode(id: id) == 0 || after.mode(id: id) == 3 else {
            return false
        }
        state.recovered(id: id)
        return resetIfSafe(after)
    }

    private func resetIfSafe(_ before: FanSMCSnapshot) -> Bool {
        // Never clear Ftst while ANY real fan is manual, including non-curve fans.
        guard before.allAutomatic else { return true }
        guard run(["reset"]).succeeded, let after = snapshot(), after.allAutomatic,
              after.values["Ftst"] == nil || after.values["Ftst"] == 0 else { return false }
        state.pendingReset = false
        return true
    }

    func disconnected() { state.expire(now: now(), disconnected: true) }

    func watchdog() {
        state.expire(now: now())
        startOperation()
        // Round-robin prevents a persistently failing fan from starving another.
        let pending = state.pendingAuto.sorted()
        if let id = pending.first(where: { $0 > lastRecoveryID }) ?? pending.first {
            lastRecoveryID = id
            _ = restoreAutomatic(id: id)
        } else if state.pendingReset, let current = snapshot() {
            _ = resetIfSafe(current)
        }
    }

    func resetFanControl() -> SMCCommandResult {
        // The legacy global reset must not override unrelated manual ownership.
        startOperation()
        disconnected()
        for id in state.pendingAuto.sorted() {
            _ = restoreAutomatic(id: id)
        }
        guard state.pendingAuto.isEmpty, let current = snapshot(), current.allAutomatic else {
            return SMCCommandResult(error: "refused global reset: fan modes are not all automatic")
        }
        state.pendingReset = true
        guard resetIfSafe(current) else { return SMCCommandResult(error: "fan control reset not confirmed") }
        return SMCCommandResult(output: "fan control restored to automatic")
    }
}

final class SMCProcessRunner {
    private var unterminated: Process?

    func run(path: String, arguments: [String], timeout: TimeInterval = 4) -> SMCCommandResult {
        if let previous = unterminated, previous.isRunning {
            kill(previous.processIdentifier, SIGKILL)
            return SMCCommandResult(error: "previous smc process has not exited")
        }
        unterminated = nil
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipes = [Pipe(), Pipe()]
        task.standardOutput = pipes[0]
        task.standardError = pipes[1]
        defer {
            for pipe in pipes {
                pipe.fileHandleForWriting.closeFile()
                pipe.fileHandleForReading.closeFile()
            }
        }
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        var descriptors = pipes.map { pollfd(fd: $0.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0) }
        for descriptor in descriptors {
            let flags = fcntl(descriptor.fd, F_GETFL)
            guard flags >= 0, fcntl(descriptor.fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                return SMCCommandResult(error: "unable to configure nonblocking smc pipes")
            }
        }
        do { try task.run() } catch {
            return SMCCommandResult(error: "runSMC: \(error.localizedDescription)")
        }
        for pipe in pipes { pipe.fileHandleForWriting.closeFile() }
        var data = [Data(), Data()]
        var open = [true, true]
        var buffer = [UInt8](repeating: 0, count: 16384)
        var overflow = false
        var didExit = false
        var timedOut = false
        let clock = { ProcessInfo.processInfo.systemUptime }
        let deadline = clock() + min(max(timeout, 0), 4)
        var drainDeadline: TimeInterval? = nil

        while true {
            if !didExit { didExit = exited.wait(timeout: .now()) == .success }
            if didExit && drainDeadline == nil { drainDeadline = min(deadline, clock() + 0.25) }
            if didExit && !open.contains(true) { break }
            if clock() >= (drainDeadline ?? deadline) {
                timedOut = !didExit || open.contains(true)
                break
            }
            _ = poll(&descriptors, nfds_t(descriptors.count), 10)
            // Multiplex BOTH nonblocking pipes, even when one producer floods its pipe.
            for index in 0..<descriptors.count where open[index] {
                for _ in 0..<16 {
                    let count = read(descriptors[index].fd, &buffer, buffer.count)
                    if count > 0 {
                        let room = max(0, 1_048_576 - data[index].count)
                        data[index].append(contentsOf: buffer.prefix(min(count, room)))
                        overflow = overflow || count > room
                    } else {
                        if count == 0 {
                            open[index] = false
                            descriptors[index].fd = -1
                        } else if errno != EAGAIN && errno != EINTR {
                            open[index] = false
                            overflow = true
                        }
                        break
                    }
                }
            }
        }
        if !didExit {
            if task.isRunning { task.terminate() }
            didExit = exited.wait(timeout: .now() + 0.25) == .success
            if !didExit {
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                didExit = exited.wait(timeout: .now() + 0.25) == .success
            }
        }
        if !didExit { unterminated = task }
        let output = String(data: data[0], encoding: .utf8)
        let error = String(data: data[1], encoding: .utf8)
        return SMCCommandResult(output: output ?? "",
                                error: overflow ? "smc output exceeded limit or pipe read failed" :
                                    (output == nil || error == nil ? "invalid smc output encoding" : error),
                                status: didExit ? task.terminationStatus : -1, timedOut: timedOut || !didExit)
    }
}

class Helper: NSObject, NSXPCListenerDelegate, HelperProtocol {
    private let listener: NSXPCListener
    private let smcQueue = DispatchQueue(label: "eu.exelban.Stats.SMC.Helper.smcQueue")
    
    private var connections = [NSXPCConnection]()
    private let quitLock = NSLock()
    private var quitRequested = false
    private var shouldQuit: Bool {
        get {
            quitLock.lock()
            defer { quitLock.unlock() }
            return quitRequested
        }
        set {
            quitLock.lock()
            defer { quitLock.unlock() }
            quitRequested = newValue
        }
    }
    private var shouldQuitWhenRecovered = false
    private var shouldQuitCheckInterval = 1.0
    
    private var smc: String? = nil
    private let processRunner = SMCProcessRunner()
    private var watchdogTimer: DispatchSourceTimer?
    private lazy var fanController = FanLeaseController { [unowned self] args, timeout in
        self.runSMC(args, timeout: timeout)
    }
    
    override init() {
        self.listener = NSXPCListener(machServiceName: "eu.exelban.Stats.SMC.Helper")
        super.init()
        self.listener.delegate = self
    }
    
    public func run() {
        let args = CommandLine.arguments.dropFirst()
        if !args.isEmpty && args.first == "uninstall" {
            NSLog("detected uninstall command")
            if let val = args.last, let pid: pid_t = Int32(val) {
                while kill(pid, 0) == 0 {
                    usleep(50000)
                }
            }
            self.uninstallHelper()
            exit(0)
        }
        
        self.listener.resume()
        let timer = DispatchSource.makeTimerSource(queue: self.smcQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.fanController.watchdog()
            self.shouldQuit = self.shouldQuitWhenRecovered && !self.fanController.state.needsRecovery
        }
        self.watchdogTimer = timer
        timer.resume()
        while !self.shouldQuit {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: self.shouldQuitCheckInterval))
        }
        timer.cancel()
    }
    
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        do {
            guard let token = CodesignCheck.auditToken(for: newConnection) else {
                NSLog("unable to read audit token, dropping")
                return false
            }
            let isValid = try CodesignCheck.codeSigningMatches(auditToken: token)
            if !isValid {
                NSLog("invalid connection, dropping")
                return false
            }
        } catch {
            NSLog("error checking code signing: \(error)")
            return false
        }
        
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = self
        let lostConnection: () -> Void = { [weak self, weak newConnection] in
            guard let self = self else { return }
            self.smcQueue.async {
                guard let connection = newConnection,
                      self.connections.contains(where: { $0 === connection }) else { return }
                self.connections.removeAll { $0 === connection }
                self.fanController.disconnected()
                self.fanController.watchdog()
                self.shouldQuitWhenRecovered = self.connections.isEmpty
                self.shouldQuit = self.shouldQuitWhenRecovered && !self.fanController.state.needsRecovery
            }
        }
        newConnection.invalidationHandler = lostConnection
        newConnection.interruptionHandler = lostConnection
        
        self.smcQueue.sync {
            self.connections.append(newConnection)
            self.shouldQuit = false
            self.shouldQuitWhenRecovered = false
        }
        newConnection.resume()
        
        return true
    }
    
    private func uninstallHelper() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.qualityOfService = QualityOfService.userInitiated
        process.arguments = ["unload", "/Library/LaunchDaemons/eu.exelban.Stats.SMC.Helper.plist"]
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus != .zero {
                NSLog("termination code: \(process.terminationStatus)")
            }
            NSLog("unloaded from launchctl")
        } catch let err {
            NSLog("launchctl unload: \(err)")
        }
        
        do {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: "/Library/LaunchDaemons/eu.exelban.Stats.SMC.Helper.plist"))
        } catch let err {
            NSLog("plist deletion: \(err)")
        }
        NSLog("property list deleted")
        
        do {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: "/Library/PrivilegedHelperTools/eu.exelban.Stats.SMC.Helper"))
        } catch let err {
            NSLog("helper deletion: \(err)")
        }
        NSLog("smc helper deleted")
    }
}

extension Helper {
    func version(completion: (String) -> Void) {
        completion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
    }
    func setSMCPath(_ path: String) {
        self.smcQueue.sync {
            // A rejected replacement must not discard the trusted tool needed for recovery.
            var isDirectory: ObjCBool = false
            let fm = FileManager.default
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fm.isExecutableFile(atPath: path),
                  (try? fm.destinationOfSymbolicLink(atPath: path)) == nil else {
                NSLog("rejected smc path: \(path)")
                return
            }
            guard CodesignCheck.matchesSelf(path: path) else {
                NSLog("rejected smc path (signature mismatch): \(path)")
                return
            }
            self.smc = path
        }
    }
    
    func setFanMode(id: Int, mode: Int, completion: (String?) -> Void) {
        self.smcQueue.sync {
            self.fanController.cancelForManualCommand(id: id)
            self.fanController.watchdog()
            let result = self.callSMC(["fan", "\(id)", "-m", "\(mode)"])
            
            if let error = result.error, !error.isEmpty {
                NSLog("error set fan mode: \(error)")
                completion(nil)
                return
            }
            
            completion(result.output)
        }
    }
    
    func setFanSpeed(id: Int, value: Int, completion: (String?) -> Void) {
        self.smcQueue.sync {
            self.fanController.cancelForManualCommand(id: id)
            self.fanController.watchdog()
            let result = self.callSMC(["fan", "\(id)", "-v", "\(value)"])
            
            if let error = result.error, !error.isEmpty {
                NSLog("error set fan speed: \(error)")
                completion(nil)
                return
            }
            
            completion(result.output)
        }
    }

    func setCurveFanSpeed(id: Int, value: Int, completion: @escaping (Bool) -> Void) {
        let connection = NSXPCConnection.current()
        let requestedAt = ProcessInfo.processInfo.systemUptime
        self.smcQueue.async {
            self.fanController.watchdog()
            guard ProcessInfo.processInfo.systemUptime - requestedAt < 8,
                  let connection = connection, self.connections.contains(where: { $0 === connection }) else {
                completion(false)
                return
            }
            completion(self.fanController.setCurveFanSpeed(id: id, value: value))
        }
    }

    func releaseCurveFan(id: Int, completion: @escaping (Bool) -> Void) {
        self.smcQueue.async {
            self.fanController.cancelForManualCommand(id: id)
            self.fanController.watchdog()
            completion(self.fanController.releaseCurveFan(id: id))
        }
    }
    
    func resetFanControl(completion: (String?) -> Void) {
        self.smcQueue.sync {
            let result = self.fanController.resetFanControl()
            if let error = result.failure {
                NSLog("error reset fan control: \(error)")
                completion(nil)
                return
            }
            completion(result.output)
        }
    }
    
    public func callSMC(_ arguments: [String]) -> (output: String?, error: String?) {
        let result = self.runSMC(arguments, timeout: 4)
        return (result.succeeded ? result.output : nil, result.failure)
    }

    private func runSMC(_ arguments: [String], timeout: TimeInterval) -> SMCCommandResult {
        guard let smc = self.smc else {
            return SMCCommandResult(error: "missing smc tool")
        }
        guard CodesignCheck.matchesSelf(path: smc) else {
            return SMCCommandResult(error: "smc tool failed signature validation")
        }
        return self.processRunner.run(path: smc, arguments: arguments, timeout: timeout)
    }
    
    func uninstall() {
        let recovered = self.smcQueue.sync { () -> Bool in
            _ = self.fanController.resetFanControl()
            return !self.fanController.state.needsRecovery
        }
        guard recovered else {
            NSLog("uninstall deferred: fan recovery has not completed")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/eu.exelban.Stats.SMC.Helper")
        process.qualityOfService = QualityOfService.userInitiated
        process.arguments = ["uninstall", String(getpid())]
        do {
            try process.run()
        } catch let err {
            NSLog("uninstall: \(err)")
        }
        exit(0)
    }
}

// https://github.com/duanefields/VirtualKVM/blob/master/VirtualKVM/CodesignCheck.swift
enum CodesignCheckError: Error {
    case message(String)
}

struct CodesignCheck {
    public static func auditToken(for connection: NSXPCConnection) -> audit_token_t? {
        let raw = connection.value(forKey: "auditToken")
        var token = audit_token_t()
        if let value = raw as? NSValue {
            withUnsafeMutableBytes(of: &token) { value.getValue($0.baseAddress!, size: $0.count) }
            return token
        }
        if let data = raw as? Data, data.count == MemoryLayout<audit_token_t>.size {
            _ = withUnsafeMutableBytes(of: &token) { data.copyBytes(to: $0) }
            return token
        }
        return nil
    }
    
    public static func codeSigningMatches(auditToken token: audit_token_t) throws -> Bool {
        return try self.codeSigningCertificatesForSelf() == self.codeSigningCertificates(forAuditToken: token)
    }
    
    public static func matchesSelf(path: String) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return false
        }
        do {
            let selfCerts = try self.codeSigningCertificatesForSelf()
            let fileCerts = try self.codeSigningCertificates(forStaticCode: code)
            return !selfCerts.isEmpty && selfCerts == fileCerts
        } catch {
            return false
        }
    }
    
    private static func codeSigningCertificatesForSelf() throws -> [SecCertificate] {
        guard let secStaticCode = try secStaticCodeSelf() else { return [] }
        return try codeSigningCertificates(forStaticCode: secStaticCode)
    }
    
    private static func codeSigningCertificates(forAuditToken token: audit_token_t) throws -> [SecCertificate] {
        guard let secStaticCode = try secStaticCode(forAuditToken: token) else { return [] }
        return try codeSigningCertificates(forStaticCode: secStaticCode)
    }
    
    private static func executeSecFunction(_ secFunction: () -> (OSStatus) ) throws {
        let osStatus = secFunction()
        guard osStatus == errSecSuccess else {
            throw CodesignCheckError.message(String(describing: SecCopyErrorMessageString(osStatus, nil)))
        }
    }
    
    private static func secStaticCodeSelf() throws -> SecStaticCode? {
        var secCodeSelf: SecCode?
        try executeSecFunction { SecCodeCopySelf(SecCSFlags(rawValue: 0), &secCodeSelf) }
        guard let secCode = secCodeSelf else {
            throw CodesignCheckError.message("SecCode returned empty from SecCodeCopySelf")
        }
        return try secStaticCode(forSecCode: secCode)
    }
    
    private static func secStaticCode(forAuditToken token: audit_token_t) throws -> SecStaticCode? {
        let tokenData = withUnsafeBytes(of: token) { Data($0) } as CFData
        var secCodeToken: SecCode?
        try executeSecFunction { SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &secCodeToken) }
        guard let secCode = secCodeToken else {
            throw CodesignCheckError.message("SecCode returned empty from SecCodeCopyGuestWithAttributes")
        }
        return try secStaticCode(forSecCode: secCode)
    }
    
    private static func secStaticCode(forSecCode secCode: SecCode) throws -> SecStaticCode? {
        var secStaticCodeCopy: SecStaticCode?
        try executeSecFunction { SecCodeCopyStaticCode(secCode, [], &secStaticCodeCopy) }
        guard let secStaticCode = secStaticCodeCopy else {
            throw CodesignCheckError.message("SecStaticCode returned empty from SecCodeCopyStaticCode")
        }
        return secStaticCode
    }
    
    private static func isValid(secStaticCode: SecStaticCode) throws {
        try executeSecFunction { SecStaticCodeCheckValidity(secStaticCode, SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSCheckNestedCode), nil) }
    }
    
    private static func secCodeInfo(forStaticCode secStaticCode: SecStaticCode) throws -> [String: Any]? {
        try isValid(secStaticCode: secStaticCode)
        var secCodeInfoCFDict: CFDictionary?
        try executeSecFunction { SecCodeCopySigningInformation(secStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &secCodeInfoCFDict) }
        guard let secCodeInfo = secCodeInfoCFDict as? [String: Any] else {
            throw CodesignCheckError.message("CFDictionary returned empty from SecCodeCopySigningInformation")
        }
        return secCodeInfo
    }
    
    private static func codeSigningCertificates(forStaticCode secStaticCode: SecStaticCode) throws -> [SecCertificate] {
        guard
            let secCodeInfo = try secCodeInfo(forStaticCode: secStaticCode),
            let secCertificates = secCodeInfo[kSecCodeInfoCertificates as String] as? [SecCertificate] else { return [] }
        return secCertificates
    }
}
