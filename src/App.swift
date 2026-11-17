import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main struct DroidBridgeApp: App {
    @StateObject private var model = Workspace()
    @NSApplicationDelegateAdaptor(DroidBridgeDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("DroidBridge", id: "main") {
            MainView(model: model)
                .frame(minWidth: 850, minHeight: 560)
                .task {
                    delegate.model = model
                    model.launch()
                }
        }
        .defaultSize(width: 1200, height: 740)
        .commands {
            CommandMenu("Устройство") {
                Button("Обновить устройства") {
                    if model.section == .fastboot { model.refreshFastboot() } else { model.refreshDevices() }
                }.keyboardShortcut("r")
                Button("Fastboot") { model.openFastboot() }.disabled(model.busy != nil)
                Button("ADB") { model.switchLink(.adb) }
                Button("MTP") { model.switchLink(.mtp) }
                Divider()
                Button("Переименовать устройство") { model.namedDevice() }.disabled(model.device == nil)
                Button("Остановить операцию") { model.cancel() }.disabled(model.busy == nil)
            }
            CommandMenu("Передача") {
                Button("Копировать из активной панели") { model.paneTransfer(move: false) }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(0xF708)!)), modifiers: [])
                    .disabled(model.section != .files || !model.canWrite)
                Button("Переместить из активной панели") { model.paneTransfer(move: true) }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(0xF709)!)), modifiers: [])
                    .disabled(model.section != .files || !model.canWrite)
                Button("Создать папку в активной панели") {
                    if model.activePane == .mac { model.createLocalFolder() } else { model.createFolder() }
                }.keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(0xF70A)!)), modifiers: [])
                    .disabled(model.section != .files || model.busy != nil || (model.activePane == .android && !model.canWrite))
                Button("Очередь передач") { model.showTransfers = true }.keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Копировать на Android") { model.upload() }.keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                    .disabled(!model.canWrite || model.selectedLocal.isEmpty)
                Button("Копировать на Mac") { model.download() }.keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                    .disabled(model.selectedRemote.isEmpty)
                Button("Новая папка на Android") { model.createFolder() }.keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.busy != nil || !model.canWrite)
            }
        }
        Settings {
            TabView {
                Form {
                Toggle("Показывать скрытые файлы", isOn: Binding(
                    get: { model.showHidden },
                    set: { model.showHidden = $0; UserDefaults.standard.set($0, forKey: "showHidden") }))
                Toggle("Сохранять права и время при скачивании по ADB", isOn: Binding(
                    get: { model.keepAttributes },
                    set: { model.keepAttributes = $0; UserDefaults.standard.set($0, forKey: "keepAttributes") }))
                Toggle("Записывать журнал операций на Mac", isOn: Binding(
                    get: { model.debugLog },
                    set: { model.debugLog = $0; UserDefaults.standard.set($0, forKey: "debugLog") }))
                ToolSettings(model: model)
                }.formStyle(.grouped)
                    .tabItem { Label("Основные", systemImage: "gearshape") }
                ScrcpySettings(model: model)
                    .tabItem { Label("scrcpy", systemImage: "macwindow") }
            }.frame(width: 790, height: 540)
        }
    }
}

