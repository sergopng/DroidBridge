import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FastbootInfo {
    var product: String?
    var mode: String?
    var slot: String?
    var unlocked: String?
    var isEmpty: Bool { product == nil && mode == nil && slot == nil && unlocked == nil }
}

enum FastbootReboot: String, CaseIterable, Identifiable {
    case system = "Android"
    case bootloader = "Загрузчик"
    case recovery = "Recovery"
    case fastbootd = "fastbootd"

    var id: String { rawValue }
    var arguments: [String] {
        switch self {
        case .system: ["reboot"]
        case .bootloader: ["reboot", "bootloader"]
        case .recovery: ["reboot", "recovery"]
        case .fastbootd: ["reboot", "fastboot"]
        }
    }
}

enum FastbootImageAction: String, Identifiable {
    case boot = "Временно загрузить"
    case flash = "Записать образ"
    var id: String { rawValue }
}

struct FastbootImageRequest {
    let action: FastbootImageAction
    let serial: String
    let image: URL
    let partition: String

    static func validPartition(_ partition: String) -> Bool {
        partition.range(of: #"\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z"#, options: .regularExpression) != nil
    }

    func validateImage() throws -> Int {
        let values = try image.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard image.pathExtension.lowercased() == "img", values.isRegularFile == true,
              let size = values.fileSize, size > 0 else {
            throw Failure("Выберите непустой файл .img.")
        }
        return size
    }

    func resolvedPartition(using runner: Runner) throws -> String {
        guard Self.validPartition(partition) else { throw Failure("Укажите допустимое имя раздела.") }
        var target = partition
        if try runner.fastbootVariable(serial, "has-slot:" + partition) == "yes" {
            guard let slot = try runner.fastbootVariable(serial, "current-slot"), ["a", "b"].contains(slot) else {
                throw Failure("Не удалось определить активный слот. Укажите раздел со слотом, например boot_a.")
            }
            target += "_" + slot
        }
        // Require a positive size so a typo or a missing recovery partition cannot reach flash.
        guard let raw = try runner.fastbootVariable(serial, "partition-size:" + target) else {
            throw Failure("Устройство не подтвердило наличие раздела «\(target)» в текущем режиме Fastboot.")
        }
        let capacity = raw.hasPrefix("0x") ? UInt64(raw.dropFirst(2), radix: 16) : UInt64(raw)
        guard let capacity, capacity > 0 else {
            throw Failure("Устройство сообщило нулевой или неизвестный размер раздела «\(target)».")
        }
        return target
    }
}

extension Runner {
    func fastbootDeviceList() throws -> [String] {
        let output = try run(.fastboot, ["devices"])
        var serials = Set<String>()
        return String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[1] == "fastboot" else { return nil }
            let serial = String(fields[0])
            guard !serial.hasPrefix("tcp:"), !serial.hasPrefix("udp:"), serials.insert(serial).inserted else { return nil }
            return serial
        }
    }

    func requireFastbootDevice(_ serial: String) throws {
        guard try fastbootDeviceList().contains(serial) else {
            throw Failure("Устройство «\(serial)» больше не видно в Fastboot. Проверьте USB и обновите список.")
        }
    }

