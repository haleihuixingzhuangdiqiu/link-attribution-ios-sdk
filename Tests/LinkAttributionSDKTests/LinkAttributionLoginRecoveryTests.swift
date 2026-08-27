import Foundation
import XCTest
@testable import LinkAttributionSDK

/// 登录恢复跨证据请求的安装代次回归；只使用本地 URLProtocol，不连接真实服务或设备。
final class LinkAttributionLoginRecoveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LinkAttributionLoginRecoveryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        LoginRecoveryURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPendingEvidenceSuccessCannotMoveOldLoginRecoveryToReplacementInstallation() async throws {
        try await assertReplacementInstallationIsUntouched(evidenceStatus: 200)
    }

    func testPendingEvidenceNetworkFailureCannotMoveOldLoginRecoveryToReplacementInstallation() async throws {
        try await assertReplacementInstallationIsUntouched(evidenceStatus: 503)
    }

    func testPendingEvidenceSuccessKeepsOriginalInstallationAndLoginFacts() async throws {
        try await assertOriginalFactsAreRetained(evidenceRetryFails: false)
    }

    func testPendingEvidenceNetworkFailureRetainsFactsUntilRelaunchRetry() async throws {
        try await assertOriginalFactsAreRetained(evidenceRetryFails: true)
    }

    func testCancelledLoginRecoveryPropagatesCancellationAndRetainsOriginalPendingFacts() async throws {
        let evidenceStarted = expectation(description: "login recovery is awaiting pending evidence")
        let releaseEvidence = DispatchSemaphore(value: 0)
        defer { releaseEvidence.signal() }
        var installationCount = 0
        var evidencePayloads: [[String: Any]] = []
        var loginPayloads: [[String: Any]] = []
        LoginRecoveryURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                installationCount += 1
                return try Self.provisionalResponse(request, installationNumber: 1)
            case "/v1/sdk/installations/user-provided-evidence":
                evidencePayloads.append(try Self.payload(request))
                if evidencePayloads.count == 1 {
                    return try Self.response(request, status: 503, body: ["error": "temporary"])
                }
                if evidencePayloads.count == 2 {
                    evidenceStarted.fulfill()
                    XCTAssertEqual(releaseEvidence.wait(timeout: .now() + 3), .success)
                    // 受控传输在任务取消后回传 URLSession 的取消结果，不清理或重建安装状态。
                    throw URLError(.cancelled)
                }
                return try Self.provisionalResponse(request, installationNumber: 1)
            case "/v1/sdk/events/login-completed":
                loginPayloads.append(try Self.payload(request))
                return try Self.loginResponse(request)
            default:
                XCTFail("unexpected request: \(request.url?.path ?? "missing")")
                return try Self.response(request, status: 500, body: ["error": "unexpected"])
            }
        }

        let sdk = try makeSdk()
        let submission = await sdk.submitUserProvidedEvidence(.linkToken("pending_cancellation_token"))
        XCTAssertEqual(submission, .deferred)
        try sdk.recordAuthenticatedLogin(accountScope: "original_account_scope")
        let originalData = try stateData()
        let originalState = try stateObject()
        let recovery = Task { try await sdk.retryPendingLoginConfirmation() }
        await fulfillment(of: [evidenceStarted], timeout: 3)

        recovery.cancel()
        releaseEvidence.signal()
        do {
            _ = try await recovery.value
            XCTFail("被取消的登录恢复不得继续或返回普通成功")
        } catch is CancellationError {
            // 公共证据提交可返回 deferred；抛错式登录恢复必须保留调用任务的取消语义。
        } catch {
            XCTFail("同一安装代次的取消应原样传播，实际为 \(error)")
        }
        XCTAssertTrue(loginPayloads.isEmpty, "取消证据等待后不得继续登录 POST")
        XCTAssertEqual(try stateData(), originalData, "取消不能改写已持久化的证据、登录事实或发送标记")

        // 新实例仍能恢复原待办，取消不等于永久拒绝或丢弃首次事实。
        try await Task.sleep(nanoseconds: 5_000_000)
        let confirmation = try await makeSdk().retryPendingLoginConfirmation()
        XCTAssertNotNil(confirmation)
        XCTAssertEqual(installationCount, 1)
        XCTAssertEqual(evidencePayloads.count, 3)
        XCTAssertEqual(loginPayloads.count, 1)
        for payload in evidencePayloads {
            XCTAssertEqual(payload["installationEventId"] as? String, originalState["eventId"] as? String)
            XCTAssertEqual(payload["eventId"] as? String, evidencePayloads.first?["eventId"] as? String)
            XCTAssertEqual(payload["occurredAt"] as? String, evidencePayloads.first?["occurredAt"] as? String)
        }
        let login = try XCTUnwrap(loginPayloads.first)
        XCTAssertEqual(login["eventId"] as? String, originalState["loginEventId"] as? String)
        XCTAssertEqual(login["occurredAt"] as? String, originalState["loginOccurredAt"] as? String)
        XCTAssertNil(try stateObject()["pendingUserProvidedEvidence"])
    }

    private func assertReplacementInstallationIsUntouched(evidenceStatus: Int) async throws {
        let evidenceStarted = expectation(description: "old login recovery is awaiting evidence")
        let releaseEvidence = DispatchSemaphore(value: 0)
        defer { releaseEvidence.signal() }
        var installationIds: [String] = []
        var loginPayloads: [[String: Any]] = []
        var evidenceCount = 0
        LoginRecoveryURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                let payload = try Self.payload(request)
                installationIds.append(try XCTUnwrap(payload["eventId"] as? String))
                return try Self.provisionalResponse(request, installationNumber: installationIds.count)
            case "/v1/sdk/installations/user-provided-evidence":
                evidenceCount += 1
                if evidenceCount == 1 {
                    return try Self.response(request, status: 503, body: ["error": "temporary"])
                }
                evidenceStarted.fulfill()
                XCTAssertEqual(releaseEvidence.wait(timeout: .now() + 3), .success)
                if evidenceStatus != 200 {
                    return try Self.response(request, status: evidenceStatus, body: ["error": "temporary"])
                }
                return try Self.provisionalResponse(request, installationNumber: 1)
            case "/v1/sdk/events/login-completed":
                let payload = try Self.payload(request)
                loginPayloads.append(payload)
                guard let installationId = payload["installationEventId"] as? String,
                      installationIds.contains(installationId) else {
                    return try Self.response(request, status: 400, body: ["error": "installation not registered"])
                }
                return try Self.loginResponse(request)
            default:
                XCTFail("unexpected request: \(request.url?.path ?? "missing")")
                return try Self.response(request, status: 500, body: ["error": "unexpected"])
            }
        }

        let sdk = try makeSdk()
        let submission = await sdk.submitUserProvidedEvidence(.linkToken("pending_generation_token"))
        XCTAssertEqual(submission, .deferred)
        try sdk.recordAuthenticatedLogin(accountScope: "original_account_scope")
        let originalState = try stateObject()
        let oldRecovery = Task { try await sdk.retryPendingLoginConfirmation() }
        await fulfillment(of: [evidenceStarted], timeout: 3)

        sdk.clearLocalState()
        try sdk.recordAuthenticatedLogin(accountScope: "replacement_account_scope")
        let replacementData = try stateData()
        let replacementState = try stateObject()
        XCTAssertNotEqual(originalState["eventId"] as? String, replacementState["eventId"] as? String)
        releaseEvidence.signal()
        do {
            _ = try await oldRecovery.value
            XCTFail("清理后的旧登录恢复必须取消，不能采用新安装")
        } catch is CancellationError {
            // 证据成功或临时失败都必须先检查原安装代次，不能越代次发送或写入发送标记。
        } catch {
            XCTFail("旧安装已清理，应返回 CancellationError，实际为 \(error)")
        }

        XCTAssertTrue(loginPayloads.isEmpty, "旧任务不得为尚未登记的新安装发送登录")
        XCTAssertEqual(try stateData(), replacementData, "新安装登录事实及发送标记必须保持逐字不变")
        XCTAssertNil(try stateObject()["loginSubmissionAttemptedAt"])
        XCTAssertNil(try stateObject()["loginConfirmation"])

        // 新安装只能由新的恢复入口先登记安装，再发送其自己已经冻结的登录事实。
        let confirmation = try await sdk.retryPendingLoginConfirmation()
        XCTAssertNotNil(confirmation)
        XCTAssertEqual(installationIds.count, 2)
        XCTAssertEqual(loginPayloads.count, 1)
        let login = try XCTUnwrap(loginPayloads.last)
        XCTAssertEqual(login["installationEventId"] as? String, replacementState["eventId"] as? String)
        XCTAssertEqual(login["eventId"] as? String, replacementState["loginEventId"] as? String)
        XCTAssertEqual(login["occurredAt"] as? String, replacementState["loginOccurredAt"] as? String)
    }

    private func assertOriginalFactsAreRetained(evidenceRetryFails: Bool) async throws {
        var installationCount = 0
        var evidencePayloads: [[String: Any]] = []
        var loginPayloads: [[String: Any]] = []
        var order: [String] = []
        LoginRecoveryURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                installationCount += 1
                return try Self.provisionalResponse(request, installationNumber: 1)
            case "/v1/sdk/installations/user-provided-evidence":
                order.append("evidence")
                let payload = try Self.payload(request)
                evidencePayloads.append(payload)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), payload["eventId"] as? String)
                if evidencePayloads.count == 1 || (evidenceRetryFails && evidencePayloads.count == 2) {
                    return try Self.response(request, status: 503, body: ["error": "temporary"])
                }
                return try Self.provisionalResponse(request, installationNumber: 1)
            case "/v1/sdk/events/login-completed":
                order.append("login")
                let payload = try Self.payload(request)
                loginPayloads.append(payload)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), payload["eventId"] as? String)
                return try Self.loginResponse(request)
            default:
                XCTFail("unexpected request: \(request.url?.path ?? "missing")")
                return try Self.response(request, status: 500, body: ["error": "unexpected"])
            }
        }

        let sdk = try makeSdk()
        let submission = await sdk.submitUserProvidedEvidence(.linkToken("pending_original_token"))
        XCTAssertEqual(submission, .deferred)
        try sdk.recordAuthenticatedLogin(accountScope: "original_account_scope")
        let originalState = try stateObject()
        let pendingEvidence = try XCTUnwrap(originalState["pendingUserProvidedEvidence"] as? [String: Any])

        if evidenceRetryFails {
            do {
                _ = try await sdk.retryPendingLoginConfirmation()
                XCTFail("证据仍未成功时不得先发送登录")
            } catch let error as LinkAttributionError {
                XCTAssertEqual(error, .network("pending_user_evidence"))
            }
            XCTAssertTrue(loginPayloads.isEmpty)
            let waitingState = try stateObject()
            for field in ["eventId", "occurredAt", "loginEventId", "loginOccurredAt"] {
                XCTAssertEqual(waitingState[field] as? String, originalState[field] as? String)
            }
            XCTAssertNil(waitingState["loginSubmissionAttemptedAt"])
            XCTAssertEqual(waitingState["loginConfirmationPermanentlyRejected"] as? Bool, false)
            let waitingEvidence = try XCTUnwrap(waitingState["pendingUserProvidedEvidence"] as? [String: Any])
            XCTAssertEqual(waitingEvidence["eventId"] as? String, pendingEvidence["eventId"] as? String)
            XCTAssertEqual(waitingEvidence["occurredAt"] as? String, pendingEvidence["occurredAt"] as? String)
        }

        try await Task.sleep(nanoseconds: 5_000_000)
        let recoveringSdk = evidenceRetryFails ? try makeSdk() : sdk
        let confirmation = try await recoveringSdk.retryPendingLoginConfirmation()
        XCTAssertNotNil(confirmation)
        XCTAssertEqual(installationCount, 1)
        XCTAssertEqual(loginPayloads.count, 1)
        XCTAssertEqual(order, evidenceRetryFails ? ["evidence", "evidence", "evidence", "login"] : ["evidence", "evidence", "login"])
        for payload in evidencePayloads {
            XCTAssertEqual(payload["installationEventId"] as? String, originalState["eventId"] as? String)
            XCTAssertEqual(payload["eventId"] as? String, pendingEvidence["eventId"] as? String)
            XCTAssertEqual(payload["occurredAt"] as? String, pendingEvidence["occurredAt"] as? String)
        }
        XCTAssertNotEqual(evidencePayloads.first?["reportedAt"] as? String, evidencePayloads.last?["reportedAt"] as? String)
        let login = try XCTUnwrap(loginPayloads.first)
        XCTAssertEqual(login["installationEventId"] as? String, originalState["eventId"] as? String)
        XCTAssertEqual(login["eventId"] as? String, originalState["loginEventId"] as? String)
        XCTAssertEqual(login["occurredAt"] as? String, originalState["loginOccurredAt"] as? String)
        XCTAssertNil(try stateObject()["pendingUserProvidedEvidence"])
    }

    private func makeSdk() throws -> LinkAttribution {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [LoginRecoveryURLProtocol.self]
        return try LinkAttribution(
            configuration: .init(
                apiBaseURL: URL(string: "https://api.example.test")!,
                sdkKey: "ios-test-key",
                appVersion: "2.10.4",
                cacheScope: "project-a/test/ios",
                storageNamespace: "login-generation-tests",
                userProvidedEvidenceEnabled: true
            ),
            session: URLSession(configuration: sessionConfiguration),
            userDefaults: defaults
        )
    }

    private func stateData() throws -> Data {
        let key = try XCTUnwrap(defaults.dictionaryRepresentation().keys.first { $0.hasSuffix(".installation.v3") })
        return try XCTUnwrap(defaults.data(forKey: key))
    }

    private func stateObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: stateData()) as? [String: Any])
    }

    private static func provisionalResponse(_ request: URLRequest, installationNumber: Int) throws -> (HTTPURLResponse, Data) {
        try response(request, body: [
            "attributionId": "00000000-0000-4000-8000-00000000027\(installationNumber)",
            "processState": "PROVISIONAL", "isFinal": false, "status": "PENDING", "outcome": NSNull(),
            "resolverType": "IOS_PROBABILISTIC_INSTALL", "decisionSequence": 0,
            "occurredAt": "2026-08-27T08:00:00Z", "reportedAt": "2026-08-27T08:00:01Z",
            "finalizedAt": NSNull(), "retryAfterMs": 1_000, "finalMatches": [], "matches": [], "matchCount": 0,
        ])
    }

    private static func loginResponse(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        try response(request, status: 201, body: [
            "confirmationId": "00000000-0000-4000-8000-000000000177", "status": "RECORDED", "source": "SDK_REPORTED",
            "occurredAt": "2026-08-27T08:01:00Z", "reportedAt": "2026-08-27T08:01:01Z",
        ])
    }

    private static func response(_ request: URLRequest, status: Int = 200, body: [String: Any]) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        return (response, try JSONSerialization.data(withJSONObject: body))
    }

    private static func payload(_ request: URLRequest) throws -> [String: Any] {
        if let body = request.httpBody {
            return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class LoginRecoveryURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