@MainActor final class DroidBridgeDelegate: NSObject, NSApplicationDelegate {
    weak var model: Workspace?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.shuttingDown { return .terminateLater }
        model.prepareToQuit()
        Task { @MainActor in
            let forceStopAt = ContinuousClock.now + .seconds(5)
            var forced = false
            while !model.readyToQuit {
                if !forced && ContinuousClock.now >= forceStopAt {
                    forced = true
                    model.forceStopStreams()
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            await Task.detached { ADBSession.shared.close() }.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MainView: View {
    @ObservedObject var model: Workspace
    @State private var searchLocal = ""
    @State private var searchRemote = ""
    @State private var searchApps = ""
    @State private var showConnect = false
    @State private var activeDrop = false
    @State private var diagnosticTab = "Вывод"
    @State private var appSort = [KeyPathComparator<Package>(\.id)]
    @State private var localDrop = false
    @State private var historyIndex = -1
    @FocusState private var focusedPane: FilePane?

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            Divider()
            navigation
            Divider()
            if let error = model.error {
                HStack(alignment: .top, spacing: 10) {
                    BridgeSymbol("exclamationmark.circle").foregroundStyle(BridgeAppearance.alert)
                    ScrollView {
                        Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 68)
                    Button { model.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Закрыть сообщение")
                }
                 .padding(.horizontal, 16).padding(.vertical, 8)
                .background(BridgeAppearance.alert.opacity(0.08))
                Divider()
            }
            Group {
                switch model.section {
                case .files: files
                case .apps: apps
                case .shell: shell
                case .diagnostics: diagnostics
                case .fastboot: FastbootView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .background(BridgeAppearance.chrome)
        .sheet(isPresented: $showConnect) { ConnectSheet(model: model) }
        .sheet(isPresented: $model.showTransfers) { TransferList(model: model) }
        .sheet(item: $model.comparison) { ComparisonView(model: model, comparison: $0) }
        .onChange(of: focusedPane) { _, value in if let value { model.activePane = value } }
    }

    private var connectionBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                BridgeSymbol("arrow.left.arrow.right").foregroundStyle(.secondary)
                Text("DroidBridge").font(.system(size: 17, weight: .semibold))
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if model.section == .fastboot {
                Text("Fastboot по USB").foregroundStyle(.secondary)
            } else {
                androidConnectionControls
            }
        }.padding(.horizontal, 20).padding(.vertical, 8)
    }

    @ViewBuilder private var androidConnectionControls: some View {
        Picker("Способ подключения", selection: Binding(get: { model.link }, set: { model.switchLink($0) })) {
            ForEach(Link.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).tint(BridgeAppearance.accent).labelsHidden().frame(width: 112).disabled(model.busy != nil)
        Divider().frame(height: 24)
        Menu {
            if model.devices.isEmpty { Text("Устройства не найдены") }
            ForEach(model.devices) { device in
                Button {
                    model.selectDevice(device.id)
                } label: {
                    Label(model.aliases[device.id] ?? device.name, systemImage: device.id == model.serial ? "checkmark" : "smartphone")
                }.help(device.id + " · " + device.state)
            }
            Divider()
            Button("Обновить список") { model.refreshDevices() }
            if model.link == .mtp, let openMTP = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.ganeshrvel.openmtp") {
                Button("Открыть OpenMTP") { NSWorkspace.shared.open(openMTP) }
            }
            Button("Переименовать…") { model.namedDevice() }.disabled(model.device == nil)
            if model.link == .adb {
                Button("Отключить Wi‑Fi ADB") {
                    let id = model.serial
                    model.job("Отключение Wi‑Fi", { try $0.text(.adb, ["disconnect", id]) }, done: { _ in model.refreshDevices() })
                }.disabled(!model.serial.contains(":"))
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.connected ? BridgeAppearance.accent : Color.secondary)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(model.device == nil ? "Устройство" : model.deviceName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .accessibilityLabel(model.device == nil ? "Выбрать устройство" : model.deviceName)
            .accessibilityValue(model.connected ? "Подключено" : "Нет подключения")
        }
        .frame(maxWidth: 232, alignment: .trailing)
        .disabled(model.busy != nil)
        iconButton("Обновить устройства", "arrow.clockwise") { model.refreshDevices() }.disabled(model.busy != nil)
        if model.link == .adb {
            Button("Wi‑Fi") { showConnect = true }
                .disabled(model.busy != nil)
        }
    }

    private var navigation: some View {
        HStack(spacing: 8) {
            ForEach(model.link == .adb ? Section.allCases : [.files, .fastboot]) { section in
                Button {
                    let wasFastboot = model.section == .fastboot
                    model.section = section
                    if wasFastboot && section != .fastboot { model.refreshDevices() }
                    else { model.refreshCurrent() }
                } label: {
                    Text(section.rawValue)
                }
                .buttonStyle(BridgeAction(kind: model.section == section ? .selected : .quiet))
                .accessibilityAddTraits(model.section == section ? .isSelected : [])
                .disabled(model.busy != nil)
            }
            Spacer()
            if model.section == .files {
                Button { model.compareFolders() } label: { Text("Сравнить папки") }
                    .disabled(!model.canWrite || model.busy != nil)
                Button { model.showTransfers = true } label: {
                    let count = model.transfers.filter { $0.state == .waiting || $0.state == .running }.count
                    Text(count == 0 ? "Очередь" : "Очередь · \(count)").monospacedDigit()
                }
            }
            if model.link == .adb && model.section != .fastboot {
                Menu {
                    Button("Запустить scrcpy") { model.mirror(record: false) }.disabled(model.mirrorRunning || !model.canLaunchScrcpy)
                    SettingsLink { Text("Настройки scrcpy…") }
                    Button("Записать видео…") { model.mirror(record: true) }.disabled(model.mirrorRunning || !model.canLaunchScrcpy)
                    Button("Закрыть экран / завершить запись") { model.stopMirror() }.disabled(!model.mirrorRunning)
                    Divider()
                    Button("Буфер Mac → Android") { model.clipboard(toAndroid: true) }.disabled(model.busy != nil || !model.adbConnected)
                    Button("Буфер Android → Mac") { model.clipboard(toAndroid: false) }.disabled(model.busy != nil || !model.adbConnected)
                } label: { Label("Экран", systemImage: "macwindow") }
                    .fixedSize()
            }
            if model.adbConnected && model.section != .fastboot {
                Toggle("Root (su)", isOn: Binding(get: { model.root }, set: {
                    model.root = $0
                    model.refreshCurrent()
                })).toggleStyle(.checkbox).disabled(model.busy != nil)
                    .help("Выполнять файловые и диагностические команды через su")
                Menu {
                    Button("Перезагрузить") { power("reboot", ["reboot"]) }
                    Button("Recovery") { power("recovery", ["reboot", "recovery"]) }
                    Button("Bootloader / Fastboot") { model.rebootADBToFastboot() }
                    Button("Download") { power("download", ["reboot", "download"]) }
                    Button("Быстрая перезагрузка (root)") { power("hot reboot", ["shell", "su -c 'setprop ctl.restart zygote'"]) }
                    Button("Выключить") { power("выключение", ["shell", "reboot -p"]) }
                    Divider()
                    Button("adb remount") {
                        if confirm("Перемонтировать системные разделы?", detail: "Операция доступна на поддерживаемых Android-сборках.", button: "Перемонтировать") {
                            model.direct("Перемонтирование разделов", args: ["remount"])
                        }
                    }
                } label: { Label("Питание", systemImage: "power") }
                    .fixedSize().disabled(model.busy != nil)
            }
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func power(_ action: String, _ args: [String]) {
        if confirm("Выполнить \(action)?", detail: model.deviceName, button: "Продолжить") {
            model.direct("Питание Android", args: args)
        }
    }

    private var files: some View {
        HSplitView {
            localPane.frame(minWidth: 312, idealWidth: 512, maxWidth: .infinity)
            remotePane.frame(minWidth: 416, idealWidth: 600, maxWidth: .infinity)
        }.onKeyPress(.tab) {
            guard focusedPane != nil, model.connected else { return .ignored }
            focusedPane = model.activePane == .mac ? .android : .mac
            return .handled
        }
    }

    private var localPane: some View {
        VStack(spacing: 0) {
            paneHeader("Mac", "laptopcomputer", active: model.activePane == .mac) {
                bookmarkMenu(.mac)
                iconButton("Рассчитать размер папок Mac", "scalemass") { model.calculateSizes(.mac) }
                    .disabled(model.busy != nil || !model.selectedLocal.contains(where: \.folder))
                iconButton("Выбрать папку Mac", "folder") { if let url = chooseFolder() { model.loadLocal(url) } }
                iconButton("Показать в Finder", "arrow.up.forward.app") { NSWorkspace.shared.open(model.localURL) }
            }
            HStack(spacing: 8) {
                iconButton("Родительская папка Mac", "arrow.up") {
                    model.loadLocal(model.localURL.deletingLastPathComponent())
                }.disabled(model.localURL.path == "/" || model.busy != nil)
                pathText(model.localURL.path, label: "Путь на Mac") {
                    if let path = ask("Перейти к папке на Mac", value: model.localURL.path) {
                        model.loadLocal(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                    }
                }
                iconButton("Обновить папку Mac", "arrow.clockwise") { model.loadLocal(model.localURL) }
            }.padding(.horizontal, 16).padding(.bottom, 8)
            filterField("Поиск по имени", label: "Поиск в папке Mac", text: $searchLocal)
            Divider()
            FileTable(entries: filtered(model.localEntries, searchLocal), sizes: model.localFolderSizes, selection: $model.localSelection, metadata: false,
                      drag: { model.dragProvider($0, pane: .mac) }, open: { entry in
                if entry.folder { model.loadLocal(URL(fileURLWithPath: entry.id)) }
                else { NSWorkspace.shared.open(URL(fileURLWithPath: entry.id)) }
            })
            .focused($focusedPane, equals: .mac)
            .onChange(of: model.localSelection) { if !model.localSelection.isEmpty { model.activePane = .mac } }
            .overlay { dropOutline(localDrop) }
            .onDrop(of: [.droidBridgeObject], isTargeted: $localDrop) { model.receiveRemoteDrop($0) }
            .overlay {
                if filtered(model.localEntries, searchLocal).isEmpty {
                    Text(searchLocal.isEmpty ? "Нет видимых файлов" : "Совпадений нет")
                        .foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            .contextMenu {
                Button("Открыть") { openLocal() }.disabled(model.selectedLocal.count != 1)
                Button("Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(model.selectedLocal.map { URL(fileURLWithPath: $0.id) })
                }.disabled(model.selectedLocal.isEmpty)
                Divider()
                Button("Копировать на Android") { model.upload() }.disabled(model.selectedLocal.isEmpty || !model.canWrite)
                Button("Переместить на Android…") { model.upload(move: true) }.disabled(model.selectedLocal.isEmpty || !model.canWrite)
            }
            Divider()
            HStack {
                selectionText(model.localEntries.count, model.localSelection.count)
                Spacer()
                Button { model.upload() } label: { Label("На Android", systemImage: "arrow.right") }
                    .buttonStyle(BridgeAction(kind: model.activePane == .mac ? .transfer : .selected))
                    .disabled(model.selectedLocal.isEmpty || !model.canWrite)
            }.padding(.horizontal, 16).frame(height: 48)
        }
    }

    private var remotePane: some View {
        VStack(spacing: 0) {
            paneHeader("Android", "smartphone", active: model.activePane == .android) {
                if model.link == .mtp && !model.storages.isEmpty {
                    Picker("Хранилище Android", selection: Binding(get: { model.storage }, set: { model.changeStorage($0) })) {
                        ForEach(model.storages) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: 190).disabled(model.busy != nil)
                }
                iconButton("Рассчитать размер папок Android", "scalemass") { model.calculateSizes(.android) }
                    .disabled(model.busy != nil || !model.selectedRemote.contains(where: \.folder))
                iconButton("Новая папка Android", "folder.badge.plus") { model.createFolder() }
                    .disabled(!model.canWrite || model.busy != nil)
                Menu {
                    Button("Открыть") { if let entry = model.selectedRemote.first { model.enter(entry) } }
                        .disabled(model.selectedRemote.count != 1)
                    Button("Редактировать текст…") { model.editRemote() }
                        .disabled(model.selectedRemote.count != 1 || model.selectedRemote.first?.folder == true)
                    Button("Переименовать…") { model.renameRemote() }.disabled(model.selectedRemote.count != 1)
                    Button("Свойства") { properties() }.disabled(model.selectedRemote.count != 1)
                    Divider()
                    Button("Переместить на Mac…") { model.download(move: true) }.disabled(model.selectedRemote.isEmpty)
                    if model.link == .adb {
                        Button("Копировать в папку Android…") { model.transferWithinADB(move: false) }.disabled(model.selectedRemote.isEmpty)
                        Button("Переместить в папку Android…") { model.transferWithinADB(move: true) }.disabled(model.selectedRemote.isEmpty)
                        ForEach(model.devices.filter { $0.online && $0.id != model.serial }) { device in
                            Button("Копировать на \(model.aliases[device.id] ?? device.name)…") { model.transferWithinADB(toDevice: device.id, move: false) }
                                .disabled(model.selectedRemote.isEmpty)
                            Button("Переместить на \(model.aliases[device.id] ?? device.name)…") { model.transferWithinADB(toDevice: device.id, move: true) }
                                .disabled(model.selectedRemote.isEmpty)
                        }
                        Button("Права доступа…") { model.changeAttributes() }.disabled(model.selectedRemote.isEmpty)
                    }
                    Divider()
                    Button("Удалить…", role: .destructive) { model.deleteRemote() }.disabled(model.selectedRemote.isEmpty || model.busy != nil)
                } label: { Image(systemName: "ellipsis").accessibilityLabel("Действия с файлами Android") }
                    .help("Действия с файлами Android")
                    .fixedSize().disabled(!model.canWrite || model.busy != nil)
            }
            if model.connected {
                HStack(spacing: 8) {
                    iconButton("Родительская папка Android", "arrow.up") { model.up() }
                        .disabled(model.breadcrumb == "/" || model.busy != nil)
                    pathText(model.breadcrumb, label: "Путь на Android") {
                        if model.link == .adb, let path = ask("Перейти к папке Android", value: model.remotePath), path.hasPrefix("/") {
                            model.loadRemote(path: path)
                        }
                    }.disabled(model.link == .mtp || model.busy != nil)
                    bookmarkMenu(.android).disabled(model.busy != nil)
                    iconButton("Обновить папку Android", "arrow.clockwise") { model.refreshCurrent() }.disabled(model.busy != nil)
                }.padding(.horizontal, 16).padding(.bottom, 8)
                filterField("Поиск по имени", label: "Поиск в папке Android", text: $searchRemote)
                Divider()
                FileTable(entries: filtered(model.remoteEntries, searchRemote), sizes: model.remoteFolderSizes,
                          selection: $model.remoteSelection, metadata: model.link == .adb, drag: { model.dragProvider($0, pane: .android) }, open: {
                    if model.busy == nil { model.enter($0) }
                })
                .focused($focusedPane, equals: .android)
                .onChange(of: model.remoteSelection) { if !model.remoteSelection.isEmpty { model.activePane = .android } }
                .overlay {
                    if filtered(model.remoteEntries, searchRemote).isEmpty && model.busy == nil {
                        Text(searchRemote.isEmpty ? "Нет видимых файлов" : "Совпадений нет")
                            .foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
                .contextMenu {
                    Button("Копировать на Mac") { model.download() }.disabled(model.selectedRemote.isEmpty)
                    Button("Переименовать…") { model.renameRemote() }.disabled(model.selectedRemote.count != 1 || model.busy != nil)
                    Button("Редактировать текст…") { model.editRemote() }.disabled(model.selectedRemote.count != 1 || model.busy != nil)
                    Button("Свойства") { properties() }.disabled(model.selectedRemote.count != 1)
                    Button("Удалить…", role: .destructive) { model.deleteRemote() }.disabled(model.selectedRemote.isEmpty || model.busy != nil)
                }
                .overlay { dropOutline(activeDrop) }
                .onDrop(of: [UTType.fileURL], isTargeted: $activeDrop) { providers in
                    guard model.canWrite, !providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.droidBridgeObject.identifier) }) else { return false }
                    Task { @MainActor in
                        var urls: [URL] = []
                        for provider in providers {
                            let value: URL? = await withCheckedContinuation { continuation in
                                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                            }
                            if let value, value.isFileURL { urls.append(value) }
                        }
                        model.upload(urls)
                    }
                    return true
                }
            } else { connectionHint }
            Divider()
            HStack {
                selectionText(model.remoteEntries.count, model.remoteSelection.count)
                if model.link == .mtp, let storage = model.storages.first(where: { $0.id == model.storage }), storage.free < UInt64.max {
                    Text("· \(bytes(storage.free)) свободно").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.download() } label: { Label("На Mac", systemImage: "arrow.left") }
                    .buttonStyle(BridgeAction(kind: model.activePane == .android ? .transfer : .selected))
                    .disabled(model.selectedRemote.isEmpty)
            }.padding(.horizontal, 16).frame(height: 48)
        }
    }

    private var connectionHint: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                BridgeSymbol("laptopcomputer")
                Capsule().fill(BridgeAppearance.rule).frame(width: 36, height: 2)
                BridgeSymbol("cable.connector")
                Capsule().fill(BridgeAppearance.rule).frame(width: 36, height: 2)
                BridgeSymbol("smartphone")
            }
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
            .accessibilityHidden(true)
            Text(model.device?.state == "unauthorized" ? "Разрешите отладку на телефоне" : "Подключите Android")
                .font(.system(size: 17, weight: .medium))
            Text(model.link == .mtp
                 ? "Подключите кабель и выберите «Передача файлов» в настройках USB на телефоне. Если запущен OpenMTP, закройте его через ⌘Q."
                 : "Подключите кабель и подтвердите отладку по USB на телефоне или выберите Wi‑Fi в верхней панели.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 284)
            Button("Обновить устройства") { model.refreshDevices() }.disabled(model.busy != nil)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BridgeAppearance.surface)
    }

    private var apps: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Имя или пакет", text: $searchApps).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Picker("Тип", selection: $model.packageFilter) {
                    Text("Все").tag("")
                    Text("Пользовательские").tag("-3")
                    Text("Системные").tag("-s")
                }.fixedSize().onChange(of: model.packageFilter) { model.loadPackages() }
                Spacer()
                Button { model.loadPackages() } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                if !model.helperAvailable {
                    Button("Имена и иконки…") { model.withHelper { model.loadPackages() } }
                }
                Button { model.install() } label: { Label("Установить APK…", systemImage: "plus.app") }
                    .buttonStyle(.borderedProminent)
            }.padding(16).disabled(!model.adbConnected || model.busy != nil)
            if model.adbConnected {
                Table(appRows, selection: $model.packageSelection, sortOrder: $appSort) {
                    TableColumn("Приложение", value: \.name) { row in
                        HStack {
                            if let icon = model.appIcons[row.id] {
                                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "app").frame(width: 20, height: 20)
                            }
                            Text(row.name)
                        }.task(id: model.helperAvailable) { model.loadIcon(row) }
                    }.width(min: 160, ideal: 230)
                    TableColumn("Версия", value: \.version).width(min: 65, ideal: 100)
                    TableColumn("Пакет", value: \.id).width(min: 150, ideal: 285)
                    TableColumn("Путь APK", value: \.path) { Text($0.path).lineLimit(1).truncationMode(.middle).help($0.path) }
                }
                Divider()
                HStack {
                    Text("Пакетов · \(model.packages.count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("Запустить") { model.packageAction("launch") }
                    Button("Остановить") { model.packageAction("stop") }
                    Button("Сведения") { model.packageAction("info") }
                    Button("Экспорт APK…") { model.packageAction("export") }
                    Menu("Ещё") {
                        Button("Ярлык на главный экран…") { model.pinShortcut() }
                        Button("Открыть Logcat для приложения") {
                            if let package = model.selectedPackages.first {
                                model.logFilter = package.id
                                model.section = .diagnostics
                                diagnosticTab = "Вывод"
                                model.startLog()
                            }
                        }
                        Button("Очистить данные…", role: .destructive) { model.packageAction("clear") }
                        Button("Удалить приложение…", role: .destructive) { model.packageAction("uninstall") }
                    }.fixedSize()
                }.padding(12).disabled(model.selectedPackages.count != 1 || model.busy != nil)
            } else { connectionHint }
        }
    }

    private var shell: some View {
        VStack(spacing: 0) {
            paneHeader("ADB Shell", "terminal") {
                Button("Открыть в Терминале") { model.interactiveShell() }.disabled(!model.adbConnected)
                Menu("Команды") {
                    Button("Сохранить введённую команду") { model.saveShellCommand() }
                        .disabled(model.consoleCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(model.savedCommands, id: \.self) { command in
                        Button(command) { model.consoleCommand = command }
                    }
                    if !model.savedCommands.isEmpty {
                        Menu("Удалить сохранённую команду") {
                            ForEach(model.savedCommands, id: \.self) { command in
                                Button(command) { model.removeShellCommand(command) }
                            }
                        }
                    }
                    Divider()
                    ForEach(model.shellHistory.prefix(20), id: \.self) { command in
                        Button(command) { model.consoleCommand = command }
                    }
                }.fixedSize()
                Button("Очистить вывод") { model.output = "" }
            }
            Divider()
            if model.adbConnected {
                console(model.output, placeholder: "Введите команду Android")
                Divider()
                HStack {
                    Text("$").font(.system(.body, design: .monospaced)).foregroundStyle(Color.accentColor)
                    TextField("Команда Android", text: $model.consoleCommand).font(.system(.body, design: .monospaced))
                        .onSubmit { historyIndex = -1; model.runShell() }
                        .onKeyPress(.upArrow) { browseHistory(older: true) }
                        .onKeyPress(.downArrow) { browseHistory(older: false) }
                    Button("Выполнить") { historyIndex = -1; model.runShell() }.buttonStyle(.borderedProminent)
                        .disabled(model.consoleCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(16).disabled(model.busy != nil)
            } else { connectionHint }
        }
    }

    private var diagnostics: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Панель диагностики", selection: $diagnosticTab) {
                    Text("Вывод").tag("Вывод")
                    Text("Журнал").tag("Журнал")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                Spacer()
                Group {
                    Button("Снимок Logcat") { diagnosticTab = "Вывод"; model.query("Чтение Logcat", command: "logcat -d -v threadtime -t 2500") }
                    Button("dmesg") { diagnosticTab = "Вывод"; model.query("Чтение dmesg", command: "dmesg") }
                    Button("Скриншот…") { model.screenshot() }
                    Menu("Ещё") {
                        Button("Отчёт об ошибках…") { model.bugreport() }
                        Button("Устройства и хранилища") { diagnosticTab = "Вывод"; model.query("Сведения об Android", command: "getprop; df -h") }
                        Divider()
                        Button("Резервная копия Android…") { model.legacyBackup(restore: false) }
                        Button("Восстановить копию Android…") {
                            if confirm("Восстановить данные из копии?", detail: "Результат зависит от версии Android. Android может заменить данные приложений.", button: "Восстановить") {
                                model.legacyBackup(restore: true)
                            }
                        }
                        Divider()
                        Button("Очистить Logcat…", role: .destructive) {
                            if confirm("Очистить журнал Logcat?", detail: "Текущие записи будут удалены с устройства.", button: "Очистить") {
                                model.query("Очистка Logcat", command: "logcat -c")
                            }
                        }
                        Button("Очистить dmesg…", role: .destructive) {
                            if confirm("Очистить журнал ядра?", detail: "Текущие записи будут удалены с устройства.", button: "Очистить") {
                                model.query("Очистка dmesg", command: "dmesg -C")
                            }
                        }
                    }.fixedSize()
                }.disabled(!model.adbConnected || model.busy != nil || model.logRunning)
            }.padding(16)
            HStack {
                TextField("Пакет для фильтра Logcat", text: $model.logFilter)
                    .textFieldStyle(.roundedBorder).disabled(model.logRunning)
                if model.logRunning { Button("Остановить поток") { model.stopLog() } }
                else {
                    Button("Запустить Logcat") { diagnosticTab = "Вывод"; model.startLog() }
                        .disabled(!model.adbConnected || model.busy != nil)
                }
            }.padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            console(diagnosticTab == "Журнал" ? model.history.joined(separator: "\n") : model.diagnostics, placeholder: "Запустите Logcat или выберите источник выше")
            Divider()
            HStack {
                Spacer()
                Button("Сохранить текст…") {
                    let contents = diagnosticTab == "Журнал" ? model.history.joined(separator: "\n") : model.diagnostics
                    if let url = saveURL("android-log.txt") {
                        do { try contents.write(to: url, atomically: true, encoding: .utf8) }
                        catch { model.error = error.localizedDescription }
                    }
                }.disabled(diagnosticTab == "Журнал" ? model.history.isEmpty : model.diagnostics.isEmpty)
            }.padding(12)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let item = model.transfers.first(where: { $0.state == .running }) {
                Text(item.toAndroid ? "На Android · \(item.label)" : "На Mac · \(item.label)")
                    .lineLimit(1).truncationMode(.middle).help(item.label)
                Spacer(minLength: 8)
                TransferProgressBar(item: item).frame(minWidth: 245, idealWidth: 310, maxWidth: 420)
                Button("Очередь") { model.showTransfers = true }.controlSize(.small)
                Button("Остановить") { model.cancel() }.controlSize(.small)
            } else if let busy = model.busy {
                ProgressView().controlSize(.small).tint(BridgeAppearance.accent).accessibilityLabel("Выполняется операция")
                Text(busy).lineLimit(1).help(busy)
                Button("Остановить") { model.cancel() }.controlSize(.small)
            } else {
                Text(model.status).lineLimit(1).help(model.status)
            }
            Spacer(minLength: 0)
            if model.section == .files && !model.transfers.contains(where: { $0.state == .running }) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        ShortcutHint(key: "Tab", action: "Панель")
                        ShortcutHint(key: "F5", action: "Копировать")
                        ShortcutHint(key: "F6", action: "Переместить")
                        ShortcutHint(key: "F7", action: "Новая папка")
                    }.fixedSize()
                    HStack(spacing: 8) {
                        ShortcutHint(key: "F5", action: "Копировать")
                        ShortcutHint(key: "F6", action: "Переместить")
                    }.fixedSize()
                    EmptyView()
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    private func dropOutline(_ targeted: Bool) -> some View {
        Rectangle()
            .fill(BridgeAppearance.accent.opacity(targeted ? 0.08 : 0))
            .overlay { Rectangle().strokeBorder(BridgeAppearance.accent.opacity(targeted ? 0.65 : 0), lineWidth: 2) }
            .allowsHitTesting(false)
    }

    private var appRows: [Package] {
        model.packages.map { package in
            let info = model.appMetadata[package.id]
            return Package(id: package.id, path: package.path, name: info?.name ?? package.id, version: info?.version ?? "")
        }.filter { searchApps.isEmpty || $0.id.localizedCaseInsensitiveContains(searchApps) || $0.name.localizedCaseInsensitiveContains(searchApps) }
            .sorted(using: appSort)
    }

    private func browseHistory(older: Bool) -> KeyPress.Result {
        guard !model.shellHistory.isEmpty else { return .ignored }
        historyIndex = older ? min(historyIndex + 1, model.shellHistory.count - 1) : max(-1, historyIndex - 1)
        model.consoleCommand = historyIndex < 0 ? "" : model.shellHistory[historyIndex]
        return .handled
    }

    private func bookmarkMenu(_ pane: FilePane) -> some View {
        let bookmarks = pane == .mac ? model.folderBookmarks.filter { $0.link == nil } : model.bookmarkScope
        return Menu {
            if pane == .android && model.link == .adb {
                Button("Внутренняя память") { model.loadRemote(path: "/sdcard") }
                Button("Download") { model.loadRemote(path: "/sdcard/Download") }
                Button("DCIM") { model.loadRemote(path: "/sdcard/DCIM") }
                Button("Корень Android") { model.loadRemote(path: "/") }
                Button("Временная папка ADB") { model.loadRemote(path: "/data/local/tmp") }
                Divider()
            }
            ForEach(bookmarks) { bookmark in
                Button(bookmark.name) { model.openBookmark(bookmark) }
            }
            Button("Добавить текущую папку…") { model.bookmark(pane) }
            if !bookmarks.isEmpty {
                Menu("Удалить закладку") {
                    ForEach(bookmarks) { bookmark in Button(bookmark.name) { model.deleteBookmark(bookmark) } }
                }
            }
        } label: { Image(systemName: "bookmark").accessibilityLabel(pane == .mac ? "Закладки Mac" : "Закладки Android") }
            .help(pane == .mac ? "Закладки Mac" : "Закладки Android")
            .fixedSize()
    }

    private func filtered(_ entries: [Entry], _ query: String) -> [Entry] {
        entries.filter { (model.showHidden || !$0.name.hasPrefix(".")) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }

    private func openLocal() {
        guard let entry = model.selectedLocal.first else { return }
        if entry.folder { model.loadLocal(URL(fileURLWithPath: entry.id)) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: entry.id)) }
    }

    private func properties() {
        guard let entry = model.selectedRemote.first else { return }
        var lines = [entry.folder ? "Папка" : bytes(entry.size)]
        if let date = entry.date { lines.append(date.formatted(date: .abbreviated, time: .standard)) }
        if !entry.mode.isEmpty { lines.append("Режим \(entry.mode) · \(entry.owner):\(entry.group)") }
        if !entry.target.isEmpty { lines.append("Ссылка → \(entry.target)") }
        if model.link == .adb { lines.append(entry.id) }
        let alert = NSAlert()
        alert.messageText = entry.name
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Закрыть")
        alert.runModal()
    }
}

struct ConnectSheet: View {
    @ObservedObject var model: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    @State private var code = ""
    @State private var alias = ""
    @State private var pairing = false
    @State private var save = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ADB по Wi‑Fi").font(.system(size: 17, weight: .medium))
            Picker("Действие", selection: $pairing) {
                Text("Подключение").tag(false)
                Text("Сопряжение").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            Text(pairing
                 ? "На Android откройте «Беспроводная отладка» → «Сопряжение с помощью кода»."
                 : "Укажите адрес и порт из раздела «Беспроводная отладка». Порт сопряжения обычно отличается от порта подключения.")
                .foregroundStyle(.secondary)
            TextField("IP-адрес и порт", text: $endpoint, prompt: Text("192.168.1.20:5555"))
                .textFieldStyle(.roundedBorder)
            if pairing { SecureField("Код сопряжения", text: $code).textFieldStyle(.roundedBorder) }
            else {
                Toggle("Добавить в закладки и подключать при запуске", isOn: $save)
                if save { TextField("Имя закладки", text: $alias).textFieldStyle(.roundedBorder) }
            }
            if !pairing && !model.bookmarks.isEmpty {
                Divider()
                ForEach(model.bookmarks) { bookmark in
                    HStack {
                        Button(bookmark.name) { endpoint = bookmark.endpoint }.buttonStyle(.link)
                        Spacer()
                        iconButton("Удалить закладку", "xmark.circle") { model.removeBookmark(bookmark) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(pairing ? "Сопрячь" : "Подключить") {
                    if save && !pairing { model.saveBookmark(endpoint: endpoint, name: alias) }
                    model.connect(endpoint, pair: pairing ? code : nil)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
                    .disabled(endpoint.isEmpty || (pairing && (code.count != 6 || !code.allSatisfy(\.isNumber))))
            }
        }.padding(24).frame(width: 448).tint(BridgeAppearance.accent)
    }
}

@MainActor private func iconButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { BridgeSymbol(symbol).frame(width: 16) }
        .buttonStyle(BridgeAction())
        .help(title)
        .accessibilityLabel(title)
}

@MainActor private func paneHeader<Actions: View>(_ name: String, _ symbol: String, active: Bool = false,
                                                 @ViewBuilder actions: () -> Actions) -> some View {
    HStack(spacing: 4) {
        HStack(spacing: 8) {
            BridgeSymbol(symbol).foregroundStyle(.secondary)
            Text(name).font(.system(size: 16, weight: .medium)).lineLimit(1)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottomLeading) {
            if active {
                Capsule().fill(BridgeAppearance.accent).frame(width: 16, height: 2).offset(y: 4)
            }
        }
        Spacer(minLength: 8)
        actions()
    }
    .padding(.horizontal, 16)
    .frame(height: 48)
}

@MainActor private func pathText(_ path: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(path)
            .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(BridgeAction(kind: .selected, monospaced: true))
    .help(path)
    .accessibilityLabel(label + " " + path)
}

@MainActor private func filterField(_ placeholder: String, label: String, text: Binding<String>) -> some View {
    HStack(spacing: 8) {
        BridgeSymbol("magnifyingglass").foregroundStyle(.secondary)
        TextField(placeholder, text: text).textFieldStyle(.plain).accessibilityLabel(label)
        if !text.wrappedValue.isEmpty {
            iconButton("Очистить поиск", "xmark.circle") { text.wrappedValue = "" }
        }
    }
    .padding(.horizontal, 8)
    .frame(height: 32)
    .background(BridgeAppearance.field, in: RoundedRectangle(cornerRadius: 8))
    .padding(.horizontal, 16).padding(.bottom, 8)
}

struct FileTable: View {
    let entries: [Entry]
    let sizes: [String: UInt64]
    @Binding var selection: Set<String>
    let metadata: Bool
    let drag: (Entry) -> NSItemProvider
    let open: (Entry) -> Void
    @State private var order = [KeyPathComparator<Entry>(\.name)]

    private var rows: [Entry] {
        entries.map { original in
            var entry = original
            if let size = sizes[entry.id] { entry.size = size }
            return entry
        }.sorted(using: order)
    }

    var body: some View {
        Table(of: Entry.self, selection: $selection, sortOrder: $order) {
            TableColumn("Имя", value: \.name) { entry in
                Label {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    BridgeSymbol(entry.folder && entry.target.isEmpty ? "folder" : entry.icon).foregroundStyle(.secondary)
                }.help(entry.target.isEmpty ? entry.name : entry.name + " → " + entry.target)
                .onDrag { drag(entry) }
            }.width(min: 115, ideal: 205)
            TableColumn("Размер", value: \.size) { entry in
                Text(entry.folder && sizes[entry.id] == nil ? "—" : bytes(entry.size))
                    .foregroundStyle(.secondary).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }.width(min: 52, ideal: 75)
            TableColumn("Изменён", value: \.sortDate) { entry in
                Text(entry.date?.formatted(date: .numeric, time: .shortened) ?? "—").foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }.width(min: 96, ideal: 128)
            if metadata {
                TableColumn("Режим", value: \.mode).width(min: 44, ideal: 55)
                TableColumn("Владелец", value: \.owner).width(min: 55, ideal: 75)
                TableColumn("Группа", value: \.group).width(min: 55, ideal: 75)
            }
        } rows: {
            ForEach(rows) { entry in TableRow(entry) }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) {
                Button("Открыть") { open(entry) }
            }
        } primaryAction: { ids in
            if ids.count == 1, let entry = entries.first(where: { ids.contains($0.id) }) { open(entry) }
        }
    }
}

private func selectionText(_ count: Int, _ selection: Int) -> some View {
    Text(selection > 0 ? "Выбрано \(selection) из \(count)" : "Объектов · \(count)")
        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
}

private func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}

private func console(_ contents: String, placeholder: String) -> some View {
    ScrollView([.vertical, .horizontal]) {
        Text(contents.isEmpty ? placeholder : contents)
            .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            .foregroundStyle(contents.isEmpty ? Color.secondary : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BridgeAppearance.surface)
}
