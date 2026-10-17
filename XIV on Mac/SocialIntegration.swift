//
//  SocialIntegration.swift
//  XIV on Mac
//
//  Created by Ming Quah on 29/12/2021.
//

import CryptoKit
import Foundation
import OSLog

enum DiscordBridge {
    private static let logger = Logger(subsystem: "XIV on Mac", category: "DiscordBridge")

    enum Status {
        case notInstalled
        case stopped
        case running
    }

    enum BridgeError: LocalizedError {
        case wineNotReady
        case download
        case verify
        case install

        var errorDescription: String? {
            switch self {
            case .wineNotReady: return NSLocalizedString("DISCORD_ERR_WINE_NOT_READY", comment: "")
            case .download: return NSLocalizedString("DISCORD_ERR_DOWNLOAD", comment: "")
            case .verify: return NSLocalizedString("DISCORD_ERR_VERIFY", comment: "")
            case .install: return NSLocalizedString("DISCORD_ERR_INSTALL", comment: "")
            }
        }
    }

    // xbridge Windows service (Rust-based Discord RPC bridge)
    private static let releaseAPI = URL(
        string: "https://api.github.com/repos/PlusoneChiang/xbridge/releases/latest")!

    private static let enabledKey = "DiscordBridgeEnabled"
    private static let cachedTagKey = "DiscordBridgeCachedTag"

    /// Whether the user asked for the bridge; survives Wine prefix rebuilds.
    private static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Development override: `defaults write <bundle id> DiscordBridgeExeOverride /path/to/xbridge.exe`
    /// uses that build instead of the downloaded release (skips download and hash check).
    private static var overridePath: URL? {
        guard let path = UserDefaults.standard.string(forKey: "DiscordBridgeExeOverride"),
            FileManager.default.fileExists(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    // xbridge.exe used for install / uninstall
    private static var localPath: URL {
        overridePath ?? cachePath
    }

    // Local download cache
    private static var cachePath: URL {
        Util.applicationSupport
            .appendingPathComponent("discord-rpc")
            .appendingPathComponent("xbridge.exe")
    }

    // Installed path inside the Wine prefix
    private static var installedPath: URL {
        Wine.prefix.appendingPathComponent("drive_c/windows/xbridge.exe")
    }

    // Registry key for IPC socket path (read by xbridge Windows service on macOS)
    private static let ipcRegistryKey =
        #"HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"#

    /// The exe is only copied into the prefix; the service may still be missing or stopped.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedPath.path)
    }

    static var status: Status {
        guard isInstalled else { return .notInstalled }
        return Wine.running(processName: "xbridge.exe") ? .running : .stopped
    }

    // macOS TMPDIR is session-specific; xbridge reads it from the registry because
    // Windows services cannot inherit POSIX environment variables.
    static func ipcDirectory() -> String {
        if let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"], !tmpdir.isEmpty {
            return tmpdir
        }
        logger.warning("[xbridge] TMPDIR is not set; falling back to /tmp/, Discord socket will likely not be found")
        return "/tmp/"
    }

    /// Writes the Discord endpoints xbridge reads from the Wine registry.
    /// - DISCORD_IPC_PATH: Unix socket directory (used where Wine supports AF_UNIX).
    /// - DISCORD_IPC_TCP / DISCORD_IPC_TOKEN: loopback relay endpoint. Wine on macOS cannot
    ///   create AF_UNIX sockets, so xbridge connects to the relay instead. Older xbridge
    ///   builds ignore these values.
    /// xbridge re-reads them on every Discord connect attempt, so writing them before the
    /// game starts is sufficient.
    private static func writeIpcRegistry() {
        let tmpdir = ipcDirectory()
        logger.info("[xbridge] refreshing DISCORD_IPC_PATH: \(tmpdir)")
        Wine.addReg(key: ipcRegistryKey, value: "DISCORD_IPC_PATH", data: tmpdir)
        do {
            let relay = try DiscordRelay.shared.start(socketDirectory: ipcDirectory)
            Wine.addReg(key: ipcRegistryKey, value: "DISCORD_IPC_TCP", data: "127.0.0.1:\(relay.port)")
            Wine.addReg(key: ipcRegistryKey, value: "DISCORD_IPC_TOKEN", data: relay.token)
        } catch {
            logger.error("[xbridge] relay failed to start: \(error.localizedDescription)")
        }
    }

    // Called before each game launch.
    static func refreshIpcPath() {
        guard isInstalled else { return }
        writeIpcRegistry()
    }

    /// Re-installs the bridge after the Wine prefix was rebuilt, if the user had enabled it.
    static func restoreIfNeeded() async {
        guard enabled, !isInstalled else { return }
        logger.info("[xbridge] prefix lost the bridge; reinstalling")
        do {
            try await install()
        } catch {
            logger.error("[xbridge] automatic reinstall failed: \(error.localizedDescription)")
        }
    }

