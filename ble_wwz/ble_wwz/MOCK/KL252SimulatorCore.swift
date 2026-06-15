// KL252SimulatorCore.swift
// BLE 虚拟设备模拟器 - 核心外设管理器
// 模拟 KL252 从机设备，响应协议 v1.0.1；含文件传输；不含固件升级 (§4.6)
// ⚠️ 本文件为独立模拟器模块，不影响项目原有 BLE 业务代码

import Foundation
import CoreBluetooth
import os
#if os(macOS)
import IOBluetooth
#endif

// MARK: - Local Logging (replaces iOS LogKit dependency)

enum LogLevel {
    case debug, info, warn
}

private func WZLog(_ message: String, level: LogLevel = .info) {
    let logger = Logger(subsystem: "com.ksmartnet.ble-wwz", category: "KL252-SIM")
    switch level {
    case .debug: logger.debug("\(message, privacy: .public)")
    case .info:  logger.info("\(message, privacy: .public)")
    case .warn:  logger.warning("\(message, privacy: .public)")
    }
#if DEBUG
    print(message)
#endif
}

// MARK: - Protocol Constants
// 00001800-0000-1000-8000-00805F9B34FB
// 0000180F-0000-1000-8000-00805F9B34FB
// 0000AB00-0000-1000-8000-00805F9B34FB
enum KL252_DEVICE_UUID {
    // 标准服务
    static let genericAccessService  = CBUUID(string: "00001800-0000-1000-8000-00805F9B34FB")
    static let batteryService        = CBUUID(string: "0000180F-0000-1000-8000-00805F9B34FB")
    // 自定义服务
    static let customService         = CBUUID(string: "0000AB00-0000-1000-8000-00805F9B34FB")

    // 标准特征
    static let deviceName            = CBUUID(string: "2A00")
    static let batteryLevel          = CBUUID(string: "2A19")
    // 自定义特征
    static let command               = CBUUID(string: "AB01")  // Write
    static let response              = CBUUID(string: "AB02")  // Notify
    static let fileTransfer          = CBUUID(string: "AB03")  // Write Without Response
}

// MARK: - MTU（Peripheral 侧说明）
//
// iOS `CBPeripheralManager` 无法主动发起 ATT MTU 交换；MTU 由 Central（KL252BLEManager）
// 在连接后协商。Peripheral 可通过 `CBCentral.maximumUpdateValueLength` 读取 Central
// 单次 Notify/Indication 可接收的最大字节数，并反推 ATT_MTU ≈ notifyMax + 3。
//
// KL252 协议参考：ATT_MTU = 247 → AB03 文件块 payloadMax = 238（= MTU - 9，§3.5）。
enum KL252SimMTU {
    static let protocolAttMtu: Int = 247
    static let protocolFilePayloadMax: Int = 238
}

// MARK: - 广播 Manufacturer Data
//
// AD Type 0xFF Manufacturer Specific Data:
//   [Company ID 2B LE][MAC 6B][NameLen 1B][Name UTF-8]
// Company ID = 0xAB52（KL252 模拟器标识，Central 可按此过滤）
enum KL252Advertisement {
    static let companyID: UInt16 = 0xAB52
    static let maxNameBytes = 20

    static func manufacturerData(mac: [UInt8], deviceName: String) -> Data {
        var mac6 = Array(mac.prefix(6))
        if mac6.count < 6 {
            mac6.append(contentsOf: Array(repeating: 0, count: 6 - mac6.count))
        }
        let nameBytes = Array(deviceName.utf8.prefix(maxNameBytes))
        var payload: [UInt8] = mac6
        payload.append(UInt8(nameBytes.count))
        payload += nameBytes

        var data = Data()
        var cid = companyID.littleEndian
        withUnsafeBytes(of: &cid) { data.append(contentsOf: $0) }
        data.append(contentsOf: payload)
        return data
    }

    static func macString(_ mac: [UInt8]) -> String {
        mac.prefix(6).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

// MARK: - Frame Codec (§3.0)

/// 全局帧头 `0xA5 0x5A` + 末字节 XOR 校验；2A19 电量与 CCCD 写入除外。
enum KL252FrameCodec {
    static let header: [UInt8] = [0xA5, 0x5A]

    /// 从帧头到负载末字节的逐字节 XOR（不含校验位）。
    static func xorChecksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0, ^)
    }

    /// 校验完整帧并返回负载（已剥离帧头与校验字节）；失败返回 nil。
    static func validateAndStrip(_ data: Data) -> [UInt8]? {
        let bytes = [UInt8](data)
        guard bytes.count >= header.count + 1,
              bytes[0] == header[0],
              bytes[1] == header[1] else { return nil }
        let body = Array(bytes.dropLast())
        guard xorChecksum(body) == bytes.last else { return nil }
        return Array(bytes.dropFirst(header.count).dropLast())
    }

    /// 为负载追加帧头与 XOR 校验，生成完整帧。
    static func wrap(_ payload: [UInt8]) -> Data {
        let body = header + payload
        let checksum = xorChecksum(body)
        return Data(body + [checksum])
    }
}

// 命令码
enum CmdID: UInt8 {
    // 闹钟与例程 0x01~0x07
    case addOrModifyAlarm   = 0x01
    case deleteAlarm        = 0x02
    case queryAlarmList     = 0x03
    case queryAlarmDetail   = 0x04
    case programBasicConfig = 0x05
    case alarmsGlobalSwitch = 0x06
    case queryRunState      = 0x07
    // 系统与来电 0x20~0x25
    case syncTime           = 0x20
    case hourFormat         = 0x21
    case screenOff          = 0x22
    case callRingConfig     = 0x23
    case callRingAction     = 0x24
    case queryDND           = 0x25
    // 设备与固件 0x30~0x3F（§4.3）
    case queryFirmware      = 0x30
    case factoryReset       = 0x31   // §4.3 恢复出厂，ConfirmCode=0xA5
    // 音源与存储 0x40~0x42
    case queryStorage       = 0x40
    case queryMusicList     = 0x41
    case deleteMusic        = 0x42
    // 音乐播放 §4.4
    case playMusic          = 0x43
    case pauseMusic         = 0x44
    case setMusicVolume     = 0x45
    case queryMusicPlayState = 0x46
    // 文件传输 §4.5
    case fileStart          = 0x50
    case fileEnd            = 0x51
    case fileWindowReq      = 0x52
    case fileWindowRsp      = 0x53
    case fileCancel         = 0x54
    // 名称修改
    case rename             = 0x55
}

// Result 码（§6.1）
enum ResultCode: UInt8 {
    case success        = 0x00
    case invalidParam   = 0x01
    case busy           = 0x02
    case fileError      = 0x03
    case unsupported    = 0x04
    case notFound       = 0x05
}

// 事件码（§6.2）
enum EventID: UInt8 {
    case alarmTrigger   = 0xE1
    case alarmTimeout   = 0xE2
    case alarmStop      = 0xE3
    case fileComplete   = 0xE5
    case fileCancel     = 0xE6
    case callRingChange = 0xE7
    case factoryRestart = 0xE8
    case dndChange      = 0xEB
}

// MARK: - Data Models

struct SimAlarm {
    var alarmType: UInt8
    var alarmID: UInt8
    var nameLen: UInt8
    var name: [UInt8]
    // 例程：睡眠段+起床段调度块
    var sleepSchedule: [UInt8]   // 4 bytes: Enable/Hour/Minute/WeekMask
    var wakeSchedule: [UInt8]    // 4 bytes
    // 其他闹钟：调度块+两期
    var mainSchedule: [UInt8]    // 4 bytes
    var activePeriod: [UInt8]    // 7 bytes
    var wakeupPeriod: [UInt8]    // 7 bytes
}

// MARK: - Simulator State

