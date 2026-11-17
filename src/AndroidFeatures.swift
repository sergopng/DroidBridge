import AppKit
import SwiftUI

struct AppMetadata: Decodable {
    let id: String
    let name: String
    let version: String
}

enum AndroidHelper {
    static let package = "local.droidbridge.helper"

    static func installed(_ runner: Runner, device: String) throws -> Bool {
        try runner.shell(device, "pm list packages " + package).contains("package:" + package)
    }

    static func payload(_ runner: Runner, device: String, path: String) throws -> [String] {
        let url = "content://" + package + "/" + path
        let response = try runner.shell(device, "content query --uri " + shellQuote(url))
        if response.contains("Error while accessing provider") || response.contains("No content provider") { throw Failure(response) }
        return response.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("Row:"), let marker = line.range(of: "payload=") else { return nil }
            return String(line[marker.upperBound...])
        }
    }

    static func metadata(_ runner: Runner, device: String) throws -> [String: AppMetadata] {
        let values = try payload(runner, device: device, path: "packages")
        var result: [String: AppMetadata] = [:]
        for value in values {
            guard let data = Data(base64Encoded: value), let info = try? JSONDecoder().decode(AppMetadata.self, from: data) else { continue }
            result[info.id] = info
        }
        return result
    }

    static func perform(_ runner: Runner, device: String, action: String, argument: String?) throws -> String {
        let token = UUID().uuidString
        var command = "am start -n \(package)/.Actions --es action \(shellQuote(action)) --es token \(shellQuote(token))"
        if let argument {
            let key = action == "pin" ? "package" : "text"
            command += " --es \(key) " + shellQuote(argument)
        }
        let response = try runner.shell(device, command)
        if response.contains("Error") { throw Failure(response) }
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try runner.check()
            if let answer = try payload(runner, device: device, path: "response/" + token).first,
               let separator = answer.firstIndex(of: ":"), let bytes = Data(base64Encoded: String(answer[answer.index(after: separator)...])) {
                let text = String(decoding: bytes, as: UTF8.self)
                switch answer[..<separator] {
                case "ok": return text
                case "cancel": throw Failure("Операция отменена на Android.")
                default: throw Failure(text)
                }
            }
            Thread.sleep(forTimeInterval: 0.45)
        }
        throw Failure("Android не ответил. Разблокируйте телефон и подтвердите запрос DroidBridge.")
    }
}

extension Workspace {
    func withHelper(_ work: @escaping () -> Void) {
        guard adbConnected, busy == nil else { return }
        if helperAvailable { work(); return }
        let id = serial
        job("Проверка помощника Android", { try AndroidHelper.installed($0, device: id) }, done: { installed in
            if installed {
                self.helperAvailable = true
                work()
                return
            }
            guard confirm("Установить помощник DroidBridge на Android?",
                          detail: "Помощник показывает имена и иконки приложений, обменивается текстом по вашему запросу и передаёт лаунчеру запрос на ярлык.",
                          button: "Установить"),
                  let apk = Bundle.main.url(forResource: "DroidBridgeHelper", withExtension: "apk") else { return }
            self.job("Установка помощника DroidBridge", { try $0.adb(id, ["install", "--no-incremental", "-r", apk.path]) }, done: { _ in
                self.helperAvailable = true
                work()
            })
        })
    }

