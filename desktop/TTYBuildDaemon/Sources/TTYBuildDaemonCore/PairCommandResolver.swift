import Foundation
import TTYBuildKit

/// Reads a pairing code from the running daemon. A daemon business rejection
/// is authoritative; only an explicit connect failure reaches the caller's
/// unavailable-daemon fallback.
public enum PairCommandResolver {
    public enum ResolutionError: Error, CustomStringConvertible, Equatable {
        case daemonRejected(String)
        case malformedDaemonResponse

        public var description: String {
            switch self {
            case .daemonRejected(let detail): "daemon rejected pairing: \(detail)"
            case .malformedDaemonResponse: "daemon returned a malformed pairing response"
            }
        }
    }

    public static func resolve(
        socketPath: String,
        reset: Bool,
        offline: () throws -> String
    ) throws -> String {
        try resolve(
            reset: reset,
            roundTrip: {
                try ControlClient.roundTrip(socketPath: socketPath, request: $0)
            },
            offline: offline
        )
    }

    static func resolve(
        reset: Bool,
        roundTrip: ([String: Any]) throws -> [String: Any],
        offline: () throws -> String
    ) throws -> String {
        let reply: [String: Any]
        do {
            reply = try roundTrip(["cmd": "pair", "reset": reset])
        } catch let error as ControlClient.ClientError {
            if case .daemonNotRunning = error {
                return try offline()
            }
            throw error
        }

        guard reply["ok"] as? Bool == true else {
            throw ResolutionError.daemonRejected(
                reply["err"] as? String ?? "daemon reported an error"
            )
        }
        guard let code = reply["code"] as? String,
              (try? PairingCode(code)) != nil
        else {
            throw ResolutionError.malformedDaemonResponse
        }
        return code
    }
}
