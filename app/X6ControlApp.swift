import AppKit
import Darwin
import Foundation
import WebKit

private struct DPISettings: Codable {
    var stages: [Int]
    var activeStage: Int
    var angleSnap: Bool
    var rippleControl: Bool
    var lodMm: Int
}

private struct LightingSettings: Codable {
    var mode: String
    var color: String
    var speed: Int
    var sleepMinutes: Double
    var debounceMs: Int
}

private struct MouseConfig: Codable {
    var dpi: DPISettings
    var pollingHz: Int
    var lighting: LightingSettings
    var buttons: [String]

    static func standard() -> MouseConfig {
        MouseConfig(
            dpi: DPISettings(stages: [800, 1200, 1600, 3200, 5600, 26000], activeStage: 2,
                             angleSnap: false, rippleControl: false, lodMm: 2),
            pollingHz: 1000,
            lighting: LightingSettings(mode: "breathing", color: "#00FF00", speed: 6,
                                       sleepMinutes: 0.5, debounceMs: 8),
            buttons: ["left", "right", "middle", "forward", "backward", "dpi_plus", "dpi_minus"]
        )
    }

    static func reset() -> MouseConfig {
        var value = standard()
        value.lighting.mode = "dpi_static"
        value.lighting.debounceMs = 4
        return value
    }

    func validated() throws -> MouseConfig {
        guard dpi.stages.count == 6,
              dpi.stages.allSatisfy({ $0 >= 50 && $0 <= 26000 && $0 % 50 == 0 }) else {
            throw AppFailure.message("DPI задаётся от 50 до 26 000 с шагом 50")
        }
        guard (1...6).contains(dpi.activeStage) else {
            throw AppFailure.message("Активный уровень DPI должен быть от 1 до 6")
        }
        guard dpi.lodMm == 1 || dpi.lodMm == 2 else {
            throw AppFailure.message("Высота отрыва должна быть 1 или 2 мм")
        }
        guard [125, 250, 500, 1000].contains(pollingHz) else {
            throw AppFailure.message("Частота опроса должна быть 125, 250, 500 или 1000 Гц")
        }
        guard LightingMode.templates[lighting.mode] != nil else {
            throw AppFailure.message("Неизвестный режим подсветки")
        }
        guard lighting.color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
            throw AppFailure.message("Цвет должен быть в формате #RRGGBB")
        }
        guard (1...8).contains(lighting.speed) else {
            throw AppFailure.message("Скорость эффекта должна быть от 1 до 8")
        }
        guard lighting.sleepMinutes.isFinite, lighting.sleepMinutes >= 0.5,
              lighting.sleepMinutes <= 60,
              lighting.sleepMinutes * 2 == (lighting.sleepMinutes * 2).rounded() else {
            throw AppFailure.message("Таймер сна задаётся от 0,5 до 60 минут с шагом 0,5")
        }
        guard (2...25).contains(lighting.debounceMs) else {
            throw AppFailure.message("Задержка кнопок задаётся от 2 до 25 мс")
        }
        guard buttons.count == 7, buttons.allSatisfy({ RemapEncoder.actionIDs[$0] != nil }) else {
            throw AppFailure.message("Нужно задать поддерживаемые действия для семи кнопок")
        }
        if !RemapEncoder.buttonOneActions.contains(buttons[0]) {
            throw AppFailure.message("Для левой кнопки доступны базовые и браузерные действия")
        }
        return self
    }
}

private struct LocalProfile: Codable {
    var id: String
    var name: String
    var config: MouseConfig
}

private struct DeviceRecord: Codable {
    var activeProfile: String
    var profiles: [LocalProfile]

    static func standard() -> DeviceRecord {
        let profile = LocalProfile(id: "standard", name: "Стандарт X6", config: .standard())
        return DeviceRecord(activeProfile: profile.id, profiles: [profile])
    }
}

private struct ProfilesFile: Codable {
    var version: Int
    var devices: [String: DeviceRecord]

    static func empty() -> ProfilesFile { ProfilesFile(version: 1, devices: [:]) }
}

private enum AppFailure: Error {
    case message(String)
    case partial(message: String, acknowledged: [String], unconfirmed: String)

