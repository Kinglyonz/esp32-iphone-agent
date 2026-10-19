import Foundation
import Security

/// One shared trial context for every model call in a run. Server leases remain authoritative.
@MainActor final class TrialService: ObservableObject {
    static let shared = TrialService()
    nonisolated static let endpoint = "https://llm.handsy.tech"
    nonisolated static let model = "handsy-qwen"
    nonisolated static let consentVersion = "2026-10-19"
    nonisolated static let consentKey = "handsyTrialRemoteConsent"

    @Published private(set) var status = "busy"
    @Published private(set) var message: String?
    @Published private(set) var checking = false
    @Published private(set) var remainingSeconds = 0
    @Published var consented: Bool {
        didSet {
            defaults.set(consented ? Self.consentVersion : nil, forKey: Self.consentKey)
            if !consented { invalidate(TrialError(code: .consent)) }
        }
    }
    var onInvalidated: ((TrialError) -> Void)?
    private(set) var lease: TrialLease?
    private(set) var runID: String?
    let deviceID: String
    private let defaults: UserDefaults
    private let storage: TrialIdentityStorage
    private let attestor: TrialAttesting
    private let session: URLSession
    private let base: URL
    private let clock: () -> Double
    private var deadline = 0.0
    private var heartbeat: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var registration: Task<String, Error>?
    private var pendingRelease: Task<Void, Never>?
    private var claiming = false
    private var runEpoch = UUID()
    private var modelSessions: [WeakTrialSession] = []

    init(defaults: UserDefaults = .standard, storage: TrialIdentityStorage? = nil,
         attestor: TrialAttesting? = nil, session: URLSession? = nil,
         endpoint: String = TrialService.endpoint,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        let saved = storage ?? TrialKeychainStorage()
        self.storage = saved
        self.attestor = attestor ?? AppTrialAttestor()
        self.clock = clock
        self.base = URL(string: endpoint) ?? URL(string: Self.endpoint)!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = session ?? URLSession(configuration: config)
        consented = defaults.string(forKey: Self.consentKey) == Self.consentVersion
        if let existing = saved.get("device-id"), UUID(uuidString: existing) != nil { deviceID = existing }
        else {
            let id = UUID().uuidString.lowercased()
            saved.set(id, for: "device-id")
            deviceID = id
        }
    }

    var isActive: Bool { lease != nil && consented && clock() < deadline }

    func checkLocal(minimum: Double = 0) throws {
        guard consented else { throw TrialError(code: .consent) }
        guard lease != nil, clock() + minimum < deadline else { throw TrialError(code: .expired) }
        try Task.checkCancellation()
    }

