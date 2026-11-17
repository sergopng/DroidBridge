import SwiftUI

struct ScrcpyOption: Identifiable {
    enum Input { case flag, required, optional }
    let id: String
    let syntax: String
    let help: String
    let input: Input

    var diagnostic: Bool { id.hasPrefix("--list-") || ["--help", "--version", "-h", "-v"].contains(id) }
    var linuxOnly: Bool { id.hasPrefix("--v4l2-") }

    var group: String {
        if diagnostic { return "Сведения и диагностика" }
        let key = id.drop(while: { $0 == "-" })
        if key.hasPrefix("camera-") || id == "--video-source" { return "Камера" }
        if key.contains("audio") { return "Звук" }
        if key.contains("display") || key.contains("screen") || key.contains("power") || ["-x", "--stay-awake", "--show-touches", "--keep-active", "--start-app"].contains(id) { return "Дисплей и питание" }
        if key.contains("window") || key.contains("render") { return "Окно" }
        if key.contains("record") { return "Запись" }
        if key.contains("video") || key.contains("orientation") || key.contains("fps") || ["--crop", "--angle", "--hwdec", "--max-size", "--min-size-alignment", "--no-downsize-on-error", "--no-mipmaps"].contains(id) { return "Видео" }
        if ScrcpyProfile.selectors.contains(id) || key.contains("tcpip") || key.contains("adb") || key.contains("tunnel") || id == "--port" { return "Подключение" }
        if key.contains("key") || key.contains("mouse") || key.contains("control") || key.contains("clipboard") || key.contains("paste") || key.contains("text") || key.contains("gamepad") || ["-G", "-K", "-M", "--otg"].contains(id) { return "Управление и ввод" }
        return "Дополнительно"
    }

    func argument(_ value: String) throws -> String {
        guard !value.contains("\0") else { throw Failure("Недопустимое значение для \(id)") }
        switch input {
        case .flag: return id
        case .optional: return value.isEmpty ? id : "\(id)=\(value)"
        case .required:
            guard !value.isEmpty else { throw Failure("Укажите значение для \(id)") }
            return "\(id)=\(value)"
        }
    }

    static func parse(_ help: String) -> [Self] {
        let header = try! NSRegularExpression(pattern: #"^ {4}(?:--[a-z0-9][a-z0-9-]*|-[A-Za-z])"#)
        let name = try! NSRegularExpression(pattern: #"--[a-z0-9][a-z0-9-]*|-[A-Za-z]"#)
        let body = help.components(separatedBy: .newlines)
        var rows: [Self] = []
        var index = 0
        while index < body.count {
            let line = body[index]
            index += 1
            guard header.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
            let syntax = line.trimmingCharacters(in: .whitespaces)
            let spelling = String(syntax.components(separatedBy: ", --").last ?? syntax)
            let rawName = spelling.hasPrefix("-") ? spelling : "--" + spelling
            guard let match = name.firstMatch(in: rawName, range: NSRange(rawName.startIndex..., in: rawName)),
                  let range = Range(match.range, in: rawName) else { continue }
            let id = String(rawName[range])
            let input: Input = rawName.hasPrefix(id + "[=") ? .optional : (rawName.hasPrefix(id + "=") ? .required : .flag)
            var description: [String] = []
            while index < body.count && body[index].hasPrefix("        ") {
                description.append(body[index].trimmingCharacters(in: .whitespaces))
                index += 1
            }
            rows.append(Self(id: id, syntax: syntax, help: description.joined(separator: "\n"), input: input))
        }
        return rows
    }
}

struct ScrcpyProfile: Codable {
    var enabled: [String: String] = [:]
    var useAudio = false
    static let selectors: Set<String> = ["--serial", "--select-usb", "--select-tcpip", "-s", "-d", "-e"]

    static var saved: Self {
        guard let data = UserDefaults.standard.data(forKey: "scrcpyProfile"),
              let profile = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return profile
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "scrcpyProfile")
    }

    func arguments(options: [ScrcpyOption], serial: String, title: String, record: URL?, diagnostic: ScrcpyOption?) throws -> [String] {
        if let diagnostic, ["--help", "--version", "-h", "-v"].contains(diagnostic.id) { return [diagnostic.id] }
        let active = options.filter { enabled[$0.id] != nil && !$0.diagnostic && !$0.linuxOnly }
        let ids = Set(active.map(\.id))
        guard ids.intersection(Self.selectors).count <= 1 else { throw Failure("Выберите один способ выбора устройства в настройках scrcpy") }
        var args: [String] = []
        let tcpipAddress = active.contains { $0.id == "--tcpip" } && !(enabled["--tcpip"] ?? "").isEmpty
        if ids.isDisjoint(with: Self.selectors) && !tcpipAddress && !serial.isEmpty {
            args += ["--serial", serial]
        }
        if let diagnostic {
            let connectionOptions: Set<String> = ["--tcpip", "--display-id", "--force-adb-forward", "--port",
                                                  "--tunnel-host", "--tunnel-port", "--verbosity"]
            for option in active where Self.selectors.contains(option.id) || connectionOptions.contains(option.id)
                || (diagnostic.id == "--list-camera-sizes" && option.id.hasPrefix("--camera-")) {
                try args.append(option.argument(enabled[option.id] ?? ""))
            }
            return args + [diagnostic.id]
        }
        if !ids.contains("--window-title") { args += ["--window-title", title] }
        if !ids.contains("--shortcut-mod") { args.append("--shortcut-mod=lalt,lsuper") }
        if !useAudio && !ids.contains("--no-audio") && !ids.contains("--require-audio") { args.append("--no-audio") }
        for option in active where !(record != nil && option.id == "--record") {
            try args.append(option.argument(enabled[option.id] ?? ""))
        }
        if let record { args.append("--record=" + record.path) }
        return args
    }
}

private struct ScrcpyChoice: Identifiable {
    let value: String
    let label: String
    var id: String { value }
}

private extension ScrcpyOption {
    var title: String {
        Self.titles[id] ?? id
    }

