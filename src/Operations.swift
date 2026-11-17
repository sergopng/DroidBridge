import AppKit
import Foundation

struct RemoteLocation {
    let link: Link
    let serial: String
    let storage: String
    let folder: String
    let root: Bool
    let attributes: Bool

    func list(_ run: Runner) throws -> [Entry] {
        if link == .adb { return try run.adbFiles(serial, folder, root: root) }
        return try run.mtpFiles(serial, storage, folder)
    }

    func shell(_ run: Runner, _ command: String) throws -> String { try run.shell(serial, command, root: root) }
    func mtp(_ run: Runner, _ action: String, object: String, extra: [String] = []) throws -> String {
        try run.text(.mtp, [action, serial, storage, object] + extra)
    }
    func pull(_ run: Runner, _ entry: Entry, _ url: URL) throws {
        if link == .mtp {
            _ = try mtp(run, "pull", object: entry.id, extra: [entry.folder ? "1" : "0", url.path])
        } else if root {
            let staged = "/data/local/tmp/droidbridge-" + UUID().uuidString
            defer { _ = try? Runner().shell(serial, "rm -rf -- " + shellQuote(staged), root: true) }
            _ = try shell(run, "umask 077; mkdir -- \(shellQuote(staged)) && cp -RLp -- \(shellQuote(entry.id)) \(shellQuote(staged + "/item")) && chown -R shell:shell \(shellQuote(staged)) && chmod -R u+rX \(shellQuote(staged))")
            _ = try run.adb(serial, ["pull"] + (attributes ? ["-a"] : []) + [staged + "/item", url.path])
        } else {
            _ = try run.adb(serial, ["pull"] + (attributes ? ["-a"] : []) + [entry.id, url.path])
        }
    }
    func push(_ run: Runner, _ url: URL, name: String) throws {
        if link == .mtp {
            _ = try mtp(run, "push", object: folder, extra: [url.path, name])
            return
        }
        let target = remoteJoin(folder, name)
        let stage = root ? "/data/local/tmp/droidbridge-" + UUID().uuidString : target
        if root { _ = try run.shell(serial, "umask 077; mkdir -- " + shellQuote(stage)) }
        defer { if root { _ = try? Runner().shell(serial, "rm -rf -- " + shellQuote(stage), root: true) } }
        _ = try run.adb(serial, ["push", url.path, root ? stage + "/item" : stage])
        if root {
            _ = try shell(run, "cp -Rp -- \(shellQuote(stage + "/item")) \(shellQuote(target))")
        }
    }
    func delete(_ run: Runner, _ entry: Entry) throws {
        if link == .adb { _ = try shell(run, "rm -rf -- " + shellQuote(entry.id)) }
        else { _ = try mtp(run, "delete", object: entry.id) }
    }
    func rename(_ run: Runner, _ entry: Entry, _ name: String) throws {
        if link == .adb {
            let old = shellQuote(entry.id), new = shellQuote(remoteJoin(folder, name))
            _ = try shell(run, "if [ -e \(new) ] || [ -L \(new) ]; then echo 'Destination already exists' >&2; exit 1; fi; mv -- \(old) \(new)")
        } else { _ = try mtp(run, "rename", object: entry.id, extra: [name]) }
    }
}

func validName(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
}

func stagingDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("DroidBridge-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return url
}

func commit(_ staged: URL, to target: URL, replace: Bool) throws {
    let fm = FileManager.default
    if replace && (try? fm.attributesOfItem(atPath: target.path)) != nil {
        _ = try fm.replaceItemAt(target, withItemAt: staged)
    } else {
        try fm.moveItem(at: staged, to: target)
    }
}

extension Workspace {
    var location: RemoteLocation {
        RemoteLocation(link: link, serial: serial, storage: storage, folder: link == .adb ? remotePath : parent, root: root, attributes: keepAttributes)
    }

