// KL252SimulatorMusicPlayer.swift
// 模拟器音源目录与真实播放 — 扫描 sounds 目录，文件名前缀为 MusicID
// ⚠️ 本文件为独立模拟器模块，不影响项目原有 BLE 业务代码

import Foundation
import AVFoundation

// MARK: - Music Catalog

/// 从 Bundle `sounds/` 目录加载音源；文件名格式 `{MusicID}_{名称}.mp3`
enum KL252SimulatorMusicCatalog {
    private static let subdirectory = "sounds"
    private static let supportedExtensions = ["mp3", "m4a", "wav", "aac", "caf"]

    /// 扫描并返回排序后的 MusicID 列表（100~999999）
    static func bundledMusicIDs() -> [UInt32] {
        indexedTracks().keys.sorted()
    }

    /// 根据 MusicID 查找音源文件 URL
    static func url(for musicID: UInt32) -> URL? {
        indexedTracks()[musicID]
    }

    /// 音源显示名（文件名 `_` 后部分，去扩展名）
    static func displayName(for musicID: UInt32) -> String? {
        guard let url = url(for: musicID) else { return nil }
        let base = url.deletingPathExtension().lastPathComponent
        guard let idx = base.firstIndex(of: "_") else { return base }
        return String(base[base.index(after: idx)...])
    }

    private static func indexedTracks() -> [UInt32: URL] {
        var map: [UInt32: URL] = [:]
        for url in bundledAudioURLs() {
            guard let id = parseMusicID(from: url.lastPathComponent) else { continue }
            map[id] = url
        }
        return map
    }

    private static func bundledAudioURLs() -> [URL] {
        var urls: [URL] = []
        for ext in supportedExtensions {
            if let found = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: subdirectory) {
                urls.append(contentsOf: found)
            }
            // Xcode 同步组可能将 sounds 内容平铺到 Resources 根目录
            if let found = Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) {
                urls.append(contentsOf: found.filter { parseMusicID(from: $0.lastPathComponent) != nil })
            }
        }
        if urls.isEmpty, let resourceURL = Bundle.main.resourceURL {
            let soundsURL = resourceURL.appendingPathComponent(subdirectory, isDirectory: true)
            if let children = try? FileManager.default.contentsOfDirectory(
                at: soundsURL,
                includingPropertiesForKeys: nil
            ) {
                urls = children.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            }
        }
        return urls
    }

    private static func parseMusicID(from filename: String) -> UInt32? {
        let stem = (filename as NSString).deletingPathExtension
        guard let idPart = stem.split(separator: "_", maxSplits: 1).first,
              let id = UInt32(idPart),
              id >= 100, id <= 999_999 else { return nil }
        return id
    }
}

// MARK: - Player Delegate

protocol KL252SimulatorMusicPlayerDelegate: AnyObject {
    func musicPlayerDidFinishPlaying(_ player: KL252SimulatorMusicPlayer)
}

// MARK: - Music Player

/// §4.4 真实音源播放（AVAudioPlayer）
final class KL252SimulatorMusicPlayer: NSObject, AVAudioPlayerDelegate {
    weak var delegate: KL252SimulatorMusicPlayerDelegate?

    private(set) var currentMusicID: UInt32 = 0
    private var audioPlayer: AVAudioPlayer?
    private var paused = false

    var isActive: Bool { audioPlayer != nil }
    var isPlaying: Bool { audioPlayer?.isPlaying == true }

    /// 播放指定 MusicID；若同曲目已暂停则恢复播放
    @discardableResult
    func play(musicID: UInt32, volume: UInt8) -> Bool {
        guard let url = KL252SimulatorMusicCatalog.url(for: musicID) else { return false }
        let vol = normalizedVolume(volume)

        if currentMusicID == musicID, let player = audioPlayer, paused {
            player.volume = vol
            paused = false
            return player.play()
        }

        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.volume = vol
            player.prepareToPlay()
            guard player.play() else { return false }
            audioPlayer = player
            currentMusicID = musicID
            paused = false
            return true
        } catch {
            return false
        }
    }

    func pause() {
        guard let player = audioPlayer, player.isPlaying else { return }
        player.pause()
        paused = true
    }

    func resume(volume: UInt8) -> Bool {
        guard let player = audioPlayer, paused else { return false }
        player.volume = normalizedVolume(volume)
        paused = false
        return player.play()
    }

    func setVolume(_ volume: UInt8) {
        audioPlayer?.volume = normalizedVolume(volume)
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        currentMusicID = 0
        paused = false
    }

    // MARK: AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        audioPlayer = nil
        currentMusicID = 0
        paused = false
        delegate?.musicPlayerDidFinishPlaying(self)
    }

    private func normalizedVolume(_ volume: UInt8) -> Float {
        Float(min(max(volume, 1), 100)) / 100.0
    }
}