    static let titles: [String: String] = [
        "--video-source": "Источник видео", "--max-size": "Максимальный размер", "--max-fps": "Частота кадров",
        "--video-bit-rate": "Битрейт видео", "--video-codec": "Видеокодек", "--video-encoder": "Видеокодировщик",
        "--audio-source": "Источник звука", "--audio-codec": "Аудиокодек", "--audio-bit-rate": "Битрейт звука",
        "--audio-buffer": "Буфер звука", "--audio-output-buffer": "Буфер вывода звука", "--audio-encoder": "Аудиокодировщик",
        "--no-audio": "Отключить звук", "--require-audio": "Требовать звук", "--audio-dup": "Оставить звук на телефоне",
        "--no-video": "Отключить видео", "--video-buffer": "Буфер видео", "--hwdec": "Декодирование видео",
        "--camera-facing": "Сторона камеры", "--camera-id": "Камера по ID", "--camera-size": "Размер кадра камеры",
        "--camera-fps": "Частота кадров камеры", "--camera-zoom": "Зум камеры", "--camera-ar": "Пропорции кадра камеры",
        "--camera-torch": "Включить фонарик", "--camera-high-speed": "Высокоскоростная съёмка",
        "--display-id": "Дисплей по ID", "--new-display": "Виртуальный дисплей", "--display-ime-policy": "Экранная клавиатура",
        "--turn-screen-off": "Гасить экран при запуске", "--screen-off-timeout": "Тайм-аут экрана",
        "--stay-awake": "Не выключать экран при зарядке", "--show-touches": "Показывать касания",
        "--capture-orientation": "Ориентация захвата", "--display-orientation": "Ориентация в окне",
        "--orientation": "Ориентация окна и записи", "--angle": "Угол поворота", "--crop": "Обрезка кадра",
        "--fullscreen": "Полноэкранный режим", "--always-on-top": "Поверх остальных окон",
        "--window-borderless": "Окно без рамки", "--window-title": "Заголовок окна",
        "--window-width": "Ширина окна", "--window-height": "Высота окна", "--window-x": "Положение окна по X", "--window-y": "Положение окна по Y",
        "--render-fit": "Масштаб в окне", "--render-driver": "Драйвер отрисовки", "--background-color": "Цвет фона окна",
        "--keyboard": "Режим клавиатуры", "--mouse": "Режим мыши", "--gamepad": "Режим геймпада",
        "--no-control": "Только просмотр", "--no-clipboard-autosync": "Отключить синхронизацию буфера",
        "--shortcut-mod": "Клавиши для сочетаний scrcpy", "--otg": "Режим OTG",
        "--record": "Файл записи", "--record-format": "Формат записи", "--record-orientation": "Ориентация записи",
        "--time-limit": "Длительность сеанса", "--serial": "Устройство по серийному номеру",
        "--select-usb": "Выбрать USB-устройство", "--select-tcpip": "Выбрать устройство по сети",
        "--tcpip": "Подключение по TCP/IP", "--port": "Локальный порт", "--push-target": "Папка для перетаскивания файлов",
        "--start-app": "Приложение при запуске", "--verbosity": "Подробность журнала", "--pause-on-exit": "Пауза при выходе",
        "--list-apps": "Список приложений", "--list-displays": "Список дисплеев", "--list-encoders": "Список кодировщиков",
        "--list-cameras": "Список камер", "--list-camera-sizes": "Размеры кадров камер", "--help": "Справка", "--version": "Версия scrcpy",
        "--min-size-alignment": "Выравнивание размеров видео"
    ]

