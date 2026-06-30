// KL252SimulatorViewController.swift
// BLE 虚拟设备模拟器 - UI 界面
// macOS SwiftUI 实现：广播开关 / HEX 日志区 / 快捷事件面板
// ⚠️ 本文件为独立模拟器模块，不影响项目原有 BLE 业务代码

import SwiftUI
import Combine

// MARK: - ViewModel

@MainActor
final class KL252SimulatorViewModel: ObservableObject, KL252SimulatorDelegate {
    let simulator = KL252SimulatorCore()

    @Published private(set) var isAdvertising = false
    @Published private(set) var deviceName = "KL252-SIM"
    @Published private(set) var batteryLevel: UInt8 = 85
    @Published private(set) var chargeStateText = "未充电"
    @Published private(set) var playStateText = "空闲"
    @Published private(set) var currentMusicText = "—"
    @Published private(set) var musicTrackCount = 0
    @Published private(set) var logLines: [LogLine] = []

    private let maxLogLines = 300

    init() {
        simulator.delegate = self
        syncFromSimulator()
    }

    func startAdvertising() { simulator.startAdvertising() }
    func stopAdvertising() { simulator.stopAdvertising() }
    func toggleAdvertising() {
        if simulator.isAdvertising { stopAdvertising() } else { startAdvertising() }
    }

    func clearLog() { logLines.removeAll() }

    // MARK: - 快捷面板：闹钟/例程 (§6.2)

    func sendAlarmTrigger() {
        simulator.sendAlarmEvent(.alarmTrigger, alarmType: 0x00, alarmID: 0x01, phase: 0x03)
    }
    func sendAlarmTimeout() {
        simulator.sendAlarmEvent(.alarmTimeout, alarmType: 0x00, alarmID: 0x01, phase: 0x03)
    }
    func sendAlarmStop() {
        simulator.sendAlarmEvent(.alarmStop, alarmType: 0x01, alarmID: 0x02, phase: 0x00)
    }

    // MARK: - 快捷面板：来电 / 免打扰

    func sendCallStart() { simulator.sendCallRingEvent(action: 0x01) }
    func sendCallStop() { simulator.sendCallRingEvent(action: 0x00) }
    func sendDNDOn() { simulator.sendDNDEvent(enabled: 0x01) }
    func sendDNDOff() { simulator.sendDNDEvent(enabled: 0x00) }

    // MARK: - 快捷面板：文件传输事件

    func sendFileComplete() { simulator.sendFileCompleteEvent() }
    func sendFileCancel() { simulator.sendFileCancelEvent() }

    // MARK: - 快捷面板：电量 / 出厂

    func sendBattery85() { simulator.notifyBatteryLevel(85) }
    func sendBattery20() { simulator.notifyBatteryLevel(20) }
    func sendCharging() { simulator.notifyChargeState(KL252ChargeState.charging.rawValue) }
    func sendFullyCharged() {
        simulator.state.batteryLevel = 100
        simulator.notifyChargeState(KL252ChargeState.fullyCharged.rawValue)
    }
    func sendNotCharging() { simulator.notifyChargeState(KL252ChargeState.notCharging.rawValue) }
    func sendFactoryEvent() { simulator.sendFactoryRestartEvent() }

    // MARK: - 快捷面板：机身音乐按键 (§4.4 真实播放)

    func devicePlay() { simulator.devicePressPlay() }
    func devicePause() { simulator.devicePressPause() }
    func devicePrevious() { simulator.devicePressPrevious() }
    func deviceNext() { simulator.devicePressNext() }

    // MARK: KL252SimulatorDelegate

    nonisolated func simulator(_ sim: KL252SimulatorCore, didLog message: String, direction: LogDirection) {
        Task { @MainActor in
            let now = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            let prefix: String
            let color: Color
            switch direction {
            case .received:
                prefix = "⬇"
                color = .blue
            case .sent:
                prefix = "⬆"
                color = .green
            case .info:
                prefix = "ℹ"
                color = .secondary
            }
            logLines.append(LogLine(text: "[\(now)] \(prefix) \(message)", color: color))
            if logLines.count > maxLogLines {
                logLines.removeFirst(logLines.count - maxLogLines)
            }
        }
    }

    nonisolated func simulatorDidUpdateState(_ sim: KL252SimulatorCore) {
        Task { @MainActor in syncFromSimulator() }
    }

    private func syncFromSimulator() {
        isAdvertising = simulator.isAdvertising
        deviceName = simulator.state.deviceName
        batteryLevel = simulator.state.batteryLevel
        chargeStateText = KL252ChargeState(rawValue: simulator.state.chargeState)?.label ?? "—"
        musicTrackCount = simulator.state.musicList.count
        playStateText = Self.playStateLabel(
            state: simulator.state.playState,
            source: simulator.state.playSource
        )
        if simulator.state.currentMusicID != 0 {
            let id = simulator.state.currentMusicID
            let name = KL252SimulatorMusicCatalog.displayName(for: id) ?? "?"
            currentMusicText = "\(id) · \(name)"
        } else {
            currentMusicText = "—"
        }
    }