class KL252SimulatorState {
    // 设备名
    var deviceName: String = "KL252-SIM"
    /// 广播 Manufacturer Data 中的 MAC（6 字节）
    var macAddress: [UInt8] = KL252SimulatorState.makeDefaultMacAddress()
    // 固件版本
    var firmwareMajor: UInt8 = 2
    var firmwareMinor: UInt8 = 1
    var firmwarePatch: UInt8 = 3
    var buildNumber: UInt16 = 100
    // 电量
    var batteryLevel: UInt8 = 85
    // 时制 0=12h 1=24h
    var hourFormat: UInt8 = KL252SimulatorDefaults.hourFormat
    // 息屏配置 [Enable, OffH, OffM, OnH, OnM]
    var screenOffConfig: [UInt8] = KL252SimulatorDefaults.screenOffConfig
    // 来电提醒 [Enable, MusicID(4B), Volume]
    var callRingConfig: [UInt8] = KL252SimulatorDefaults.callRingConfig
    // 免打扰
    var dndEnabled: UInt8 = 0x00
    // Alarms 全局开关
    var alarmsGlobalEnabled: UInt8 = KL252SimulatorDefaults.alarmsGlobalEnabled
    // 例程基础设置（38字节）
    var programBasicConfig: [UInt8] = KL252SimulatorDefaults.programBasicConfig
    // 闹钟列表（出厂默认 3 条，见 KL252SimulatorDefaults.alarms）
    var alarms: [UInt8: SimAlarm] = KL252SimulatorDefaults.simAlarms
    // 运行状态：[RunState, AlarmType, AlarmID, Phase]
    var runState: [UInt8] = [0x00, 0x00, 0x00, 0x00]
    // 音源列表 MusicID
    var musicList: [UInt32] = KL252SimulatorMusicCatalog.bundledMusicIDs()
    // 存储：128MB total, 64MB free
    var storageTotal: UInt32 = 134_217_728
    var storageFree: UInt32  = 67_108_864
    // 音乐播放 §4.4
    var musicVolume: UInt8 = 80          // 0x45 持久化音量
    var playState: UInt8 = 0x00          // 0x00 空闲 / 0x01 播放 / 0x02 暂停
    var playSource: UInt8 = 0x00         // 0x00 APP / 0x01 例程闹钟 / 0x02 来电
    var currentMusicID: UInt32 = 0

    var macAddressString: String { KL252Advertisement.macString(macAddress) }

    /// 从持久化快照恢复设备设置字段（不影响运行时/非持久字段）
    func apply(_ snapshot: KL252SimulatorSnapshot) {
        hourFormat = snapshot.hourFormat
        screenOffConfig = snapshot.screenOffConfig
        callRingConfig = snapshot.callRingConfig
        alarmsGlobalEnabled = snapshot.alarmsGlobalEnabled
        programBasicConfig = snapshot.programBasicConfig
        alarms = Dictionary(uniqueKeysWithValues: snapshot.alarms.map { ($0.alarmID, $0.toSimAlarm()) })
    }

    func makeSnapshot() -> KL252SimulatorSnapshot {
        KL252SimulatorSnapshot(
            hourFormat: hourFormat,
            screenOffConfig: screenOffConfig,
            callRingConfig: callRingConfig,
            alarmsGlobalEnabled: alarmsGlobalEnabled,
            programBasicConfig: programBasicConfig,
            alarms: alarms.values.map { PersistedAlarm(from: $0) }.sorted { $0.alarmID < $1.alarmID }
        )
    }

    static func makeDefaultMacAddress() -> [UInt8] {
#if os(macOS)
        if let addr = IOBluetoothHostController.default()?.addressAsString() {
            let parts = addr.split(separator: ":").compactMap { UInt8($0, radix: 16) }
            if parts.count == 6 { return parts }
        }
#endif
        return [0x52, 0x4B, 0x25, 0x32, 0x00, 0x01]
    }
}

// MARK: - Delegate Protocol

protocol KL252SimulatorDelegate: AnyObject {
    func simulator(_ sim: KL252SimulatorCore, didLog message: String, direction: LogDirection)
    func simulatorDidUpdateState(_ sim: KL252SimulatorCore)
}

enum LogDirection {
    case received   // APP → 设备
    case sent       // 设备 → APP
    case info       // 系统信息
}

// MARK: - File Transfer Session (§4.5 + §5)

private struct FileTransferSession {
    var fileID: UInt8
    var musicID: UInt32
    var fileSize: UInt32
    var packetCount: Int
    var payloadMax: Int
    var received: [UInt16: Data] = [:]
    var fileXor: UInt8 = 0
}

// MARK: - Core Simulator

final class KL252SimulatorCore: NSObject {

    // MARK: Public
    weak var delegate: KL252SimulatorDelegate?
    private(set) var isAdvertising = false
    let state = KL252SimulatorState()

    /// Central 协商后的 Notify 上限（Peripheral 无法主动设置 MTU，只读）
    private(set) var lastCentralNotifyMaxLength: Int = 0
    /// 由 notifyMax 反推的 ATT_MTU（≈ notifyMax + 3）
    private(set) var lastEstimatedAttMtu: Int = 0
    /// 与 KL252BLEManager.payloadMax 同口径的文件块 payload 估算值
    private(set) var lastEstimatedFilePayloadMax: Int = 0

    // MARK: Private - CoreBluetooth
    private var peripheralManager: CBPeripheralManager!
    private var responseChar: CBMutableCharacteristic?
    private var batteryChar: CBMutableCharacteristic?
    private var deviceNameChar: CBMutableCharacteristic?

    /// 用户期望保持广播（开启后 true，手动停止后 false）
    private var wantsAdvertising = false
    /// 已添加的 GATT 服务数量，三个全部就绪后再 startAdvertising
    private var addedServiceCount = 0
    private let expectedServiceCount = 3
    /// Central 对各特征的订阅计数（同一 Central 会订阅 AB02 + 2A19）
    private var centralSubscriptions: [UUID: Int] = [:]
    /// 已建立 GATT 会话的 Central（订阅 / 读 / 写 任一即视为已连接）
    private var connectedCentrals: Set<UUID> = []
    /// 各 Central 已订阅 Notify 的特征
    private var centralSubscribedCharacteristics: [UUID: Set<CBUUID>] = [:]
    private var resumeAdvertisingWorkItem: DispatchWorkItem?
    /// 进行中的音源文件传输会话（§5.0）
    private var fileTransferSession: FileTransferSession?
    /// §4.4 真实音源播放器
    private let musicPlayer = KL252SimulatorMusicPlayer()

    // MARK: Init
    override init() {
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
        if let snapshot = KL252SimulatorPersistence.load() {
            state.apply(snapshot)
        }
        reloadBundledMusicList()
        musicPlayer.delegate = self
    }

    /// 将设备设置字段写入 Application Support JSON
    private func persistDeviceSettings() {
        KL252SimulatorPersistence.save(state.makeSnapshot())
    }

    // MARK: Public Control

    func startAdvertising() {
        guard peripheralManager.state == .poweredOn else {
            log("蓝牙未就绪，无法开启广播", direction: .info, level: .warn)
            return
        }
        log("准备开启广播 wantsAdvertising=true", direction: .info)
        wantsAdvertising = true

        if peripheralManager.isAdvertising {
            isAdvertising = true
            delegate?.simulatorDidUpdateState(self)
            return
        }

        // 连接后系统已停播但 isAdvertising 仍为 true 的 stale 状态
        if isAdvertising, responseChar != nil, !peripheralManager.isAdvertising {
            if hasConnectedCentrals {
                log("⚠️ Central 可能已断开（未收到 unsubscribe），清除陈旧订阅", direction: .info)
                centralSubscriptions.removeAll()
                connectedCentrals.removeAll()
                centralSubscribedCharacteristics.removeAll()
            }
            log("🔄 检测到广播已中断，正在恢复…", direction: .info)
            beginAdvertising()
            return
        }

        guard !isAdvertising else { return }
        addedServiceCount = 0
        setupServices()
    }

    func stopAdvertising() {
        log("手动停止广播", direction: .info)
        wantsAdvertising = false
        resumeAdvertisingWorkItem?.cancel()
        resumeAdvertisingWorkItem = nil
        centralSubscriptions.removeAll()
        connectedCentrals.removeAll()
        centralSubscribedCharacteristics.removeAll()

        guard isAdvertising || peripheralManager.isAdvertising || responseChar != nil else { return }
        if peripheralManager.isAdvertising {
            peripheralManager.stopAdvertising()
        }
        peripheralManager.removeAllServices()
        isAdvertising = false
        addedServiceCount = 0
        lastCentralNotifyMaxLength = 0
        lastEstimatedAttMtu = 0
        lastEstimatedFilePayloadMax = 0
        responseChar = nil
        batteryChar = nil
        deviceNameChar = nil
        log("🔴 已停止 BLE 广播", direction: .info)
        delegate?.simulatorDidUpdateState(self)
    }

    // MARK: - Proactive Events (快捷面板触发)

    /// 主动上报电量
    func notifyBatteryLevel(_ level: UInt8) {
        state.batteryLevel = level
        guard let battChar = batteryChar else { return }
        let data = Data([level])
        let ok = peripheralManager.updateValue(data, for: battChar, onSubscribedCentrals: nil)
        log("2A19 battery notify level=\(level)% \(hexString(data))\(ok ? "" : " [缓冲满]")", direction: .sent, level: ok ? .info : .warn)
    }

