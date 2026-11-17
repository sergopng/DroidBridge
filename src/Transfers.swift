import AppKit
import SwiftUI

enum Collision: String { case replace, skip, keepBoth, reject }

enum TransferState: String {
    case waiting = "В очереди", running = "Копирование", done = "Готово", skipped = "Пропущено", failed = "Ошибка", stopped = "Остановлено"
}

struct Transfer: Identifiable {
    let id = UUID()
    let source: Entry
    let directory: URL
    let remote: RemoteLocation
    var relativeFolders: [String] = []
    let toAndroid: Bool
    let move: Bool
    let collision: Collision
    var original: Entry? = nil
    var state = TransferState.waiting
    var message = ""
    var fraction: Double? = nil
    var bytes: UInt64 = 0
    var total: UInt64 = 0
    var speed: Double = 0
    var lastSample: TimeInterval?

    var label: String { (relativeFolders + [source.name]).joined(separator: "/") }

    mutating func updateProgress(bytes reported: UInt64, total: UInt64, fraction: Double, at now: TimeInterval) {
        let current = total > 0 ? min(total, reported == 0 ? UInt64(Double(total) * fraction) : reported) : reported
        guard self.fraction == nil || fraction >= (self.fraction ?? 0) else { return }
        if let lastSample, now > lastSample, current > bytes {
            let rate = Double(current - bytes) / (now - lastSample)
            speed = speed > 0 ? speed * 0.65 + rate * 0.35 : rate
        }
        if lastSample == nil || current > bytes { lastSample = now }
        bytes = current
        self.total = total
        self.fraction = fraction
    }

    var timeRemaining: String {
        if fraction == 1 { return "Завершение…" }
        guard speed > 0, total > bytes else { return "Оцениваем время…" }
        let seconds = min(86_400, max(1, ceil(Double(total - bytes) / speed)))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute, .second] : [.second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.calendar = Calendar(identifier: .gregorian)
        return "Осталось ≈ " + (formatter.string(from: seconds) ?? "\(Int(seconds)) с")
    }
}

struct Difference: Identifiable {
    var id: String { (folders + [name]).joined(separator: "/") }
    let folders: [String]
    let name: String
    let local: Entry?
    let remote: Entry?
    let type: String
}

struct Comparison: Identifiable {
    let id = UUID()
    let directory: URL
    let remote: RemoteLocation
    let rows: [Difference]
    let matching: Int
}

extension RemoteLocation {
    func child(_ entry: Entry) -> Self {
        Self(link: link, serial: serial, storage: storage, folder: entry.id, root: root, attributes: attributes)
    }

    func resolveExisting(_ path: [String], run: Runner) throws -> Self {
        var location = self
        for name in path {
            guard let entry = try location.list(run).first(where: { $0.name == name && $0.folder && $0.target.isEmpty }) else {
                throw Failure("Исходная папка «\(name)» недоступна.")
            }
            location = location.child(entry)
        }
        return location
    }

    func resolve(_ path: [String], run: Runner) throws -> Self {
        var location = self
        for name in path {
            if let entry = try location.list(run).first(where: { $0.name == name }) {
                guard entry.folder && entry.target.isEmpty else { throw Failure("«\(name)» уже существует и не является обычной папкой.") }
                location = location.child(entry)
            } else {
                if link == .adb { _ = try location.shell(run, "mkdir -- " + shellQuote(remoteJoin(location.folder, name))) }
                else { _ = try location.mtp(run, "mkdir", object: location.folder, extra: [name]) }
                guard let entry = try location.list(run).first(where: { $0.name == name && $0.folder }) else {
                    throw Failure("Не удалось открыть созданную папку «\(name)».")
                }
                location = location.child(entry)
            }
        }
        return location
    }

