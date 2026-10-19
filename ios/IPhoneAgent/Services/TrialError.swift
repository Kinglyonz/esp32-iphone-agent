import Foundation

/// Trial failures are terminal for the current run; never feed them into the agent's retry loop.
struct TrialError: LocalizedError {
    enum Code: String { case busy, consent, unsupported, expired, revoked, unavailable, invalidResponse, auxiliary }
    let code: Code
    var errorDescription: String? {
        switch code {
        case .busy: return String(localized: "The free trial is busy. Try your own model provider.")
        case .consent: return String(localized: "Agree to remote trial recording before starting, or use your own provider.")
        case .unsupported: return String(localized: "The free trial is busy on this device. App integrity verification is required.")
        case .expired: return String(localized: "The 60-second free trial task has ended. Your replay is saved on this iPhone.")
        case .revoked: return String(localized: "The free trial session ended. No more phone actions will be sent.")
        case .unavailable: return String(localized: "The free trial connection is unavailable. The task has stopped safely.")
        case .invalidResponse: return String(localized: "The free trial returned an invalid session response.")
        case .auxiliary: return String(localized: "Use your own model provider for recording analysis, optimization and diagnostics.")
        }
    }
}