    var response: [String: Any] {
        switch self {
        case .message(let value):
            return ["ok": false, "error": value]
        case .partial(let value, let acknowledged, let unconfirmed):
            return ["ok": false, "message": value, "partial": acknowledged, "unconfirmed": unconfirmed]
        }
    }
}

private final class ProfileStore {
    private let lock = NSRecursiveLock()
    private let fileURL: URL
    private var file: ProfilesFile

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("X6 Control", isDirectory: true)
        fileURL = directory.appendingPathComponent("profiles.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(ProfilesFile.self, from: data), saved.version == 1 {
            file = saved
        } else {
            file = .empty()
        }
    }

    func record(for key: String) throws -> DeviceRecord {
        lock.lock(); defer { lock.unlock() }
        if var record = file.devices[key], !record.profiles.isEmpty {
            if !record.profiles.contains(where: { $0.id == record.activeProfile }) {
                record.activeProfile = record.profiles[0].id
                file.devices[key] = record
                try saveLocked()
            }
            return record
        }
        let record = DeviceRecord.standard()
        file.devices[key] = record
        try saveLocked()
        return record
    }

    func config(for key: String, profileID: String) throws -> (DeviceRecord, LocalProfile) {
        lock.lock(); defer { lock.unlock() }
        let record = try ensureLocked(key)
        guard let profile = record.profiles.first(where: { $0.id == profileID }) else {
            throw AppFailure.message("Локальный профиль не найден")
        }
        return (record, profile)
    }

    func saveConfig(_ config: MouseConfig, key: String, profileID: String) throws {
        lock.lock(); defer { lock.unlock() }
        var record = try ensureLocked(key)
        guard let index = record.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw AppFailure.message("Локальный профиль не найден")
        }
        record.profiles[index].config = try config.validated()
        file.devices[key] = record
        try saveLocked()
    }

    func manage(_ operation: String, key: String, profileID: String, name: String?) throws -> DeviceRecord {
        lock.lock(); defer { lock.unlock() }
        var record = try ensureLocked(key)
        guard let index = record.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw AppFailure.message("Локальный профиль не найден")
        }
        switch operation {
        case "create":
            let newName = cleanName(name, fallback: "Новый профиль")
            let profile = LocalProfile(id: UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased(),
                                       name: newName, config: record.profiles[index].config)
            record.profiles.append(profile)
            record.activeProfile = profile.id
        case "duplicate":
            let newName = cleanName(name, fallback: record.profiles[index].name + " копия")
            let profile = LocalProfile(id: UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased(),
                                       name: newName, config: record.profiles[index].config)
            record.profiles.append(profile)
        case "rename":
            record.profiles[index].name = try requiredName(name)
        case "activate":
            record.activeProfile = profileID
        case "delete":
            guard record.profiles.count > 1 else { throw AppFailure.message("Нельзя удалить последний профиль") }
            guard profileID != record.activeProfile else { throw AppFailure.message("Сначала переключитесь на другой профиль") }
            record.profiles.remove(at: index)
        default:
            throw AppFailure.message("Неизвестная операция с профилем")
        }
        file.devices[key] = record
        try saveLocked()
        return record
    }

    private func ensureLocked(_ key: String) throws -> DeviceRecord {
        guard !key.isEmpty else { throw AppFailure.message("Нет выбранного устройства") }
        if var record = file.devices[key], !record.profiles.isEmpty {
            if !record.profiles.contains(where: { $0.id == record.activeProfile }) {
                record.activeProfile = record.profiles[0].id
                file.devices[key] = record
                try saveLocked()
            }
            return record
        }
        let record = DeviceRecord.standard()
        file.devices[key] = record
        try saveLocked()
        return record
    }

    private func saveLocked() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: .atomic)
        _ = chmod(fileURL.path, 0o600)
    }

    private func cleanName(_ name: String?, fallback: String) -> String {
        let value = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String((value.isEmpty ? fallback : value).prefix(40))
    }

    private func requiredName(_ name: String?) throws -> String {
        let value = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AppFailure.message("Введите название профиля") }
        return String(value.prefix(40))
    }
}