    static let common = ["--max-size", "--max-fps", "--video-bit-rate", "--video-codec",
                         "--audio-source", "--audio-codec", "--video-source", "--camera-facing",
                         "--fullscreen", "--always-on-top", "--keyboard", "--mouse", "--record-format"]

    var choices: [ScrcpyChoice] {
        func simple(_ values: [String]) -> [ScrcpyChoice] {
            values.map { ScrcpyChoice(value: $0, label: $0) }
        }
        func named(_ values: [(String, String)]) -> [ScrcpyChoice] {
            values.map { ScrcpyChoice(value: $0.0, label: $0.1) }
        }
        func units(_ values: [String], _ unit: String) -> [ScrcpyChoice] {
            values.map { ScrcpyChoice(value: $0, label: "\($0) \(unit)") }
        }
        switch id {
        case "--video-codec": return named([("h264", "H.264"), ("h265", "H.265 / HEVC"), ("av1", "AV1"), ("vp8", "VP8"), ("vp9", "VP9")])
        case "--audio-codec": return named([("opus", "Opus"), ("aac", "AAC"), ("flac", "FLAC"), ("raw", "PCM без сжатия")])
        case "--video-source": return named([("display", "Экран"), ("camera", "Камера")])
        case "--audio-source":
            return named([("output", "Вывод устройства"), ("playback", "Звук приложений"),
                          ("mic", "Микрофон"), ("mic-unprocessed", "Микрофон без обработки"),
                          ("mic-camcorder", "Микрофон камеры"), ("mic-voice-recognition", "Распознавание речи"),
                          ("mic-voice-communication", "Голосовое общение"), ("voice-call", "Телефонный разговор"),
                          ("voice-call-uplink", "Исходящий звук звонка"), ("voice-call-downlink", "Входящий звук звонка"),
                          ("voice-performance", "Микрофон и воспроизведение")])
        case "--camera-facing": return named([("front", "Фронтальная"), ("back", "Задняя"), ("external", "Внешняя")])
        case "--keyboard", "--mouse":
            return named([("sdk", "Системный ввод Android (SDK)"), ("uhid", "Эмуляция HID (UHID)"),
                          ("aoa", "USB-аксессуар (AOA)"), ("disabled", "Выключен")])
        case "--gamepad": return named([("uhid", "UHID"), ("aoa", "AOA"), ("disabled", "Выключен")])
        case "--hwdec":
            return named([("auto", "Автоматически"), ("videotoolbox", "Apple VideoToolbox"), ("disabled", "Программное декодирование")])
        case "--display-ime-policy": return named([("local", "На выбранном дисплее"), ("fallback", "На резервном дисплее"), ("hide", "Скрыть")])
        case "--render-fit": return named([("letterbox", "Сохранить пропорции"), ("stretched", "Растянуть"), ("unscaled", "Без масштабирования")])
        case "--render-driver": return named([("metal", "Metal"), ("opengl", "OpenGL"), ("software", "Программный")])
        case "--pause-on-exit": return named([("true", "Всегда"), ("false", "Никогда"), ("if-error", "При ошибке")])
        case "--verbosity": return named([("verbose", "Подробно"), ("debug", "Отладка"), ("info", "Информация"), ("warn", "Предупреждения"), ("error", "Ошибки")])
        case "--record-format": return named([("mp4", "MP4"), ("mkv", "MKV"), ("m4a", "M4A · аудио"), ("mka", "MKA · аудио"),
                                               ("opus", "Opus · аудио"), ("aac", "AAC · аудио"), ("flac", "FLAC · аудио"), ("wav", "WAV · аудио")])
        case "--display-orientation", "--capture-orientation", "--record-orientation", "--orientation", "--angle":
            var items = units(["0", "90", "180", "270"], "°")
            if ["--display-orientation", "--capture-orientation"].contains(id) {
                items += [0, 90, 180, 270].map { ScrcpyChoice(value: "flip\($0)", label: "Отразить и повернуть на \($0)°") }
            }
            if id == "--capture-orientation" {
                items += named([("@", "Зафиксировать начальную ориентацию")])
                items += [0, 90, 180, 270].map { ScrcpyChoice(value: "@\($0)", label: "Зафиксировать \($0)°") }
            }
            return items
        case "--max-fps", "--camera-fps": return units(["24", "30", "48", "60", "90", "120"], "кадр/с")
        case "--max-size": return named([("0", "Без ограничения")]) + units(["480", "720", "1080", "1440", "2160"], "пикс.")
        case "--video-bit-rate": return ["1", "2", "4", "8", "12", "16", "24"].map { ScrcpyChoice(value: $0 + "M", label: $0 + " Мбит/с") }
        case "--audio-bit-rate": return ["64", "96", "128", "192", "256", "320"].map { ScrcpyChoice(value: $0 + "K", label: $0 + " кбит/с") }
        case "--audio-buffer", "--audio-output-buffer", "--video-buffer": return units(["0", "10", "25", "50", "100", "200"], "мс")
        case "--screen-off-timeout", "--time-limit": return units(["15", "30", "60", "120", "300"], "с")
        case "--window-width": return named([("0", "Автоматически")]) + units(["640", "800", "960", "1280", "1600"], "пикс.")
        case "--window-height": return named([("0", "Автоматически")]) + units(["480", "600", "720", "900", "1080"], "пикс.")
        case "--window-x", "--window-y": return named([("auto", "Автоматически"), ("0", "0 пикс.")])
        case "--camera-size", "--new-display": return named([("640x480", "640 × 480"), ("1280x720", "1280 × 720"), ("1920x1080", "1920 × 1080")])
        case "--camera-ar": return named([("sensor", "Пропорции сенсора")]) + simple(["4:3", "16:9", "1:1"])
        case "--camera-zoom": return units(["1", "1.5", "2", "3"], "×")
        case "--min-size-alignment": return units(["1", "2", "4", "8", "16"], "пикс.")
        case "--shortcut-mod": return named([("lalt,lsuper", "Левая Option или Command"), ("lsuper", "Левая Command"), ("lalt", "Левая Option"), ("lctrl", "Левая Control")])
        default: return []
        }
    }