    func createFolder() {
        guard canWrite, let name = ask("Новая папка на Android", button: "Создать"), validName(name) else { return }
        let here = location
        job("Создание папки", { run in
            guard try !here.list(run).contains(where: { $0.name == name }) else { throw Failure("Папка или файл с таким именем уже есть.") }
            if here.link == .adb { _ = try here.shell(run, "mkdir -- " + shellQuote(remoteJoin(here.folder, name))) }
            else { _ = try here.mtp(run, "mkdir", object: here.folder, extra: [name]) }
        }, done: { self.loadRemote() })
    }

    func renameRemote() {
        guard selectedRemote.count == 1, let entry = selectedRemote.first,
              let name = ask("Переименовать «\(entry.name)»", value: entry.name, button: "Переименовать"),
              validName(name), name != entry.name else { return }
        let here = location
        job("Переименование", { run in
            guard try !here.list(run).contains(where: { $0.name == name }) else { throw Failure("Это имя уже занято.") }
            try here.rename(run, entry, name)
        }, done: { self.loadRemote() })
    }

    func deleteRemote() {
        let entries = selectedRemote
        guard !entries.isEmpty, confirm("Удалить с Android?", detail: "Будет удалено объектов: \(entries.count). Отменить удаление нельзя.", button: "Удалить") else { return }
        let here = location
        job("Удаление объектов", { run in
            for entry in entries { try here.delete(run, entry) }
        }, done: { self.loadRemote() })
    }

