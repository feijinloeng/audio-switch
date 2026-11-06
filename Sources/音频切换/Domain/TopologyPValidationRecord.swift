import Foundation

/// Machine-readable Phase-0 evidence. This type deliberately validates the
/// relationship between a claimed gate status and the evidence that supports
/// it; callers cannot approve topology P by changing only a JSON string.
struct TopologyPValidationRecord: Codable, Equatable, Sendable {
    enum GateStatus: String, Codable, Sendable {
        case rejected
        case approved
    }

    struct ASRCLock: Codable, Equatable, Sendable {
        let library: String
        let version: String
        let sourceSHA256: String?
        let converterType: String?
        let controller: String?
        let bufferProfiles: [String: String]
        let configSHA256: String?
    }

    struct Toolchain: Codable, Equatable, Sendable {
        let developerDir: String
        let xcodeVersion: String
        let xcodeBuild: String
        let swiftCompilerVersion: String
        let swiftLanguageMode: String
        let packageToolsVersion: String
        let packageSHA256: String
    }

    let gateStatus: GateStatus
    let architecture: String
    let topology: String
    let topologyVersion: Int
    let asrc: ASRCLock
    let approvalCandidate: TopologyPValidationCandidate
    let toolchain: Toolchain
    let validatedEntitlements: [String: Bool]
    let testedOSVersions: [String]
    let testedHardwareMatrix: [String]
    let evidencePaths: [String]
    let rejectionReasons: [String]
    let approvedAt: String?

    func validate() throws {
        guard architecture == "coreAudioProcessTap",
              topology == "P_decoupledCapture_AUHAL",
              topologyVersion == 1 else {
            throw TopologyPValidationRecordError.invalidArchitecture
        }
        guard !evidencePaths.isEmpty else {
            throw TopologyPValidationRecordError.missingEvidencePaths
        }
        guard toolchain.isComplete else {
            throw TopologyPValidationRecordError.incompleteToolchain
        }

        let candidateRejections = TopologyPApprovalPolicy.rejectionReasons(for: approvalCandidate)
        switch gateStatus {
        case .rejected:
            guard approvedAt == nil else {
                throw TopologyPValidationRecordError.rejectedRecordHasApprovalTimestamp
            }
            guard !rejectionReasons.isEmpty, !candidateRejections.isEmpty else {
                throw TopologyPValidationRecordError.rejectedRecordLacksEvidenceBasedReason
            }
        case .approved:
            guard approvedAt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw TopologyPValidationRecordError.approvedRecordLacksTimestamp
            }
            guard rejectionReasons.isEmpty, candidateRejections.isEmpty else {
                throw TopologyPValidationRecordError.approvedRecordHasUnmetRequirements
            }
            guard !validatedEntitlements.isEmpty,
                  !testedOSVersions.isEmpty,
                  !testedHardwareMatrix.isEmpty else {
                throw TopologyPValidationRecordError.approvedRecordLacksAcceptanceEvidence
            }
            try validateApprovedASRCLock()
        }
    }

    private func validateApprovedASRCLock() throws {
        guard asrc.library == "libsamplerate",
              asrc.version == "0.2.2",
              asrc.sourceSHA256?.isEmpty == false,
              asrc.converterType?.isEmpty == false,
              asrc.controller?.isEmpty == false,
              !asrc.bufferProfiles.isEmpty,
              asrc.configSHA256?.isEmpty == false else {
            throw TopologyPValidationRecordError.approvedRecordLacksASRCLock
        }
        guard asrc.library == approvalCandidate.asrc.library,
              asrc.version == approvalCandidate.asrc.version,
              asrc.sourceSHA256 == approvalCandidate.asrc.sourceSHA256,
              asrc.converterType == approvalCandidate.asrc.converterType,
              asrc.configSHA256 == approvalCandidate.asrc.configSHA256 else {
            throw TopologyPValidationRecordError.approvedRecordHasInconsistentASRCLock
        }
    }
}

private extension TopologyPValidationRecord.Toolchain {
    var isComplete: Bool {
        [
            developerDir,
            xcodeVersion,
            xcodeBuild,
            swiftCompilerVersion,
            swiftLanguageMode,
            packageToolsVersion,
            packageSHA256,
        ].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

enum TopologyPValidationRecordError: Error, Equatable {
    case invalidArchitecture
    case missingEvidencePaths
    case incompleteToolchain
    case rejectedRecordHasApprovalTimestamp
    case rejectedRecordLacksEvidenceBasedReason
    case approvedRecordLacksTimestamp
    case approvedRecordHasUnmetRequirements
    case approvedRecordLacksAcceptanceEvidence
    case approvedRecordLacksASRCLock
    case approvedRecordHasInconsistentASRCLock
}