    var valueHint: String {
        switch id {
        case "--video-bit-rate": return "Например, 8M или 8000000"
        case "--audio-bit-rate": return "Например, 128K или 128000"
        case "--max-fps", "--camera-fps": return "Кадров в секунду, например 30"
        case "--max-size", "--window-width", "--window-height": return "Пиксели, например 1080"
        case "--audio-buffer", "--audio-output-buffer", "--video-buffer": return "Миллисекунды, например 50"
        case "--time-limit", "--screen-off-timeout": return "Секунды, например 60"
        case "--camera-size": return "Ширина × высота, например 1920x1080"
        case "--new-display": return "Размер и DPI, например 1920x1080/240"
        case "--camera-ar": return "Например, 16:9 или sensor"
        case "--camera-zoom": return "Например, 1.5"
        case "--crop": return "Ширина:высота:X:Y, например 1080:1920:0:0"
        case "--port": return "Один порт или диапазон, например 27183:27199"
        case "--tcpip": return "IP-адрес и порт, например 192.168.1.20:5555"
        case "--background-color": return "Цвет в HEX, например #222222"
        case "--record": return "Путь к файлу, например ~/Movies/Android.mkv"
        case "--display-id", "--camera-id": return "Введите ID из раздела «Сведения и диагностика»"
        default:
            if let index = syntax.firstIndex(of: "=") { return String(syntax[syntax.index(after: index)...]) }
            return "Введите значение"
        }
    }

    func valueProblem(_ value: String) -> String? {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return input == .required ? "Укажите значение" : nil
        }
        let pattern: String
        switch id {
        case "--max-size", "--window-width", "--window-height", "--audio-buffer", "--audio-output-buffer", "--video-buffer",
             "--time-limit", "--screen-off-timeout", "--display-id", "--min-size-alignment":
            pattern = #"^[0-9]+$"#
        case "--max-fps", "--camera-fps", "--camera-zoom":
            guard let amount = Double(value), amount.isFinite, amount > 0 else { return "Введите число больше нуля" }
            return nil
        case "--video-bit-rate", "--audio-bit-rate": pattern = #"^[1-9][0-9]*[KkMm]?$"#
        case "--camera-size": pattern = #"^[1-9][0-9]*x[1-9][0-9]*$"#
        case "--new-display": pattern = #"^(?:[1-9][0-9]*x[1-9][0-9]*(?:/[1-9][0-9]*)?|/[1-9][0-9]*)$"#
        case "--background-color": pattern = #"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$"#
        case "--crop": pattern = #"^[1-9][0-9]*:[1-9][0-9]*:[0-9]+:[0-9]+$"#
        default: return nil
        }
        return value.range(of: pattern, options: .regularExpression) == nil ? "Проверьте формат. \(valueHint)" : nil
    }
}