    /// 触发闹钟事件
    func sendAlarmEvent(_ eventID: EventID, alarmType: UInt8, alarmID: UInt8, phase: UInt8) {
        let payload: [UInt8] = [alarmType, alarmID, phase]
        sendEventFrame(eventID: eventID.rawValue, payload: payload)
    }

    /// 来电提醒状态变更
    func sendCallRingEvent(action: UInt8) {
        if action == 0x01 {
            beginCallRingPlayback()
        } else if action == 0x00 {
            stopCallRingPlayback()
        }
        sendEventFrame(eventID: EventID.callRingChange.rawValue, payload: [action])
    }

    /// 免打扰状态变更
    func sendDNDEvent(enabled: UInt8) {
        state.dndEnabled = enabled
        sendEventFrame(eventID: EventID.dndChange.rawValue, payload: [enabled])
    }

    /// 恢复出厂重启事件
    func sendFactoryRestartEvent() {
        sendEventFrame(eventID: EventID.factoryRestart.rawValue, payload: [])
    }

    // MARK: - Private: Service Setup

    private func setupServices() {
        // --- 1. Generic Access Service (0x1800) ---
        let nameChar = CBMutableCharacteristic(
            type: KL252_DEVICE_UUID.deviceName,
            properties: [.read, .write],
            value: nil,
            permissions: [.readable, .writeable]
        )
        deviceNameChar = nameChar
        let genericAccessService = CBMutableService(type: KL252_DEVICE_UUID.genericAccessService, primary: true)
        genericAccessService.characteristics = [nameChar]

        // --- 2. Custom Service (0xAB00) ---
        let cmdChar = CBMutableCharacteristic(
            type: KL252_DEVICE_UUID.command,
            properties: [.write],
            value: nil,
            permissions: [.writeable]
        )
        let rspChar = CBMutableCharacteristic(
            type: KL252_DEVICE_UUID.response,
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )
        let fileChar = CBMutableCharacteristic(
            type: KL252_DEVICE_UUID.fileTransfer,
            properties: [.writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        responseChar = rspChar
        let customService = CBMutableService(type: KL252_DEVICE_UUID.customService, primary: true)
        customService.characteristics = [cmdChar, rspChar, fileChar]

        // --- 3. Battery Service (0x180F) ---
        let batChar = CBMutableCharacteristic(
            type: KL252_DEVICE_UUID.batteryLevel,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )
        batteryChar = batChar
        let batteryService = CBMutableService(type: KL252_DEVICE_UUID.batteryService, primary: true)
        batteryService.characteristics = [batChar]

        peripheralManager.add(genericAccessService)
        peripheralManager.add(customService)
        peripheralManager.add(batteryService)
        log("正在注册 GATT 服务 (0x1800 / 0xAB00 / 0x180F)…", direction: .info)
    }

    private func beginAdvertising() {
        guard wantsAdvertising else { return }
        guard peripheralManager.state == .poweredOn else { return }
        guard responseChar != nil else { return }
        guard !hasConnectedCentrals else {
            log("ℹ️ Central 仍连接中，暂不恢复广播", direction: .info)
            return
        }
        if peripheralManager.isAdvertising {
            isAdvertising = true
            delegate?.simulatorDidUpdateState(self)
            return
        }
        let advData = buildAdvertisementData()
        let mfgData = advData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()
        peripheralManager.startAdvertising(advData)
        isAdvertising = true
        log(
            "🟢 开始广播 name=\(state.deviceName) MAC=\(state.macAddressString) " +
            "mfgData=\(hexString(mfgData))",
            direction: .info
        )
        delegate?.simulatorDidUpdateState(self)
    }

    /// 构建广播包：LocalName + ServiceUUIDs + ManufacturerData(MAC + 自定义名称)
    private func buildAdvertisementData() -> [String: Any] {
        let manufacturer = KL252Advertisement.manufacturerData(
            mac: state.macAddress,
            deviceName: state.deviceName
        )
        return [
            CBAdvertisementDataLocalNameKey: state.deviceName,
            CBAdvertisementDataServiceUUIDsKey: [
                KL252_DEVICE_UUID.customService,
                KL252_DEVICE_UUID.batteryService
            ],
            CBAdvertisementDataManufacturerDataKey: manufacturer
        ]
    }

    /// 设备名变更后刷新广播，使 Manufacturer Data 与 LocalName 同步
    private func refreshAdvertisingPayload() {
        guard wantsAdvertising, responseChar != nil, !hasConnectedCentrals else { return }
        guard peripheralManager.state == .poweredOn else { return }
        if peripheralManager.isAdvertising {
            peripheralManager.stopAdvertising()
        }
        beginAdvertising()
    }

    private var hasConnectedCentrals: Bool {
        !centralSubscriptions.isEmpty
    }

    /// 从 Central 读取协商后的 MTU 信息（Peripheral 侧无法主动修改）
    private func mtuInfo(from central: CBCentral) -> (notifyMax: Int, attMtu: Int, filePayloadMax: Int) {
        let notifyMax = central.maximumUpdateValueLength
        let attMtu = notifyMax + 3
        let filePayloadMax = max(1, attMtu - 9)
        return (notifyMax, attMtu, filePayloadMax)
    }

    private func updateMtuCache(from central: CBCentral) {
        let mtu = mtuInfo(from: central)
        lastCentralNotifyMaxLength = mtu.notifyMax
        lastEstimatedAttMtu = mtu.attMtu
        lastEstimatedFilePayloadMax = mtu.filePayloadMax
    }

    private func mtuStatusNote(attMtu: Int) -> String {
        if attMtu >= KL252SimMTU.protocolAttMtu {
            return "已达协议参考 ATT_MTU=\(KL252SimMTU.protocolAttMtu)"
        }
        return "低于协议参考 ATT_MTU=\(KL252SimMTU.protocolAttMtu)（文件传输可能降速）"
    }

    private func characteristicDisplayName(_ uuid: CBUUID) -> String {
        switch uuid {
        case KL252_DEVICE_UUID.command:       return "AB01(命令写入)"
        case KL252_DEVICE_UUID.response:      return "AB02(应答/事件 Notify)"
        case KL252_DEVICE_UUID.fileTransfer:  return "AB03(文件传输)"
        case KL252_DEVICE_UUID.deviceName:    return "2A00(设备名)"
        case KL252_DEVICE_UUID.batteryLevel:  return "2A19(电量)"
        default:                              return uuid.uuidString
        }
    }

    private func centralShortID(_ central: CBCentral) -> String {
        String(central.identifier.uuidString.prefix(8))
    }

    /// 首次 GATT 交互（读/写/订阅）时记录连接日志
    private func noteCentralConnected(_ central: CBCentral, trigger: String) {
        let id = central.identifier
        guard !connectedCentrals.contains(id) else { return }
        connectedCentrals.insert(id)
        updateMtuCache(from: central)
        let shortID = centralShortID(central)
        log(
            "🔗 BLE 应用已连接 central=\(shortID) uuid=\(central.identifier.uuidString) " +
            "触发=\(trigger) 设备=\(state.deviceName) 电量=\(state.batteryLevel)% " +
            "notifyMax=\(lastCentralNotifyMaxLength)B estATT_MTU=\(lastEstimatedAttMtu) " +
            "estWriteMax=\(lastEstimatedAttMtu - 3)B estFilePayloadMax=\(lastEstimatedFilePayloadMax)B " +
            "[\(mtuStatusNote(attMtu: lastEstimatedAttMtu))] " +
            "已连接数=\(connectedCentrals.count)",
            direction: .info
        )
        log(
            "   GATT 服务: 1800(Generic Access) / AB00(KL252 自定义) / 180F(Battery)",
            direction: .info
        )
        if !peripheralManager.isAdvertising {
            log("   广播已由系统暂停（Central 连接中）", direction: .info)
        }
    }

    private func logCentralConnected(_ central: CBCentral, via characteristic: CBCharacteristic) {
        noteCentralConnected(central, trigger: "订阅 \(characteristicDisplayName(characteristic.uuid))")
        let id = central.identifier
        var subscribed = centralSubscribedCharacteristics[id] ?? []
        subscribed.insert(characteristic.uuid)
        centralSubscribedCharacteristics[id] = subscribed

        let shortID = centralShortID(central)
        log(
            "central=\(shortID) 订阅 \(characteristicDisplayName(characteristic.uuid)) " +
            "该Central订阅特征=\(subscribed.map { characteristicDisplayName($0) }.sorted().joined(separator: ", ")) " +
            "activeCentrals=\(centralSubscriptions.count)",
            direction: .info
        )

        if characteristic.uuid == KL252_DEVICE_UUID.response {
            log("✅ central=\(shortID) 协议应答通道 AB02 已就绪，可收发命令/事件", direction: .info)
        }
        if subscribed.contains(KL252_DEVICE_UUID.response),
           subscribed.contains(KL252_DEVICE_UUID.batteryLevel) {
            log("✅ central=\(shortID) 全部 Notify 订阅完成 (AB02 + 2A19)，连接就绪", direction: .info)
        }
    }

    private func logCentralDisconnected(_ central: CBCentral, via characteristic: CBCharacteristic) {
        let shortID = centralShortID(central)
        let remaining = centralSubscriptions.count
        log(
            "已断开 central=\(shortID) 取消订阅 \(characteristicDisplayName(characteristic.uuid)) " +
            "剩余Central=\(remaining) " +
            "最近 notifyMax=\(lastCentralNotifyMaxLength)B estATT_MTU=\(lastEstimatedAttMtu)",
            direction: .info
        )
        if remaining == 0 {
            connectedCentrals.removeAll()
            centralSubscribedCharacteristics.removeAll()
            fileTransferSession = nil
            log("🔌 BLE 应用已全部断开", direction: .info)
            log(
                wantsAdvertising ? "全部 Central 已断开，0.5s 后恢复广播" : "全部 Central 已断开，保持停播",
                direction: .info
            )
        }
    }

    private func addCentralSubscription(_ central: CBCentral, characteristic: CBCharacteristic) {
        let id = central.identifier
        let count = (centralSubscriptions[id] ?? 0) + 1
        centralSubscriptions[id] = count
        if count == 1 {
            logCentralConnected(central, via: characteristic)
        } else {
            var subscribed = centralSubscribedCharacteristics[id] ?? []
            subscribed.insert(characteristic.uuid)
            centralSubscribedCharacteristics[id] = subscribed
            log(
                "central=\(centralShortID(central)) 追加订阅 \(characteristicDisplayName(characteristic.uuid)) " +
                "该Central订阅数=\(count) 特征=\(subscribed.map { characteristicDisplayName($0) }.sorted().joined(separator: ", "))",
                direction: .info
            )
            if characteristic.uuid == KL252_DEVICE_UUID.response {
                log("✅ central=\(centralShortID(central)) 协议应答通道 AB02 已就绪，可收发命令/事件", direction: .info)
            }
            if subscribed.contains(KL252_DEVICE_UUID.response),
               subscribed.contains(KL252_DEVICE_UUID.batteryLevel) {
                log("✅ central=\(centralShortID(central)) 全部 Notify 订阅完成 (AB02 + 2A19)，连接就绪", direction: .info)
            }
        }
        syncAdvertisingState(reason: "Central 订阅")
    }

    private func removeCentralSubscription(_ central: CBCentral, characteristic: CBCharacteristic) {
        let id = central.identifier
        guard let count = centralSubscriptions[id] else { return }
        if count <= 1 {
            centralSubscriptions.removeValue(forKey: id)
            centralSubscribedCharacteristics.removeValue(forKey: id)
            connectedCentrals.remove(id)
            logCentralDisconnected(central, via: characteristic)
            syncAdvertisingState(reason: "Central 取消订阅")
            scheduleResumeAdvertising()
        } else {
            centralSubscriptions[id] = count - 1
            if var subscribed = centralSubscribedCharacteristics[id] {
                subscribed.remove(characteristic.uuid)
                centralSubscribedCharacteristics[id] = subscribed.isEmpty ? nil : subscribed
            }
            log(
                "central=\(centralShortID(central)) 取消订阅 \(characteristicDisplayName(characteristic.uuid)) " +
                "该Central剩余订阅=\(count - 1)",
                direction: .info
            )
        }
    }

    /// 与 peripheralManager.isAdvertising 对齐，避免 UI 显示「广播中」但实际已停播
    private func syncAdvertisingState(reason: String) {
        let actuallyAdvertising = peripheralManager.isAdvertising
        guard isAdvertising != actuallyAdvertising else { return }
        isAdvertising = actuallyAdvertising
        log("ℹ️ 广播状态同步 (\(reason)): \(actuallyAdvertising ? "广播中" : "已停播")", direction: .info)
        delegate?.simulatorDidUpdateState(self)
    }

    /// Central 全部断开后延迟恢复广播（iOS 连接释放需要短暂窗口）
    private func scheduleResumeAdvertising() {
        guard wantsAdvertising, !hasConnectedCentrals else { return }
        resumeAdvertisingWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.wantsAdvertising, !self.hasConnectedCentrals else { return }
            self.log("🔄 Central 断开后恢复广播", direction: .info)
            self.beginAdvertising()
        }
        resumeAdvertisingWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    // MARK: - Private: Frame Handling

    /// 处理写入 0xAB01 的命令帧（§3.2，经 §3.0 帧解码）
    private func handleCommandFrame(_ data: Data) {
        guard let bytes = KL252FrameCodec.validateAndStrip(data), bytes.count >= 3 else {
            log("⚠️ 命令帧校验失败或过短: \(hexString(data))", direction: .received, level: .warn)
            return
        }
        let cmdID = bytes[0]
        let seq   = bytes[1]
        let dataLen = bytes[2]
        let payloadEnd = min(bytes.count, 3 + Int(dataLen))
        let payload = dataLen > 0 ? Array(bytes[3..<payloadEnd]) : []

        log("AB01 cmd=0x\(String(format: "%02X", cmdID)) seq=\(seq) payloadLen=\(dataLen) frame=\(hexString(data))", direction: .received)

        switch cmdID {
        // ── 闹钟与例程 ──
        case CmdID.addOrModifyAlarm.rawValue:   handleAddAlarm(seq: seq, payload: payload)
        case CmdID.deleteAlarm.rawValue:         handleDeleteAlarm(seq: seq, payload: payload)
        case CmdID.queryAlarmList.rawValue:      handleQueryAlarmList(seq: seq)
        case CmdID.queryAlarmDetail.rawValue:    handleQueryAlarmDetail(seq: seq, payload: payload)
        case CmdID.programBasicConfig.rawValue:  handleProgramBasicConfig(seq: seq, payload: payload, dataLen: dataLen)
        case CmdID.alarmsGlobalSwitch.rawValue:  handleAlarmsGlobalSwitch(seq: seq, payload: payload, dataLen: dataLen)
        case CmdID.queryRunState.rawValue:       handleQueryRunState(seq: seq)
        // ── 系统与来电 ──
        case CmdID.syncTime.rawValue:           handleSyncTime(seq: seq, payload: payload)
        case CmdID.hourFormat.rawValue:          handleHourFormat(seq: seq, payload: payload, dataLen: dataLen)
        case CmdID.screenOff.rawValue:           handleScreenOff(seq: seq, payload: payload, dataLen: dataLen)
        case CmdID.callRingConfig.rawValue:      handleCallRingConfig(seq: seq, payload: payload, dataLen: dataLen)
        case CmdID.callRingAction.rawValue:      handleCallRingAction(seq: seq, payload: payload)
        case CmdID.queryDND.rawValue:            handleQueryDND(seq: seq)
        // ── 设备与固件 ──
        case CmdID.queryFirmware.rawValue:       handleQueryFirmware(seq: seq)
        case CmdID.factoryReset.rawValue:        handleFactoryReset(seq: seq, payload: payload)
        // ── 音源与存储 ──
        case CmdID.queryStorage.rawValue:        handleQueryStorage(seq: seq)
        case CmdID.queryMusicList.rawValue:      handleQueryMusicList(seq: seq)
        case CmdID.deleteMusic.rawValue:         handleDeleteMusic(seq: seq, payload: payload)
        // ── 音乐播放 §4.4 ──
        case CmdID.playMusic.rawValue:           handlePlayMusic(seq: seq, payload: payload)
        case CmdID.pauseMusic.rawValue:          handlePauseMusic(seq: seq)
        case CmdID.setMusicVolume.rawValue:      handleSetMusicVolume(seq: seq, payload: payload)
        case CmdID.queryMusicPlayState.rawValue: handleQueryMusicPlayState(seq: seq)
        // ── 文件传输 §4.5 ──
        case CmdID.fileStart.rawValue:           handleFileStart(seq: seq, payload: payload)
        case CmdID.fileEnd.rawValue:             handleFileEnd(seq: seq, payload: payload)
        case CmdID.fileWindowReq.rawValue:       handleFileWindowReq(seq: seq, payload: payload)
        case CmdID.fileCancel.rawValue:          handleFileCancel(seq: seq, payload: payload)
        default:
            sendReply(seq: seq, cmdID: cmdID, result: ResultCode.unsupported.rawValue)
        }
    }

    /// 处理写入 0x2A00 的名称修改帧（§3.1，经 §3.0 帧解码）
    private func handleRenameFrame(_ data: Data) {
        guard let bytes = KL252FrameCodec.validateAndStrip(data),
              bytes.count >= 3, bytes[0] == CmdID.rename.rawValue else {
            log("2A00 rename 校验失败或格式错误 frame=\(hexString(data))", direction: .received, level: .warn)
            return
        }
        let seq     = bytes[1]
        let nameLen = Int(bytes[2])
        log("2A00 rename seq=\(seq) nameLen=\(nameLen) frame=\(hexString(data))", direction: .received)

        guard bytes.count >= 3 + nameLen, nameLen >= 1, nameLen <= 20 else {
            sendRenameReply(seq: seq, result: ResultCode.invalidParam.rawValue)
            return
        }
        let nameBytes = Array(bytes[3..<(3 + nameLen)])
        if let newName = String(bytes: nameBytes, encoding: .utf8) {
            state.deviceName = newName
            log("ℹ️ 设备名已更新为: \(newName)", direction: .info)
            refreshAdvertisingPayload()
        }
        sendRenameReply(seq: seq, result: ResultCode.success.rawValue)
    }

    // MARK: - Command Handlers

    private func handleAddAlarm(seq: UInt8, payload: [UInt8]) {
        guard payload.count >= 3 else {
            sendReply(seq: seq, cmdID: CmdID.addOrModifyAlarm.rawValue, result: ResultCode.invalidParam.rawValue)
            return
        }
        let alarmType = payload[0]
        let alarmID   = payload[1]
        let nameLen   = Int(payload[2])
        let headerEnd = 3 + nameLen
        let nameBytes = nameLen > 0 && payload.count >= headerEnd ? Array(payload[3..<headerEnd]) : []

        var alarm = SimAlarm(alarmType: alarmType, alarmID: alarmID,
                             nameLen: UInt8(nameLen), name: nameBytes,
                             sleepSchedule: [], wakeSchedule: [],
                             mainSchedule: [], activePeriod: [], wakeupPeriod: [])

        if alarmType == 0x00 {
            // 例程：公共头 + 睡眠段(4B) + 起床段(4B)
            guard payload.count >= headerEnd + 8 else {
                sendReply(seq: seq, cmdID: CmdID.addOrModifyAlarm.rawValue, result: ResultCode.invalidParam.rawValue)
                return
            }
            alarm.sleepSchedule = Array(payload[headerEnd..<(headerEnd+4)])
            alarm.wakeSchedule  = Array(payload[(headerEnd+4)..<(headerEnd+8)])
        } else {
            // 其他闹钟：公共头 + 调度块(4B) + 激活期(7B) + 唤醒期(7B)
            guard payload.count >= headerEnd + 18 else {
                sendReply(seq: seq, cmdID: CmdID.addOrModifyAlarm.rawValue, result: ResultCode.invalidParam.rawValue)
                return
            }
            alarm.mainSchedule  = Array(payload[headerEnd..<(headerEnd+4)])
            alarm.activePeriod  = Array(payload[(headerEnd+4)..<(headerEnd+11)])
            alarm.wakeupPeriod  = Array(payload[(headerEnd+11)..<(headerEnd+18)])
        }
        state.alarms[alarmID] = alarm
        persistDeviceSettings()
        sendReply(seq: seq, cmdID: CmdID.addOrModifyAlarm.rawValue, result: ResultCode.success.rawValue)
    }

    private func handleDeleteAlarm(seq: UInt8, payload: [UInt8]) {
        guard let alarmID = payload.first else {
            sendReply(seq: seq, cmdID: CmdID.deleteAlarm.rawValue, result: ResultCode.invalidParam.rawValue)
            return
        }
        if state.alarms[alarmID] != nil {
            state.alarms.removeValue(forKey: alarmID)
            persistDeviceSettings()
            sendReply(seq: seq, cmdID: CmdID.deleteAlarm.rawValue, result: ResultCode.success.rawValue)
        } else {
            sendReply(seq: seq, cmdID: CmdID.deleteAlarm.rawValue, result: ResultCode.notFound.rawValue)
        }
    }

    private func handleQueryAlarmList(seq: UInt8) {
        var data: [UInt8] = [UInt8(state.alarms.count)]
        for (_, alarm) in state.alarms.sorted(by: { $0.key < $1.key }) {
            data.append(alarm.alarmType)
            data.append(alarm.alarmID)
        }
        sendReply(seq: seq, cmdID: CmdID.queryAlarmList.rawValue, result: ResultCode.success.rawValue, extra: data)
    }

    private func handleQueryAlarmDetail(seq: UInt8, payload: [UInt8]) {
        guard let alarmID = payload.first, let alarm = state.alarms[alarmID] else {
            sendReply(seq: seq, cmdID: CmdID.queryAlarmDetail.rawValue, result: ResultCode.notFound.rawValue)
            return
        }
        var data: [UInt8] = [alarm.alarmType, alarm.alarmID, alarm.nameLen] + alarm.name
        if alarm.alarmType == 0x00 {
            data += alarm.sleepSchedule + alarm.wakeSchedule
        } else {
            data += alarm.mainSchedule + alarm.activePeriod + alarm.wakeupPeriod
        }
        sendReply(seq: seq, cmdID: CmdID.queryAlarmDetail.rawValue, result: ResultCode.success.rawValue, extra: data)
    }

    private func handleProgramBasicConfig(seq: UInt8, payload: [UInt8], dataLen: UInt8) {
        if dataLen == 0 {
            // 查询
            sendReply(seq: seq, cmdID: CmdID.programBasicConfig.rawValue,
                      result: ResultCode.success.rawValue, extra: state.programBasicConfig)
        } else if dataLen == 38 && payload.count == 38 {
            // 设置
            state.programBasicConfig = payload
            persistDeviceSettings()
            sendReply(seq: seq, cmdID: CmdID.programBasicConfig.rawValue, result: ResultCode.success.rawValue)
        } else {
            sendReply(seq: seq, cmdID: CmdID.programBasicConfig.rawValue, result: ResultCode.invalidParam.rawValue)
        }
    }

    private func handleAlarmsGlobalSwitch(seq: UInt8, payload: [UInt8], dataLen: UInt8) {
        if dataLen == 0 {
            sendReply(seq: seq, cmdID: CmdID.alarmsGlobalSwitch.rawValue,
                      result: ResultCode.success.rawValue, extra: [state.alarmsGlobalEnabled])
        } else if dataLen == 1, let v = payload.first {
            state.alarmsGlobalEnabled = v
            persistDeviceSettings()
            sendReply(seq: seq, cmdID: CmdID.alarmsGlobalSwitch.rawValue, result: ResultCode.success.rawValue)
        } else {
            sendReply(seq: seq, cmdID: CmdID.alarmsGlobalSwitch.rawValue, result: ResultCode.invalidParam.rawValue)
        }
    }

    private func handleQueryRunState(seq: UInt8) {
        let rs = state.runState
        var extra: [UInt8] = [rs[0]]
        if rs[0] == 0x01 { extra += [rs[1], rs[2], rs[3]] }
        sendReply(seq: seq, cmdID: CmdID.queryRunState.rawValue, result: ResultCode.success.rawValue, extra: extra)
    }

    private func handleSyncTime(seq: UInt8, payload: [UInt8]) {
        guard payload.count == 8 else {
            sendReply(seq: seq, cmdID: CmdID.syncTime.rawValue, result: ResultCode.invalidParam.rawValue)
            return
        }
        // 简单验证 Week 范围
        let week = payload[4]
        guard week >= 1 && week <= 7 else {
            sendReply(seq: seq, cmdID: CmdID.syncTime.rawValue, result: ResultCode.invalidParam.rawValue)
            return
        }
        sendReply(seq: seq, cmdID: CmdID.syncTime.rawValue, result: ResultCode.success.rawValue)
    }

    private func handleHourFormat(seq: UInt8, payload: [UInt8], dataLen: UInt8) {
        if dataLen == 0 {
            sendReply(seq: seq, cmdID: CmdID.hourFormat.rawValue,
                      result: ResultCode.success.rawValue, extra: [state.hourFormat])
        } else if dataLen == 1, let v = payload.first {
            state.hourFormat = v
            persistDeviceSettings()
            sendReply(seq: seq, cmdID: CmdID.hourFormat.rawValue, result: ResultCode.success.rawValue)
        } else {
            sendReply(seq: seq, cmdID: CmdID.hourFormat.rawValue, result: ResultCode.invalidParam.rawValue)
        }
    }

    private func handleScreenOff(seq: UInt8, payload: [UInt8], dataLen: UInt8) {
        if dataLen == 0 {
            sendReply(seq: seq, cmdID: CmdID.screenOff.rawValue,
                      result: ResultCode.success.rawValue, extra: state.screenOffConfig)
        } else if dataLen == 5 && payload.count == 5 {
            state.screenOffConfig = payload
            persistDeviceSettings()
            sendReply(seq: seq, cmdID: CmdID.screenOff.rawValue, result: ResultCode.success.rawValue)
        } else {
            sendReply(seq: seq, cmdID: CmdID.screenOff.rawValue, result: ResultCode.invalidParam.rawValue)
        }
    }

    private func handleCallRingConfig(seq: UInt8, payload: [UInt8], dataLen: UInt8) {
        if dataLen == 0 {
            sendReply(seq: seq, cmdID: CmdID.callRingConfig.rawValue,
                      result: ResultCode.success.rawValue, extra: state.callRingConfig)
        } else if dataLen == 6 && payload.count == 6 {
            state.callRingConfig = payload
            persistDeviceSettings()
            sendReply(seq: seq, cmdID: CmdID.callRingConfig.rawValue, result: ResultCode.success.rawValue)
        } else {
            sendReply(seq: seq, cmdID: CmdID.callRingConfig.rawValue, result: ResultCode.invalidParam.rawValue)
        }
    }

    private func handleCallRingAction(seq: UInt8, payload: [UInt8]) {
        guard let action = payload.first else {
            sendReply(seq: seq, cmdID: CmdID.callRingAction.rawValue, result: ResultCode.invalidParam.rawValue)
            return
        }
        sendReply(seq: seq, cmdID: CmdID.callRingAction.rawValue, result: ResultCode.success.rawValue)
        if action == 0x01 {
            beginCallRingPlayback()
        } else if action == 0x00 {
            stopCallRingPlayback()
        }
        // 立即触发事件 0xE7
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.sendCallRingEvent(action: action)
        }
    }

    private func handleQueryDND(seq: UInt8) {
        sendReply(seq: seq, cmdID: CmdID.queryDND.rawValue,
                  result: ResultCode.success.rawValue, extra: [state.dndEnabled])
    }

    private func handleQueryFirmware(seq: UInt8) {
        let build = withUnsafeBytes(of: state.buildNumber.littleEndian) { Array($0) }
        let extra: [UInt8] = [state.firmwareMajor, state.firmwareMinor, state.firmwarePatch] + build
        sendReply(seq: seq, cmdID: CmdID.queryFirmware.rawValue,
                  result: ResultCode.success.rawValue, extra: extra)
    }

    private func handleFactoryReset(seq: UInt8, payload: [UInt8]) {
        guard payload.first == 0xA5 else {
            sendReply(seq: seq, cmdID: CmdID.factoryReset.rawValue, result: ResultCode.invalidParam.rawValue)
            return
        }
        // 重置持久化字段并写回出厂默认快照
        state.apply(KL252SimulatorDefaults.makeSnapshot())
        persistDeviceSettings()
        state.dndEnabled      = 0
        state.runState = [0,0,0,0]
        musicPlayer.stop()
        state.musicVolume = 80
        state.playState = 0x00
        state.playSource = 0x00
        state.currentMusicID = 0
        reloadBundledMusicList()
        fileTransferSession = nil
        sendReply(seq: seq, cmdID: CmdID.factoryReset.rawValue, result: ResultCode.success.rawValue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendFactoryRestartEvent()
        }
    }

    private func handleQueryStorage(seq: UInt8) {
        var extra: [UInt8] = []
        extra += withUnsafeBytes(of: state.storageTotal.littleEndian) { Array($0) }
        extra += withUnsafeBytes(of: state.storageFree.littleEndian)  { Array($0) }
        let used = state.storageTotal - state.storageFree
        extra += withUnsafeBytes(of: used.littleEndian) { Array($0) }
        sendReply(seq: seq, cmdID: CmdID.queryStorage.rawValue,
                  result: ResultCode.success.rawValue, extra: extra)
    }

    private func handleQueryMusicList(seq: UInt8) {
        var extra: [UInt8] = [UInt8(state.musicList.count)]
        for mid in state.musicList {
            extra += withUnsafeBytes(of: mid.littleEndian) { Array($0) }
        }
        sendReply(seq: seq, cmdID: CmdID.queryMusicList.rawValue,
                  result: ResultCode.success.rawValue, extra: extra)
    }

    private func handleDeleteMusic(seq: UInt8, payload: [UInt8]) {
        guard payload.count >= 4 else {
            sendReply(seq: seq, cmdID: CmdID.deleteMusic.rawValue, result: ResultCode.invalidParam.rawValue)
            return
        }
        let mid = readUInt32LE(payload, offset: 0)
        if isMusicPlaybackBusy(for: mid) {
            sendReply(seq: seq, cmdID: CmdID.deleteMusic.rawValue, result: ResultCode.busy.rawValue)
            return
        }
        if let idx = state.musicList.firstIndex(of: mid) {
            state.musicList.remove(at: idx)
            sendReply(seq: seq, cmdID: CmdID.deleteMusic.rawValue, result: ResultCode.success.rawValue)
        } else {
            sendReply(seq: seq, cmdID: CmdID.deleteMusic.rawValue, result: ResultCode.notFound.rawValue)
        }
    }

    /// §4.4 命令 0x43 — 指定 ID 播放音乐
    private func handlePlayMusic(seq: UInt8, payload: [UInt8]) {
        guard payload.count >= 4 else {
            sendReply(seq: seq, cmdID: CmdID.playMusic.rawValue, result: ResultCode.invalidParam.rawValue)
            return
        }
        let mid = readUInt32LE(payload, offset: 0)
        guard mid >= 100, mid <= 999_999 else {
            sendReply(seq: seq, cmdID: CmdID.playMusic.rawValue, result: ResultCode.invalidParam.rawValue)
            return
        }
        guard state.musicList.contains(mid) else {
            sendReply(seq: seq, cmdID: CmdID.playMusic.rawValue, result: ResultCode.notFound.rawValue)
            return
        }
        if beginAppMusicPlayback(musicID: mid) {
            sendReply(seq: seq, cmdID: CmdID.playMusic.rawValue, result: ResultCode.success.rawValue)
        } else {
            sendReply(seq: seq, cmdID: CmdID.playMusic.rawValue, result: ResultCode.notFound.rawValue)
        }
    }

    /// §4.4 命令 0x44 — 暂停 APP 点播播放
    private func handlePauseMusic(seq: UInt8) {
        if state.playSource == 0x00, state.playState == 0x01 {
            musicPlayer.pause()
            state.playState = 0x02
        }
        sendReply(seq: seq, cmdID: CmdID.pauseMusic.rawValue, result: ResultCode.success.rawValue)
    }

    /// §4.4 命令 0x45 — 音量设置
    private func handleSetMusicVolume(seq: UInt8, payload: [UInt8]) {
        guard let volume = payload.first, volume >= 1, volume <= 100 else {
            sendReply(seq: seq, cmdID: CmdID.setMusicVolume.rawValue, result: ResultCode.invalidParam.rawValue)
            return
        }
        state.musicVolume = volume
        musicPlayer.setVolume(volume)
        sendReply(seq: seq, cmdID: CmdID.setMusicVolume.rawValue, result: ResultCode.success.rawValue)
    }

    /// §4.4 命令 0x46 — 查询音乐播放状态
    private func handleQueryMusicPlayState(seq: UInt8) {
        var extra: [UInt8]
        if state.playState == 0x00 {
            extra = [state.playState, state.musicVolume]
        } else {
            extra = [state.playState, state.playSource]
            extra += withUnsafeBytes(of: state.currentMusicID.littleEndian) { Array($0) }
            extra.append(state.musicVolume)
        }
        sendReply(seq: seq, cmdID: CmdID.queryMusicPlayState.rawValue,
                  result: ResultCode.success.rawValue, extra: extra)
    }

    /// §4.5 命令 0x50 — 文件传输开始
    private func handleFileStart(seq: UInt8, payload: [UInt8]) {
        guard payload.count >= 9 else {
            sendReply(seq: seq, cmdID: CmdID.fileStart.rawValue, result: ResultCode.invalidParam.rawValue)
            return
        }
        if fileTransferSession != nil {
            sendReply(seq: seq, cmdID: CmdID.fileStart.rawValue, result: ResultCode.busy.rawValue)
            return
        }
        let fileID = payload[0]
        let musicID = readUInt32LE(payload, offset: 1)
        let fileSize = readUInt32LE(payload, offset: 5)
        guard musicID >= 100, musicID <= 999_999, fileSize > 0 else {
            sendReply(seq: seq, cmdID: CmdID.fileStart.rawValue, result: ResultCode.invalidParam.rawValue)
            return
        }
        guard fileSize <= state.storageFree else {
            sendReply(seq: seq, cmdID: CmdID.fileStart.rawValue, result: ResultCode.fileError.rawValue)
            return
        }
        let payloadMax = currentFilePayloadMax()
        let packetCount = Int((fileSize + UInt32(payloadMax) - 1) / UInt32(payloadMax))
        fileTransferSession = FileTransferSession(
            fileID: fileID,
            musicID: musicID,
            fileSize: fileSize,
            packetCount: packetCount,
            payloadMax: payloadMax
        )
        sendReply(seq: seq, cmdID: CmdID.fileStart.rawValue, result: ResultCode.success.rawValue)
    }

    /// §4.5 命令 0x51 — 文件传输结束
    private func handleFileEnd(seq: UInt8, payload: [UInt8]) {
        guard payload.count >= 2 else {
            sendReply(seq: seq, cmdID: CmdID.fileEnd.rawValue, result: ResultCode.invalidParam.rawValue)
            return
        }
        let fileID = payload[0]
        let expectedXor = payload[1]
        guard let session = fileTransferSession, session.fileID == fileID else {
            sendReply(seq: seq, cmdID: CmdID.fileEnd.rawValue, result: ResultCode.notFound.rawValue)
            return
        }
        guard session.received.count == session.packetCount, session.fileXor == expectedXor else {
            fileTransferSession = nil
            sendReply(seq: seq, cmdID: CmdID.fileEnd.rawValue, result: ResultCode.fileError.rawValue)
            return
        }
        if !state.musicList.contains(session.musicID) {
            state.musicList.append(session.musicID)
            state.musicList.sort()
        }
        state.storageFree -= session.fileSize
        let completedFileID = session.fileID
        let completedMusicID = session.musicID
        fileTransferSession = nil
        sendReply(seq: seq, cmdID: CmdID.fileEnd.rawValue, result: ResultCode.success.rawValue)
        sendEventFrame(eventID: EventID.fileComplete.rawValue,
                       payload: [completedFileID] + withUnsafeBytes(of: completedMusicID.littleEndian) { Array($0) } + [0x00])
    }

    /// §4.5 命令 0x52 — 请求窗口状态（应答 CmdID 0x53）
    private func handleFileWindowReq(seq: UInt8, payload: [UInt8]) {
        guard payload.count >= 3 else {
            sendReply(seq: seq, cmdID: CmdID.fileWindowRsp.rawValue, result: ResultCode.invalidParam.rawValue)
            return
        }
        let fileID = payload[0]
        let windowBase = readUInt16LE(payload, offset: 1)
        guard let session = fileTransferSession, session.fileID == fileID else {
            sendReply(seq: seq, cmdID: CmdID.fileWindowRsp.rawValue, result: ResultCode.notFound.rawValue)
            return
        }
        let bitmap = buildWindowBitmap(session: session, windowBase: windowBase)
        var extra: [UInt8] = [fileID]
        extra += withUnsafeBytes(of: windowBase.littleEndian) { Array($0) }
        extra += bitmap
        sendReply(seq: seq, cmdID: CmdID.fileWindowRsp.rawValue, result: ResultCode.success.rawValue, extra: extra)
    }

    /// §4.5 命令 0x54 — 取消文件传输
    private func handleFileCancel(seq: UInt8, payload: [UInt8]) {
        guard let fileID = payload.first else {
            sendReply(seq: seq, cmdID: CmdID.fileCancel.rawValue, result: ResultCode.invalidParam.rawValue)
            return
        }
        guard let session = fileTransferSession, session.fileID == fileID else {
            sendReply(seq: seq, cmdID: CmdID.fileCancel.rawValue, result: ResultCode.notFound.rawValue)
            return
        }
        fileTransferSession = nil
        sendReply(seq: seq, cmdID: CmdID.fileCancel.rawValue, result: ResultCode.success.rawValue)
        sendEventFrame(eventID: EventID.fileCancel.rawValue, payload: [fileID, 0x00])
    }

    /// §3.5 AB03 文件数据块
    private func handleFileDataChunk(_ data: Data) {
        guard var session = fileTransferSession else {
            log("AB03 无活跃传输会话，忽略 len=\(data.count)", direction: .received, level: .warn)
            return
        }
        guard let bytes = KL252FrameCodec.validateAndStrip(data), bytes.count >= 3, bytes[0] == 0x00 else {
            log("AB03 帧校验失败 \(hexString(data))", direction: .received, level: .warn)
            return
        }
        let packetIndex = readUInt16LE(bytes, offset: 1)
        let payload = Data(bytes[3...])
        guard Int(packetIndex) < session.packetCount else {
            log("AB03 忽略越界包 index=\(packetIndex) N=\(session.packetCount)", direction: .received)
            return
        }
        let maxPayload = session.payloadMax
        let isLast = Int(packetIndex) == session.packetCount - 1
        let expectedSize: Int
        if isLast {
            let remainder = Int(session.fileSize) - (session.packetCount - 1) * maxPayload
            expectedSize = max(1, min(maxPayload, remainder))
        } else {
            expectedSize = maxPayload
        }
        guard payload.count <= maxPayload, !isLast || payload.count == expectedSize else {
            log("AB03 包 \(packetIndex) 长度异常 got=\(payload.count) expect≤\(expectedSize)", direction: .received, level: .warn)
            return
        }
        if !isLast, payload.count != maxPayload {
            log("AB03 包 \(packetIndex) 非末包长度不足 got=\(payload.count) expect=\(maxPayload)", direction: .received, level: .warn)
            return
        }
        if session.received[packetIndex] == nil {
            session.received[packetIndex] = payload
            session.fileXor ^= KL252FrameCodec.xorChecksum([UInt8](payload))
            fileTransferSession = session
        }
        log("AB03 收包 index=\(packetIndex) len=\(payload.count) 进度=\(session.received.count)/\(session.packetCount)", direction: .received)
    }

    // MARK: - Reply Helpers

    /// 发送命令应答帧 (RspType=0x00，§3.3)
    private func sendReply(seq: UInt8, cmdID: UInt8, result: UInt8, extra: [UInt8] = []) {
        var payload: [UInt8] = [0x00, seq, cmdID, result]
        payload += extra
        log("rsp seq=\(seq) cmd=0x\(String(format: "%02X", cmdID)) result=0x\(String(format: "%02X", result)) extraLen=\(extra.count)", direction: .sent)
        sendNotify(KL252FrameCodec.wrap(payload))
    }

    /// 发送名称修改应答（通过 0xAB02，§3.1）
    private func sendRenameReply(seq: UInt8, result: UInt8) {
        let payload: [UInt8] = [0x00, seq, CmdID.rename.rawValue, result]
        sendNotify(KL252FrameCodec.wrap(payload))
    }

    /// 发送事件通知帧 (RspType=0x01，§3.4)
    func sendEventFrame(eventID: UInt8, payload: [UInt8]) {
        var framePayload: [UInt8] = [0x01, 0xFF, eventID, UInt8(payload.count)]
        framePayload += payload
        log("event id=0x\(String(format: "%02X", eventID)) payloadLen=\(payload.count)", direction: .sent)
        sendNotify(KL252FrameCodec.wrap(framePayload))
    }

    private func sendNotify(_ data: Data) {
        guard let char = responseChar else {
            log("notify 失败 — AB02 未就绪", direction: .info, level: .warn)
            return
        }
        let ok = peripheralManager.updateValue(data, for: char, onSubscribedCentrals: nil)
        log("AB02 notify \(hexString(data))\(ok ? "" : " [缓冲满]")", direction: .sent, level: ok ? .info : .warn)
    }

    // MARK: - Helpers

    private func hexString(_ data: Data, maxBytes: Int = 64) -> String {
        guard !data.isEmpty else { return "(empty)" }
        let slice = data.prefix(maxBytes)
        let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
        return data.count > maxBytes ? "\(hex) …(\(data.count)B total)" : hex
    }

    private func log(_ msg: String, direction: LogDirection, level: LogLevel = .info) {
        let tag: String
        switch direction {
        case .received: tag = "[KL252-SIM] RX"
        case .sent:     tag = "[KL252-SIM] TX"
        case .info:     tag = "[KL252-SIM]"
        }
        WZLog("\(tag) \(msg)", level: level)
        delegate?.simulator(self, didLog: msg, direction: direction)
    }

    private func readUInt32LE(_ bytes: [UInt8], offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) |
        (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private func readUInt16LE(_ bytes: [UInt8], offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }


    /// 合并 Bundle 预置音源与已传输音源 ID
    private func reloadBundledMusicList() {
        var ids = Set(KL252SimulatorMusicCatalog.bundledMusicIDs())
        ids.formUnion(state.musicList)
        state.musicList = ids.sorted()
    }

    /// §4.4 APP 点播（0x43）：播放或恢复暂停曲目
    @discardableResult
    private func beginAppMusicPlayback(musicID: UInt32) -> Bool {
        if state.playSource == 0x00,
           state.playState == 0x02,
           state.currentMusicID == musicID,
           musicPlayer.resume(volume: state.musicVolume) {
            state.playState = 0x01
            if let name = KL252SimulatorMusicCatalog.displayName(for: musicID) {
                log("▶️ 恢复播放 MusicID=\(musicID) (\(name))", direction: .info)
            }
            return true
        }
        guard musicPlayer.play(musicID: musicID, volume: state.musicVolume) else { return false }
        state.playSource = 0x00
        state.playState = 0x01
        state.currentMusicID = musicID
        if let name = KL252SimulatorMusicCatalog.displayName(for: musicID) {
            log("▶️ 开始播放 MusicID=\(musicID) (\(name)) Vol=\(state.musicVolume)", direction: .info)
        }
        return true
    }

    /// §4.2 来电提醒播放（PlaySource=0x02）
    private func beginCallRingPlayback() {
        guard state.callRingConfig.first == 0x01 else { return }
        let musicID = readUInt32LE(state.callRingConfig, offset: 1)
        let volume = state.callRingConfig[5]
        guard state.musicList.contains(musicID),
              musicPlayer.play(musicID: musicID, volume: volume) else { return }
        state.playSource = 0x02
        state.playState = 0x01
        state.currentMusicID = musicID
        state.musicVolume = volume
        if let name = KL252SimulatorMusicCatalog.displayName(for: musicID) {
            log("📞 来电提醒播放 MusicID=\(musicID) (\(name))", direction: .info)
        }
    }

    private func stopCallRingPlayback() {
        guard state.playSource == 0x02 else { return }
        musicPlayer.stop()
        state.playState = 0x00
        state.playSource = 0x00
        state.currentMusicID = 0
        log("📞 来电提醒停止", direction: .info)
    }

    /// §4.4 删除音源时，正在播放/暂停该 MusicID 则返回 busy
    private func isMusicPlaybackBusy(for musicID: UInt32) -> Bool {
        guard state.playSource == 0x00 else { return false }
        guard state.playState == 0x01 || state.playState == 0x02 else { return false }
        return state.currentMusicID == musicID
    }

    /// §5.2 当前 AB03 单包 payload 上限
    private func currentFilePayloadMax() -> Int {
        if lastEstimatedFilePayloadMax > 0 {
            return lastEstimatedFilePayloadMax
        }
        return KL252SimMTU.protocolFilePayloadMax
    }

    /// §5.2 按 WindowBase 生成 128 位收包位图（bit0=LSB）
    private func buildWindowBitmap(session: FileTransferSession, windowBase: UInt16) -> [UInt8] {
        var bitmap = [UInt8](repeating: 0, count: 16)
        for k in 0..<128 {
            let packetIndex = Int(windowBase) + k
            guard packetIndex < session.packetCount else { continue }
            guard session.received[UInt16(packetIndex)] != nil else { continue }
            let byteIndex = k / 8
            let bitIndex = k % 8
            bitmap[byteIndex] |= (1 << bitIndex)
        }
        return bitmap
    }

    // MARK: - Run State (供快捷面板修改)
    func setRunState(running: Bool, alarmType: UInt8 = 0, alarmID: UInt8 = 1, phase: UInt8 = 0) {
        if running {
            state.runState = [0x01, alarmType, alarmID, phase]
        } else {
            state.runState = [0x00, 0x00, 0x00, 0x00]
        }
    }
}


// MARK: - Music Player Delegate

extension KL252SimulatorCore: KL252SimulatorMusicPlayerDelegate {
    func musicPlayerDidFinishPlaying(_ player: KL252SimulatorMusicPlayer) {
        if state.playState != 0x00 {
            log("⏹ 播放结束 MusicID=\(state.currentMusicID)", direction: .info)
        }
        state.playState = 0x00
        state.playSource = 0x00
        state.currentMusicID = 0
        delegate?.simulatorDidUpdateState(self)
    }
}

// MARK: - CBPeripheralManagerDelegate

extension KL252SimulatorCore: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            log("✅ 蓝牙已开启", direction: .info)
            delegate?.simulatorDidUpdateState(self)
        case .poweredOff:
            log("蓝牙已关闭", direction: .info, level: .warn)
            isAdvertising = false
            wantsAdvertising = false
            centralSubscriptions.removeAll()
            connectedCentrals.removeAll()
            centralSubscribedCharacteristics.removeAll()
            lastCentralNotifyMaxLength = 0
            lastEstimatedAttMtu = 0
            lastEstimatedFilePayloadMax = 0
            resumeAdvertisingWorkItem?.cancel()
            delegate?.simulatorDidUpdateState(self)
        case .unauthorized:
            log("蓝牙权限未授权，请在「设置」中开启", direction: .info, level: .warn)
        case .unsupported:
            log("设备不支持 BLE 外设模式", direction: .info, level: .warn)
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let err = error {
            log("服务添加失败 \(service.uuid.uuidString) → \(err.localizedDescription)", direction: .info, level: .warn)
            return
        }
        log("服务已注册 \(service.uuid.uuidString) (\(addedServiceCount + 1)/\(expectedServiceCount))", direction: .info)
        addedServiceCount += 1
        guard addedServiceCount >= expectedServiceCount else { return }
        guard wantsAdvertising, !peripheral.isAdvertising else { return }
        beginAdvertising()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let err = error {
            log("广播启动失败 → \(err.localizedDescription)", direction: .info, level: .warn)
            isAdvertising = false
            delegate?.simulatorDidUpdateState(self)
        } else {
            log("广播启动成功 name=\(state.deviceName) MAC=\(state.macAddressString)", direction: .info)
            isAdvertising = true
            delegate?.simulatorDidUpdateState(self)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for req in requests {
            guard let data = req.value, !data.isEmpty else {
                log("write 空数据 char=\(req.characteristic.uuid.uuidString)", direction: .received, level: .warn)
                continue
            }

            let central = req.central
            noteCentralConnected(central, trigger: "写入 \(characteristicDisplayName(req.characteristic.uuid))")
            let mtu = mtuInfo(from: central)
            let writeMax = mtu.attMtu - 3
            if data.count > writeMax {
                log(
                    "write 超长 len=\(data.count)B > estWriteMax=\(writeMax)B " +
                    "char=\(req.characteristic.uuid.uuidString) estATT_MTU=\(mtu.attMtu)",
                    direction: .received,
                    level: .warn
                )
            }

            if req.characteristic.uuid == KL252_DEVICE_UUID.command {
                handleCommandFrame(data)
            } else if req.characteristic.uuid == KL252_DEVICE_UUID.deviceName {
                handleRenameFrame(data)
            } else if req.characteristic.uuid == KL252_DEVICE_UUID.fileTransfer {
                handleFileDataChunk(data)
            } else {
                log("write char=\(req.characteristic.uuid.uuidString) \(hexString(data))", direction: .received)
            }
            peripheral.respond(to: req, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveRead request: CBATTRequest) {
        noteCentralConnected(request.central, trigger: "读取 \(characteristicDisplayName(request.characteristic.uuid))")
        if request.characteristic.uuid == KL252_DEVICE_UUID.batteryLevel {
            request.value = Data([state.batteryLevel])
            peripheral.respond(to: request, withResult: .success)
            log("read 2A19 battery → \(state.batteryLevel)%", direction: .received)
        } else if request.characteristic.uuid == KL252_DEVICE_UUID.deviceName {
            request.value = state.deviceName.data(using: .utf8)
            peripheral.respond(to: request, withResult: .success)
            log("read 2A00 name → \"\(state.deviceName)\"", direction: .received)
        } else {
            log("read 未支持 char=\(request.characteristic.uuid.uuidString)", direction: .received, level: .warn)
            peripheral.respond(to: request, withResult: .attributeNotFound)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        addCentralSubscription(central, characteristic: characteristic)
        // 订阅电量特征后立即推送当前电量
        if characteristic.uuid == KL252_DEVICE_UUID.batteryLevel {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.notifyBatteryLevel(self?.state.batteryLevel ?? 85)
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        removeCentralSubscription(central, characteristic: characteristic)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        log("notify 缓冲区就绪，可重试发送", direction: .info, level: .debug)
    }
}
