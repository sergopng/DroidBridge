import AppKit
import Foundation
import Darwin
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case files = "Файлы", apps = "Приложения", shell = "Shell", diagnostics = "Диагностика", fastboot = "Fastboot"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .files: "folder"
        case .apps: "square.grid.2x2"
        case .shell: "terminal"
        case .diagnostics: "waveform.path.ecg"
        case .fastboot: "bolt.horizontal"
        }
    }
}

struct Bookmark: Codable, Identifiable {
    var id: String { endpoint }
    let name: String
    let endpoint: String
}

@MainActor final class Workspace: ObservableObject {
    @Published var link = Link.adb
    @Published var section = Section.files
    @Published var devices: [Device] = []
    @Published var serial = ""
    @Published var aliases = UserDefaults.standard.dictionary(forKey: "aliases") as? [String: String] ?? [:]
    @Published var bookmarks = (try? JSONDecoder().decode([Bookmark].self, from: UserDefaults.standard.data(forKey: "bookmarks") ?? Data())) ?? []
    @Published var localURL = FileManager.default.homeDirectoryForCurrentUser
    @Published var localEntries: [Entry] = []
    @Published var localSelection = Set<String>()
    @Published var remoteEntries: [Entry] = []
    @Published var remoteSelection = Set<String>()
    @Published var storages: [Storage] = []
    @Published var storage = ""
    @Published var remotePath = "/sdcard"
    @Published var mtpTrail: [Entry] = []
    @Published var packages: [Package] = []
    @Published var packageSelection = Set<String>()
    @Published var packageFilter = ""
    @Published var output = ""
    @Published var diagnostics = ""
    @Published var history: [String] = []
    @Published var busy: String?
    @Published var fastbootDevices: [String] = []
    @Published var fastbootSerial = ""
    @Published var fastbootOutput = ""
    @Published var fastbootInfo = FastbootInfo()
    @Published var writingFastbootImage = false
    @Published var error: String?
    @Published var status = "Готово"
    @Published var root = false
    @Published var showHidden = UserDefaults.standard.bool(forKey: "showHidden")
    @Published var keepAttributes = UserDefaults.standard.object(forKey: "keepAttributes") as? Bool ?? true
    @Published var debugLog = UserDefaults.standard.bool(forKey: "debugLog")
    @Published var consoleCommand = ""
    @Published var transfers: [Transfer] = []
    @Published var comparison: Comparison?
    @Published var activePane = FilePane.mac
    @Published var showTransfers = false
    @Published var localFolderSizes: [String: UInt64] = [:]
    @Published var remoteFolderSizes: [String: UInt64] = [:]
    @Published var folderBookmarks = (try? JSONDecoder().decode([FolderBookmark].self, from: UserDefaults.standard.data(forKey: "folderBookmarks") ?? Data())) ?? []
    var dragEntries: [String: (Entry, RemoteLocation)] = [:]
    @Published var mirrorRunning = false
    @Published var scrcpyProfile = ScrcpyProfile.saved { didSet { scrcpyProfile.save() } }
    @Published var scrcpyOptions: [ScrcpyOption] = []
    @Published var scrcpyCatalogError = ""
    @Published var scrcpyDiagnostic = ""
    @Published var scrcpyDiagnosticID: String?
    @Published var logRunning = false
    @Published var logFilter = ""
    @Published var helperAvailable = false
    @Published var appMetadata: [String: AppMetadata] = [:]
    @Published var appIcons: [String: NSImage] = [:]
    @Published var shellHistory = UserDefaults.standard.stringArray(forKey: "shellHistory") ?? []
    @Published var savedCommands = UserDefaults.standard.stringArray(forKey: "savedCommands") ?? []
    var iconRequests = Set<String>()
    nonisolated static let iconGate = DispatchSemaphore(value: 2)
    var mirrorProcess: Process?
    var mirrorStopping = false
    var logProcess: Process?
    var logTimer: Timer?
    private var runner: Runner?
    private(set) var shuttingDown = false

    var readyToQuit: Bool { busy == nil && mirrorProcess?.isRunning != true && logProcess?.isRunning != true }