    func stagedUpload(_ run: Runner, _ file: URL, name: String, replacing existing: Entry?) throws {
        let suffix = (name as NSString).pathExtension
        let extensionPart = suffix.isEmpty ? "" : "." + suffix
        if link == .mtp && existing == nil {
            try push(run, file, name: name)
            return // The MTP helper verifies the name using the new object's ID.
        }
        let temporary = (link == .adb ? ".DroidBridge-" : "DroidBridge-") + UUID().uuidString + extensionPart
        let backupName = "DroidBridge-old-" + UUID().uuidString + extensionPart
        var backup: Entry?
        var staged: Entry?
        let commit = Runner()
        do {
            try push(run, file, name: temporary)
            guard let uploaded = try list(run).first(where: { $0.name == temporary }) else { throw Failure("Android не вернул загруженный файл.") }
            staged = uploaded
            try run.check()
            if let existing {
                if link == .adb && attributes && !existing.folder && !uploaded.folder && !existing.mode.isEmpty {
                    if root && !existing.owner.isEmpty && !existing.group.isEmpty {
                        _ = try shell(run, "chown \(shellQuote(existing.owner + ":" + existing.group)) -- \(shellQuote(uploaded.id))")
                    }
                    _ = try shell(run, "chmod \(shellQuote(existing.mode)) -- \(shellQuote(uploaded.id))")
                }
                try rename(commit, existing, backupName)
                backup = link == .adb ? Entry(id: remoteJoin(folder, backupName), name: backupName, folder: existing.folder) : existing
            }
            try rename(commit, uploaded, name)
            if link == .mtp {
                let actual = try list(commit).first(where: { $0.id == uploaded.id })?.name
                guard actual == name else { throw Failure("Телефон не сохранил имя «\(name)». Файл не заменён.") }
            }
        } catch {
            if link == .mtp, let staged { try? delete(commit, staged) }
            else if let remaining = try? list(commit).first(where: { $0.name == temporary }) { try? delete(commit, remaining) }
            if let backup { try? rename(commit, backup, name) }
            throw error
        }
        if let backup { try? delete(commit, backup) }
    }
}

extension Transfer {
    func perform(_ run: Runner) throws -> (TransferState, String?) {
        guard validName(source.name), relativeFolders.allSatisfy(validName) else { throw Failure("Недопустимое имя файла.") }
        let fm = FileManager.default
        let localFolder = relativeFolders.reduce(directory) { $0.appendingPathComponent($1, isDirectory: true) }
        if toAndroid {
            let destination = try remote.resolve(relativeFolders, run: run)
            let listing = try destination.list(run)
            let existing = listing.first { $0.name == source.name }
            if let original, existing != original { throw Failure("Файл на Android изменился. Сравните папки ещё раз.") }
            guard let name = try destinationName(existing: existing != nil, occupied: { name in listing.contains { $0.name == name } }) else { return (.skipped, nil) }
            try destination.stagedUpload(run, URL(fileURLWithPath: source.id), name: name, replacing: name == source.name ? existing : nil)
            if move { try fm.trashItem(at: URL(fileURLWithPath: source.id), resultingItemURL: nil) }
            return (.done, name)
        } else {
            try fm.createDirectory(at: localFolder, withIntermediateDirectories: true)
            let originalTarget = localFolder.appendingPathComponent(source.name)
            let exists = (try? fm.attributesOfItem(atPath: originalTarget.path)) != nil
            if remote.link == .mtp {
                let origin = try remote.resolveExisting(relativeFolders, run: run)
                guard try origin.list(run).contains(where: { $0.id == source.id && $0.name == source.name && $0.folder == source.folder }) else {
                    throw Failure("Объект MTP изменился. Обновите папку и повторите.")
                }
            }
            if let original, try !Entry.local(localFolder).contains(original) { throw Failure("Файл на Mac изменился. Сравните папки ещё раз.") }
            guard let name = try destinationName(existing: exists, occupied: {
                (try? fm.attributesOfItem(atPath: localFolder.appendingPathComponent($0).path)) != nil
            }) else { return (.skipped, nil) }
            let staging = localFolder.appendingPathComponent(".DroidBridge-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: staging) }
            let file = staging.appendingPathComponent(name)
            try remote.pull(run, source, file)
            try run.check()
            try commit(file, to: localFolder.appendingPathComponent(name), replace: exists && name == source.name)
            if move { try remote.delete(Runner(), source) }
            return (.done, name)
        }
    }

    fileprivate func expectedTransferBytes(_ run: Runner) throws -> UInt64 {
        guard source.folder else { return source.size }
        guard toAndroid else { return 0 }
        return try localFolderByteCount(URL(fileURLWithPath: source.id), run: run)
    }

    private func destinationName(existing: Bool, occupied: (String) -> Bool) throws -> String? {
        guard existing else { return source.name }
        switch collision {
        case .replace: return source.name
        case .skip: return nil
        case .reject: throw Failure("«\(source.name)» уже существует.")
        case .keepBoth:
            let suffix = source.folder ? "" : (source.name as NSString).pathExtension
            let stem = suffix.isEmpty ? source.name : (source.name as NSString).deletingPathExtension
            for number in 2...10_000 {
                let name = "\(stem) (\(number))" + (suffix.isEmpty ? "" : "." + suffix)
                if !occupied(name) { return name }
            }
            throw Failure("Не удалось подобрать свободное имя.")
        }
    }
}

extension Workspace {
    func enqueue(_ items: [Transfer]) {
        guard !items.isEmpty else { return }
        transfers.append(contentsOf: items)
        runNextTransfer()
    }