struct ScrcpySettings: View {
    @ObservedObject var model: Workspace
    @State private var search = ""
    @State private var category = "Основные"
    @State private var selected: String?
    @State private var showReset = false

    private let groups = ["Видео", "Звук", "Камера", "Дисплей и питание", "Окно", "Управление и ввод",
                          "Запись", "Подключение", "Сведения и диагностика", "Дополнительно"]

    private var shown: [ScrcpyOption] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return model.scrcpyOptions.filter {
                [$0.title, $0.syntax, $0.help, $0.group].contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }
        switch category {
        case "Основные":
            return ScrcpyOption.common.compactMap { id in model.scrcpyOptions.first { $0.id == id } }
        case "Все параметры": return model.scrcpyOptions
        default: return model.scrcpyOptions.filter { $0.group == category }
        }
    }

    private var current: ScrcpyOption? {
        shown.first(where: { $0.id == selected }) ?? shown.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("Раздел", selection: $category) {
                    ForEach(["Основные", "Все параметры"] + groups, id: \.self) { Text($0).tag($0) }
                }
                TextField("Поиск по названию или параметру", text: $search).textFieldStyle(.roundedBorder)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle") }
                        .accessibilityLabel("Очистить поиск")
                }
            }
            if !model.scrcpyCatalogError.isEmpty {
                HStack {
                    Text(model.scrcpyCatalogError).textSelection(.enabled)
                    Spacer()
                    Button("Повторить") { model.loadScrcpyOptions() }
                }.foregroundStyle(.secondary)
            }
            HSplitView {
                List(selection: $selected) {
                    ForEach(shown) { option in
                        HStack {
                            Text(option.title).lineLimit(1)
                            Spacer(minLength: 8)
                            if model.scrcpyProfile.enabled[option.id] != nil {
                                Image(systemName: "checkmark").foregroundStyle(BridgeAppearance.accent)
                                    .accessibilityLabel("Настроено")
                            }
                        }.tag(option.id).help(option.syntax)
                    }
                }
                .frame(minWidth: 248, idealWidth: 276)
                .overlay {
                    if shown.isEmpty {
                        Text(model.scrcpyOptions.isEmpty ? "Читаю параметры scrcpy…" : "Совпадений нет")
                            .foregroundStyle(.secondary)
                    }
                }
                if let current {
                    ScrcpyOptionEditor(option: current, model: model).id(current.id)
                        .frame(minWidth: 328, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Text("Выберите параметр").foregroundStyle(.secondary)
                        .frame(minWidth: 328, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Toggle("Звук при запуске", isOn: $model.scrcpyProfile.useAudio)
                    .help("Передавать звук по умолчанию. Отдельные параметры звука могут переопределить это значение.")
                Spacer()
                Text("Изменения при следующем запуске").foregroundStyle(.secondary)
                Button("Сбросить…") { showReset = true }
            }.font(.caption)
        }
        .padding(16)
        .task { model.loadScrcpyOptions() }
        .onChange(of: shown.map(\.id), initial: true) { _, ids in
            if !ids.contains(selected ?? "") { selected = ids.first }
        }
        .confirmationDialog("Сбросить параметры scrcpy?", isPresented: $showReset, titleVisibility: .visible) {
            Button("Сбросить настройки scrcpy", role: .destructive) { model.scrcpyProfile = ScrcpyProfile() }
        }
    }
}

private struct ScrcpyOptionEditor: View {
    let option: ScrcpyOption
    @ObservedObject var model: Workspace
    @State private var draft = ""
    @State private var custom = false
    @State private var showHelp = false