    func download(move: Bool = false) {
        let entries = selectedRemote
        guard connected, !entries.isEmpty else { return }
        let directory = localURL
        let collisions = entries.filter { (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent($0.name).path)) != nil }
        guard let collision = chooseCollision(collisions.map(\.name)) else { return }
        if move && !confirm("Переместить на Mac?", detail: "Android удалит исходные объекты после успешного копирования.", button: "Переместить") { return }
        let here = location
        enqueue(entries.map { entry in
            Transfer(source: entry, directory: directory, remote: here, toAndroid: false, move: move,
                     collision: collisions.contains(entry) ? collision : .reject)
        })
    }

    func upload(_ urls: [URL]? = nil, move: Bool = false, replaceEdited: Bool = false, name: String? = nil) {
        let files = urls ?? selectedLocal.map { URL(fileURLWithPath: $0.id) }
        guard canWrite, !files.isEmpty else { return }
        let names = files.map { name ?? $0.lastPathComponent }
        guard names.allSatisfy(validName), Set(names).count == names.count else {
            error = "Выбранные имена должны быть допустимыми и уникальными."
            return
        }
        let here = location, directory = localURL
        let knownCollisions = Set(remoteEntries.filter { names.contains($0.name) }.map(\.name))
        guard let collision: Collision = replaceEdited ? .replace : chooseCollision(knownCollisions.sorted()) else { return }
        if move && !confirm("Переместить на Android?", detail: "После копирования исходные файлы на Mac попадут в Корзину.", button: "Переместить") { return }
        let items = zip(files, names).map { file, name in
            let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            let entry = Entry(id: file.path, name: name, folder: info?.isDirectory == true, size: UInt64(max(0, info?.fileSize ?? 0)))
            return Transfer(source: entry, directory: directory, remote: here, toAndroid: true, move: move,
                            collision: replaceEdited || knownCollisions.contains(name) ? collision : .reject)
        }
        enqueue(items)
    }

    func openRemote(_ entry: Entry) {
        guard validName(entry.name) else { return }
        let here = location
        job("Открытие «\(entry.name)»", { run in
            let dir = try stagingDirectory()
            let file = dir.appendingPathComponent(entry.name)
            do { try here.pull(run, entry, file); return file }
            catch { try? FileManager.default.removeItem(at: dir); throw error }
        }, done: { NSWorkspace.shared.open($0) })
    }

    func editRemote() {
        guard selectedRemote.count == 1, let entry = selectedRemote.first, !entry.folder, validName(entry.name) else { return }
        let here = location
        job("Чтение «\(entry.name)»", { run in
            let dir = try stagingDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent(entry.name)
            try here.pull(run, entry, file)
            let info = try file.resourceValues(forKeys: [.fileSizeKey])
            guard (info.fileSize ?? 0) < 2_000_000 else { throw Failure("Встроенный редактор открывает текстовые файлы до 2 МБ.") }
            let value = try String(contentsOf: file, encoding: .utf8)
            guard !value.contains("\0") else { throw Failure("Редактор открывает текстовые файлы в UTF‑8.") }
            return value
        }, done: { initial in
            let alert = NSAlert()
            alert.messageText = entry.name
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: 320))
            let editor = NSTextView(frame: scroll.bounds)
            editor.isVerticallyResizable = true
            editor.autoresizingMask = .width
            editor.isRichText = false
            editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            editor.string = initial
            scroll.documentView = editor
            scroll.hasVerticalScroller = true
            alert.accessoryView = scroll
            alert.addButton(withTitle: "Сохранить на Android")
            alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn, initial != editor.string else { return }
            do {
                let file = try stagingDirectory().appendingPathComponent(entry.name)
                try editor.string.write(to: file, atomically: true, encoding: .utf8)
                self.upload([file], replaceEdited: true)
            } catch { self.error = error.localizedDescription }
        })
    }

    func changeAttributes() {
        guard adbConnected, !selectedRemote.isEmpty,
              let input = ask("Права доступа и владелец", value: selectedRemote.first?.mode ?? "644",
                              button: "Применить", detail: "Укажите режим, например 644, или режим и владельца через пробел, например 644 shell:shell.") else { return }
        let parts = input.split(whereSeparator: \.isWhitespace).map(String.init)
        guard (1...2).contains(parts.count), (3...4).contains(parts[0].count), parts[0].allSatisfy({ "01234567".contains($0) }),
              parts.count == 1 || (!parts[1].hasPrefix("-") && parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_:.-".contains($0)) }) else {
            error = "Проверьте режим и владельца."
            return
        }
        let here = location, entries = selectedRemote
        job("Изменение прав доступа", { run in
            for entry in entries {
                if parts.count == 2 { _ = try here.shell(run, "chown \(shellQuote(parts[1])) -- \(shellQuote(entry.id))") }
                _ = try here.shell(run, "chmod \(shellQuote(parts[0])) -- \(shellQuote(entry.id))")
            }
        }, done: { self.loadRemote() })
    }

    func transferWithinADB(toDevice destination: String? = nil, move: Bool) {
        guard adbConnected, !selectedRemote.isEmpty,
              let target = ask("Папка назначения на Android", value: destination == nil ? remotePath : "/sdcard", button: move ? "Переместить" : "Копировать"),
              target.hasPrefix("/") else { return }
        let here = location, entries = selectedRemote
        let other = RemoteLocation(link: .adb, serial: destination ?? serial, storage: "", folder: target, root: destination == nil && root, attributes: keepAttributes)
        job(move ? "Перемещение на Android" : "Копирование на Android", { run in
            let dir = try stagingDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let names = Set(try other.list(run).map(\.name))
            guard !entries.contains(where: { names.contains($0.name) }) else { throw Failure("В папке назначения уже есть объекты с такими именами.") }
            for entry in entries {
                if here.serial == other.serial {
                    let source = shellQuote(entry.id), dest = shellQuote(remoteJoin(target, entry.name))
                    let action = move ? "mv" : "cp -Rp"
                    _ = try here.shell(run, "\(action) -- \(source) \(dest)")
                } else {
                    let file = dir.appendingPathComponent(entry.name)
                    try here.pull(run, entry, file)
                    try other.push(run, file, name: entry.name)
                    if move { try here.delete(run, entry) }
                }
            }
        }, done: { self.loadRemote() })
    }

    func install() {
        guard adbConnected else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty, panel.urls.allSatisfy({ $0.pathExtension.lowercased() == "apk" }) else { return }
        let files = panel.urls.map(\.path)
        direct("Установка APK", args: [files.count == 1 ? "install" : "install-multiple", "-r"] + files, refresh: true)
    }

    func packageAction(_ action: String) {
        guard adbConnected, let app = selectedPackages.first else { return }
        let name = shellQuote(app.id)
        switch action {
        case "launch": direct("Запуск приложения", args: ["shell", "monkey -p \(name) -c android.intent.category.LAUNCHER 1"])
        case "stop": direct("Остановка приложения", args: ["shell", "am force-stop " + name])
        case "uninstall":
            if confirm("Удалить «\(app.id)»?", detail: "Android может удалить и локальные данные приложения.", button: "Удалить") {
                direct("Удаление приложения", args: ["uninstall", app.id], refresh: true)
            }
        case "clear":
            if confirm("Очистить данные «\(app.id)»?", detail: "Настройки и данные приложения будут удалены.", button: "Очистить") {
                direct("Очистка данных", args: ["shell", "pm clear " + name])
            }
        case "info":
            let id = serial
            job("Сведения о приложении", { try $0.shell(id, "dumpsys package " + name) }, done: {
                self.diagnostics = $0
                self.section = .diagnostics
            })
        case "export":
            guard let directory = chooseFolder() else { return }
            let id = serial, elevated = root
            job("Экспорт APK", { run in
                let paths = try run.shell(id, "pm path " + name).components(separatedBy: .newlines).filter { $0.hasPrefix("package:") }.map { String($0.dropFirst(8)) }
                guard !paths.isEmpty else { throw Failure("Android не вернул путь APK.") }
                let folder = directory.appendingPathComponent(app.id + "-" + UUID().uuidString.prefix(8))
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                do {
                    let transport = RemoteLocation(link: .adb, serial: id, storage: "", folder: "/", root: elevated, attributes: true)
                    for path in paths {
                        let file = (path as NSString).lastPathComponent
                        try transport.pull(run, Entry(id: path, name: file, folder: false), folder.appendingPathComponent(file))
                    }
                } catch { try? FileManager.default.removeItem(at: folder); throw error }
                return folder
            }, done: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
        default: break
        }
    }

    func screenshot() {
        guard adbConnected, let destination = saveURL("Android-\(Date.now.formatted(.iso8601.year().month().day())).png") else { return }
        let id = serial
        job("Снимок экрана", { run in
            let temp = try stagingDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            let file = temp.appendingPathComponent("screenshot.png")
            _ = try run.run(.adb, ["-s", id, "exec-out", "screencap", "-p"], output: file)
            let data = try Data(contentsOf: file)
            guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw Failure("Android не вернул PNG.") }
            try data.write(to: destination, options: .atomic)
        })
    }

    func bugreport() {
        guard adbConnected, let destination = saveURL("android-bugreport.zip") else { return }
        let id = serial
        job("Сохранение отчёта Android", { run in
            let dir = try stagingDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("report.zip")
            _ = try run.adb(id, ["bugreport", file.path])
            try commit(file, to: destination, replace: true)
        })
    }

    func legacyBackup(restore: Bool) {
        guard adbConnected else { return }
        let file: URL?
        if restore {
            let panel = NSOpenPanel()
            file = panel.runModal() == .OK ? panel.url : nil
        } else {
            file = saveURL("android-backup.ab")
        }
        guard let file else { return }
        let id = serial
        job(restore ? "Восстановление резервной копии" : "Резервное копирование", { run in
            if restore {
                _ = try run.adb(id, ["restore", file.path])
            } else {
                let temp = try stagingDirectory()
                defer { try? FileManager.default.removeItem(at: temp) }
                let staged = temp.appendingPathComponent("backup.ab")
                _ = try run.adb(id, ["backup", "-f", staged.path, "-apk", "-shared", "-all"])
                let bytes = try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard bytes > 24 else { throw Failure("Android не вернул резервную копию. Поддержка зависит от версии системы и приложения.") }
                try commit(staged, to: file, replace: true)
            }
        })
    }
}
