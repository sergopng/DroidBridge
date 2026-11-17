import AppKit
import CryptoKit
import SwiftUI

struct ToolInstallation {
    static let base = URL.applicationSupportDirectory.appendingPathComponent("DroidBridge/Tools", isDirectory: true)

    static func selected(_ tool: Tool) -> URL {
        let directory = base.appendingPathComponent(tool == .fastboot ? Tool.adb.rawValue : tool.rawValue, isDirectory: true)
        if [.adb, .fastboot, .scrcpy].contains(tool),
           let value = try? String(contentsOf: directory.appendingPathComponent("current"), encoding: .utf8),
           UUID(uuidString: value) != nil {
            let active = directory.appendingPathComponent(value)
            if FileManager.default.isExecutableFile(atPath: active.appendingPathComponent(tool.rawValue).path) { return active }
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
    }

    static func scrcpyEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let directory = selected(.scrcpy)
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/scrcpy")
        let assets = FileManager.default.fileExists(atPath: directory.appendingPathComponent("scrcpy-server").path) ? directory : bundled
        environment["ADB"] = Runner.executable(.adb).path
        environment["SCRCPY_SERVER_PATH"] = assets.appendingPathComponent("scrcpy-server").path
        environment["SCRCPY_ICON_DIR"] = assets.path
        return environment
    }

    static func restore(_ tool: Tool) throws {
        let directory = base.appendingPathComponent(tool.rawValue)
        let marker = directory.appendingPathComponent("current")
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
    }

    static func version(_ tool: Tool) throws -> String {
        let output = try command(Runner.executable(tool), [tool == .adb ? "version" : "--version"])
        if tool == .adb { return output.components(separatedBy: .newlines).first { $0.hasPrefix("Version ") } ?? output }
        return output.components(separatedBy: .newlines).first { $0.hasPrefix(tool.rawValue + " ") } ?? output
    }

    static func command(_ url: URL, _ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = url
        task.arguments = arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard task.terminationStatus == 0 else { throw Failure(text.isEmpty ? "Команда завершилась с ошибкой." : text) }
        return text
    }

    static func candidate(_ tool: Tool) async throws -> ToolRelease {
        if tool == .scrcpy {
            let url = URL(string: "https://api.github.com/repos/Genymobile/scrcpy/releases/latest")!
            let data = try await fetch(url, hosts: ["api.github.com"])
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            #if arch(arm64)
            let arch = "aarch64"
            #else
            let arch = "x86_64"
            #endif
            let file = "scrcpy-macos-\(arch)-\(release.tag_name).tar.gz"
            guard let asset = release.assets.first(where: { $0.name == file }), let digest = asset.digest, digest.hasPrefix("sha256:"),
                  asset.browser_download_url.host == "github.com",
                  asset.browser_download_url.path.hasPrefix("/Genymobile/scrcpy/releases/download/") else {
                throw Failure("В официальном релизе нет проверяемой сборки scrcpy для этого Mac.")
            }
            return ToolRelease(tool: tool, version: release.tag_name, url: asset.browser_download_url, checksum: String(digest.dropFirst(7)))
        }
        let data = try await fetch(URL(string: "https://dl.google.com/android/repository/repository2-3.xml")!, hosts: ["dl.google.com"])
        let delegate = AndroidRepository()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let release = delegate.release else { throw Failure("В репозитории Google нет стабильной сборки ADB для Mac.") }
        return release
    }

    static func install(_ release: ToolRelease) async throws {
        let stage = try stagingDirectory()
        defer { try? FileManager.default.removeItem(at: stage) }
        let hosts: Set<String> = release.tool == .adb ? ["dl.google.com"] : ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
        let data = try await fetch(release.url, hosts: hosts)
        let hash = release.tool == .adb ? Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() :
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == release.checksum.lowercased() else { throw Failure("Контрольная сумма архива не совпала.") }
        let archive = stage.appendingPathComponent("download")
        try data.write(to: archive)
        let expanded = stage.appendingPathComponent("expanded", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: expanded, withIntermediateDirectories: false)
        let root: URL
        if release.tool == .adb {
            _ = try command(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, expanded.path])
            root = expanded.appendingPathComponent("platform-tools")
        } else {
            _ = try command(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", expanded.path])
            root = expanded.appendingPathComponent(release.url.deletingPathExtension().deletingPathExtension().lastPathComponent)
        }
        let directory = base.appendingPathComponent(release.tool.rawValue)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString
        let target = directory.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let required = release.tool == .adb ? ["adb", "fastboot"] : ["scrcpy", "scrcpy-server"]
            for name in required + (release.tool == .adb ? ["NOTICE.txt"] : ["scrcpy.png", "disconnected.png", "LICENSE"]) {
                let source = root.appendingPathComponent(name)
                if !required.contains(name), !fm.fileExists(atPath: source.path) { continue }
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure("В архиве нет обычного файла \(name).") }
                try fm.copyItem(at: source, to: target.appendingPathComponent(name))
            }
            let binaries: [(Tool, String)] = release.tool == .adb
                ? [(.adb, "version"), (.fastboot, "--version")] : [(.scrcpy, "--version")]
            for (tool, flag) in binaries {
                let output = try command(target.appendingPathComponent(tool.rawValue), [flag])
                guard output.contains(release.version.trimmingCharacters(in: CharacterSet(charactersIn: "v"))) else {
                    throw Failure("Версия \(tool.rawValue) не совпала с версией релиза.")
                }
            }
            try id.write(to: directory.appendingPathComponent("current"), atomically: true, encoding: .utf8)
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
    }

    private static func fetch(_ url: URL, hosts: Set<String>) async throws -> Data {
        guard url.scheme == "https", let host = url.host, hosts.contains(host) else { throw Failure("Адрес загрузки не принадлежит официальному источнику.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("DroidBridge/1.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let final = http.url, final.scheme == "https", let host = final.host, hosts.contains(host), data.count <= 100_000_000 else {
            throw Failure("Официальный сервер не вернул ожидаемый файл.")
        }
        return data
    }
}

struct ToolRelease {
    let tool: Tool
    let version: String
    let url: URL
    let checksum: String
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let digest: String?
        let browser_download_url: URL
    }
    let tag_name: String
    let assets: [Asset]
}

