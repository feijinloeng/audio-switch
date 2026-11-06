import Foundation

/// A stable identity for an endpoint explicitly selected by the user. The
/// identifier deliberately distinguishes a Core Audio output from a trusted
/// companion peer, so a planner can never silently substitute one for the
/// other.
enum PanoramaEndpointID: Codable, Equatable, Hashable, Sendable {
    case macDevice(uid: String)
    case iPhone(peerID: String)
}

enum PanoramaEndpointHost: Codable, Equatable, Sendable {
    case thisMac
    case iPhone(peerID: String)
}

enum PanoramaEndpointTransport: String, Codable, Equatable, Sendable {
    case builtIn
    case bluetooth
    case wired
    case network
}

enum PanoramaEndpointAvailability: Codable, Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

struct PanoramaEndpointCandidate: Codable, Equatable, Sendable, Identifiable {
    let id: PanoramaEndpointID
    let name: String
    let host: PanoramaEndpointHost
    let transport: PanoramaEndpointTransport
    let availability: PanoramaEndpointAvailability

}

struct PanoramaGroupMember: Codable, Equatable, Sendable {
    static let maximumManualDelayMilliseconds = 1_000

    let endpointID: PanoramaEndpointID
    let manualDelayMilliseconds: Int

    private enum CodingKeys: String, CodingKey {
        case endpointID
        case manualDelayMilliseconds
    }

    init(
        endpointID: PanoramaEndpointID,
        manualDelayMilliseconds: Int = 0
    ) {
        self.endpointID = endpointID
        self.manualDelayMilliseconds = min(
            max(manualDelayMilliseconds, 0),
            Self.maximumManualDelayMilliseconds
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            endpointID: try container.decode(PanoramaEndpointID.self, forKey: .endpointID),
            manualDelayMilliseconds: try container.decodeIfPresent(Int.self, forKey: .manualDelayMilliseconds) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpointID, forKey: .endpointID)
        try container.encode(manualDelayMilliseconds, forKey: .manualDelayMilliseconds)
    }
}

struct PanoramaGroupConfiguration: Codable, Equatable, Sendable {
    let members: [PanoramaGroupMember]

    init(members: [PanoramaGroupMember]) {
        self.members = members
    }

    func member(for endpointID: PanoramaEndpointID) -> PanoramaGroupMember? {
        members.first { $0.endpointID == endpointID }
    }

}

struct PanoramaTopologyPlan: Equatable, Sendable {
    let localEndpoints: [PanoramaEndpointCandidate]
    let remoteEndpoints: [PanoramaEndpointCandidate]
    let targetBufferFrames: Int

    static let sampleRate = 48_000
}

enum PanoramaTopologyValidationError: Error, Equatable, Sendable {
    case memberCountOutOfRange(actual: Int)
    case duplicateEndpoint(id: PanoramaEndpointID)
    case selectedEndpointMissing(id: PanoramaEndpointID)
    case endpointUnavailable(id: PanoramaEndpointID, reason: String)
    case executableEndpointCountOutOfRange(actual: Int)
    case tooManyMacEndpoints(actual: Int)
    case tooManyMacBluetoothEndpoints(actual: Int)
    case tooManyIPhoneEndpoints(actual: Int)
}

enum PanoramaTopologyLimits {
    /// 2026-08-14 极限测试验证：3 蓝牙 + 本机扬声器 + iPhone 网络路可稳定同时播放。
    static let maximumMemberCount = 5
    /// 2026-08-14 极限测试验证：3 蓝牙 + 本机扬声器可稳定同时播放。
    static let maximumMacEndpointCount = 4
    /// 2026-08-14 极限测试验证：一块 Mac 蓝牙射频可稳定带 3 台 A2DP 音箱。
    /// 注意：再加第 4 个蓝牙设备（如鼠标）会挤爆射频导致音频全断，属射频物理上限。
    static let maximumMacBluetoothEndpointCount = 3
    static let maximumIPhoneEndpointCount = 1
}

/// Mirrors topology admission in the settings UI without mutating the user's
/// selection. A disabled checkbox always explains the exact constraint that
/// the planner would otherwise reject later.
enum PanoramaSelectionConstraint {
    static func disabledReason(
        for candidate: PanoramaEndpointCandidate,
        selected: [PanoramaEndpointCandidate]
    ) -> String? {
        guard !selected.contains(where: { $0.id == candidate.id }) else { return nil }
        if selected.count >= PanoramaTopologyLimits.maximumMemberCount {
            return "最多选择 \(PanoramaTopologyLimits.maximumMemberCount) 路"
        }
        if candidate.host == .thisMac,
           selected.filter({ $0.host == .thisMac }).count
               >= PanoramaTopologyLimits.maximumMacEndpointCount {
            return "这台 Mac 最多同时使用 \(PanoramaTopologyLimits.maximumMacEndpointCount) 个输出"
        }
        if candidate.host == .thisMac,
           candidate.transport == .bluetooth,
           selected.filter({ $0.host == .thisMac && $0.transport == .bluetooth }).count
               >= PanoramaTopologyLimits.maximumMacBluetoothEndpointCount {
            return "这台 Mac 最多同时使用 \(PanoramaTopologyLimits.maximumMacBluetoothEndpointCount) 个蓝牙输出"
        }
        if case .iPhone = candidate.host,
           selected.contains(where: {
               if case .iPhone = $0.host { return true }
               return false
           }) {
            return "每次只能选择一个 iPhone 输出"
        }
        return nil
    }
}

