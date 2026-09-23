import Foundation

private struct PanoramaGroupFileRecord: Codable, Sendable {
    static let currentVersion = 1
    let version: Int
    let configuration: PanoramaGroupConfiguration
}

private struct PanoramaGroupFileHeader: Decodable {
    let version: Int
}

private struct PanoramaGroupLoadResult: Sendable {
    let record: PanoramaGroupFileRecord?
    let isReadOnly: Bool
    let error: String?
}

private actor PanoramaGroupPersistence {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func load() -> PanoramaGroupLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PanoramaGroupLoadResult(record: nil, isReadOnly: false, error: nil)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return PanoramaGroupLoadResult(
                record: nil,
                isReadOnly: true,
                error: "无法读取全景组配置；为保护原文件，当前已禁止保存。\(error.localizedDescription)"
            )
        }

        guard let header = try? JSONDecoder().decode(PanoramaGroupFileHeader.self, from: data),
              header.version >= 0 else {
            return quarantineCorruptFile()
        }

        if header.version > PanoramaGroupFileRecord.currentVersion {
            let compatibleRecord = try? JSONDecoder().decode(PanoramaGroupFileRecord.self, from: data)
            return PanoramaGroupLoadResult(
                record: compatibleRecord,
                isReadOnly: true,
                error: "此全景组配置由较新版本创建（格式版本 \(header.version)）。当前版本已只读打开，不会覆盖原文件。"
            )
        }

        guard let record = try? JSONDecoder().decode(PanoramaGroupFileRecord.self, from: data) else {
            return quarantineCorruptFile()
        }
        return PanoramaGroupLoadResult(record: record, isReadOnly: false, error: nil)
    }

    private func quarantineCorruptFile() -> PanoramaGroupLoadResult {
        let quarantineURL = url
            .deletingPathExtension()
            .appendingPathExtension("corrupt-\(UUID().uuidString).json")
        do {
            try FileManager.default.moveItem(at: url, to: quarantineURL)
            return PanoramaGroupLoadResult(
                record: nil,
                isReadOnly: false,
                error: "全景组文件已损坏，已隔离为 \(quarantineURL.lastPathComponent)"
            )
        } catch {
            return PanoramaGroupLoadResult(
                record: nil,
                isReadOnly: true,
                error: "全景组文件无法读取且未能隔离；为保护原文件，当前已禁止保存。\(error.localizedDescription)"
            )
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
            let result = await persistence.load()
            guard let self else { return }
            let hadLocalMutationBeforeLoad = self.hasLocalMutationBeforeLoad
            self.isReadOnly = result.isReadOnly
            if let record = result.record,
               !hadLocalMutationBeforeLoad || result.isReadOnly {
                self.configuration = record.configuration
            }
            self.persistenceError = result.error
            self.isLoaded = true
            self.hasLocalMutationBeforeLoad = false
            self.onLoaded?()
            if hadLocalMutationBeforeLoad, !self.isReadOnly {
                self.persist(self.configuration)
            }
        }
    }

    static var defaultStorageURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("音频切换")
        return directory.appendingPathComponent("panorama-group.json")
    }

    func save(_ configuration: PanoramaGroupConfiguration) {
        guard !isReadOnly else { return }
        self.configuration = configuration
        guard isLoaded else {
            hasLocalMutationBeforeLoad = true
            return
        }
        persist(configuration)
    }

    private func persist(_ configuration: PanoramaGroupConfiguration) {
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