    func runNextTransfer() {
        guard !shuttingDown, busy == nil, let index = transfers.firstIndex(where: { $0.state == .waiting }) else { return }
        transfers[index].state = .running
        let item = transfers[index]
        job(item.toAndroid ? "На Android · \(item.label)" : "На Mac · \(item.label)", { run in
            let expected = try item.expectedTransferBytes(run)
            run.transferExpectedBytes = expected
            run.transferProgress = { bytes, total, fraction in
                let now = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async {
                    guard let index = self.transfers.firstIndex(where: { $0.id == item.id && $0.state == .running }) else { return }
                    self.transfers[index].updateProgress(bytes: bytes, total: total == 0 ? expected : total, fraction: fraction, at: now)
                }
            }
            return try item.perform(run)
        }, done: { state, name in
            let message = name.flatMap { $0 == item.source.name ? nil : "Сохранено как «\($0)»" } ?? ""
            self.finishTransfer(item, state: state, message: message)
        }, failed: { error in
            self.finishTransfer(item, state: error.localizedDescription == "Операция остановлена." ? .stopped : .failed, message: error.localizedDescription)
        })
    }

    func finishTransfer(_ item: Transfer, state: TransferState, message: String = "") {
        if let index = transfers.firstIndex(where: { $0.id == item.id }) {
            transfers[index].state = state
            transfers[index].message = message
            if state == .done { transfers[index].fraction = 1 }
        }
        guard !shuttingDown else { return }
        guard !transfers.contains(where: { $0.state == .waiting }) else { runNextTransfer(); return }
        loadLocal(localURL)
        if connected, section == .files { loadRemote() }
    }

    func retryTransfer(_ id: UUID) {
        guard let i = transfers.firstIndex(where: { $0.id == id && [.failed, .stopped].contains($0.state) }) else { return }
        transfers[i].state = .waiting
        transfers[i].message = ""
        transfers[i].fraction = nil
        transfers[i].bytes = 0
        transfers[i].total = 0
        transfers[i].speed = 0
        transfers[i].lastSample = nil
        runNextTransfer()
    }

    func chooseCollision(_ names: [String]) -> Collision? {
        guard !names.isEmpty else { return .reject }
        let alert = NSAlert()
        alert.messageText = "В папке назначения уже есть объекты с такими именами"
        alert.informativeText = names.prefix(8).joined(separator: "\n") + "\n\nЕсли сохранить обе версии, новый файл получит номер в имени."
        alert.addButton(withTitle: "Сохранить обе версии").keyEquivalent = ""
        alert.addButton(withTitle: "Пропустить")
        alert.addButton(withTitle: "Заменить")
        let cancel = alert.addButton(withTitle: "Отмена")
        cancel.keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .keepBoth
        case .alertSecondButtonReturn: return .skip
        case .alertThirdButtonReturn: return .replace
        default: return nil
        }
    }

