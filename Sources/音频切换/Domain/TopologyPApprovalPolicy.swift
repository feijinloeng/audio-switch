import Foundation

enum TopologyPHardwareRole: String, CaseIterable, Codable, Hashable, Sendable {
    case builtIn
    case usb44k1
    case bluetoothOne
    case bluetoothTwo
}

enum TopologyPSigningMode: String, CaseIterable, Codable, Hashable, Sendable {
    case debug
    case developerID
    case appStore
}

struct TopologyPASRCEvidence: Codable, Equatable, Sendable {
    let library: String
    let version: String
    let sourceSHA256: String?
    let converterType: String?
    let configSHA256: String?
}

/// Structured facts supplied by Phase-0 hardware and archive validation. A
/// claimed gate string is intentionally not accepted as approval evidence.
struct TopologyPValidationCandidate: Codable, Equatable, Sendable {
    let aggregateLifecycleCycles: Int
    let driftDurationHours: Double
    let coveredDriftPPM: Set<Int>
    let hardwareRoles: Set<TopologyPHardwareRole>
    let asrc: TopologyPASRCEvidence
    let signingModes: Set<TopologyPSigningMode>
    let validatedTCC: Bool
    let validatedBrowserHelperReplacement: Bool
}

enum TopologyPApprovalPolicy {
    private static let requiredDriftPPM: Set<Int> = [-300, -100, -50, 50, 100, 300]

    static func rejectionReasons(for candidate: TopologyPValidationCandidate) -> [String] {
        var reasons: [String] = []
        if candidate.aggregateLifecycleCycles < 100 {
            reasons.append("The required 100-cycle tap-only Aggregate lifecycle test is incomplete.")
        }
        if candidate.driftDurationHours < 8 || !requiredDriftPPM.isSubset(of: candidate.coveredDriftPPM) {
            reasons.append("The required 8-hour ±50, ±100, and ±300 ppm drift validation is incomplete.")
        }
        if !Set(TopologyPHardwareRole.allCases).isSubset(of: candidate.hardwareRoles) {
            reasons.append("The required built-in, 44.1 kHz USB, one-Bluetooth, and two-Bluetooth hardware matrix is incomplete.")
        }
        if candidate.asrc.library != "libsamplerate"
            || candidate.asrc.version != "0.2.2"
            || candidate.asrc.sourceSHA256?.isEmpty != false
            || candidate.asrc.converterType?.isEmpty != false
            || candidate.asrc.configSHA256?.isEmpty != false {
            reasons.append("libsamplerate 0.2.2 source and ASRC configuration are not locked and validated.")
        }
        if !Set(TopologyPSigningMode.allCases).isSubset(of: candidate.signingModes) {
            reasons.append("Debug, Developer ID, and App Store signing validation is incomplete.")
        }
        if !candidate.validatedTCC {
            reasons.append("Audio capture TCC validation is incomplete.")
        }
        if !candidate.validatedBrowserHelperReplacement {
            reasons.append("Browser helper replacement validation is incomplete.")
        }
        return reasons
    }
}
