import AppKit
import AudioToolbox

struct AudioApp: Identifiable, Hashable {
    let id: pid_t
    let name: String
    let icon: NSImage
    let bundleID: String?
    let isHelperBacked: Bool
    /// CoreAudio 进程对象 ID 列表，用于 ProcessTap 创建
    var processObjectIDs: [AudioObjectID] = []

    var persistenceIdentifier: String {
        bundleID ?? "name:\(name)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id
    }
}
