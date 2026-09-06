#if SWIFT_PACKAGE
import Foundation

/// Strict, serializable input for a real-machine topology-P evidence run.
/// It deliberately does not infer a device role from its name or transport:
/// the operator declares the matrix scenario and the raw device descriptors
/// are preserved in the resulting record.
struct TopologyPHardwareHarnessConfiguration: Equatable, Sendable {
    enum Scenario: String, Equatable, Sendable {
        case builtIn = "built-in"
        case usb44k1 = "usb-44k1"
        case bluetoothOne = "bluetooth-one"
        case bluetoothTwo = "bluetooth-two"
    }

    struct Route: Equatable, Sendable {
        let pid: pid_t
        let deviceUID: String
    }

    enum Failure: Error, Equatable {
        case invalidScenario
        case missingRoutes
        case malformedRoute
        case invalidDuration
        case insufficientRoutes
        case duplicateOutputUID
    }

    let scenario: Scenario
    let routes: [Route]
    let durationSeconds: UInt64

    static func parse(
        scenario rawScenario: String,
        routes rawRoutes: String,
        durationSeconds rawDuration: String
    ) throws -> Self {
        guard let scenario = Scenario(rawValue: rawScenario) else {
            throw Failure.invalidScenario
        }
        guard let durationSeconds = UInt64(rawDuration), durationSeconds > 0 else {
            throw Failure.invalidDuration
        }

        let routes = try rawRoutes
            .split(whereSeparator: \.isNewline)
            .map { rawRoute -> Route in
                let components = rawRoute.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard components.count == 2,
                      let pid = pid_t(components[0]), pid > 0,
                      !components[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Failure.malformedRoute
                }
                return Route(
                    pid: pid,
                    deviceUID: components[1].trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        guard !routes.isEmpty else { throw Failure.missingRoutes }
        if scenario == .bluetoothTwo {
            guard routes.count >= 2 else { throw Failure.insufficientRoutes }
            guard Set(routes.map(\.deviceUID)).count >= 2 else { throw Failure.duplicateOutputUID }
        }
        return Self(scenario: scenario, routes: routes, durationSeconds: durationSeconds)
    }
}
#endif
