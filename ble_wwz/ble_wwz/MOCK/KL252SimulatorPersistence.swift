// KL252SimulatorPersistence.swift
// 模拟器设备设置持久化 — Codable 快照、出厂默认值、JSON 原子读写
// ⚠️ 本文件为独立模拟器模块，不影响项目原有 BLE 业务代码

import Foundation

// MARK: - Factory Defaults

enum KL252SimulatorDefaults {
    static let hourFormat: UInt8 = 0x00
    static let screenOffConfig: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00]
    /// 关闭 + MusicID=3 + Vol=100（§4.2 `0x23` 协议默认）
    static let callRingConfig: [UInt8] = [0x00, 0x03, 0x00, 0x00, 0x00, 0x64]
    static let alarmsGlobalEnabled: UInt8 = 0x01

    /// §4.1 出厂默认闹钟（与协议 0x03 示例一致：例程 ID=1 + 其他闹钟 ID=2）
    static let alarms: [PersistedAlarm] = [
        PersistedAlarm(from: SimAlarm(
            alarmType: 0x00, alarmID: 1, nameLen: 0, name: [],
            sleepSchedule: [0x01, 0x16, 0x00, 0x7F], wakeSchedule: [0x01, 0x07, 0x00, 0x7F],
            mainSchedule: [], activePeriod: [], wakeupPeriod: []
        )),
        PersistedAlarm(from: SimAlarm(
            alarmType: 0x01, alarmID: 2, nameLen: 0, name: [],
            sleepSchedule: [], wakeSchedule: [],
            mainSchedule: [0x01, 0x07, 0x1E, 0x3E],
            activePeriod: [0x01, 0xC8, 0x00, 0x00, 0x00, 0x3C, 0x0A],
            wakeupPeriod: [0x01, 0xC8, 0x00, 0x00, 0x00, 0x3C, 0x0A]
        )),
        PersistedAlarm(from: SimAlarm(
            alarmType: 0x01, alarmID: 3, nameLen: 6, name: Array("午休".utf8),
            sleepSchedule: [], wakeSchedule: [],
            mainSchedule: [0x01, 0x0C, 0x1E, 0x7F],
            activePeriod: [0x01, 0x64, 0x00, 0x00, 0x00, 0x14, 0x05],
            wakeupPeriod: [0x01, 0x64, 0x00, 0x00, 0x00, 0x14, 0x05]
        )),
    ]

    static var simAlarms: [UInt8: SimAlarm] {
        Dictionary(uniqueKeysWithValues: alarms.map { ($0.alarmID, $0.toSimAlarm()) })
    }

    /// §4.1.1 出厂 38B 例程基础设置
    static var programBasicConfig: [UInt8] {
        var cfg: [UInt8] = []
        cfg += [0xE0, 0x01]                           // TargetDuration=480
        cfg += [0x01, 0x64, 0x00, 0x00, 0x00, 0x50, 0x2D, 0x00]  // 睡眠提醒
        cfg += [0x01, 0x64, 0x00, 0x00, 0x00, 0x50, 0x05]         // 提示期
        cfg += [0x01, 0x64, 0x00, 0x00, 0x00, 0x50, 0x05]         // 激活期
        cfg += [0x01, 0x64, 0x00, 0x00, 0x00, 0x50, 0x05]         // 唤醒期
        cfg += [0x00, 0x64, 0x00, 0x00, 0x00, 0x50, 0x05]         // 锁定期
        return cfg
    }

    static func makeSnapshot() -> KL252SimulatorSnapshot {
        KL252SimulatorSnapshot(
            hourFormat: hourFormat,
            screenOffConfig: screenOffConfig,
            callRingConfig: callRingConfig,
            alarmsGlobalEnabled: alarmsGlobalEnabled,
            programBasicConfig: programBasicConfig,
            alarms: alarms
        )
    }
}

// MARK: - Persisted Alarm

struct PersistedAlarm: Codable, Equatable {
    var alarmType: UInt8
    var alarmID: UInt8
    var nameLen: UInt8
    var name: [UInt8]
    var sleepSchedule: [UInt8]
    var wakeSchedule: [UInt8]
    var mainSchedule: [UInt8]
    var activePeriod: [UInt8]
    var wakeupPeriod: [UInt8]

