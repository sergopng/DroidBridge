import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum FilePane { case mac, android }

struct FolderBookmark: Codable, Identifiable {
    var id: UUID = UUID()
    let name: String
    let link: Link?
    let path: String
    let storage: String?
    let folders: [String]
}

extension Link: Codable {}

extension UTType {
    static let droidBridgeObject = UTType(exportedAs: "local.droidbridge.remote-object", conformingTo: .data)
}

extension Workspace {
    var bookmarkScope: [FolderBookmark] { folderBookmarks.filter { $0.link == link } }

    func bookmark(_ pane: FilePane) {
        let remote = pane == .android
        let path = remote ? breadcrumb : localURL.path
        guard let name = ask("Название закладки", value: (path as NSString).lastPathComponent, button: "Добавить"), !name.isEmpty else { return }
        folderBookmarks.append(FolderBookmark(name: name, link: remote ? link : nil, path: path,
                                              storage: remote && link == .mtp ? storages.first { $0.id == storage }?.name : nil,
                                              folders: remote ? mtpTrail.map(\.name) : []))
        saveFolderBookmarks()
    }

    func deleteBookmark(_ bookmark: FolderBookmark) {
        folderBookmarks.removeAll { $0.id == bookmark.id }
        saveFolderBookmarks()
    }

    private func saveFolderBookmarks() {
        UserDefaults.standard.set(try? JSONEncoder().encode(folderBookmarks), forKey: "folderBookmarks")
    }

    func openBookmark(_ bookmark: FolderBookmark) {
        guard let transport = bookmark.link else { loadLocal(URL(fileURLWithPath: bookmark.path)); return }
        guard transport == link, connected else { return }
        if transport == .adb { loadRemote(path: bookmark.path); return }
        guard let id = storages.first(where: { $0.name == bookmark.storage })?.id else { error = "Хранилище из закладки недоступно."; return }
        let start = RemoteLocation(link: .mtp, serial: serial, storage: id, folder: "0", root: false, attributes: false)
        job("Открытие закладки MTP", { run -> ([Entry], [Entry]) in
            var location = start
            var trail: [Entry] = []
            for name in bookmark.folders {
                guard let entry = try location.list(run).first(where: { $0.name == name && $0.folder }) else { throw Failure("Папка из закладки недоступна.") }
                trail.append(entry)
                location = location.child(entry)
            }
            return (trail, try location.list(run))
        }, done: {
            self.storage = id
            self.mtpTrail = $0.0
            self.remoteEntries = $0.1
            self.remoteSelection.removeAll()
        })
    }

    func createLocalFolder() {
        guard let name = ask("Новая папка на Mac", button: "Создать"), validName(name) else { return }
        do {
            try FileManager.default.createDirectory(at: localURL.appendingPathComponent(name), withIntermediateDirectories: false)
            loadLocal(localURL)
        } catch { self.error = error.localizedDescription }
    }

    func paneTransfer(move: Bool) {
        if activePane == .mac { upload(move: move) } else { download(move: move) }
    }

    func calculateSizes(_ pane: FilePane) {
        let entries = (pane == .mac ? selectedLocal : selectedRemote).filter(\.folder)
        guard !entries.isEmpty else { return }
        let here = location
        job("Расчёт размеров папок", { run in
            var sizes: [String: UInt64] = [:]
            for entry in entries {
                try run.check()
                if pane == .mac {
                    sizes[entry.id] = try localFolderByteCount(URL(fileURLWithPath: entry.id), run: run)
                } else {
                    func sum(_ folder: RemoteLocation, depth: Int) throws -> UInt64 {
                        guard depth < 128 else { throw Failure("Слишком глубокая вложенность папок.") }
                        var size: UInt64 = 0
                        for child in try folder.list(run) where child.target.isEmpty {
                            try run.check()
                            size += child.folder ? try sum(folder.child(child), depth: depth + 1) : child.size
                        }
                        return size
                    }
                    sizes[entry.id] = try sum(here.child(entry), depth: 0)
                }
            }
            return sizes
        }, done: { sizes in
            if pane == .mac { self.localFolderSizes.merge(sizes) { _, new in new } }
            else { self.remoteFolderSizes.merge(sizes) { _, new in new } }
        })
    }

    func dragProvider(_ entry: Entry, pane: FilePane) -> NSItemProvider {
        if pane == .mac { return NSItemProvider(object: URL(fileURLWithPath: entry.id) as NSURL) }
        let provider = NSItemProvider()
        provider.suggestedName = entry.name
        let snapshot = location
        let token = UUID().uuidString
        dragEntries[token] = (entry, snapshot)
        if dragEntries.count > 128, let oldest = dragEntries.keys.first(where: { $0 != token }) { dragEntries.removeValue(forKey: oldest) }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.droidBridgeObject.identifier, visibility: .ownProcess) { completion in
            completion(Data(token.utf8), nil)
            return nil
        }
        let fileType = entry.folder ? UTType.folder : (UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
        provider.registerFileRepresentation(forTypeIdentifier: fileType.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            let runner = Runner()
            progress.cancellationHandler = { runner.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard validName(entry.name) else { throw Failure("Недопустимое имя файла.") }
                    let dir = try stagingDirectory()
                    let file = dir.appendingPathComponent(entry.name)
                    do {
                        try snapshot.pull(runner, entry, file)
                        progress.completedUnitCount = 1
                        completion(file, false, nil)
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 600) { try? FileManager.default.removeItem(at: dir) }
                    } catch {
                        try? FileManager.default.removeItem(at: dir)
                        throw error
                    }
                } catch { completion(nil, false, error) }
            }
            return progress
        }
        return provider
    }

    func receiveRemoteDrop(_ providers: [NSItemProvider]) -> Bool {
        let matches = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.droidBridgeObject.identifier) }
        guard connected, !matches.isEmpty else { return false }
        let destination = localURL
        Task { @MainActor in
            var items: [(Entry, RemoteLocation)] = []
            for provider in matches {
                let token: String? = await withCheckedContinuation { continuation in
                    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.droidBridgeObject.identifier) { data, _ in
                        continuation.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) })
                    }
                }
                if let token, let entry = self.dragEntries.removeValue(forKey: token) { items.append(entry) }
            }
            let entries = items.map { $0.0 }
            let known = Set(entries.filter { (try? FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent($0.name).path)) != nil }.map(\.id))
            guard let choice = self.chooseCollision(entries.filter { known.contains($0.id) }.map(\.name)) else { return }
            self.enqueue(items.map { entry, location in
                Transfer(source: entry, directory: destination, remote: location, toAndroid: false, move: false,
                         collision: known.contains(entry.id) ? choice : .reject)
            })
        }
        return true
    }
}

func localFolderByteCount(_ root: URL, run: Runner) throws -> UInt64 {
    var failure: Error?
    let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, error in
        failure = error
        return false
    }) else { throw Failure("Не удалось открыть «\(root.lastPathComponent)».") }
    var size: UInt64 = 0
    for case let file as URL in walker {
        try run.check()
        let values = try file.resourceValues(forKeys: Set(keys))
        if values.isSymbolicLink == true { walker.skipDescendants() }
        else if values.isRegularFile == true { size += UInt64(max(0, values.fileSize ?? 0)) }
    }
    if let failure { throw failure }
    return size
}