private enum LightingMode {
    static let templates: [String: [UInt8]] = [
        "off": hex("050f010003a800ff00010401af"),
        "fixed": hex("050f011003a800ff00010401bf"),
        "breathing": hex("050f012003a800ff00010401cf"),
        "neon": hex("050f013002a80000ff010401de"),
        "color_cycle": hex("050f014003a80000ff010401ef"),
        "dpi_static": hex("050f015002a80000ff010401fe"),
        "dpi_breathing": hex("050f016004a80000ff01040210"),
    ]
    static let reset = hex("050f015003a800ff00010401ff")

    static func encode(_ config: MouseConfig, reset: Bool = false) -> [UInt8] {
        if reset { return self.reset }
        var report = templates[config.lighting.mode]!
        report[4] = (report[4] & 0xF0) | UInt8(9 - config.lighting.speed)
        report[9] = UInt8((config.lighting.sleepMinutes * 2).rounded())
        report[10] = UInt8(config.lighting.debounceMs)
        if config.lighting.mode == "fixed" || config.lighting.mode == "breathing" {
            let color = Array(config.lighting.color.dropFirst())
            report[6] = UInt8(String(color[0..<2]), radix: 16) ?? 0
            report[7] = UInt8(String(color[2..<4]), radix: 16) ?? 0
            report[8] = UInt8(String(color[4..<6]), radix: 16) ?? 0
        }
        let checksum = report[3..<11].reduce(0) { $0 + Int($1) }
        report[11] = UInt8((checksum >> 8) & 0xff)
        report[12] = UInt8(checksum & 0xff)
        return report
    }
}

private enum DPIEncoder {
    static let stageColors: [[UInt8]] = [
        [255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0],
        [0, 255, 255], [255, 0, 255], [255, 64, 0], [255, 255, 255],
    ]

    static func encode(_ config: MouseConfig) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 52)
        report[0...2] = [0x04, 0x38, 0x01]
        let angle: UInt8 = config.dpi.angleSnap ? 1 : 0
        report[3] = angle
        report[4] = config.dpi.rippleControl ? 1 : 0
        report[5] = 0x3F
        report[6] = angle
        report[7] = config.dpi.lodMm == 2 ? 1 : 0
        let stages = config.dpi.stages + [50, 50]
        for (index, value) in stages.enumerated() {
            let raw = value / 50 - 1
            report[8 + index] = UInt8(raw & 0xff)
            report[16 + index] = UInt8((raw >> 8) & 0xff)
        }
        report[24] = UInt8(config.dpi.activeStage)
        for (index, color) in stageColors.enumerated() {
            report.replaceSubrange((25 + index * 3)..<(28 + index * 3), with: color)
        }
        report[49] = 1
        let checksum = report[3..<50].reduce(0) { $0 + Int($1) }
        report[50] = UInt8((checksum >> 8) & 0xff)
        report[51] = UInt8(checksum & 0xff)
        return report
    }
}

private enum PollingEncoder {
    static func encode(_ config: MouseConfig) -> [UInt8] {
        let divisor = UInt8(1000 / config.pollingHz)
        return [0x06, 0x09, 0x01, divisor, ~divisor, 0, 0, 0, 0]
    }
}

private enum RemapEncoder {
    static let groups = [1, 2, 3, 7, 8, 5, 6]
    static let actionIDs: [String: UInt8] = [
        "off": 0x01, "left": 0x02, "right": 0x03, "middle": 0x04,
        "backward": 0x05, "forward": 0x06, "double_click": 0x07, "fire": 0x08,
        "scroll_up": 0x09, "scroll_down": 0x0A, "dpi_cycle": 0x0D,
        "dpi_plus": 0x0E, "dpi_minus": 0x0F, "media_player": 0x15,
        "previous_track": 0x16, "next_track": 0x17, "play_pause": 0x18,
        "stop": 0x19, "mute": 0x1A, "volume_up": 0x1B, "volume_down": 0x1C,
        "browser_calculator": 0x1D, "browser_email": 0x1E, "browser_forward": 0x20,
        "browser_backward": 0x21, "browser_stop": 0x22, "browser_computer": 0x23,
        "browser_refresh": 0x24, "browser_home": 0x25, "browser_search": 0x26,
    ]
    static let buttonOneActions: Set<String> = [
        "off", "left", "right", "middle", "backward", "forward", "double_click", "fire",
        "browser_calculator", "browser_email", "browser_forward", "browser_backward",
        "browser_stop", "browser_computer", "browser_refresh", "browser_home", "browser_search",
    ]
    static let baseline = hex("083b010200000300000400000d00000e00000f00000600000500003c00000100000100000100000100000100000100000100000a00000900000094")