    init(from alarm: SimAlarm) {
        alarmType = alarm.alarmType
        alarmID = alarm.alarmID
        nameLen = alarm.nameLen
        name = alarm.name
        sleepSchedule = alarm.sleepSchedule
        wakeSchedule = alarm.wakeSchedule
        mainSchedule = alarm.mainSchedule
        activePeriod = alarm.activePeriod
        wakeupPeriod = alarm.wakeupPeriod
    }

    func toSimAlarm() -> SimAlarm {
        SimAlarm(
            alarmType: alarmType,
            alarmID: alarmID,
            nameLen: nameLen,
            name: name,
            sleepSchedule: sleepSchedule,
            wakeSchedule: wakeSchedule,
            mainSchedule: mainSchedule,
            activePeriod: activePeriod,
            wakeupPeriod: wakeupPeriod
        )
    }

    /// 与 `handleAddAlarm` 校验口径一致
    var isValid: Bool {
        guard Int(nameLen) == name.count else { return false }
        if alarmType == 0x00 {
            return sleepSchedule.count == 4 && wakeSchedule.count == 4
        }
        return mainSchedule.count == 4
            && activePeriod.count == 7
            && wakeupPeriod.count == 7
    }
}

// MARK: - Snapshot

struct KL252SimulatorSnapshot: Codable, Equatable {
    var version: Int = 1
    var hourFormat: UInt8
    var screenOffConfig: [UInt8]
    var callRingConfig: [UInt8]
    var alarmsGlobalEnabled: UInt8
    var programBasicConfig: [UInt8]
    var alarms: [PersistedAlarm]

    /// 裁剪/校验字段长度与闹钟结构；无效时返回 nil
    func validated() -> KL252SimulatorSnapshot? {
        guard programBasicConfig.count == 38,
              screenOffConfig.count == 5,
              callRingConfig.count == 6 else { return nil }
        let validAlarms = alarms.filter(\.isValid)
        return KL252SimulatorSnapshot(
            version: version,
            hourFormat: hourFormat,
            screenOffConfig: screenOffConfig,
            callRingConfig: callRingConfig,
            alarmsGlobalEnabled: alarmsGlobalEnabled,
            programBasicConfig: programBasicConfig,
            alarms: validAlarms
        )
    }
}

// MARK: - Persistence

enum KL252SimulatorPersistence {
    private static let bundleID = "com.ksmartnet.ble-wwz"
    private static let fileName = "device_state.json"
    private static let tmpFileName = "device_state.json.tmp"

    private static var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("KL252Simulator", isDirectory: true)
    }

    private static var storageURL: URL {
        storageDirectory.appendingPathComponent(fileName)
    }

    private static var tmpURL: URL {
        storageDirectory.appendingPathComponent(tmpFileName)
    }

    /// 文件不存在或解码/校验失败时返回 `nil`；坏文件会被出厂默认覆盖
    static func load() -> KL252SimulatorSnapshot? {
        let url = storageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(KL252SimulatorSnapshot.self, from: data)
            if let validated = snapshot.validated() {
                return validated
            }
            overwriteCorruptFile()
            return nil
        } catch {
            overwriteCorruptFile()
            return nil
        }
    }

    /// 原子写入：先写 `.tmp` 再 `replaceItem`
    static func save(_ snapshot: KL252SimulatorSnapshot) {
        guard let validated = snapshot.validated() else { return }
        do {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(validated)
            try data.write(to: tmpURL, options: .atomic)
            if FileManager.default.fileExists(atPath: storageURL.path) {
                _ = try FileManager.default.replaceItem(
                    at: storageURL,
                    withItemAt: tmpURL,
                    backupItemName: nil,
                    options: [],
                    resultingItemURL: nil
                )
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: storageURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
        }
    }

    static func remove() {
        try? FileManager.default.removeItem(at: storageURL)
        try? FileManager.default.removeItem(at: tmpURL)
    }

    private static func overwriteCorruptFile() {
        save(KL252SimulatorDefaults.makeSnapshot())
    }
}
