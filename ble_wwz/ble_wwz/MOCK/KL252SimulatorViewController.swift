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

    // 快捷面板
    func sendAlarmTrigger() {
        simulator.sendAlarmEvent(.alarmTrigger, alarmType: 0x00, alarmID: 0x01, phase: 0x03)
    }
    func sendAlarmTimeout() {
        simulator.sendAlarmEvent(.alarmTimeout, alarmType: 0x00, alarmID: 0x01, phase: 0x03)
    }
    func sendAlarmStop() {
        simulator.sendAlarmEvent(.alarmStop, alarmType: 0x01, alarmID: 0x02, phase: 0x00)
    }
    func sendCallStart() { simulator.sendCallRingEvent(action: 0x01) }
    func sendCallStop() { simulator.sendCallRingEvent(action: 0x00) }
    func sendDNDOn() { simulator.sendDNDEvent(enabled: 0x01) }
    func sendDNDOff() { simulator.sendDNDEvent(enabled: 0x00) }
    func sendBattery85() { simulator.notifyBatteryLevel(85) }
    func sendBattery20() { simulator.notifyBatteryLevel(20) }
    func sendFactoryEvent() { simulator.sendFactoryRestartEvent() }

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
    }
}

struct LogLine: Identifiable {
    let id = UUID()
    let text: String
    let color: Color
}

// MARK: - SwiftUI View

struct KL252SimulatorView: View {
    @StateObject private var viewModel = KL252SimulatorViewModel()

    private let quickActions: [(title: String, action: (KL252SimulatorViewModel) -> Void)] = [
        ("🔔 闹钟触发 E1", { $0.sendAlarmTrigger() }),
        ("⏱ 闹钟超时 E2", { $0.sendAlarmTimeout() }),
        ("🛑 手动停止 E3", { $0.sendAlarmStop() }),
        ("📞 来电开始 E7↑", { $0.sendCallStart() }),
        ("📵 来电停止 E7↓", { $0.sendCallStop() }),
        ("🔕 开启免打扰 EB", { $0.sendDNDOn() }),
        ("🔔 关闭免打扰 EB", { $0.sendDNDOff() }),
        ("🔋 上报电量 85%", { $0.sendBattery85() }),
        ("🔋 上报电量 20%", { $0.sendBattery20() }),
        ("🏭 恢复出厂事件 E8", { $0.sendFactoryEvent() }),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                statusCard
                logCard
                quickPanelCard
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 680)
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
            Text("设备名: \(viewModel.deviceName)  |  电量: \(viewModel.batteryLevel)%")
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
            Text("⚡ 快捷上报面板")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            let rows = quickActions.chunked(into: 2)
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