    static func encode(_ config: MouseConfig) -> [UInt8] {
        var report = baseline
        for index in 0..<7 {
            let offset = 3 + (groups[index] - 1) * 3
            report[offset] = actionIDs[config.buttons[index]]!
        }
        let checksum = report[3..<57].reduce(0) { $0 + Int($1) }
        report[57] = UInt8((checksum >> 8) & 0xff)
        report[58] = UInt8(checksum & 0xff)
        return report
    }
}

private func hex(_ value: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        if let byte = UInt8(value[index..<next], radix: 16) { bytes.append(byte) }
        index = next
    }
    return bytes
}

private func configJSON(_ config: MouseConfig) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(config),
          let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return result
}

private final class NativeAPI {
    private let profiles = ProfileStore()
    private let hardwareLock = NSLock()
    private let bridgeURL = Bundle.main.url(forResource: "X6Bridge", withExtension: nil)!

    func handle(path: String, method: String, body: [String: Any]?) -> [String: Any] {
        do {
            if method == "GET", path.hasPrefix("/api/state") { return try state(path: path) }
            guard method == "POST" else { throw AppFailure.message("Метод запроса не поддерживается") }
            guard let body else { throw AppFailure.message("Пустой запрос") }
            if path == "/api/profile/config" { return try saveConfig(body) }
            if path == "/api/profile/manage" { return try manageProfile(body) }
            if path == "/api/apply" { return try apply(body) }
            if path == "/api/reset" { return try reset(body) }
            throw AppFailure.message("Маршрут не найден")
        } catch let failure as AppFailure {
            return failure.response
        } catch {
            return ["ok": false, "error": "Ошибка приложения: \(error.localizedDescription)"]
        }
    }