    private var saved: String? { model.scrcpyProfile.enabled[option.id] }
    private var choices: [ScrcpyChoice] { option.choices }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title).font(.title2.weight(.medium))
                    if option.title != option.id {
                        Text(option.syntax).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if option.linuxOnly {
                    Label("Доступно в Linux", systemImage: "info.circle").foregroundStyle(.secondary)
                } else if option.diagnostic {
                    Button("Выполнить") { model.runScrcpyDiagnostic(option) }
                        .disabled(model.busy != nil || model.mirrorRunning)
                    if model.scrcpyDiagnosticID == option.id && !model.scrcpyDiagnostic.isEmpty {
                        Text(model.scrcpyDiagnostic).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                } else if option.input == .flag {
                    Toggle("Включить", isOn: Binding(get: { saved != nil }, set: {
                        model.scrcpyProfile.enabled[option.id] = $0 ? "" : nil
                    })).toggleStyle(.switch)
                } else {
                    editor
                }
                Divider()
                DisclosureGroup("Справка scrcpy", isExpanded: $showHelp) {
                    Text(option.help).foregroundStyle(.secondary).textSelection(.enabled)
                        .padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: sync)
        .onChange(of: saved) { sync() }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Значение", selection: Binding(get: selectedValue, set: select)) {
                Text("По умолчанию").tag(Selection.inherited)
                if option.input == .optional {
                    Text("Включить без значения").tag(Selection.bare)
                }
                ForEach(choices) { choice in Text(choice.label).tag(Selection.preset(choice.value)) }
                Text("Своё значение…").tag(Selection.custom)
            }.pickerStyle(.menu)
            if custom {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Своё значение").font(.subheadline.weight(.medium))
                    HStack {
                        TextField("Своё значение", text: $draft, prompt: Text(option.valueHint))
                            .labelsHidden().textFieldStyle(.roundedBorder).onSubmit(apply)
                        if option.id == "--record" {
                            Button("Выбрать файл…") {
                                let format = model.scrcpyProfile.enabled["--record-format"] ?? "mkv"
                                if let url = saveURL("Android.\(format)") { draft = url.path; apply() }
                            }
                        }
                    }
                    HStack {
                        Button("Применить", action: apply).disabled(draft == saved || option.valueProblem(draft) != nil)
                        if let problem = option.valueProblem(draft), !draft.isEmpty {
                            Text(problem).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private enum Selection: Hashable { case inherited, bare, preset(String), custom }

    private func selectedValue() -> Selection {
        if custom { return .custom }
        guard let saved else { return .inherited }
        if saved.isEmpty && option.input == .optional { return .bare }
        return choices.contains { $0.value == saved } ? .preset(saved) : .custom
    }

    private func select(_ selection: Selection) {
        switch selection {
        case .inherited: custom = false; model.scrcpyProfile.enabled[option.id] = nil
        case .bare: custom = false; model.scrcpyProfile.enabled[option.id] = ""
        case .preset(let value): custom = false; model.scrcpyProfile.enabled[option.id] = value
        case .custom: draft = saved ?? ""; custom = true
        }
    }

    private func apply() {
        guard option.valueProblem(draft) == nil else { return }
        model.scrcpyProfile.enabled[option.id] = draft
    }

    private func sync() {
        draft = saved ?? ""
        custom = saved.map { value in
            !(value.isEmpty && option.input == .optional) && !choices.contains { $0.value == value }
        } ?? false
    }
}

extension Workspace {
    func loadScrcpyOptions() {
        let binary = Runner.executable(.scrcpy)
        Task {
            do {
                let options = try await Task.detached {
                    let options = ScrcpyOption.parse(try ToolInstallation.command(binary, ["--help"]))
                    guard !options.isEmpty else { throw Failure("Список параметров scrcpy пуст") }
                    return options
                }.value
                guard binary == Runner.executable(.scrcpy) else { return }
                self.scrcpyOptions = options
                self.scrcpyCatalogError = ""
            } catch { self.scrcpyCatalogError = error.localizedDescription }
        }
    }

    func runScrcpyDiagnostic(_ option: ScrcpyOption) {
        scrcpyDiagnosticID = option.id
        if option.id.hasPrefix("--list-") && !canLaunchScrcpy {
            scrcpyDiagnostic = "Подключите Android через ADB"
            return
        }
        do {
            let args = try scrcpyProfile.arguments(options: scrcpyOptions, serial: serial, title: deviceName, record: nil, diagnostic: option)
            scrcpyDiagnostic = ""
            job("scrcpy \(option.id)", { runner in
                try runner.text(.scrcpy, args, allowError: true)
            }, done: { self.scrcpyDiagnostic = $0 })
        } catch { scrcpyDiagnostic = error.localizedDescription }
    }
}
