// KL252SimulatorStorage.swift
// 模拟器接收文件落盘 — 音源传输 (§4.5) 与固件升级 (§4.6)
// 开发态写入 MOCK/received/（源码树内，便于查看）；Release 写入 Application Support

import Foundation

enum KL252SimulatorStorage {

    enum StoreError: Error {
        case createFailed
        case writeFailed
        case incomplete
        case checksumMismatch
        case finalizeFailed
    }

    // MARK: - Directories

    /// 接收文件根目录（优先 MOCK/received，便于在项目中直接查看）
    static var receivedRoot: URL {
        let mockReceived = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("received", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: mockReceived.deletingLastPathComponent().path) {
            return mockReceived
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("com.ksmartnet.ble-wwz/KL252Simulator/received", isDirectory: true)
    }

    static var musicDirectory: URL {
        receivedRoot.appendingPathComponent("music", isDirectory: true)
    }

    static var firmwareDirectory: URL {
        receivedRoot.appendingPathComponent("firmware", isDirectory: true)
    }

    static var stagingDirectory: URL {
        receivedRoot.appendingPathComponent("staging", isDirectory: true)
    }

    static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [receivedRoot, musicDirectory, firmwareDirectory, stagingDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Storage accounting

    static func directorySize(_ directory: URL) -> UInt64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return items.reduce(0) { partial, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return partial + UInt64(max(0, size))
        }
    }

    static func totalPersistedBytes() -> UInt64 {
        directorySize(musicDirectory) + directorySize(firmwareDirectory)
    }

    static func transferredMusicURLs() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: musicDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.filter { !$0.hasDirectoryPath }
    }

    static func transferredMusicIDs() -> [UInt32] {
        transferredMusicURLs().compactMap { parseMusicID(from: $0.lastPathComponent) }.sorted()
    }

    static func musicURL(for musicID: UInt32) -> URL? {
        transferredMusicURLs().first { parseMusicID(from: $0.lastPathComponent) == musicID }
    }

    static func deleteTransferredMusic(musicID: UInt32) -> Bool {
        guard let url = musicURL(for: musicID) else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }

    static func parseMusicID(from filename: String) -> UInt32? {
        let stem = (filename as NSString).deletingPathExtension
        guard let idPart = stem.split(separator: "_", maxSplits: 1).first,
              let id = UInt32(idPart),
              id >= 100, id <= 999_999 else { return nil }
        return id
    }

    /// 全文件逐字节 XOR（§4.5 0x51 CheckSum）
    static func xorChecksum(of url: URL, length: Int) throws -> UInt8 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var xor: UInt8 = 0
        var remaining = length
        while remaining > 0 {
            let chunk = handle.readData(ofLength: min(65_536, remaining))
            if chunk.isEmpty { break }
            xor ^= KL252FrameCodec.xorChecksum([UInt8](chunk))
            remaining -= chunk.count
        }
        guard remaining == 0 else { throw StoreError.incomplete }
        return xor
    }

    // MARK: - Music staging (random access by packet)

    final class MusicStagingFile {
        let url: URL
        let fileSize: UInt32
        let payloadMax: Int
        let packetCount: Int
        private let handle: FileHandle

        static func create(fileID: UInt8, musicID: UInt32, fileSize: UInt32, payloadMax: Int) throws -> MusicStagingFile {
            ensureDirectories()
            let name = "music_f\(String(format: "%02X", fileID))_\(musicID).part"
            let url = stagingDirectory.appendingPathComponent(name)
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw StoreError.createFailed
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(fileSize))
            let packetCount = Int((fileSize + UInt32(payloadMax) - 1) / UInt32(payloadMax))
            return MusicStagingFile(
                url: url,
                fileSize: fileSize,
                payloadMax: payloadMax,
                packetCount: packetCount,
                handle: handle
            )
        }

        private init(url: URL, fileSize: UInt32, payloadMax: Int, packetCount: Int, handle: FileHandle) {
            self.url = url
            self.fileSize = fileSize
            self.payloadMax = payloadMax
            self.packetCount = packetCount
            self.handle = handle
        }

        func write(packetIndex: UInt16, payload: Data) throws {
            let offset = UInt64(packetIndex) * UInt64(payloadMax)
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: payload)
        }

        func finalize(musicID: UInt32, expectedXor: UInt8, receivedPacketCount: Int) throws -> URL {
            guard receivedPacketCount == packetCount else { throw StoreError.incomplete }
            try handle.close()
            let actualXor = try xorChecksum(of: url, length: Int(fileSize))
            guard actualXor == expectedXor else { throw StoreError.checksumMismatch }

            ensureDirectories()
            let dest = musicDirectory.appendingPathComponent("\(musicID)_received.mp3")
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: url, to: dest)
            return dest
        }

        func cancel() {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }

        deinit {
            try? handle.close()
        }
    }

    // MARK: - Firmware staging (sequential append)

    final class FirmwareStagingFile {
        let url: URL
        let fileSize: UInt32
        let payloadMax: Int
        private let handle: FileHandle
        private(set) var receivedBytes: Int = 0

        static func create(fileSize: UInt32, payloadMax: Int) throws -> FirmwareStagingFile {
            ensureDirectories()
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = stagingDirectory.appendingPathComponent("firmware_\(stamp).part")
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw StoreError.createFailed
            }
            return FirmwareStagingFile(
                url: url,
                fileSize: fileSize,
                payloadMax: payloadMax,
                handle: try FileHandle(forWritingTo: url)
            )
        }

        private init(url: URL, fileSize: UInt32, payloadMax: Int, handle: FileHandle) {
            self.url = url
            self.fileSize = fileSize
            self.payloadMax = payloadMax
            self.handle = handle
        }

        func append(_ payload: Data) throws {
            try handle.write(contentsOf: payload)
            receivedBytes += payload.count
        }

        func finalize(firmwareVersion: String) throws -> URL {
            try handle.close()
            guard receivedBytes == Int(fileSize) else { throw StoreError.incomplete }

            ensureDirectories()
            let safeVersion = firmwareVersion.replacingOccurrences(of: ".", with: "_")
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let dest = firmwareDirectory.appendingPathComponent("firmware_v\(safeVersion)_\(stamp).bin")
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: url, to: dest)
            return dest
        }

        func cancel() {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }

        deinit {
            try? handle.close()
        }
    }
}