enum PanoramaTopologyPlanner {
    /// Turns only the explicit user selection into a topology. It never adds,
    /// removes, replaces, or reorders endpoints as a convenience fallback.
    static func makePlan(
        configuration: PanoramaGroupConfiguration,
        candidates: [PanoramaEndpointCandidate],
        minimumExecutableEndpointCount: Int = 2
    ) -> Result<PanoramaTopologyPlan, PanoramaTopologyValidationError> {
        guard (2 ... PanoramaTopologyLimits.maximumMemberCount)
            .contains(configuration.members.count) else {
            return .failure(.memberCountOutOfRange(actual: configuration.members.count))
        }

        var selectedIDs = Set<PanoramaEndpointID>()
        for member in configuration.members {
            guard selectedIDs.insert(member.endpointID).inserted else {
                return .failure(.duplicateEndpoint(id: member.endpointID))
            }
        }

        // 候选端点 ID 可能来自系统发现或配置，防御重复 ID 避免字典断言崩溃。
        let candidatesByID = Dictionary(
            candidates.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var executable: [PanoramaEndpointCandidate] = []
        for member in configuration.members {
            guard let candidate = candidatesByID[member.endpointID] else {
                return .failure(.selectedEndpointMissing(id: member.endpointID))
            }
            if case let .unavailable(reason) = candidate.availability {
                return .failure(.endpointUnavailable(id: candidate.id, reason: reason))
            }
            executable.append(candidate)
        }

        let localCount = executable.filter { $0.host == .thisMac }.count
        guard localCount <= PanoramaTopologyLimits.maximumMacEndpointCount else {
            return .failure(.tooManyMacEndpoints(actual: localCount))
        }

        let macBluetoothCount = executable.filter {
            $0.host == .thisMac && $0.transport == .bluetooth
        }.count
        guard macBluetoothCount <= PanoramaTopologyLimits.maximumMacBluetoothEndpointCount else {
            return .failure(.tooManyMacBluetoothEndpoints(actual: macBluetoothCount))
        }

        let iPhoneCount = executable.filter {
            if case .iPhone = $0.host { return true }
            return false
        }.count
        guard iPhoneCount <= PanoramaTopologyLimits.maximumIPhoneEndpointCount else {
            return .failure(.tooManyIPhoneEndpoints(actual: iPhoneCount))
        }

        let minimumExecutableCount = min(
            max(minimumExecutableEndpointCount, 1),
            PanoramaTopologyLimits.maximumMemberCount
        )
        guard executable.count >= minimumExecutableCount else {
            return .failure(.executableEndpointCountOutOfRange(actual: executable.count))
        }

        return .success(
            PanoramaTopologyPlan(
                localEndpoints: executable.filter { $0.host == .thisMac },
                remoteEndpoints: executable.filter {
                    if case .iPhone = $0.host { return true }
                    return false
                },
                targetBufferFrames: PanoramaTopologyPlan.sampleRate
            )
        )
    }
}

/// Decides fault handling from the user's immutable membership rather than
/// substituting a newly discovered device. A recovered endpoint is never
/// auto-added or auto-activated; only the all-failed case requests a return
/// to the route that preceded panorama playback.
enum PanoramaFaultRecoveryAction: Equatable, Sendable {
    case remainActive(healthyEndpointCount: Int)
    case fallBackToSingleDevice(uid: String)
    case fallBackToSystemDefault
}

enum PanoramaGroupState: Equatable, Sendable {
    case unconfigured
    case ready
    case degraded(healthyEndpointCount: Int)
    case unavailable

    var displayName: String {
        switch self {
        case .unconfigured: return "未配置"
        case .ready: return "就绪"
        case let .degraded(healthyEndpointCount): return "降级（剩余 \(healthyEndpointCount) 路）"
        case .unavailable: return "不可用"
        }
    }
}

enum PanoramaFaultRecoveryPlanner {
    static func action(
        configuration: PanoramaGroupConfiguration,
        candidates: [PanoramaEndpointCandidate],
        lastSuccessfulSingleDeviceUID: String?
    ) -> PanoramaFaultRecoveryAction {
        // 候选端点 ID 可能来自系统发现或配置，防御重复 ID 避免字典断言崩溃。
        let byID = Dictionary(
            candidates.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let healthyCount = configuration.members.reduce(into: 0) { count, member in
            guard let candidate = byID[member.endpointID],
                  case .available = candidate.availability else { return }
            count += 1
        }
        guard healthyCount == 0 else { return .remainActive(healthyEndpointCount: healthyCount) }
        if let uid = lastSuccessfulSingleDeviceUID?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty {
            return .fallBackToSingleDevice(uid: uid)
        }
        return .fallBackToSystemDefault
    }
}
