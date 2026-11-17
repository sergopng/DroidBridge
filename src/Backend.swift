import AppKit
import Foundation
import Darwin

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Tool: String { case adb, mtp = "mtp-bridge", scrcpy, fastboot }
enum Link: String, CaseIterable, Identifiable {
    case adb = "ADB", mtp = "MTP"
    var id: String { rawValue }
}

struct Device: Identifiable, Hashable {
    let id: String
    let name: String
    let state: String
    var online: Bool { state == "device" }
}

struct Entry: Identifiable, Hashable {
    let id: String
    let name: String
    let folder: Bool
    var size: UInt64 = 0
    var date: Date? = nil
    var mode = ""
    var owner = ""
    var group = ""
    var target = ""
    var sortDate: Date { date ?? .distantPast }
    var icon: String { !target.isEmpty ? "arrow.turn.up.right" : (folder ? "folder.fill" : "doc") }

    static func local(_ url: URL) throws -> [Entry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys)).compactMap {
            let values = try? $0.resourceValues(forKeys: keys)
            return Entry(id: $0.path, name: $0.lastPathComponent, folder: values?.isDirectory == true,
                         size: UInt64(max(0, values?.fileSize ?? 0)), date: values?.contentModificationDate)
        }.ordered
    }
}
extension Array where Element == Entry {
    var ordered: [Entry] {
        sorted {
            if $0.folder != $1.folder { return $0.folder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
struct Storage: Identifiable, Hashable {
    let id: String
    let size: UInt64
    let free: UInt64
    let name: String
}

struct Package: Identifiable, Hashable {
    let id: String
    let path: String
    var name = ""
    var version = ""
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func remoteJoin(_ path: String, _ name: String) -> String { (path == "/" ? "" : path) + "/" + name }
func decodeHex(_ value: String) -> String {
    var bytes: [UInt8] = []
    var index = value.startIndex
    while index < value.endIndex {
        guard let end = value.index(index, offsetBy: 2, limitedBy: value.endIndex),
              let byte = UInt8(value[index..<end], radix: 16) else { return "" }
        bytes.append(byte)
        index = end
    }
    return String(decoding: bytes, as: UTF8.self)
}

final class Runner: @unchecked Sendable {
    private static let mtpLock = NSLock()
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    var transferExpectedBytes: UInt64 = 0
    var transferProgress: ((UInt64, UInt64, Double) -> Void)?

    static func executable(_ tool: Tool) -> URL {
        ToolInstallation.selected(tool).appendingPathComponent(tool.rawValue)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        if let running, running.isRunning { running.terminate() }
        lock.unlock()
        if let running {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self, weak running] in
                guard let self, let running else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                if self.process === running, running.isRunning { kill(running.processIdentifier, SIGKILL) }
            }
        }
    }

    func check() throws {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped { throw Failure("Операция остановлена.") }
    }

    func run(_ tool: Tool, _ args: [String], output: URL? = nil, allowError: Bool = false, includeStandardError: Bool = false) throws -> Data {
        if tool == .mtp { Self.mtpLock.lock() }
        defer { if tool == .mtp { Self.mtpLock.unlock() } }
        try check()
        if let report = transferProgress, output == nil,
           (tool == .adb && args.dropFirst(2).first.map({ ["push", "pull"].contains($0) }) == true ||
            tool == .mtp && args.first.map({ ["push", "pull"].contains($0) }) == true) {
            return try transferOutput(tool, args, report: report)
        }
        let task = Process()
        task.executableURL = Self.executable(tool)
        task.arguments = args
        if tool == .adb { task.environment = try ADBSession.shared.environment() }
        if tool == .scrcpy {
            let environment = ToolInstallation.scrcpyEnvironment()
            task.environment = args.contains("--otg") ? environment : try ADBSession.shared.environment(base: environment)
        }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("DroidBridge-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        let stdout = output ?? temp.appendingPathComponent("stdout")
        let stderr = temp.appendingPathComponent("stderr")
        for url in [stdout, stderr] {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw Failure("Не удалось создать файл «\(url.lastPathComponent)».")
            }
        }
        let out = try FileHandle(forWritingTo: stdout)
        let err = try FileHandle(forWritingTo: stderr)
        defer { try? out.close(); try? err.close() }
        task.standardOutput = out
        task.standardError = err
        task.standardInput = FileHandle.nullDevice
        lock.lock()
        do {
            if cancelled { throw Failure("Операция остановлена.") }
            try task.run()
            process = task
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        task.waitUntilExit()
        lock.lock()
        process = nil
        lock.unlock()
        try check()
        let data = output == nil ? try Data(contentsOf: stdout) : Data()
        let errorText = (try? String(contentsOf: stderr, encoding: .utf8)) ?? ""
        if task.terminationStatus != 0 && !allowError {
            let details = (errorText + "\n" + String(decoding: data.prefix(8_000), as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(details.isEmpty ? "Команда завершилась с кодом \(task.terminationStatus)." : details)
        }
        if (allowError || includeStandardError) && !errorText.isEmpty { return data + Data(errorText.utf8) }
        return data
    }

    private func transferOutput(_ tool: Tool, _ args: [String], report: (UInt64, UInt64, Double) -> Void) throws -> Data {
        var master: Int32 = 0, slave: Int32 = 0
        var dimensions = winsize(ws_row: 24, ws_col: 240, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &dimensions) == 0 else { throw Failure("Не удалось открыть поток прогресса.") }
        let reader = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let writer = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        defer { try? reader.close(); try? writer.close() }
        let task = Process()
        task.executableURL = Self.executable(tool)
        task.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm"
        task.environment = tool == .adb ? try ADBSession.shared.environment(base: environment) : environment
        task.standardOutput = writer
        task.standardError = writer
        task.standardInput = FileHandle.nullDevice
        lock.lock()
        do {
            if cancelled { throw Failure("Операция остановлена.") }
            try task.run()
            process = task
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        try? writer.close()
        let percentPattern = try NSRegularExpression(pattern: #"^(?:\x1b\[[0-9;?]*[A-Za-z])*\[\s*(\d{1,3})%\]"#)
        var capture = Data()
        var pending = Data()
        var lastReport = Date.distantPast
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            // FileHandle.read(upToCount:) can wait for a full buffer even on a PTY.
            // A single read delivers the progress records as soon as they arrive.
            let count = buffer.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
            if count == -1 && errno == EINTR { continue }
            guard count > 0 else { break }
            let bytes = buffer.prefix(count)
            capture.append(contentsOf: bytes)
            if capture.count > 32_000 { capture.removeFirst(capture.count - 32_000) }
            pending.append(contentsOf: bytes)
            guard let lastBreak = pending.lastIndex(where: { $0 == 10 || $0 == 13 }) else {
                if pending.count > 16_000 { pending.removeAll() }
                continue
            }
            let lines = String(decoding: pending[...lastBreak], as: UTF8.self).components(separatedBy: .newlines)
            pending.removeSubrange(...lastBreak)
            guard Date().timeIntervalSince(lastReport) > 0.13 else { continue }
            for line in lines.reversed() {
                if tool == .mtp, line.hasPrefix("P ") {
                    let fields = line.split(separator: " ")
                    if fields.count == 3, let bytes = UInt64(fields[1]), let reportedTotal = UInt64(fields[2]) {
                        let total = reportedTotal == 0 ? transferExpectedBytes : reportedTotal
                        if total > 0 { report(bytes, total, min(1, Double(bytes) / Double(total))) }
                        lastReport = .now
                        break
                    }
                } else if tool == .adb, let match = percentPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                          let range = Range(match.range(at: 1), in: line), let value = Double(line[range]) {
                    report(0, 0, min(1, value / 100))
                    lastReport = .now
                    break
                }
            }
        }
        task.waitUntilExit()
        lock.lock()
        process = nil
        lock.unlock()
        try check()
        if task.terminationStatus != 0 {
            throw Failure(String(decoding: capture, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return capture
    }

    func text(_ tool: Tool, _ args: [String], allowError: Bool = false) throws -> String {
        String(decoding: try run(tool, args, allowError: allowError), as: UTF8.self)
    }

    func devices(_ link: Link) throws -> [Device] {
        if link == .mtp {
            return try rows(text(.mtp, ["devices"]), "D", 3).map {
                Device(id: $0[1], name: decodeHex($0[2]), state: "device")
            }
        }
        return try text(.adb, ["devices", "-l"]).components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, !line.hasPrefix("List of"), !line.hasPrefix("*") else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            return Device(id: parts[0], name: model ?? parts[0], state: parts[1])
        }
    }

    func adb(_ device: String, _ args: [String]) throws -> String { try text(.adb, ["-s", device] + args) }

    func shell(_ device: String, _ command: String, root: Bool = false) throws -> String {
        try adb(device, ["shell", root ? "su -c " + shellQuote(command) : command])
    }

    func adbFiles(_ device: String, _ path: String, root: Bool) throws -> [Entry] {
        let quoted = shellQuote(path)
        let command = """
        cd \(quoted) || exit
        test -r . && test -x . || { echo 'Permission denied' >&2; exit 1; }
        for f in ./* ./.[!.]* ./..?*; do
          [ -e "$f" ] || [ -L "$f" ] || continue
          if [ -d "$f" ]; then kind=d; elif [ -L "$f" ]; then kind=l; else kind=f; fi
          statline=$(stat -c '%s|%Y|%a|%U|%G' -- "$f" 2>/dev/null) || statline='0|0|||'
          target=''
          if [ -L "$f" ]; then target=$(readlink -- "$f"); fi
          printf '%s\\0%s\\0%s\\0%s\\0' "${f#./}" "$kind" "$statline" "$target"
        done
        """
        let fields = try shell(device, command, root: root).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        return stride(from: 0, to: max(0, fields.count - 3), by: 4).map { i in
            let name = fields[i]
            let stat = fields[i + 2].components(separatedBy: "|")
            let stamp = stat.count == 5 ? Double(stat[1]) : nil
            return Entry(id: remoteJoin(path, name), name: name, folder: fields[i + 1] == "d",
                         size: UInt64(stat.first ?? "") ?? 0,
                         date: stamp.flatMap { $0 == 0 ? nil : Date(timeIntervalSince1970: $0) },
                         mode: stat.count == 5 ? stat[2] : "", owner: stat.count == 5 ? stat[3] : "",
                         group: stat.count == 5 ? stat[4] : "", target: fields[i + 3])
        }.ordered
    }

    func storages(_ device: String) throws -> [Storage] {
        try rows(text(.mtp, ["storage", device]), "S", 5).map {
            let name = decodeHex($0[4])
            return Storage(id: $0[1], size: UInt64($0[2]) ?? 0, free: UInt64($0[3]) ?? 0, name: name.isEmpty ? "Хранилище \($0[1])" : name)
        }
    }
    func mtpFiles(_ device: String, _ storage: String, _ parent: String) throws -> [Entry] {
        try rows(text(.mtp, ["list", device, storage, parent]), "F", 6).map {
            let stamp = Double($0[4]) ?? 0
            return Entry(id: $0[1], name: decodeHex($0[5]), folder: $0[2] == "1", size: UInt64($0[3]) ?? 0,
                         date: stamp == 0 ? nil : Date(timeIntervalSince1970: stamp))
        }.ordered
    }

    func packages(_ device: String, filter: String) throws -> [Package] {
        let args = filter.isEmpty ? "pm list packages -f" : "pm list packages -f " + filter
        return try shell(device, args).components(separatedBy: .newlines).compactMap { line -> Package? in
            guard line.hasPrefix("package:"), let equal = line.lastIndex(of: "=") else { return nil }
            return Package(id: String(line[line.index(after: equal)...]), path: String(line[line.index(line.startIndex, offsetBy: 8)..<equal]))
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private func rows(_ response: String, _ prefix: String, _ count: Int) -> [[String]] {
        response.components(separatedBy: .newlines).map { $0.components(separatedBy: "\t") }.filter {
            $0.count == count && $0.first == prefix
        }
    }
}
