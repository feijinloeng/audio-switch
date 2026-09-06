import Foundation
import XCTest
@testable import YinPinQieHuan

@MainActor
final class SettingsPersistenceTests: XCTestCase {
    func testCorruptSettingsAreQuarantinedAndReported() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("perapp.json")
        try Data("not-json".utf8).write(to: url)

        let settings = SettingsManager(storageURL: url, saveDelay: 0)
        await waitUntilLoaded(settings)

        XCTAssertNotNil(settings.perAppPersistenceError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix("perapp.corrupt-") }
        )
    }

    func testFutureSettingsVersionRemainsReadOnly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("perapp.json")
        try JSONSerialization.data(withJSONObject: ["version": 999]).write(to: url)

        let settings = SettingsManager(storageURL: url, saveDelay: 0)
        await waitUntilLoaded(settings)

        XCTAssertTrue(settings.isPerAppStoreReadOnly)
        settings.setVolume(for: "test", to: 0.2)
        settings.flush()
        try? await Task.sleep(for: .milliseconds(50))
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(persisted?["version"] as? Int, 999)
    }

    func testMutationDuringBackgroundLoadOverlaysInsteadOfDiscardingExistingData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("perapp.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 4,
            "volumes": ["existing": 0.7],
        ]).write(to: url)

        let settings = SettingsManager(storageURL: url, saveDelay: 0)
        settings.setVolume(for: "new", to: 0.2)
        await waitUntilLoaded(settings)

        XCTAssertEqual(settings.getVolume(for: "existing") ?? -1, 0.7, accuracy: 0.001)
        XCTAssertEqual(settings.getVolume(for: "new") ?? -1, 0.2, accuracy: 0.001)
    }

    private func waitUntilLoaded(_ settings: SettingsManager) async {
        for _ in 0 ..< 100 where !settings.isPerAppStoreLoaded {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(settings.isPerAppStoreLoaded)
    }
}
