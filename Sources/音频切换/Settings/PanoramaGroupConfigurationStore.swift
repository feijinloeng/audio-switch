import Foundation

private struct PanoramaGroupFileRecord: Codable, Sendable {
    static let currentVersion = 1
    let version: Int
    let configuration: PanoramaGroupConfiguration
}

private actor PanoramaGroupPersistence {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func load() -> (PanoramaGroupFileRecord?, String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
        do {
            let data = try Data(contentsOf: url)
            guard let record = try? JSONDecoder().decode(PanoramaGroupFileRecord.self, from: data) else {
                let quarantineURL = url
                    .deletingPathExtension()
                    .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
                try FileManager.default.moveItem(at: url, to: quarantineURL)
                return (nil, "全景组文件已损坏，已隔离为 \(quarantineURL.lastPathComponent)")
            }
            return (record, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    func save(_ record: PanoramaGroupFileRecord) -> String? {
        let temporaryURL = url.appendingPathExtension("tmp")
        do {
            let data = try JSONEncoder().encode(record)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: temporaryURL, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(
                    url,
                    withItemAt: temporaryURL,
                    backupItemName: "panorama-group.backup.json"
                )
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            }
            return nil
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            return error.localizedDescription
        }
    }
}

/// Main actor owns the live snapshot; all JSON and filesystem work is
/// serialized by `PanoramaGroupPersistence` away from UI and audio control.
@MainActor
final class PanoramaGroupConfigurationStore {
    private let persistence: PanoramaGroupPersistence
    private var hasLocalMutationBeforeLoad = false
    private(set) var isReadOnly = false
    private(set) var configuration = PanoramaGroupConfiguration(members: [])
    private(set) var persistenceError: String?
    private(set) var isLoaded = false
    var onLoaded: (() -> Void)? {
        didSet { if isLoaded { onLoaded?() } }
    }

    init(storageURL: URL) {
        persistence = PanoramaGroupPersistence(url: storageURL)
        Task { [weak self, persistence] in
            let (record, error) = await persistence.load()
            guard let self else { return }
            if !self.hasLocalMutationBeforeLoad, let record {
                self.configuration = record.configuration
                self.isReadOnly = record.version > PanoramaGroupFileRecord.currentVersion
            }
            self.persistenceError = error
            self.isLoaded = true
            self.onLoaded?()
        }
    }

    static var defaultStorageURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("音频切换")
        return directory.appendingPathComponent("panorama-group.json")
    }

    func save(_ configuration: PanoramaGroupConfiguration) {
        guard !isReadOnly else { return }
        if !isLoaded { hasLocalMutationBeforeLoad = true }
        self.configuration = configuration
        let record = PanoramaGroupFileRecord(
            version: PanoramaGroupFileRecord.currentVersion,
            configuration: configuration
        )
        Task { [weak self, persistence] in
            let error = await persistence.save(record)
            self?.persistenceError = error
        }
    }
}
