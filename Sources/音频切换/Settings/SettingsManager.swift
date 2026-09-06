import Foundation
import os

/// 所有按应用存储的持久化数据，序列化为单个 JSON 文件以支持原子写入。
/// version 用于在升级时自动迁移旧数据，避免因结构变更导致数据丢失。
private struct PerAppStore: Codable, Sendable {
    /// 数据格式版本号。当前版本 == 4。设备别名为可选字段，旧 v4 文件可直接读取。
    static let currentVersion = 4
    var version: Int = PerAppStore.currentVersion
    var volumes: [String: Float] = [:]
    var mutes: [String: Bool] = [:]
    var pinned: [String: PinnedAppInfo] = [:]
    var ignored: [String: IgnoredAppInfo] = [:]
    var devicePriority: [String] = []
    var deviceAliases: [String: String] = [:]
    var routePreferences: [String: RoutePreferenceRecord] = [:]
    /// The recovery destination for a panorama group that loses every
    /// endpoint. It is intentionally separate from the desired route, which
    /// can remain `.panoramaGroup` while this preserves the user's last
    /// confirmed single-device choice.
    var lastSuccessfulSingleDeviceUIDs: [String: String] = [:]

    private enum CodingKeys: String, CodingKey {
        case version, volumes, mutes, pinned, ignored, devicePriority, deviceAliases, routePreferences, lastSuccessfulSingleDeviceUIDs
    }

    init(
        version: Int = PerAppStore.currentVersion,
        volumes: [String: Float] = [:],
        mutes: [String: Bool] = [:],
        pinned: [String: PinnedAppInfo] = [:],
        ignored: [String: IgnoredAppInfo] = [:],
        devicePriority: [String] = [],
        deviceAliases: [String: String] = [:],
        routePreferences: [String: RoutePreferenceRecord] = [:],
        lastSuccessfulSingleDeviceUIDs: [String: String] = [:]
    ) {
        self.version = version
        self.volumes = volumes
        self.mutes = mutes
        self.pinned = pinned
        self.ignored = ignored
        self.devicePriority = devicePriority
        self.deviceAliases = deviceAliases
        self.routePreferences = routePreferences
        self.lastSuccessfulSingleDeviceUIDs = lastSuccessfulSingleDeviceUIDs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? PerAppStore.currentVersion
        volumes = try values.decodeIfPresent([String: Float].self, forKey: .volumes) ?? [:]
        mutes = try values.decodeIfPresent([String: Bool].self, forKey: .mutes) ?? [:]
        pinned = try values.decodeIfPresent([String: PinnedAppInfo].self, forKey: .pinned) ?? [:]
        ignored = try values.decodeIfPresent([String: IgnoredAppInfo].self, forKey: .ignored) ?? [:]
        devicePriority = try values.decodeIfPresent([String].self, forKey: .devicePriority) ?? []
        deviceAliases = try values.decodeIfPresent([String: String].self, forKey: .deviceAliases) ?? [:]
        routePreferences = try values.decodeIfPresent([String: RoutePreferenceRecord].self, forKey: .routePreferences) ?? [:]
        lastSuccessfulSingleDeviceUIDs = try values.decodeIfPresent([String: String].self, forKey: .lastSuccessfulSingleDeviceUIDs) ?? [:]
    }

    func overlaying(_ newer: PerAppStore) -> PerAppStore {
        var merged = self
        merged.volumes.merge(newer.volumes) { _, new in new }
        merged.mutes.merge(newer.mutes) { _, new in new }
        merged.pinned.merge(newer.pinned) { _, new in new }
        merged.ignored.merge(newer.ignored) { _, new in new }
        merged.deviceAliases.merge(newer.deviceAliases) { _, new in new }
        merged.routePreferences.merge(newer.routePreferences) { _, new in new }
        merged.lastSuccessfulSingleDeviceUIDs.merge(newer.lastSuccessfulSingleDeviceUIDs) { _, new in new }
        if !newer.devicePriority.isEmpty { merged.devicePriority = newer.devicePriority }
        return merged
    }
}

private struct PerAppStoreLoadResult: Sendable {
    let store: PerAppStore
    let isReadOnly: Bool
    let didMigrate: Bool
}

private struct LegacyPerAppStore: Codable, Sendable {
    var volumes: [String: Float] = [:]
    var mutes: [String: Bool] = [:]
    var pinned: [String: PinnedAppInfo] = [:]
    var ignored: [String: IgnoredAppInfo] = [:]
    var devicePriority: [String] = []
}