    static func install() async throws {
        do {
            try await Task.detached { try Wine.waitUntilReady() }.value
        } catch {
            throw BridgeError.wineNotReady
        }

        if status == .running {
            logger.info("[xbridge] service already running, skipping install.")
            enabled = true
            return
        }

        if overridePath == nil {
            try await ensureLocalCopy()
        } else {
            logger.warning("[xbridge] using local override build: \(localPath.path)")
        }

        // Write IPC endpoints before install so xbridge finds them at first start
        writeIpcRegistry()

        // xbridge's --install only re-enables an already registered service and never re-copies
        // the exe, so a stale registration (service present, exe missing or stopped) cannot be
        // repaired in place. Remove the registration first, then install from scratch.
        logger.info("[xbridge] resetting any stale service registration...")
        Wine.launch(command: "\"\(localPath.path)\" --uninstall", blocking: true)
        clearPendingDelete()
        try? FileManager.default.removeItem(at: installedPath)
        writeIpcRegistry()

        logger.info("[xbridge] installing service in Wine prefix...")
        Wine.launch(command: "\"\(localPath.path)\" --install", blocking: true)

        for _ in 0..<20 {
            if await Task.detached(operation: { status }).value == .running { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard await Task.detached(operation: { status }).value == .running else {
            logger.error("[xbridge] install finished but the service is not running.")
            throw BridgeError.install
        }
        enabled = true
        logger.info("[xbridge] install complete.")
    }

    /// --uninstall schedules `C:\windows\xbridge.exe` for deletion at reboot. Wine may honour
    /// that on a later prefix start and delete a freshly installed exe, so clear it.
    private static func clearPendingDelete() {
        Wine.launch(
            command:
                #"reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager" /v PendingFileRenameOperations /f"#,
            blocking: true)
    }

    static func uninstall() async {
        enabled = false
        guard isInstalled else {
            logger.info("[xbridge] not installed, nothing to uninstall.")
            return
        }
        logger.info("[xbridge] uninstalling xbridge service...")
        Wine.launch(command: "\"\(installedPath.path)\" --uninstall", blocking: true)
        // xbridge only schedules exe deletion for the next reboot; drop that entry so it cannot
        // delete a later reinstall, and remove the exe ourselves.
        clearPendingDelete()
        if !Wine.running(processName: "xbridge.exe") {
            try? FileManager.default.removeItem(at: installedPath)
        }
        logger.info("[xbridge] uninstall complete.")
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let digest: String?
        }
        let tag_name: String
        let assets: [Asset]
    }

    /// Makes sure the cached xbridge.exe matches the latest release and its published SHA-256.
    /// Works offline when a cached copy already exists.
    private static func ensureLocalCopy() async throws {
        let cached = FileManager.default.fileExists(atPath: cachePath.path)
        let release: Release
        do {
            var request = URLRequest(url: releaseAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            logger.error("[xbridge] release lookup failed: \(error.localizedDescription)")
            if cached { return }
            throw BridgeError.download
        }

        if cached, UserDefaults.standard.string(forKey: cachedTagKey) == release.tag_name {
            return
        }
        guard let asset = release.assets.first(where: { $0.name == "xbridge.exe" }),
            let digest = asset.digest, digest.hasPrefix("sha256:")
        else {
            logger.error("[xbridge] release \(release.tag_name) has no sha256 digest for xbridge.exe")
            throw BridgeError.verify
        }
        let expected = String(digest.dropFirst("sha256:".count)).lowercased()

        logger.info("[xbridge] downloading xbridge.exe \(release.tag_name)...")
        let downloadURL = URL(
            string:
                "https://github.com/PlusoneChiang/xbridge/releases/download/\(release.tag_name)/xbridge.exe"
        )!
        let tempURL: URL
        do {
            let (url, response) = try await URLSession.shared.download(from: downloadURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            tempURL = url
        } catch {
            logger.error("[xbridge] download failed: \(error.localizedDescription)")
            throw BridgeError.download
        }

        let actual = SHA256.hash(data: try Data(contentsOf: tempURL))
            .map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            logger.error("[xbridge] sha256 mismatch: expected \(expected), got \(actual)")
            try? FileManager.default.removeItem(at: tempURL)
            throw BridgeError.verify
        }

        let dir = cachePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: nil)
        try? FileManager.default.removeItem(at: cachePath)
        try FileManager.default.moveItem(at: tempURL, to: cachePath)
        UserDefaults.standard.set(release.tag_name, forKey: cachedTagKey)
        logger.info("[xbridge] downloaded and verified \(release.tag_name)")
    }
}
