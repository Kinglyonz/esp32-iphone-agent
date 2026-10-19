import XCTest
import UIKit
@testable import IPhoneAgent

private final class TrialStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (URLRequest, [String: Any]) -> (Int, [String: Any]) = { _, _ in (503, [:]) }
    nonisolated(unsafe) static var paths: [String] = []
    nonisolated(unsafe) static var contentType = "application/json"
    nonisolated(unsafe) static var rawResponse: Data?
    nonisolated(unsafe) static var nextFailure: Error?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Self.paths.append(request.url?.path ?? "")
        let (code, value) = Self.handler(request, body)
        if let error = Self.nextFailure {
            Self.nextFailure = nil
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                       headerFields: ["Content-Type": Self.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.rawResponse ?? (try? JSONSerialization.data(withJSONObject: value)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class MemoryTrialIdentity: TrialIdentityStorage {
    var values: [String: String] = [:]
    func get(_ key: String) -> String? { values[key] }
    func set(_ value: String, for key: String) { values[key] = value }
}

@MainActor private final class TestTrialAttestor: TrialAttesting {
    var isSupported = true
    var receivedChallenge: Data?
    var attestCalls = 0
    func generateKey() async throws -> String { "test-attestation-key" }
    func attest(keyID: String, challenge: Data) async throws -> Data {
        receivedChallenge = challenge
        attestCalls += 1
        return Data("test-attestation".utf8)
    }
}

@MainActor final class TrialTests: XCTestCase {
    private var time = 100.0
    private var defaults: UserDefaults!
    private var storage: MemoryTrialIdentity!
    private var attestor: TestTrialAttestor!
    private var session: URLSession!
    private var trial: TrialService!
    private var suite = ""

    override func setUp() async throws {
        suite = "trial-test-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        storage = MemoryTrialIdentity()
        attestor = TestTrialAttestor()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TrialStubProtocol.self]
        session = URLSession(configuration: config)
        trial = TrialService(defaults: defaults, storage: storage, attestor: attestor, session: session,
                             endpoint: "https://trial.test", clock: { [weak self] in self?.time ?? 100 })
        TrialStubProtocol.paths = []
        TrialStubProtocol.contentType = "application/json"
        TrialStubProtocol.rawResponse = nil
        TrialStubProtocol.nextFailure = nil
        TrialStubProtocol.handler = Self.respond
    }

    override func tearDown() async throws {
        await trial.release()
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suite)
        trial = nil
    }

    nonisolated private static func respond(_ request: URLRequest, _ body: [String: Any]) -> (Int, [String: Any]) {
        switch request.url?.path {
        case "/trial/challenge":
            return (200, ["challenge_id": "challenge-1", "challenge": Data(repeating: 4, count: 32).base64EncodedString()])
        case "/trial/register": return (200, ["device_token": body["device_token"] as? String ?? "test-device-token"])
        case "/trial/status": return (200, ["status": "free"])
        case "/trial/leases":
            return (200, ["lease_id": "lease-1", "lease_token": "test-lease-token", "generation": 2, "remaining_seconds": 60])
        case "/trial/leases/lease-1/action", "/trial/leases/lease-1/heartbeat":
            return (200, ["remaining_seconds": 60, "generation": 2])
        case "/trial/leases/lease-1": return (200, [:])
        default: return (503, ["status": "busy"])
        }
    }

    func testConsentBlocksClaimAndAnyModelHeadersBeforeNetwork() async {
        do { try await trial.acquire(); XCTFail("Expected consent failure") }
        catch { XCTAssertEqual((error as? TrialError)?.code, .consent) }
        XCTAssertThrowsError(try trial.modelHeaders(requestID: UUID().uuidString))
        XCTAssertTrue(TrialStubProtocol.paths.isEmpty)
    }

    func testAttestedRegistrationIdentityAndLeaseHeaders() async throws {
        trial.consented = true
        try await trial.acquire()
        XCTAssertEqual(attestor.receivedChallenge, Data(repeating: 4, count: 32))
        let headers = try trial.modelHeaders(requestID: "request-1")
        XCTAssertEqual(headers["Authorization"], "Bearer " + (storage.get("device-token") ?? ""))
        XCTAssertEqual(headers["X-Device-ID"], storage.get("device-id"))
        XCTAssertEqual(headers["X-Lease-Token"], "test-lease-token")
        XCTAssertNotNil(UUID(uuidString: headers["X-Run-ID"] ?? ""))
        XCTAssertEqual(trial.remainingSeconds, 60)
    }

    func testLostRegistrationResponseRecoversWithPersistedCandidateWithoutReattesting() async throws {
        trial.consented = true
        var enrolled: String?
        var registrations = 0
        TrialStubProtocol.handler = { request, body in
            if request.url?.path == "/trial/register" {
                registrations += 1
                let candidate = body["device_token"] as? String
                XCTAssertEqual(candidate?.count, 43)
                XCTAssertFalse(candidate?.contains("=") ?? true)
                XCTAssertEqual(self.storage.get("pending-device-token"), candidate)
                enrolled = candidate
                TrialStubProtocol.nextFailure = URLError(.networkConnectionLost)
                return (200, ["device_token": candidate ?? ""])
            }
            if request.url?.path == "/trial/status" {
                guard let enrolled, request.value(forHTTPHeaderField: "Authorization") == "Bearer " + enrolled else {
                    return (401, [:])
                }
                return (200, ["status": "busy"])
            }
            return Self.respond(request, body)
        }
        await trial.refreshStatus()
        XCTAssertEqual(trial.status, "busy")
        XCTAssertNotNil(enrolled)
        XCTAssertEqual(storage.get("device-token"), enrolled)
        XCTAssertEqual(attestor.attestCalls, 1)
        XCTAssertEqual(registrations, 1)
        await trial.refreshStatus()
        XCTAssertEqual(attestor.attestCalls, 1)
        XCTAssertEqual(registrations, 1)
    }

    func testPendingRegistrationReusesProofAfterRelaunchInsteadOfAttestingAgain() async throws {
        trial.consented = true
        var canCommit = false
        var registered = false
        var proofs: [String] = []
        TrialStubProtocol.handler = { request, body in
            if request.url?.path == "/trial/register" {
                proofs.append(body["attestation"] as? String ?? "")
                if !canCommit { return (503, ["status": "busy"]) }
                registered = true
                return (200, ["device_token": body["device_token"] as? String ?? ""])
            }
            if request.url?.path == "/trial/status" {
                return registered ? (200, ["status": "free"]) : (401, [:])
            }
            return Self.respond(request, body)
        }
        await trial.refreshStatus()
        XCTAssertNil(storage.get("device-token"))
        XCTAssertNotNil(storage.get("pending-registration"))
        canCommit = true
        let resumed = TrialService(defaults: defaults, storage: storage, attestor: attestor, session: session,
                                   endpoint: "https://trial.test")
        await resumed.refreshStatus()
        XCTAssertEqual(resumed.status, "free")
        XCTAssertEqual(attestor.attestCalls, 1)
        XCTAssertEqual(proofs.count, 2)
        XCTAssertEqual(proofs.first, proofs.last)
    }

    func testUnsupportedAttestationIsBusyWithoutRegistrationFallback() async {
        attestor.isSupported = false
        trial.consented = true
        await trial.refreshStatus()
        XCTAssertEqual(trial.status, "busy")
        do { try await trial.acquire(); XCTFail("Expected unsupported failure") }
        catch { XCTAssertEqual((error as? TrialError)?.code, .unsupported) }
        XCTAssertTrue(TrialStubProtocol.paths.isEmpty)
    }

    func testActionChecksGenerationAndDoesNotExtendOriginalDeadline() async throws {
        trial.consented = true
        try await trial.acquire()
        time += 30
        try await trial.authorizeAction(["action": .str("tap")])
        XCTAssertEqual(trial.remainingSeconds, 30)
        time += 31
        XCTAssertThrowsError(try trial.checkLocal())
        let before = TrialStubProtocol.paths.count
        do { try await trial.authorizeAction(["action": .str("tap")]); XCTFail("Expected expiry") }
        catch { XCTAssertEqual((error as? TrialError)?.code, .expired) }
        XCTAssertEqual(TrialStubProtocol.paths.count, before)
    }

    func testGenerationChangeRevokesBeforeAnyGesture() async throws {
        trial.consented = true
        try await trial.acquire()
        var invalidated = false
        trial.onInvalidated = { _ in invalidated = true }
        TrialStubProtocol.handler = { request, body in
            if request.url?.path.hasSuffix("/action") == true {
                XCTAssertEqual(body["generation"] as? Int, 2)
                return (200, ["remaining_seconds": 50, "generation": 3])
            }
            return Self.respond(request, body)
        }
        do { try await trial.authorizeAction(["action": .str("tap")]); XCTFail("Expected revoked lease") }
        catch { XCTAssertEqual((error as? TrialError)?.code, .revoked) }
        XCTAssertFalse(trial.isActive)
        XCTAssertTrue(invalidated)
    }

    func testWithdrawConsentSynchronouslyRevokesModelAndActionAuthority() async throws {
        trial.consented = true
        try await trial.acquire()
        trial.consented = false
        XCTAssertFalse(trial.isActive)
        XCTAssertNil(trial.lease)
        XCTAssertThrowsError(try trial.modelHeaders(requestID: UUID().uuidString))
        XCTAssertNil(defaults.string(forKey: TrialService.consentKey))
    }

    func testBusyClaimDoesNotCreateLocalLease() async {
        trial.consented = true
        TrialStubProtocol.handler = { request, body in
            if request.url?.path == "/trial/leases" { return (503, ["status": "busy"]) }
            return Self.respond(request, body)
        }
        do { try await trial.acquire(); XCTFail("Expected busy") }
        catch { XCTAssertEqual((error as? TrialError)?.code, .busy) }
        XCTAssertNil(trial.lease)
    }

    func testLocalDeadlineInvalidatesAndSignalsStopWithoutARequest() async throws {
        trial.consented = true
        try await trial.acquire()
        var stopped = false
        trial.onInvalidated = { error in stopped = error.code == .expired }
        time += 61
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(trial.isActive)
        XCTAssertNil(trial.lease)
        XCTAssertTrue(stopped)
    }

    func testTrialProviderFixesModelAndRejectsCallsWithoutLease() async throws {
        let settings = Settings(defaults: defaults, info: [:], trial: trial)
        settings.selectProvider(.handsyTrial)
        settings.model = "a-different-model"
        settings.actorModel = "another-model"
        XCTAssertEqual(settings.currentModel, "handsy-qwen")
        XCTAssertEqual(settings.baseURL, "https://llm.handsy.tech/v1")
        XCTAssertTrue(settings.apiKey.isEmpty)
        do { _ = try await settings.client("actor"); XCTFail("Expected consent failure") }
        catch { XCTAssertEqual((error as? TrialError)?.code, .consent) }
    }

    func testTrialEmptyResponseIsNotRepeatedAndHeadersAreBoundToLease() async throws {
        trial.consented = true
        try await trial.acquire()
        var calls = 0
        TrialStubProtocol.handler = { request, body in
            if request.url?.path == "/v1/chat/completions" {
                calls += 1
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Lease-ID"), "lease-1")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-ID"), self.storage.get("device-id"))
                XCTAssertNotNil(UUID(uuidString: request.value(forHTTPHeaderField: "X-Request-ID") ?? ""))
                return (200, ["choices": [["message": ["content": ""], "finish_reason": "stop"]]])
            }
            return Self.respond(request, body)
        }
        let modelConfig = URLSessionConfiguration.ephemeral
        modelConfig.protocolClasses = [TrialStubProtocol.self]
        let modelSession = URLSession(configuration: modelConfig)
        let client = LLMClient(baseURL: "https://trial.test/v1", model: TrialService.model, session: modelSession, trial: trial)
        do { _ = try await client.chat(system: "test", text: "test"); XCTFail("Expected empty reply failure") }
        catch { XCTAssertEqual((error as? TrialError)?.code, .invalidResponse) }
        XCTAssertEqual(calls, 1)
    }

    func testTrialPartialActionStreamWithoutDoneIsRejectedWithoutRetry() async throws {
        trial.consented = true
        try await trial.acquire()
        TrialStubProtocol.contentType = "text/event-stream"
        let event: [String: Any] = ["choices": [["delta": ["content": "THINK: Go home\nDO: home"]]]]
        let encoded = try JSONSerialization.data(withJSONObject: event)
        TrialStubProtocol.rawResponse = Data(("data: " + String(decoding: encoded, as: UTF8.self) + "\n\n").utf8)
        var calls = 0
        TrialStubProtocol.handler = { request, body in
            if request.url?.path == "/v1/chat/completions" { calls += 1; return (200, [:]) }
            return Self.respond(request, body)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TrialStubProtocol.self]
        let client = LLMClient(baseURL: "https://trial.test/v1", model: TrialService.model,
                               session: URLSession(configuration: config), trial: trial)
        do { _ = try await client.chat(system: "test", text: "test"); XCTFail("Expected incomplete stream failure") }
        catch { XCTAssertEqual((error as? TrialError)?.code, .invalidResponse) }
        XCTAssertEqual(calls, 1)
    }

    func testTrialErrorsNeverTriggerReplanOrTimeoutRetry() async {
        let model = TerminalTrialModel()
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil)
        await agent.run()
        XCTAssertEqual(model.calls, 2)
        XCTAssertEqual(agent.steps.last?["action"], .str("error"))
    }

    func testEveryIndependentActionIsAuthorizedBeforeSending() async throws {
        let model = FakeModel { _ in "THINK: Go home\nDO: home\nDO: type hello" }
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: FakeScreen(), actor: model, planner: model, trace: nil)
        var checks = 0
        agent.authorizeAction = { _ in
            checks += 1
            if checks == 2 { throw TrialError(code: .expired) }
        }
        do { _ = try await agent.step(); XCTFail("Expected action denial") }
        catch { XCTAssertEqual((error as? TrialError)?.code, .expired) }
        XCTAssertEqual(phone.calls, ["home"])
        XCTAssertEqual(checks, 2)
    }

    func testTrialScreenshotIsBoundedBeforeSending() throws {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 4000)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2000, height: 4000))
        }.jpegData(compressionQuality: 1)!
        let result = try TrialImage.prepare(data)
        let image = try XCTUnwrap(UIImage(data: result))
        XCTAssertLessThanOrEqual(result.count, 256 * 1024)
        XCTAssertLessThanOrEqual(image.size.width * image.size.height, 1_500_000)
    }
}

@MainActor private final class TerminalTrialModel: ChatModel {
    let model = "trial-test"
    let isTrial = true
    var calls = 0
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        calls += 1
        if calls == 1 { return ChatResult(text: "1. Observe the screen", total: 0) }
        throw URLError(.timedOut)
    }
}