private final class AndroidRepository: NSObject, XMLParserDelegate {
    var release: ToolRelease?
    private var package = false
    private var stable = false
    private var revision: [String: String] = [:]
    private var archive: [String: String] = [:]
    private var macArchive: [String: String]?
    private var stack: [String] = []
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(name)
        text = ""
        if name == "remotePackage" {
            package = attributes["path"] == "platform-tools"
            stable = false
            revision = [:]
            macArchive = nil
        }
        if package && name == "channelRef" { stable = attributes["ref"] == "channel-0" }
        if package && name == "archive" { archive = [:] }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { _ = stack.popLast(); text = "" }
        guard package else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stack.dropLast().last == "revision" { revision[name] = value }
        if ["host-os", "url", "checksum"].contains(name), stack.contains("archive") { archive[name] = value }
        if name == "archive", archive["host-os"] == "macosx" { macArchive = archive }
        if name == "remotePackage", stable, let file = macArchive?["url"],
           file.range(of: #"^platform-tools_r[0-9.]+-darwin\.zip$"#, options: .regularExpression) != nil,
           let checksum = macArchive?["checksum"], checksum.count == 40,
           let url = URL(string: "https://dl.google.com/android/repository/" + file) {
            let version = ["major", "minor", "micro"].map { revision[$0] ?? "0" }.joined(separator: ".")
            let next = ToolRelease(tool: .adb, version: version, url: url, checksum: checksum)
            if release == nil || version.compare(release!.version, options: .numeric) == .orderedDescending { release = next }
        }
    }
}

struct ToolSettings: View {
    @ObservedObject var model: Workspace
    @State private var versions: [Tool: String] = [:]
    @State private var message = ""
    @State private var working = false
    @State private var releases: [Tool: ToolRelease] = [:]

    var body: some View {
        SwiftUI.Section("ADB, Fastboot и scrcpy") {
            ForEach([Tool.adb, .scrcpy], id: \.self) { tool in
                HStack {
                    VStack(alignment: .leading) {
                        Text(tool == .adb ? "Android SDK Platform Tools" : "scrcpy").fontWeight(.medium)
                        Text(versions[tool] ?? "Чтение версии…").font(.caption).foregroundStyle(.secondary)
                        if tool == .adb, let fastboot = versions[.fastboot] {
                            Text(fastboot).font(.caption).foregroundStyle(.secondary)
                        }
                        if let release = releases[tool] { Text("Официальный релиз \(release.version)").font(.caption) }
                    }
                    Spacer()
                    if let release = releases[tool],
                       ([tool] + (tool == .adb ? [.fastboot] : [])).contains(where: {
                           versions[$0]?.contains(release.version.trimmingCharacters(in: CharacterSet(charactersIn: "v"))) != true
                       }) {
                        Button("Установить") { install(release) }
                    }
                    Button("Встроенная версия") {
                        do { try ToolInstallation.restore(tool); reload(); if tool == .scrcpy { model.loadScrcpyOptions() } }
                        catch { message = error.localizedDescription }
                    }.disabled(ToolInstallation.selected(tool).path == Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS").path)
                }
            }
            HStack {
                Button("Проверить обновления") {
                    working = true
                    message = ""
                    Task {
                        var errors: [String] = []
                        for tool in [Tool.adb, .scrcpy] {
                            do { releases[tool] = try await ToolInstallation.candidate(tool) }
                            catch { errors.append("\(tool.rawValue) · \(error.localizedDescription)") }
                        }
                        message = errors.isEmpty ? "Проверка завершена." : errors.joined(separator: "\n")
                        working = false
                    }
                }
                if working { ProgressView().controlSize(.small) }
            }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
        }
        .disabled(working || model.busy != nil || model.mirrorRunning || model.logRunning)
        .task { reload() }
    }

    private func reload() {
        Task {
            let results = await Task.detached {
                Dictionary(uniqueKeysWithValues: [Tool.adb, .fastboot, .scrcpy].map { tool in
                    (tool, (try? ToolInstallation.version(tool)) ?? "Версия недоступна")
                })
            }.value
            versions = results
        }
    }

    private func install(_ release: ToolRelease) {
        working = true
        message = "Загрузка и проверка \(release.tool.rawValue)…"
        Task {
            do {
                try await ToolInstallation.install(release)
                message = "Установлена версия \(release.version)."
                reload()
                if release.tool == .scrcpy { model.loadScrcpyOptions() }
            } catch { message = error.localizedDescription }
            working = false
        }
    }
}
