import CryptoKit
import DeviceCheck
import Foundation

@MainActor protocol TrialIdentityStorage: AnyObject {
    func get(_ key: String) -> String?
    func set(_ value: String, for key: String)
}

@MainActor final class TrialKeychainStorage: TrialIdentityStorage {
    func get(_ key: String) -> String? { Keychain.get("handsy-trial-" + key) }
    func set(_ value: String, for key: String) { Keychain.set(value, for: "handsy-trial-" + key, deviceOnly: true) }
}

@MainActor protocol TrialAttesting: AnyObject {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attest(keyID: String, challenge: Data) async throws -> Data
}

@MainActor final class AppTrialAttestor: TrialAttesting {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.generateKey { key, error in
                if let key { continuation.resume(returning: key) }
                else { continuation.resume(throwing: error ?? TrialError(code: .unsupported)) }
            }
        }
    }

    func attest(keyID: String, challenge: Data) async throws -> Data {
        let hash = Data(SHA256.hash(data: challenge))
        return try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.attestKey(keyID, clientDataHash: hash) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? TrialError(code: .unsupported)) }
            }
        }
    }
}