    private static func playStateLabel(state: UInt8, source: UInt8) -> String {
        switch state {
        case 0x01:
            let src = source == 0x01 ? "例程/闹钟" : (source == 0x02 ? "来电" : "APP/机身")
            return "播放中 (\(src))"
        case 0x02:
            return "已暂停"
        default:
            return "空闲"
        }
    }
}

struct LogLine: Identifiable {
    let id = UUID()
    let text: String
    let color: Color
}

// MARK: - Quick Action Model

private struct SimulatorQuickSection: Identifiable {
    let id = UUID()
    let title: String
    let actions: [(title: String, action: (KL252SimulatorViewModel) -> Void)]
}

// MARK: - SwiftUI View

struct KL252SimulatorView: View {
    @StateObject private var viewModel = KL252SimulatorViewModel()

    private var quickSections: [SimulatorQuickSection] {
        [
            SimulatorQuickSection(title: "🔔 闹钟 / 例程", actions: [
                ("触发 E1 + 播放", { $0.sendAlarmTrigger() }),
                ("超时 E2 + 停止", { $0.sendAlarmTimeout() }),
                ("手动停止 E3", { $0.sendAlarmStop() }),
            ]),
            SimulatorQuickSection(title: "🎵 机身音乐按键", actions: [
                ("▶️ 播放", { $0.devicePlay() }),
                ("⏸ 暂停", { $0.devicePause() }),
                ("⏮ 上一首", { $0.devicePrevious() }),
                ("⏭ 下一首", { $0.deviceNext() }),
            ]),
            SimulatorQuickSection(title: "📞 来电 / 免打扰", actions: [
                ("来电开始 E7↑", { $0.sendCallStart() }),
                ("来电停止 E7↓", { $0.sendCallStop() }),
                ("开启免打扰 EB", { $0.sendDNDOn() }),
                ("关闭免打扰 EB", { $0.sendDNDOff() }),
            ]),
            SimulatorQuickSection(title: "📁 文件传输", actions: [
                ("传输完成 E5", { $0.sendFileComplete() }),
                ("传输取消 E6", { $0.sendFileCancel() }),
            ]),
            SimulatorQuickSection(title: "🔋 电源状态 / 系统", actions: [
                ("上报电量 85%", { $0.sendBattery85() }),
                ("上报电量 20%", { $0.sendBattery20() }),
                ("充电中 FF01", { $0.sendCharging() }),
                ("已充满 FF01", { $0.sendFullyCharged() }),
                ("未充电 FF01", { $0.sendNotCharging() }),
                ("恢复出厂 E8", { $0.sendFactoryEvent() }),
            ]),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                statusCard
                logCard
                quickPanelCard
            }
            .padding(16)
        }
        .frame(minWidth: 560, minHeight: 780)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("KL252 设备模拟器")
    }

    // MARK: - Status Card

    private var statusCard: some View {
        SimulatorCard {
            HStack {
                Text(viewModel.isAdvertising ? "🟢 广播中" : "🔴 未广播")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(viewModel.isAdvertising ? .green : .secondary)
                Spacer()
                Button(viewModel.isAdvertising ? "停止广播" : "开启广播") {
                    viewModel.toggleAdvertising()
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isAdvertising ? .red : .green)
            }
            Text("设备名: \(viewModel.deviceName)  |  电量: \(viewModel.batteryLevel)%  |  充电: \(viewModel.chargeStateText)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("播放: \(viewModel.playStateText)  |  曲目: \(viewModel.currentMusicText)  |  音源数: \(viewModel.musicTrackCount)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Log Card

    private var logCard: some View {
        SimulatorCard {
            HStack {
                Text("📋 HEX 通信日志")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("清空") { viewModel.clearLog() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.logLines) { line in
                        Text(line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 220)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Quick Panel

    private var quickPanelCard: some View {
        SimulatorCard {
            Text("⚡ 设备主动上报 / 机身触发面板")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(quickSections) { section in
                Text(section.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)

                let rows = section.actions.chunked(into: 2)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, item in
                            Button(item.title) { item.action(viewModel) }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .disabled(!viewModel.isAdvertising)
                                .opacity(viewModel.isAdvertising ? 1 : 0.4)
                        }
                        if row.count == 1 {
                            Color.clear.frame(maxWidth: .infinity, minHeight: 38)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Card Container

private struct SimulatorCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Array Chunk Helper

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

#Preview {
    KL252SimulatorView()
}