private actor PerAppStorePersistence {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func load() -> (PerAppStoreLoadResult?, String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
        do {
            let data = try Data(contentsOf: url)
            if let result = Self.decode(data) { return (result, nil) }
            let quarantineURL = url
                .deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try FileManager.default.moveItem(at: url, to: quarantineURL)
            return (nil, "设置文件已损坏，已隔离为 \(quarantineURL.lastPathComponent)")
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    func save(_ store: PerAppStore) -> String? {
        do {
            let data = try JSONEncoder().encode(store)
            let temporaryURL = url.appendingPathExtension("tmp")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: temporaryURL, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(
                    url,
                    withItemAt: temporaryURL,
                    backupItemName: "perapp.backup.json"
                )
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            }
            return nil
        } catch {
            try? FileManager.default.removeItem(at: url.appendingPathExtension("tmp"))
            return error.localizedDescription
        }
    }

    private static func decode(_ data: Data) -> PerAppStoreLoadResult? {
        if let store = try? JSONDecoder().decode(PerAppStore.self, from: data) {
            if store.version == PerAppStore.currentVersion {
                return PerAppStoreLoadResult(store: store, isReadOnly: false, didMigrate: false)
            }
            if store.version > PerAppStore.currentVersion {
                return PerAppStoreLoadResult(store: store, isReadOnly: true, didMigrate: false)
            }
            var migrated = store
            migrated.version = PerAppStore.currentVersion
            return PerAppStoreLoadResult(store: migrated, isReadOnly: false, didMigrate: true)
        }
        guard let legacy = try? JSONDecoder().decode(LegacyPerAppStore.self, from: data) else {
            return nil
        }
        return PerAppStoreLoadResult(
            store: PerAppStore(
                volumes: legacy.volumes,
                mutes: legacy.mutes,
                pinned: legacy.pinned,
                ignored: legacy.ignored,
                devicePriority: legacy.devicePriority
            ),
            isReadOnly: false,
            didMigrate: true
        )
    }
}

@Observable
@MainActor
final class SettingsManager {
    private let logger = Logger(subsystem: "com.mankeipun.yinpinqiehuan", category: "Settings")
    private let perAppStoreURL: URL
    private let saveDelay: TimeInterval
    private let persistence: PerAppStorePersistence

    var appSettings: AppSettings {
        didSet { saveAppSettings() }
    }

    // MARK: - 设置数据

    private var store = PerAppStore()
    /// A newer on-disk schema is preserved verbatim until a compatible app can
    /// open it. No user interaction in this version may overwrite it.
    private(set) var isPerAppStoreReadOnly = false
    /// Disk failures never roll back an already-committed audio transaction;
    /// callers can present this state as "not saved" instead.
    private(set) var perAppPersistenceError: String?

    /// savePerApp 的防抖工作项
    private var savePerAppTask: Task<Void, Never>?
    private var hasLocalMutationsBeforeLoad = false
    private(set) var isPerAppStoreLoaded = false
    var onPerAppStoreLoaded: (() -> Void)? {
        didSet {
            if isPerAppStoreLoaded { onPerAppStoreLoaded?() }
        }
    }

    // MARK: - 存储路径

    private static var defaultPerAppStoreURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("音频切换")
        return dir.appendingPathComponent("perapp.json")
    }

    init(storageURL: URL? = nil, saveDelay: TimeInterval = 0.3) {
        self.perAppStoreURL = storageURL ?? Self.defaultPerAppStoreURL
        self.saveDelay = max(0, saveDelay)
        self.persistence = PerAppStorePersistence(url: self.perAppStoreURL)
        self.appSettings = Self.loadAppSettings()
        Task { [weak self, persistence] in
            let (loaded, error) = await persistence.load()
            guard let self else { return }
            if let loaded {
                self.store = loaded.isReadOnly
                    ? loaded.store
                    : loaded.store.overlaying(
                        self.hasLocalMutationsBeforeLoad ? self.store : PerAppStore()
                    )
                self.isPerAppStoreReadOnly = loaded.isReadOnly
                if loaded.isReadOnly {
                    Log.warning(self.logger, "检测到更高版本的 per-app 设置，以只读模式打开")
                } else if loaded.didMigrate || self.hasLocalMutationsBeforeLoad {
                    self.persistCurrentStore()
                }
            }
            self.perAppPersistenceError = error
            self.isPerAppStoreLoaded = true
            self.onPerAppStoreLoaded?()
        }
    }

    // MARK: - 音量

    func setVolume(for identifier: String, to volume: Float) {
        store.volumes[identifier] = volume
        savePerApp()
    }
    func getVolume(for identifier: String) -> Float? { store.volumes[identifier] }

    func setMute(for identifier: String, to muted: Bool) {
        store.mutes[identifier] = muted
        savePerApp()
    }
    func getMute(for identifier: String) -> Bool? { store.mutes[identifier] }

    // MARK: - 稳定逐应用路由偏好

    /// Returns only a record that satisfies the on-disk wire-format invariants.
    /// Invalid records remain in the source file for diagnosis and are not
    /// silently replaced by an empty configuration.
    func routePreference(for identity: AppIdentity) -> RoutePreferenceRecord? {
        guard let record = store.routePreferences[identity.persistenceKey],
              record.validatedDesiredRoute() != nil else {
            return nil
        }
        return record
    }

    func desiredRoute(for identity: AppIdentity) -> DesiredRoute {
        routePreference(for: identity)?.validatedDesiredRoute() ?? .followSystemDefault
    }

    /// Persists an explicit user choice. Callers must invoke this only after a
    /// future route transaction has committed; this legacy manager does not
    /// perform audio routing itself.
    func setDesiredRoute(_ route: DesiredRoute, for identity: AppIdentity) {
        store.routePreferences[identity.persistenceKey] = RoutePreferenceRecord(desiredRoute: route)
        savePerApp()
    }

    func lastSuccessfulSingleDeviceRoute(for identity: AppIdentity) -> String? {
        let uid = store.lastSuccessfulSingleDeviceUIDs[identity.persistenceKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return uid?.isEmpty == false ? uid : nil
    }

    func setLastSuccessfulSingleDeviceRoute(uid: String, for identity: AppIdentity) {
        let normalized = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        store.lastSuccessfulSingleDeviceUIDs[identity.persistenceKey] = normalized
        savePerApp()
    }

    // MARK: - 固定和忽略

    func pinApp(_ identifier: String, info: PinnedAppInfo) {
        store.pinned[identifier] = info
        savePerApp()
    }
    func unpinApp(_ identifier: String) {
        store.pinned.removeValue(forKey: identifier)
        savePerApp()
    }
    func isPinned(_ identifier: String) -> Bool { store.pinned[identifier] != nil }
    func getPinnedAppInfo() -> [PinnedAppInfo] { Array(store.pinned.values) }

    func ignoreApp(_ identifier: String, info: IgnoredAppInfo) {
        store.ignored[identifier] = info
        savePerApp()
    }
    func unignoreApp(_ identifier: String) {
        store.ignored.removeValue(forKey: identifier)
        savePerApp()
    }
    func isIgnored(_ identifier: String) -> Bool { store.ignored[identifier] != nil }
    func getIgnoredAppInfo() -> [IgnoredAppInfo] { Array(store.ignored.values) }

    // MARK: - 设备优先级

    func ensureDeviceInPriority(_ uid: String) {
        guard !store.devicePriority.contains(uid) else { return }
        store.devicePriority.append(uid)
        savePerApp()
    }
    var devicePriority: [String] { store.devicePriority }
    func setDevicePriority(_ order: [String]) {
        store.devicePriority = order
        savePerApp()
    }

    // MARK: - 输出设备别名

    func deviceAlias(for uid: String) -> String? {
        let alias = store.deviceAliases[uid]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return alias?.isEmpty == false ? alias : nil
    }

    /// An empty alias restores the device's hardware-provided display name.
    func setDeviceAlias(_ alias: String, for uid: String) {
        let normalizedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUID.isEmpty else { return }

        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedAlias.isEmpty {
            store.deviceAliases.removeValue(forKey: normalizedUID)
        } else {
            store.deviceAliases[normalizedUID] = String(normalizedAlias.prefix(32))
        }
        savePerApp()
    }

    // MARK: - 持久化（基于文件的原子写入）

    private static func loadAppSettings() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: "appSettings"),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    private func saveAppSettings() {
        guard let data = try? JSONEncoder().encode(appSettings) else { return }
        UserDefaults.standard.set(data, forKey: "appSettings")
    }

    private func savePerApp() {
        guard !isPerAppStoreReadOnly else { return }
        if !isPerAppStoreLoaded {
            hasLocalMutationsBeforeLoad = true
            return
        }
        savePerAppTask?.cancel()
        savePerAppTask = Task { [weak self] in
            guard let self else { return }
            if self.saveDelay > 0 {
                try? await Task.sleep(for: .seconds(self.saveDelay))
            }
            guard !Task.isCancelled else { return }
            self.persistCurrentStore()
        }
    }

    func flush() {
        savePerAppTask?.cancel()
        persistCurrentStore()
    }

    /// 真正的原子写入：先写临时文件，再 rename 到目标路径。
    /// 相比 .atomic 选项，rename 在文件系统层面是原子操作，不会出现半写文件。
    private func persistCurrentStore() {
        guard !isPerAppStoreReadOnly else { return }
        let snapshot = store
        Task { [weak self, persistence] in
            let error = await persistence.save(snapshot)
            guard let self else { return }
            self.perAppPersistenceError = error
            if let error {
                Log.error(self.logger, "持久化 per-app 设置失败: \(error)")
            }
        }
    }
}

struct IgnoredAppInfo: Codable, Equatable, Sendable {
    let persistenceIdentifier: String
    let displayName: String
    let bundleID: String?
}