    func refreshStatus() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            guard attestor.isSupported else { throw TrialError(code: .unsupported) }
            let token = try await registeredToken()
            struct Status: Decodable { let status: String }
            let result: Status = try await request("/trial/status", token: token)
            guard ["free", "busy"].contains(result.status) else { throw TrialError(code: .invalidResponse) }
            status = result.status
            message = status == "busy" ? TrialError(code: .busy).localizedDescription : nil
        } catch {
            status = "busy"
            message = (error as? TrialError ?? TrialError(code: .unavailable)).localizedDescription
        }
    }

    func acquire(runID: String = UUID().uuidString.lowercased()) async throws {
        guard consented else { throw TrialError(code: .consent) }
        guard lease == nil, !claiming else { throw TrialError(code: .busy) }
        guard UUID(uuidString: runID) != nil else { throw TrialError(code: .invalidResponse) }
        claiming = true
        let epoch = runEpoch
        defer { claiming = false }
        let token = try await registeredToken()
        guard consented, epoch == runEpoch else { throw TrialError(code: .consent) }
        let began = clock()
        let value: TrialLease = try await request("/trial/leases", method: "POST", token: token,
            body: ["run_id": runID, "consent_version": Self.consentVersion])
        guard consented, epoch == runEpoch else {
            await releaseRemote(value)
            throw TrialError(code: .revoked)
        }
        guard !value.leaseID.isEmpty, !value.leaseToken.isEmpty, value.generation >= 0,
              value.remainingSeconds.isFinite, value.remainingSeconds > 0 else {
            await releaseRemote(value)
            throw TrialError(code: .invalidResponse)
        }
        // Subtract the full round trip instead of adding transit time to a server reservation.
        deadline = began + min(60, value.remainingSeconds)
        guard deadline > clock() else {
            await releaseRemote(value)
            throw TrialError(code: .expired)
        }
        lease = value
        self.runID = runID
        status = "busy"
        message = nil
        updateRemaining()
        startWatchdogs()
    }

    func authorizeAction(_ action: JObject) async throws {
        try checkLocal()
        guard let value = lease else { throw TrialError(code: .expired) }
        let began = clock()
        let result: TrialLeaseUpdate = try await request("/trial/leases/\(value.leaseID)/action", method: "POST",
            token: try await registeredToken(), lease: value, body: ["generation": value.generation])
        try accept(result, for: value, began: began)
        let duration = Self.actionAllowance(action)
        try checkLocal(minimum: duration)
    }

    static func actionAllowance(_ action: JObject) -> Double {
        switch action["action"]?.str {
        case "type": return 2 + Double(action["text"]?.str?.utf8.count ?? 0) * 0.06
        case "path", "circle": return 7
        case "swipe": return 5
        default: return 3
        }
    }

    func modelHeaders(requestID: String) throws -> [String: String] {
        try checkLocal(minimum: 8)
        guard let value = lease, let runID, let token = storage.get("device-token"), !token.isEmpty else {
            throw TrialError(code: .unavailable)
        }
        return ["Authorization": "Bearer \(token)", "X-Device-ID": deviceID,
                "X-Lease-ID": value.leaseID, "X-Lease-Token": value.leaseToken,
                "X-Run-ID": runID, "X-Request-ID": requestID]
    }

    var modelTimeout: Double { max(0.1, min(20, deadline - clock() - 3)) }

    func registerModelSession(_ value: URLSession) {
        modelSessions.removeAll { $0.session == nil }
        modelSessions.append(WeakTrialSession(value))
    }

    func release() async {
        let value = lease
        clearLocal()
        if let value { await releaseRemote(value) }
        await pendingRelease?.value
        pendingRelease = nil
    }

    /// Invalidate local authority synchronously; network release must never delay a safety cleanup.
    func endLocally() {
        let value = lease
        clearLocal()
        if let value { pendingRelease = Task { await releaseRemote(value) } }
    }

    private func invalidate(_ error: TrialError) {
        let value = lease
        let hadSession = value != nil || claiming
        clearLocal()
        status = "busy"
        message = error.localizedDescription
        if let value { pendingRelease = Task { await releaseRemote(value) } }
        if hadSession { onInvalidated?(error) }
    }

    private func clearLocal() {
        runEpoch = UUID()
        heartbeat?.cancel(); heartbeat = nil
        timer?.cancel(); timer = nil
        lease = nil; runID = nil; deadline = 0; remainingSeconds = 0
        for item in modelSessions { item.session?.invalidateAndCancel() }
        modelSessions = []
    }

    private func releaseRemote(_ value: TrialLease) async {
        guard let token = storage.get("device-token") else { return }
        let _: EmptyTrialResponse? = try? await request("/trial/leases/\(value.leaseID)", method: "DELETE", token: token, lease: value)
    }

    private func startWatchdogs() {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(0.25)) } catch { return }
                guard let self else { return }
                updateRemaining()
                if clock() >= deadline { invalidate(TrialError(code: .expired)); return }
            }
        }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, let value = lease else { return }
                do {
                    let began = clock()
                    let update: TrialLeaseUpdate = try await request("/trial/leases/\(value.leaseID)/heartbeat", method: "POST",
                        token: try await registeredToken(), lease: value, body: ["generation": value.generation])
                    try accept(update, for: value, began: began)
                } catch {
                    if !Task.isCancelled { invalidate(error as? TrialError ?? TrialError(code: .unavailable)) }
                    return
                }
            }
        }
    }

    private func accept(_ update: TrialLeaseUpdate, for value: TrialLease, began: Double) throws {
        guard lease?.leaseID == value.leaseID, consented else { throw TrialError(code: .revoked) }
        guard update.generation == value.generation, update.remainingSeconds.isFinite, update.remainingSeconds > 0 else {
            invalidate(TrialError(code: .revoked)); throw TrialError(code: .revoked)
        }
        deadline = min(deadline, began + update.remainingSeconds)
        updateRemaining()
        try checkLocal()
    }

    private func updateRemaining() { remainingSeconds = max(0, Int(ceil(deadline - clock()))) }

    private func registeredToken() async throws -> String {
        guard attestor.isSupported, storage.get("device-id") == deviceID else { throw TrialError(code: .unsupported) }
        if let token = storage.get("device-token"), !token.isEmpty { return token }
        if let registration { return try await registration.value }
        let task = Task { try await register() }
        registration = task
        defer { registration = nil }
        return try await task.value
    }

    private func register() async throws -> String {
        let candidate: String
        if let saved = storage.get("pending-device-token"), Self.validToken(saved) {
            candidate = saved
            if await candidateAccepted(candidate) { return try confirmToken(candidate) }
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw TrialError(code: .unsupported)
            }
            candidate = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            storage.set(candidate, for: "pending-device-token")
            guard storage.get("pending-device-token") == candidate else { throw TrialError(code: .unsupported) }
        }
        let payload: [String: Any]
        if let cached = storage.get("pending-registration"), let data = cached.data(using: .utf8),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           saved["device_id"] as? String == deviceID, saved["device_token"] as? String == candidate,
           saved["key_id"] as? String == storage.get("attest-key") {
            // Reuse a successful proof; App Attest must not attest an already-attested key again.
            payload = saved
        } else {
            let keyID: String
            if let key = storage.get("attest-key"), !key.isEmpty { keyID = key }
            else {
                keyID = try await attestor.generateKey()
                storage.set(keyID, for: "attest-key")
            }
            struct Challenge: Decodable { let challenge_id: String; let challenge: String }
            let challenge: Challenge = try await request("/trial/challenge", method: "POST",
                body: ["device_id": deviceID, "key_id": keyID])
            guard let bytes = Data(base64Encoded: challenge.challenge), bytes.count == 32 else {
                throw TrialError(code: .invalidResponse)
            }
            let proof = try await attestor.attest(keyID: keyID, challenge: bytes)
            payload = ["device_id": deviceID, "key_id": keyID, "challenge_id": challenge.challenge_id,
                       "attestation": proof.base64EncodedString(), "device_token": candidate]
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            storage.set(encoded, for: "pending-registration")
            guard storage.get("pending-registration") == encoded else { throw TrialError(code: .unsupported) }
        }
        do {
            struct Registered: Decodable { let device_token: String }
            let result: Registered = try await request("/trial/register", method: "POST", body: payload)
            guard result.device_token == candidate else { throw TrialError(code: .invalidResponse) }
            return try confirmToken(candidate)
        } catch {
            // The server may have committed enrollment before its response was lost.
            if await candidateAccepted(candidate) { return try confirmToken(candidate) }
            throw error
        }
    }

    private func candidateAccepted(_ token: String) async -> Bool {
        struct Status: Decodable { let status: String }
        guard let result: Status = try? await request("/trial/status", token: token) else { return false }
        return ["free", "busy"].contains(result.status)
    }

    private func confirmToken(_ token: String) throws -> String {
        storage.set(token, for: "device-token")
        guard storage.get("device-token") == token else { throw TrialError(code: .unsupported) }
        storage.set("", for: "pending-registration")
        storage.set("", for: "pending-device-token")
        return token
    }

    private static func validToken(_ value: String) -> Bool {
        guard value.count == 43 else { return false }
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        return Data(base64Encoded: base64)?.count == 32
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", token: String? = nil,
                                      lease: TrialLease? = nil, body: [String: Any]? = nil) async throws -> T {
        var request = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let lease { request.setValue(lease.leaseToken, forHTTPHeaderField: "X-Lease-Token") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw TrialError(code: .invalidResponse) }
            guard (200..<300).contains(response.statusCode) else {
                throw TrialError(code: [409, 429, 503].contains(response.statusCode) ? .busy : .unavailable)
            }
            if data.isEmpty, let empty = EmptyTrialResponse() as? T { return empty }
            guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw TrialError(code: .invalidResponse) }
            return value
        } catch let error as TrialError { throw error }
        catch { throw TrialError(code: .unavailable) }
    }
}

private struct EmptyTrialResponse: Decodable {}
private final class WeakTrialSession {
    weak var session: URLSession?
    init(_ session: URLSession) { self.session = session }
}