    func prepareToQuit() {
        shuttingDown = true
        if !writingFastbootImage { runner?.cancel() }
        logTimer?.invalidate()
        stopLog()
        stopMirror()
    }

    func forceStopStreams() {
        for process in [logProcess, mirrorProcess].compactMap({ $0 }) where process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
    private var autoConnected = false

    var device: Device? { devices.first { $0.id == serial } }
    var connected: Bool { device?.online == true }
    var adbConnected: Bool { link == .adb && connected }
    var deviceName: String { device.map { aliases[$0.id] ?? $0.name } ?? "Android" }
    var parent: String { mtpTrail.last?.id ?? "0" }
    var breadcrumb: String { link == .adb ? remotePath : "/" + mtpTrail.map(\.name).joined(separator: "/") }
    var selectedLocal: [Entry] { localEntries.filter { localSelection.contains($0.id) } }
    var selectedRemote: [Entry] { remoteEntries.filter { remoteSelection.contains($0.id) } }
    var selectedPackages: [Package] { packages.filter { packageSelection.contains($0.id) } }
    var canWrite: Bool { connected && (link == .adb || !storage.isEmpty) }

    func record(_ message: String) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        history.append("\(timestamp)  \(message)")
        if history.count > 350 { history.removeFirst(history.count - 350) }
        if debugLog {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DroidBridge")
            let file = dir.appendingPathComponent("activity.log")
            if (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil {
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                if let handle = try? FileHandle(forWritingTo: file) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data("\(history.last ?? "")\n".utf8))
                    try? handle.close()
                }
            }
        }
    }

    func job<T>(_ title: String, _ work: @escaping (Runner) throws -> T, done: @escaping (T) -> Void = { _ in }, failed: @escaping (Error) -> Void = { _ in }) {
        guard !shuttingDown, busy == nil else { return }
        let operation = Runner()
        runner = operation
        busy = title
        error = nil
        record(title)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work(operation) }
            DispatchQueue.main.async {
                self.runner = nil
                self.busy = nil
                guard !self.shuttingDown else { return }
                switch result {
                case .success(let value):
                    self.status = "Готово · \(title)"
                    done(value)
                case .failure(let issue):
                    self.error = issue.localizedDescription
                    self.status = "Ошибка · \(title)"
                    self.record(issue.localizedDescription)
                    failed(issue)
                }
                self.runNextTransfer()
            }
        }
    }

    func cancel() {
        guard let runner else { return }
        if writingFastbootImage,
           !confirm("Прервать запись образа?", detail: "Раздел может остаться частично записанным. Дождитесь завершения, если устройство ещё отвечает.", button: "Прервать запись") { return }
        runner.cancel()
    }
    func launch() {
        if FileManager.default.fileExists(atPath: localURL.path) {
            loadLocal(localURL)
        } else {
            loadLocal(FileManager.default.homeDirectoryForCurrentUser)
        }
        refreshDevices()
    }
    private var localLoad = UUID()

    func loadLocal(_ url: URL) {
        let request = UUID()
        localLoad = request
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Entry.local(url) }
            DispatchQueue.main.async {
                guard self.localLoad == request else { return }
                switch result {
                case .success(let entries):
                    self.localEntries = entries
                    self.localFolderSizes.removeAll()
                    self.localURL = url
                    self.localSelection.removeAll()
                case .failure(let error):
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func switchLink(_ value: Link) {
        guard busy == nil, link != value else { return }
        link = value
        section = .files
        serial = ""
        devices = []
        clearRemote()
        refreshDevices()
    }

    func clearRemote() {
        stopLog()
        remoteFolderSizes.removeAll()
        helperAvailable = false
        appMetadata = [:]
        appIcons = [:]
        iconRequests = []
        remotePath = "/sdcard"
        remoteSelection.removeAll()
        remoteEntries = []
        storages = []
        storage = ""
        mtpTrail = []
        packages = []
        packageSelection.removeAll()
        output = ""
        diagnostics = ""
        root = false
    }

    func refreshDevices() {
        let transport = link
        let saved = autoConnected || transport == .mtp ? [] : bookmarks
        autoConnected = autoConnected || transport == .adb
        job("Поиск устройств", { operation in
            for bookmark in saved { _ = try? operation.text(.adb, ["connect", bookmark.endpoint]) }
            return try operation.devices(transport)
        }, done: { list in
            self.devices = list
            let preferred = list.first { $0.id == self.serial } ?? list.first(where: \.online) ?? list.first
            if self.serial != (preferred?.id ?? "") {
                self.selectDevice(preferred?.id ?? "")
            } else if self.connected {
                self.refreshCurrent()
            }
        })
    }

    func selectDevice(_ id: String) {
        guard busy == nil else { return }
        serial = id
        clearRemote()
        refreshCurrent()
    }

    func refreshCurrent() {
        if section == .fastboot { refreshFastboot(); return }
        guard connected else { return }
        switch section {
        case .files:
            if link == .mtp && storage.isEmpty { loadStorages() } else { loadRemote() }
        case .apps: loadPackages()
        case .shell, .diagnostics, .fastboot: break
        }
    }

    func loadStorages() {
        let id = serial
        job("Чтение хранилищ MTP", { try $0.storages(id) }, done: { list in
            self.storages = list
            if let first = list.first {
                self.changeStorage(first.id)
            } else {
                self.error = "Телефон не открыл хранилище. Разблокируйте его и выберите «Передача файлов»."
            }
        })
    }

    func changeStorage(_ id: String) {
        storage = id
        mtpTrail = []
        remoteEntries = []
        remoteSelection.removeAll()
        loadRemote()
    }

    func loadRemote(path: String? = nil, trail: [Entry]? = nil) {
        guard connected else { return }
        let transport = link, id = serial, sid = storage, elevated = root
        let nextPath = path ?? remotePath, nextTrail = trail ?? mtpTrail
        guard transport == .adb || !sid.isEmpty else { return }
        job("Чтение папки Android", { operation in
            if transport == .adb { return try operation.adbFiles(id, nextPath, root: elevated) }
            return try operation.mtpFiles(id, sid, nextTrail.last?.id ?? "0")
        }, done: { entries in
            self.remotePath = nextPath
            self.mtpTrail = nextTrail
            self.remoteEntries = entries
            self.remoteFolderSizes.removeAll()
            self.remoteSelection.removeAll()
        })
    }

    func enter(_ entry: Entry) {
        if !entry.folder { openRemote(entry); return }
        if link == .adb { loadRemote(path: entry.id) } else { loadRemote(trail: mtpTrail + [entry]) }
    }

    func up() {
        if link == .adb {
            if remotePath != "/" { loadRemote(path: (remotePath as NSString).deletingLastPathComponent) }
        } else if !mtpTrail.isEmpty {
            loadRemote(trail: Array(mtpTrail.dropLast()))
        }
    }

    func namedDevice() {
        guard let device, let name = ask("Имя устройства", value: aliases[device.id] ?? device.name, button: "Сохранить") else { return }
        aliases[device.id] = name
        UserDefaults.standard.set(aliases, forKey: "aliases")
    }

    func connect(_ endpoint: String, pair: String? = nil) {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("-"), value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            error = "Введите адрес телефона и порт, например 192.168.1.20:5555."
            return
        }
        job(pair == nil ? "Подключение по Wi‑Fi" : "Сопряжение по Wi‑Fi", { operation in
            let response = try operation.text(.adb, pair.map { ["pair", value, $0] } ?? ["connect", value])
            let lower = response.lowercased()
            if !lower.contains("connected to") && !lower.contains("successfully paired") { throw Failure(response) }
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        }, done: {
            self.record($0)
            self.status = $0
            if pair == nil { self.refreshDevices() }
        })
    }

    func saveBookmark(endpoint: String, name: String) {
        guard !endpoint.isEmpty, !endpoint.hasPrefix("-"), !endpoint.contains(where: \.isWhitespace) else { return }
        bookmarks.removeAll { $0.endpoint == endpoint }
        bookmarks.append(Bookmark(name: name.isEmpty ? endpoint : name, endpoint: endpoint))
        UserDefaults.standard.set(try? JSONEncoder().encode(bookmarks), forKey: "bookmarks")
    }

    func removeBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        UserDefaults.standard.set(try? JSONEncoder().encode(bookmarks), forKey: "bookmarks")
    }

    func loadPackages() {
        guard adbConnected else { return }
        let id = serial, filter = packageFilter
        job("Чтение списка приложений", { runner in
            let packages = try runner.packages(id, filter: filter)
            let installed = (try? AndroidHelper.installed(runner, device: id)) == true
            let details = installed ? (try? AndroidHelper.metadata(runner, device: id)) ?? [:] : [:]
            return (packages, installed, details)
        }, done: { result in
            self.packages = result.0
            self.helperAvailable = result.1
            self.appMetadata = result.2
            self.packageSelection.removeAll()
        })
    }

    func saveShellCommand() {
        let command = consoleCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !savedCommands.contains(command) else { return }
        savedCommands.append(command)
        UserDefaults.standard.set(savedCommands, forKey: "savedCommands")
    }

    func removeShellCommand(_ command: String) {
        savedCommands.removeAll { $0 == command }
        UserDefaults.standard.set(savedCommands, forKey: "savedCommands")
    }

    func runShell() {
        let cmd = consoleCommand
        guard adbConnected, !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let id = serial, elevated = root
        consoleCommand = ""
        shellHistory.removeAll { $0 == cmd }
        shellHistory.insert(cmd, at: 0)
        if shellHistory.count > 100 { shellHistory.removeLast(shellHistory.count - 100) }
        UserDefaults.standard.set(shellHistory, forKey: "shellHistory")
        output += "$ " + cmd + "\n"
        job("Выполнение команды Shell", { operation in
            let wrapped = elevated ? "su -c " + shellQuote(cmd) : cmd
            return try operation.text(.adb, ["-s", id, "shell", wrapped], allowError: true)
        }, done: { self.output += $0 + ($0.hasSuffix("\n") ? "" : "\n") })
    }

    func interactiveShell() {
        guard adbConnected else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DroidBridge-Shell-" + UUID().uuidString + ".command")
        do {
            let environment = try ADBSession.shared.environment()
            guard let socket = environment["ADB_SERVER_SOCKET"] else { return }
            let command = ["/usr/bin/env", "ADB_SERVER_SOCKET=" + socket, Runner.executable(.adb).path,
                           "-s", serial, "shell"] + (root ? ["su"] : [])
            let script = "#!/bin/sh\nrm -f -- \"$0\"\n[ -S " + shellQuote(String(socket.dropFirst("localfilesystem:".count))) +
                " ] || exit 1\nexec " + command.map(shellQuote).joined(separator: " ") + "\n"
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: .init()) { _, failure in
                if let failure { Task { @MainActor in self.error = failure.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }

    func query(_ title: String, command: String) {
        guard adbConnected else { return }
        let id = serial, elevated = root
        job(title, { try $0.shell(id, command, root: elevated) }, done: { self.diagnostics = $0 })
    }

    func direct(_ title: String, args: [String], refresh: Bool = false) {
        guard adbConnected else { return }
        let id = serial
        job(title, { try $0.adb(id, args) }, done: {
            self.record($0)
            if refresh { self.refreshCurrent() }
        })
    }
}

@MainActor func ask(_ title: String, value: String = "", button: String = "Готово", detail: String = "") -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 350, height: 24))
    field.stringValue = value
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: "Отмена")
    return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
}

@MainActor func confirm(_ title: String, detail: String, button: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: button).hasDestructiveAction = true
    alert.addButton(withTitle: "Отмена").keyEquivalent = "\r"
    return alert.runModal() == .alertFirstButtonReturn
}

@MainActor func chooseFolder() -> URL? {
    let dialog = NSOpenPanel()
    dialog.canChooseFiles = false
    dialog.canChooseDirectories = true
    dialog.prompt = "Открыть"
    return dialog.runModal() == .OK ? dialog.url : nil
}

@MainActor func saveURL(_ name: String) -> URL? {
    let dialog = NSSavePanel()
    dialog.nameFieldStringValue = name
    return dialog.runModal() == .OK ? dialog.url : nil
}