    func clipboard(toAndroid: Bool) {
        var argument: String?
        if toAndroid {
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { error = "В буфере Mac нет текста."; return }
            guard text.utf8.count <= 48_000 else { error = "Для передачи из меню сократите текст до 48 КБ."; return }
            argument = Data(text.utf8).base64EncodedString()
        }
        let id = serial
        withHelper {
            self.job("Подтвердите обмен буфером на телефоне", {
                try AndroidHelper.perform($0, device: id, action: toAndroid ? "write" : "read", argument: argument)
            }, done: { value in
                if !toAndroid {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
                self.status = toAndroid ? "Текст отправлен на Android" : "Текст скопирован на Mac"
            })
        }
    }

    func pinShortcut() {
        guard let app = selectedPackages.first, selectedPackages.count == 1 else { return }
        let id = serial
        withHelper {
            self.job("Подтвердите ярлык на телефоне", {
                try AndroidHelper.perform($0, device: id, action: "pin", argument: app.id)
            }, done: { _ in self.status = "Запрос передан лаунчеру Android" })
        }
    }

    func loadIcon(_ package: Package) {
        guard helperAvailable, appIcons[package.id] == nil, !iconRequests.contains(package.id) else { return }
        iconRequests.insert(package.id)
        let device = serial
        DispatchQueue.global(qos: .utility).async {
            Self.iconGate.wait()
            defer { Self.iconGate.signal() }
            let raw = try? AndroidHelper.payload(Runner(), device: device, path: "icon/" + package.id).first
            let bytes = raw.flatMap { Data(base64Encoded: $0) }
            DispatchQueue.main.async {
                guard self.serial == device else { return }
                if let bytes, let icon = NSImage(data: bytes) { self.appIcons[package.id] = icon }
            }
        }
    }

    var canLaunchScrcpy: Bool {
        adbConnected || scrcpyProfile.enabled["--otg"] != nil ||
            ScrcpyProfile.selectors.contains { scrcpyProfile.enabled[$0] != nil } ||
            !(scrcpyProfile.enabled["--tcpip"] ?? "").isEmpty
    }

    func mirror(record: Bool) {
        guard canLaunchScrcpy, !mirrorRunning else { return }
        let format = scrcpyProfile.enabled["--record-format"] ?? "mkv"
        let ext = format.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil ? format : "mkv"
        let picked = record ? saveURL("Android-screen-\(Date.now.formatted(.iso8601.year().month().day())).\(ext)") : nil
        if record && picked == nil { return }
        let task = Process()
        task.executableURL = Runner.executable(.scrcpy)
        task.standardInput = FileHandle.nullDevice
        let destination: URL?
        do {
            let options = try ScrcpyOption.parse(ToolInstallation.command(Runner.executable(.scrcpy), ["--help"]))
            destination = picked ?? scrcpyProfile.enabled["--record"].flatMap { path in
                path.isEmpty ? nil : URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
            let args = try scrcpyProfile.arguments(options: options, serial: serial, title: "DroidBridge · " + deviceName, record: destination, diagnostic: nil)
            task.arguments = args
            let environment = ToolInstallation.scrcpyEnvironment()
            task.environment = args.contains("--otg") ? environment : try ADBSession.shared.environment(base: environment)
        } catch {
            self.error = error.localizedDescription
            return
        }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        let log = ProcessTail()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { log.append(data) }
        }
        task.terminationHandler = { process in
            DispatchQueue.main.async {
                guard self.mirrorProcess === process else { return }
                self.mirrorProcess = nil
                self.mirrorRunning = false
                if process.terminationStatus != 0 && !self.mirrorStopping {
                    self.error = "scrcpy · " + log.text
                } else if let destination, FileManager.default.fileExists(atPath: destination.path) {
                    self.status = "Запись сохранена · " + destination.lastPathComponent
                }
            }
        }
        do {
            try task.run()
            mirrorProcess = task
            mirrorStopping = false
            mirrorRunning = true
        } catch { self.error = error.localizedDescription }
    }

    func stopMirror() {
        mirrorStopping = true
        mirrorProcess?.interrupt()
    }

    func startLog() {
        guard adbConnected, !logRunning else { return }
        let filter = logFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = serial
        job("Запуск Logcat", { runner -> [String] in
            if filter.isEmpty { return [] }
            guard filter.range(of: #"^[A-Za-z0-9_.]+$"#, options: .regularExpression) != nil else {
                throw Failure("Введите имя пакета Android.")
            }
            let output = try runner.shell(device, "ps -A -o PID,NAME")
            let ids = output.components(separatedBy: .newlines).compactMap { line -> String? in
                let values = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard values.count == 2, values[0].allSatisfy(\.isNumber), values[1] == filter || values[1].hasPrefix(filter + ":") else { return nil }
                return values[0]
            }
            guard !ids.isEmpty else { throw Failure("Запустите приложение «\(filter)» и повторите.") }
            return ids
        }, done: { self.streamLog(device: device, pids: Set($0)) })
    }

    private func streamLog(device: String, pids: Set<String>) {
        let task = Process()
        task.executableURL = Runner.executable(.adb)
        task.arguments = ["-s", device, "logcat", "-v", "threadtime", "-T", "1"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        let stream = LogBuffer(pids: pids)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { stream.append(data) }
        }
        task.terminationHandler = { process in
            DispatchQueue.main.async {
                guard self.logProcess === process else { return }
                self.logTimer?.invalidate()
                self.diagnostics += stream.drain()
                self.logProcess = nil
                self.logRunning = false
                if process.terminationStatus != 0 { self.status = "Поток Logcat завершился" }
            }
        }
        do {
            task.environment = try ADBSession.shared.environment()
            try task.run()
            logProcess = task
            logRunning = true
            diagnostics = ""
            logTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
                let batch = stream.drain()
                guard !batch.isEmpty else { return }
                DispatchQueue.main.async {
                    guard let self, self.logProcess === task else { return }
                    self.diagnostics.append(batch)
                    if self.diagnostics.utf8.count > 450_000 { self.diagnostics = String(self.diagnostics.suffix(220_000)) }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func stopLog() { logProcess?.terminate() }
}

private final class ProcessTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) {
        lock.lock()
        data.append(bytes)
        if data.count > 8_000 { data.removeFirst(data.count - 8_000) }
        lock.unlock()
    }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var lines = ""
    private let pids: Set<String>

    init(pids: Set<String>) { self.pids = pids }

    func append(_ bytes: Data) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(bytes)
        guard let end = pending.lastIndex(of: 10) else {
            if pending.count > 65_536 { pending.removeAll() }
            return
        }
        let chunk = String(decoding: pending[...end], as: UTF8.self)
        pending.removeSubrange(...end)
        if pids.isEmpty { lines += chunk }
        else {
            for line in chunk.split(separator: "\n") {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.count > 2 && pids.contains(String(fields[2])) { lines += line + "\n" }
            }
        }
        if lines.utf8.count > 200_000 { lines = String(lines.suffix(80_000)) }
    }

    func drain() -> String {
        lock.lock()
        defer { lock.unlock() }
        let result = lines
        lines = ""
        return result
    }
}