    func compareFolders() {
        guard canWrite else { return }
        let directory = localURL, remote = location, hidden = showHidden
        job("Сравнение папок", { run in
            var rows: [Difference] = []
            var matching = 0
            func scan(_ mac: URL, _ android: RemoteLocation, _ folders: [String]) throws {
                try run.check()
                guard folders.count < 128 else { throw Failure("Слишком глубокая вложенность папок.") }
                let left = Dictionary(grouping: try Entry.local(mac).filter { hidden || !$0.name.hasPrefix(".") }, by: \.name)
                let right = Dictionary(grouping: try android.list(run).filter { hidden || !$0.name.hasPrefix(".") }, by: \.name)
                for name in Set(left.keys).union(right.keys).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                    guard validName(name) else { continue }
                    let l = left[name]?.first, r = right[name]?.first
                    let type: String
                    if (left[name]?.count ?? 0) > 1 || (right[name]?.count ?? 0) > 1 { type = "Несколько объектов с одним именем" }
                    else if l == nil { type = "Только Android" }
                    else if r == nil { type = "Только Mac" }
                    else if let l, let r, l.folder && r.folder && r.target.isEmpty,
                            (try? mac.appendingPathComponent(name).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
                        try scan(mac.appendingPathComponent(name), android.child(r), folders + [name])
                        continue
                    } else if l?.folder != r?.folder || l?.folder == true { type = "Разные типы или ссылки" }
                    else if let l, let r, l.size == r.size, let ld = l.date, let rd = r.date, abs(ld.timeIntervalSince(rd)) <= 2 {
                        matching += 1
                        continue
                    } else { type = "Отличаются" }
                    rows.append(Difference(folders: folders, name: name, local: l, remote: r, type: type))
                }
            }
            try scan(directory, remote, [])
            return Comparison(directory: directory, remote: remote, rows: rows, matching: matching)
        }, done: { self.comparison = $0 })
    }

    func synchronize(_ comparison: Comparison, selection: Set<String>, toAndroid: Bool) {
        let rows = comparison.rows.filter { selection.contains($0.id) && $0.type != "Разные типы или ссылки" && $0.type != "Несколько объектов с одним именем" }
        let conflicts = rows.filter { $0.local != nil && $0.remote != nil }.map(\.id)
        guard let collision = chooseCollision(conflicts) else { return }
        let items = rows.compactMap { row -> Transfer? in
            guard let entry = toAndroid ? row.local : row.remote else { return nil }
            return Transfer(source: entry, directory: comparison.directory, remote: comparison.remote, relativeFolders: row.folders,
                            toAndroid: toAndroid, move: false, collision: collision, original: toAndroid ? row.remote : row.local)
        }
        self.comparison = nil
        enqueue(items)
    }
}

struct TransferProgressBar: View {
    let item: Transfer

    var body: some View {
        HStack(spacing: 10) {
            if let fraction = item.fraction {
                ProgressView(value: fraction)
                    .accessibilityLabel("Прогресс передачи")
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            } else {
                ProgressView().progressViewStyle(.linear).accessibilityLabel("Прогресс передачи")
            }
            Text(item.timeRemaining).monospacedDigit().fixedSize()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .tint(BridgeAppearance.accent)
    }
}

struct TransferList: View {
    @ObservedObject var model: Workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Очередь передач").font(.system(size: 17, weight: .medium))
            List(model.transfers) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(item.label, systemImage: item.toAndroid ? "arrow.right" : "arrow.left").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(item.state.rawValue).font(.system(size: 12)).foregroundStyle(.secondary)
                        if [.failed, .stopped].contains(item.state) { Button("Повторить") { model.retryTransfer(item.id) } }
                        if item.state == .waiting {
                            Button("Убрать") { model.transfers.removeAll { $0.id == item.id && $0.state == .waiting } }
                        }
                    }
                    if item.state == .running {
                        TransferProgressBar(item: item)
                    }
                    if !item.message.isEmpty { Text(item.message).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).lineLimit(4) }
                }.padding(.vertical, 4)
            }.overlay { if model.transfers.isEmpty { Text("Очередь пуста").foregroundStyle(.secondary) } }
            HStack {
                Button("Убрать завершённые") { model.transfers.removeAll { [.done, .skipped].contains($0.state) } }
                if model.transfers.contains(where: { $0.state == .running }) { Button("Остановить текущую") { model.cancel() } }
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 672, height: 448).tint(BridgeAppearance.accent)
    }
}

struct ComparisonView: View {
    @ObservedObject var model: Workspace
    let comparison: Comparison
    @State private var selection = Set<String>()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Сравнение папок").font(.system(size: 17, weight: .medium))
            Text("\(comparison.matching) совпадений по размеру и времени · \(comparison.rows.count) различий")
                .foregroundStyle(.secondary)
            Table(comparison.rows, selection: $selection) {
                TableColumn("Путь") { Text($0.id).truncationMode(.middle).help($0.id) }
                TableColumn("Состояние") { Text($0.type) }.width(min: 180, ideal: 220)
            }
            HStack {
                Button("Выбрать всё") { selection = Set(comparison.rows.map(\.id)) }.disabled(comparison.rows.isEmpty)
                Spacer()
                Button("На Mac") { model.synchronize(comparison, selection: selection, toAndroid: false) }
                    .disabled(!canCopy(toAndroid: false))
                Button("На Android") { model.synchronize(comparison, selection: selection, toAndroid: true) }
                    .disabled(!canCopy(toAndroid: true))
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 720, height: 480).tint(BridgeAppearance.accent)
    }

    private func canCopy(toAndroid: Bool) -> Bool {
        comparison.rows.contains { row in
            selection.contains(row.id) && ["Отличаются", "Только Mac", "Только Android"].contains(row.type) &&
                (toAndroid ? row.local != nil : row.remote != nil)
        }
    }
}