    func fastbootCommand(_ serial: String, _ args: [String]) throws -> String {
        let output = try run(.fastboot, ["-s", serial] + args, includeStandardError: true)
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func fastbootVariable(_ serial: String, _ name: String) throws -> String? {
        let output: String
        do {
            output = try fastbootCommand(serial, ["getvar", name])
        } catch {
            try check()
            try requireFastbootDevice(serial)
            return nil // Some bootloaders omit optional variables.
        }
        let prefix = name + ":"
        return output.split(whereSeparator: \.isNewline).first { $0.hasPrefix(prefix) }
            .map { $0.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension Workspace {
    func openFastboot() {
        guard busy == nil else { return }
        section = .fastboot
        refreshFastboot()
    }

    func refreshFastboot() {
        job("Поиск устройств Fastboot", { try $0.fastbootDeviceList() }, done: { self.updateFastbootDevices($0) })
    }

    private func updateFastbootDevices(_ devices: [String], preferred: String? = nil) {
        fastbootDevices = devices
        let candidate = preferred ?? fastbootSerial
        let next = devices.contains(candidate) ? candidate : (preferred == nil && devices.count == 1 ? devices[0] : "")
        if next != fastbootSerial { selectFastboot(next) }
    }

    func selectFastboot(_ serial: String) {
        fastbootSerial = serial
        fastbootInfo = FastbootInfo()
        fastbootOutput = ""
    }

    func rebootADBToFastboot() {
        guard adbConnected, busy == nil else { return }
        let id = serial
        let name = deviceName
        guard confirm("Перезагрузить в загрузчик?", detail: name, button: "Перезагрузить") else { return }
        section = .fastboot
        selectFastboot("")
        fastbootDevices = []
        job("Переход в Fastboot", { runner in
            _ = try runner.adb(id, ["reboot", "bootloader"])
            for _ in 0..<12 {
                try runner.check()
                let devices = try runner.fastbootDeviceList()
                if devices.contains(id) { return devices }
                Thread.sleep(forTimeInterval: 0.65)
            }
            return try runner.fastbootDeviceList()
        }, done: {
            self.devices.removeAll { $0.id == id }
            self.updateFastbootDevices($0, preferred: id)
            if $0.isEmpty { self.fastbootOutput = "Устройство ещё не появилось. Проверьте экран телефона и обновите список." }
        })
    }

    func readFastbootInfo() {
        let id = fastbootSerial
        guard !id.isEmpty else { return }
        job("Чтение сведений Fastboot", { runner in
            try runner.requireFastbootDevice(id)
            let product = try runner.fastbootVariable(id, "product")
            let userspace = try runner.fastbootVariable(id, "is-userspace")
            let mode = userspace == "yes" ? "fastbootd" : userspace == "no" ? "Загрузчик" : nil
            let slot = try runner.fastbootVariable(id, "current-slot")
            let unlocked = try runner.fastbootVariable(id, "unlocked")
            return FastbootInfo(product: product, mode: mode, slot: slot, unlocked: unlocked)
        }, done: { info in
            self.fastbootInfo = info
            if info.isEmpty {
                self.fastbootOutput = "Загрузчик не вернул эти сведения. Попробуйте «Все переменные»."
            }
        })
    }

    func runFastboot(_ title: String, arguments: [String], changesMode: Bool = false) {
        let id = fastbootSerial
        guard !id.isEmpty else { return }
        executeFastboot(title, serial: id, arguments: arguments, changesMode: changesMode)
    }

    func submitFastbootImage(_ request: FastbootImageRequest) {
        guard busy == nil, !request.serial.isEmpty, request.serial == fastbootSerial else { return }
        job("Проверка образа Fastboot", { runner in
            try runner.requireFastbootDevice(request.serial)
            let size = try request.validateImage()
            if try runner.fastbootVariable(request.serial, "unlocked") == "no" {
                throw Failure("Загрузчик сообщает, что он заблокирован. Проверьте требования производителя.")
            }
            if request.action == .boot, try runner.fastbootVariable(request.serial, "is-userspace") == "yes" {
                throw Failure("Для временной загрузки образа перезагрузите телефон из fastbootd в загрузчик.")
            }
            let target = request.action == .flash ? try request.resolvedPartition(using: runner) : ""
            return (target, size)
        }, done: { target, size in
            let writing = request.action == .flash
            let formattedSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            let detail = "Устройство: \(request.serial)\nОбраз: \(request.image.lastPathComponent) (\(formattedSize))"
            let prompt = writing
                ? detail + "\nРаздел: \(target)\n\nЗапись заменит содержимое раздела. Несовместимый образ может нарушить загрузку Android."
                : detail + "\n\nТелефон перезагрузится с выбранным образом."
            guard confirm(request.action.rawValue + "?", detail: prompt, button: request.action.rawValue) else { return }
            let args = writing ? ["flash", target, request.image.path] : ["boot", request.image.path]
            self.executeFastboot(request.action.rawValue, serial: request.serial, arguments: args, changesMode: !writing, image: request)
        })
    }

    private func executeFastboot(_ title: String, serial: String, arguments: [String],
                                 changesMode: Bool, image: FastbootImageRequest? = nil) {
        guard busy == nil else { return }
        writingFastbootImage = image?.action == .flash
        let command = (["fastboot", "-s", serial] + arguments).map {
            $0.range(of: #"^[A-Za-z0-9_./:-]+$"#, options: .regularExpression) == nil ? shellQuote($0) : $0
        }.joined(separator: " ")
        fastbootOutput = "$ " + command
        job(title, { runner in
            try runner.requireFastbootDevice(serial)
            if let image {
                _ = try image.validateImage()
                if image.action == .flash, try image.resolvedPartition(using: runner) != arguments[1] {
                    throw Failure("Активный слот изменился. Проверьте устройство и повторите операцию.")
                }
            }
            return try runner.fastbootCommand(serial, arguments)
        }, done: { output in
            self.writingFastbootImage = false
            self.fastbootOutput += "\n" + (output.isEmpty ? "Команда выполнена." : output)
            if changesMode {
                self.fastbootDevices = []
                self.fastbootSerial = ""
                self.fastbootInfo = FastbootInfo()
            }
        }, failed: { error in
            self.writingFastbootImage = false
            self.fastbootOutput += "\n" + error.localizedDescription
        })
    }
}

struct FastbootView: View {
    @ObservedObject var model: Workspace
    @State private var imageAction: FastbootImageAction?
    @State private var rebootDestination: FastbootReboot?

    private var selected: Bool { !model.fastbootSerial.isEmpty && model.busy == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceControls
            HStack(alignment: .top, spacing: 20) {
                actions.frame(width: 266, alignment: .leading)
                Divider()
                output.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
        .sheet(item: $imageAction) { action in
            FastbootImageSheet(action: action, serial: model.fastbootSerial) { request in
                model.submitFastbootImage(request)
            }
        }
        .alert("Перезагрузить устройство?", isPresented: Binding(
            get: { rebootDestination != nil }, set: { if !$0 { rebootDestination = nil } }
        ), presenting: rebootDestination) { destination in
            Button("Отмена", role: .cancel) {}
            Button("Перезагрузить") {
                model.runFastboot("Перезагрузка в \(destination.rawValue)", arguments: destination.arguments, changesMode: true)
            }
        } message: { destination in
            Text("\(model.fastbootSerial) → \(destination.rawValue)")
        }
    }

    private var deviceControls: some View {
        HStack(spacing: 12) {
            if model.fastbootDevices.isEmpty {
                Label("Устройства Fastboot не найдены", systemImage: "iphone")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Устройство Fastboot", selection: Binding(
                    get: { model.fastbootSerial }, set: { model.selectFastboot($0) }
                )) {
                    if model.fastbootSerial.isEmpty { Text("Выберите устройство").tag("") }
                    ForEach(model.fastbootDevices, id: \.self) { Text($0).tag($0) }
                }.disabled(model.busy != nil)
            }
            Spacer()
            Button("Обновить", systemImage: "arrow.clockwise") { model.refreshFastboot() }
                .disabled(model.busy != nil)
            if model.adbConnected {
                Button("В загрузчик через ADB") { model.rebootADBToFastboot() }.disabled(model.busy != nil)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Устройство").font(.headline)
            Text("Подключите телефон по USB в режиме загрузчика или fastbootd.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                Button("Читать сведения", systemImage: "info.circle") { model.readFastbootInfo() }
                Button("Все переменные", systemImage: "list.bullet") {
                    model.runFastboot("Чтение переменных Fastboot", arguments: ["getvar", "all"])
                }
                Menu("Перезагрузить", systemImage: "power") {
                    ForEach(FastbootReboot.allCases) { destination in
                        Button(destination.rawValue) { rebootDestination = destination }
                    }
                }.fixedSize()
            }.disabled(!selected)
            Divider()
            Text("Образы .img").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Button("Временно загрузить…", systemImage: "play") { imageAction = .boot }
                Button("Записать в раздел…", systemImage: "arrow.down.to.line") { imageAction = .flash }
            }.disabled(!selected)
        }
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let product = model.fastbootInfo.product { LabeledContent("Код устройства", value: product) }
            if let mode = model.fastbootInfo.mode { LabeledContent("Режим", value: mode) }
            if let slot = model.fastbootInfo.slot { LabeledContent("Активный слот", value: slot) }
            if let lock = model.fastbootInfo.unlocked {
                LabeledContent("Загрузчик", value: lock == "yes" ? "Разблокирован" : lock == "no" ? "Заблокирован" : lock)
            }
            if !model.fastbootOutput.isEmpty {
                Text("Вывод команды").font(.headline)
                ScrollView {
                    Text(model.fastbootOutput).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.background(BridgeAppearance.chrome, in: RoundedRectangle(cornerRadius: 6))
            } else if model.fastbootInfo.isEmpty {
                Text("Здесь появятся сведения об устройстве и вывод команд.")
                    .foregroundStyle(.secondary)
            }
        }.padding(.leading, 4)
    }
}

private struct FastbootImageSheet: View {
    let action: FastbootImageAction
    let serial: String
    let submit: (FastbootImageRequest) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: URL?
    @State private var partition = ""

    private var target: String { partition.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var writing: Bool { action == .flash }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(action.rawValue).font(.title3.bold())
            LabeledContent("Устройство", value: serial)
            HStack {
                Button("Выбрать .img…") { chooseImage() }
                if let image { Text(image.lastPathComponent).lineLimit(1).truncationMode(.middle).help(image.path) }
            }
            if writing {
                TextField("Раздел", text: $partition, prompt: Text("Например, recovery или boot_a"))
                Text("Возьмите имя раздела из инструкции к образу для вашей модели. Отдельный recovery есть не у всех устройств.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Fastboot загрузит образ в память без записи в раздел, если загрузчик поддерживает эту команду.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Проверить образ") {
                    guard let image else { return }
                    let request = FastbootImageRequest(action: action, serial: serial, image: image, partition: target)
                    dismiss()
                    submit(request)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(image == nil || (writing && !FastbootImageRequest.validPartition(target)))
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.message = "Выберите образ для вашей модели Android"
        panel.allowedContentTypes = [UTType(filenameExtension: "img") ?? .data]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { image = panel.url }
    }
}