    private func state(path: String) throws -> [String: Any] {
        let parts = URLComponents(string: "http://x6.local\(path)")
        let query = Dictionary((parts?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        var devices: [[String: Any]] = []
        var bridgeError = ""
        do { devices = try onlineDevices() }
        catch { bridgeError = error.localizedDescription }

        let requestedLocation = query["location"] ?? ""
        let requestedKey = query["deviceKey"] ?? ""
        var selected = devices.first { String(describing: $0["locationID"] ?? "") == requestedLocation }
        if selected == nil, !requestedKey.isEmpty { selected = devices.first { ($0["deviceKey"] as? String) == requestedKey } }
        if selected == nil, devices.count == 1 { selected = devices.first }

        if selected == nil && devices.count > 1 && requestedKey.isEmpty {
            return ["ok": true, "devices": devices, "selected": NSNull(), "profile": configJSON(.standard()),
                    "profileList": [[String: String]](), "bridgeError": bridgeError, "message": "Выберите подключённую мышь или приёмник."]
        }
        guard let device = selected, let key = device["deviceKey"] as? String else {
            if !requestedKey.isEmpty {
                let record = try profiles.record(for: requestedKey)
                let active = record.profiles.first { $0.id == record.activeProfile } ?? record.profiles[0]
                return ["ok": true, "devices": devices, "selected": NSNull(), "profile": configJSON(active.config),
                        "profileID": active.id, "profileName": active.name, "profileList": publicRecord(record),
                        "bridgeError": bridgeError, "online": false, "deviceKey": requestedKey,
                        "message": "Настройки профиля хранятся на Mac. X6 не сообщает сохранённые значения для чтения."]
            }
            return ["ok": true, "devices": devices, "selected": NSNull(), "profile": configJSON(.standard()),
                    "profileList": [[String: String]](), "bridgeError": bridgeError, "online": false,
                    "message": "Подключите Attack Shark X6, чтобы отправлять настройки."]
        }
        let record = try profiles.record(for: key)
        guard let active = record.profiles.first(where: { $0.id == record.activeProfile }) ?? record.profiles.first else {
            throw AppFailure.message("Локальный профиль не найден")
        }
        return ["ok": true, "devices": devices, "selected": device, "profile": configJSON(active.config),
                "profileID": active.id, "profileName": active.name, "profileList": publicRecord(record),
                "bridgeError": bridgeError, "online": true, "deviceKey": key,
                "message": "Настройки профиля хранятся на Mac. X6 не сообщает сохранённые значения для чтения."]
    }

    private func saveConfig(_ body: [String: Any]) throws -> [String: Any] {
        let key = body["deviceKey"] as? String ?? ""
        let profileID = body["profileID"] as? String ?? ""
        guard let value = body["config"], let data = try? JSONSerialization.data(withJSONObject: value),
              let config = try? JSONDecoder().decode(MouseConfig.self, from: data) else {
            throw AppFailure.message("Профиль имеет неверный формат")
        }
        try profiles.saveConfig(config.validated(), key: key, profileID: profileID)
        return ["ok": true]
    }

    private func manageProfile(_ body: [String: Any]) throws -> [String: Any] {
        let key = body["deviceKey"] as? String ?? ""
        let profileID = body["profileID"] as? String ?? ""
        let operation = body["operation"] as? String ?? ""
        let record = try profiles.manage(operation, key: key, profileID: profileID, name: body["name"] as? String)
        guard let current = record.profiles.first(where: { $0.id == record.activeProfile }) ?? record.profiles.first else {
            throw AppFailure.message("Локальный профиль не найден")
        }
        return ["ok": true, "profile": configJSON(current.config), "profileID": current.id,
                "profileName": current.name, "profileList": publicRecord(record)]
    }

    private func apply(_ body: [String: Any]) throws -> [String: Any] {
        let device = try selectedDevice(body)
        let key = device["deviceKey"] as? String ?? ""
        let profileID = body["profileID"] as? String ?? ""
        let (_, profile) = try profiles.config(for: key, profileID: profileID)
        let config = try profile.config.validated()
        let reports: [[UInt8]]
        switch body["section"] as? String ?? "" {
        case "performance": reports = [DPIEncoder.encode(config), PollingEncoder.encode(config)]
        case "lighting": reports = [LightingMode.encode(config)]
        case "controls": reports = [DPIEncoder.encode(config), LightingMode.encode(config)]
        case "buttons": reports = [RemapEncoder.encode(config)]
        case "profile": reports = [DPIEncoder.encode(config), LightingMode.encode(config), PollingEncoder.encode(config), RemapEncoder.encode(config)]
        default: throw AppFailure.message("Неизвестная группа настроек")
        }
        return ["ok": true, "acknowledged": try sendReports(reports, to: device)]
    }

    private func reset(_ body: [String: Any]) throws -> [String: Any] {
        let device = try selectedDevice(body)
        let key = device["deviceKey"] as? String ?? ""
        let config = MouseConfig.reset()
        let reports = [DPIEncoder.encode(config), LightingMode.encode(config, reset: true),
                       PollingEncoder.encode(config), RemapEncoder.encode(config)]
        let acknowledged = try sendReports(reports, to: device)
        let record = try profiles.record(for: key)
        let profileID = body["profileID"] as? String ?? record.activeProfile
        try profiles.saveConfig(config, key: key, profileID: profileID)
        return ["ok": true, "acknowledged": acknowledged, "profile": configJSON(config),
                "profileID": profileID, "profileName": record.profiles.first(where: { $0.id == profileID })?.name ?? "Стандарт X6"]
    }

    private func selectedDevice(_ body: [String: Any]) throws -> [String: Any] {
        let location = String(describing: body["locationID"] ?? "")
        let key = body["deviceKey"] as? String ?? ""
        guard let device = try onlineDevices().first(where: {
            String(describing: $0["locationID"] ?? "") == location && ($0["deviceKey"] as? String) == key
        }) else {
            throw AppFailure.message("Выбранная мышь отключена или изменилась. Обновите список устройств.")
        }
        return device
    }

    private func onlineDevices() throws -> [[String: Any]] {
        let response = try bridgeCall(["list"])
        let source = response["devices"] as? [[String: Any]] ?? []
        return source.map { original in
            var value = original
            value["deviceKey"] = Self.deviceKey(original)
            return value
        }
    }

    private func sendReports(_ reports: [[UInt8]], to device: [String: Any]) throws -> [String] {
        hardwareLock.lock(); defer { hardwareLock.unlock() }
        let location = String(describing: device["locationID"] ?? "")
        var acknowledged: [String] = []
        for report in reports {
            let response = try bridgeCall(["send", location, report.map { String(format: "%02x", $0) }.joined()])
            let reportID = response["reportID"] as? Int ?? Int(report[0])
            let label = String(format: "0x%02x", reportID)
            guard response["acknowledged"] as? Bool == true else {
                throw AppFailure.partial(message: "Команда \(label) отправлена, но подтверждение мыши не пришло. Устройство могло принять настройку.",
                                         acknowledged: acknowledged, unconfirmed: label)
            }
            acknowledged.append(label)
        }
        return acknowledged
    }

    private func bridgeCall(_ arguments: [String]) throws -> [String: Any] {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = bridgeURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        do { try process.run() }
        catch { throw AppFailure.message("Не удалось запустить системный USB-мост: \(error.localizedDescription)") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let detail = String(data: errorData, encoding: .utf8) ?? "пустой ответ"
            throw AppFailure.message("USB-мост X6 вернул некорректный ответ: \(detail)")
        }
        guard process.terminationStatus == 0, response["ok"] as? Bool == true else {
            throw AppFailure.message(response["error"] as? String ?? "USB-мост X6 завершился с ошибкой")
        }
        return response
    }

    private func publicRecord(_ record: DeviceRecord) -> [String: Any] {
        ["activeProfile": record.activeProfile,
         "profiles": record.profiles.map { ["id": $0.id, "name": $0.name] }]
    }

    private static func deviceKey(_ device: [String: Any]) -> String {
        let vendor = device["vendorID"] as? String ?? "1d57"
        let product = device["productID"] as? String ?? "fa61"
        let serial = (device["serial"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !serial.isEmpty { return "\(vendor):\(product):serial:\(serial)" }
        return "\(vendor):\(product):location:\(device["locationID"] ?? "unknown")"
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private let api = NativeAPI()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureMenu()
        let content = WKUserContentController()
        content.add(self, name: "x6Native")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self

        let minimum = NSSize(width: 980, height: 680)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "X6 Control"
        window.minSize = minimum
        window.center()
        window.contentView = webView
        window.setFrameAutosaveName("X6ControlMainWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "public") {
            webView.loadFileURL(page, allowingReadAccessTo: Bundle.main.resourceURL!)
        } else {
            showStartupError("Не найден интерфейс X6 Control в приложении.")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let requestID = payload["id"] as? Int,
              let path = payload["path"] as? String,
              let method = payload["method"] as? String else { return }
        let body = payload["body"] as? [String: Any]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.api.handle(path: path, method: method, body: body)
            let json = (try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
            let encoded = json.base64EncodedString()
            DispatchQueue.main.async {
                let script = "window.__x6NativeReply && window.__x6NativeReply(\(requestID), '\(encoded)');"
                self.webView.evaluateJavaScript(script, completionHandler: nil)
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let resourceRoot = Bundle.main.resourceURL?.standardizedFileURL.path ?? ""
        let target = url.standardizedFileURL.path
        if url.isFileURL && target.hasPrefix(resourceRoot) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    private func configureMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "О X6 Control", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Завершить X6 Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "Окно")
        viewMenu.addItem(withTitle: "Обновить интерфейс", action: #selector(reloadPage), keyEquivalent: "r")
        viewMenu.addItem(withTitle: "Свернуть", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func reloadPage() { webView.reload() }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "X6 Control"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        alert.informativeText = "Приложение для настройки Attack Shark X6 · версия \(version)"
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func showStartupError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Не удалось открыть X6 Control"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
}

@main
private enum X6ControlMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
