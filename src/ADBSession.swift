import Darwin
import Foundation

final class ADBSession: @unchecked Sendable {
    static let shared = ADBSession()

    private let lock = NSLock()
    private var server: Process?
    private var directory: URL?
    private var closed = false

    func environment(base: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw Failure("DroidBridge завершает работу.") }

        let binary = Runner.executable(.adb)
        if server?.isRunning != true || server?.executableURL != binary {
            stopServer()
            try startServer(binary)
        }
        guard let directory else { throw Failure("Сокет DroidBridge ADB недоступен.") }
        var environment = base
        environment["ADB_SERVER_SOCKET"] = "localfilesystem:" + directory.appendingPathComponent("adb").path
        return environment
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        stopServer()
    }

    private func startServer(_ binary: URL) throws {
        var template = Array("/tmp/droidbridge-adb.XXXXXX".utf8CString)
        guard let path = template.withUnsafeMutableBufferPointer({ buffer -> String? in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }) else { throw Failure("Не удалось создать папку для сокета DroidBridge ADB.") }

        let directory = URL(fileURLWithPath: path, isDirectory: true)
        self.directory = directory
        let socket = directory.appendingPathComponent("adb").path
        let log = directory.appendingPathComponent("server.log")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-L", "localfilesystem:" + socket, "server", "nodaemon"]
        process.standardInput = FileHandle.nullDevice
        do {
            try Data().write(to: log)
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            process.standardOutput = output
            process.standardError = output
            try process.run()
            server = process
            let timeout = ContinuousClock.now + .seconds(3)
            while process.isRunning && ContinuousClock.now < timeout {
                if FileManager.default.fileExists(atPath: socket) { return }
                Thread.sleep(forTimeInterval: 0.025)
            }
            let details = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw Failure("Не удалось запустить сервер DroidBridge ADB.\n" + String(details.suffix(3000)))
        } catch {
            stopServer()
            throw error
        }
    }

    private func stopServer() {
        // Removing the private socket directory prevents a late adb client from relaunching its daemon.
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        guard let server else { return }
        if server.isRunning {
            server.terminate()
            let timeout = ContinuousClock.now + .seconds(1)
            while server.isRunning && ContinuousClock.now < timeout {
                Thread.sleep(forTimeInterval: 0.025)
            }
            if server.isRunning { Darwin.kill(server.processIdentifier, SIGKILL) }
        }
        server.waitUntilExit()
        self.server = nil
    }
}
