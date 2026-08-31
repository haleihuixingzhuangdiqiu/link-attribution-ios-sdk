import Foundation
import XCTest
@testable import LinkAttributionSDK

/// Server Key 登录信任链回归；只使用本地 URLProtocol，不连接真实服务或设备。
final class LinkAttributionLoginRecoveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LinkAttributionServerLoginTruthTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        ServerLoginTruthURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRetiredMobileLoginEntrypointsNeverMutateOrUseNetwork() async throws {
        var requestCount = 0
        ServerLoginTruthURLProtocol.handler = { request in
            requestCount += 1
            return try Self.response(request, status: 500, body: ["error": "unexpected"])
        }
        let sdk = try makeSdk()

        do {
            _ = try await sdk.trackLoginCompleted()
            XCTFail("停用入口必须返回稳定错误")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(
                error,
                .invalidArgument("mobile login confirmation is retired; use local account binding and Server Key confirmation")
            )
        }
        let retry = try await sdk.retryPendingLoginConfirmation()
        XCTAssertNil(retry)
        XCTAssertThrowsError(try sdk.recordLoginCompletedOccurrence())
        XCTAssertThrowsError(try sdk.bindAuthenticatedAccount(scope: "account_scope_0001"))
        XCTAssertEqual(requestCount, 0)
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.allSatisfy { $0.hasSuffix(".installation.v4") == false })
    }

    func testLocalAccountBindingPollsSameAttributionAndDeliversServerFinalUntilAck() async throws {
        let attributionId = "00000000-0000-4000-8000-000000000301"
        let accountScope = "account_scope_0301"
        var paths: [String] = []
        ServerLoginTruthURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            switch path {
            case "/v1/sdk/installations/resolve":
                return try Self.provisionalResponse(request, attributionId: attributionId, sequence: 1)
            case "/v1/sdk/attributions/\(attributionId)":
                return try Self.matchedFinalResponse(request, attributionId: attributionId, sequence: 2, share: "server-confirmed")
            default:
                XCTFail("unexpected request: \(path)")
                return try Self.response(request, status: 500, body: ["error": "unexpected"])
            }
        }

        let sdk = try makeSdk()
        try sdk.recordAuthenticatedLogin(accountScope: accountScope)
        let provisional = try await sdk.resolveInstallation()
        XCTAssertEqual(provisional.attributionId, attributionId)
        XCTAssertEqual(provisional.decisionId, Self.decisionId(for: attributionId))
        let outcome = try await sdk.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0)

        XCTAssertEqual(outcome.phase, .final)
        XCTAssertNil(outcome.result, "可消费 FINAL 只能从账号 outbox 读取")
        XCTAssertEqual(paths, ["/v1/sdk/installations/resolve", "/v1/sdk/attributions/\(attributionId)"])
        let delivery = try XCTUnwrap(sdk.pendingFinalDelivery(accountScope: accountScope))
        XCTAssertEqual(delivery.result.decisionId, Self.decisionId(for: attributionId))
        XCTAssertEqual(delivery.result.finalMatches.first?.externalIdentifier, "server-confirmed")
        XCTAssertThrowsError(try sdk.acknowledgeFinalDelivery(deliveryId: delivery.deliveryId, accountScope: "other_account_0301"))

        let relaunched = try makeSdk()
        XCTAssertEqual(try relaunched.pendingFinalDelivery(accountScope: accountScope)?.deliveryId, delivery.deliveryId)
        try relaunched.acknowledgeFinalDelivery(deliveryId: delivery.deliveryId, accountScope: accountScope)
        XCTAssertNil(try relaunched.pendingFinalDelivery(accountScope: accountScope))
        XCTAssertTrue(try relaunched.isFinalBound(to: accountScope))
    }

    func testAccountBindingIsAtomicIdempotentAndCannotSwitchAccounts() throws {
        let sdk = try makeSdk()
        try sdk.recordAuthenticatedLogin(accountScope: "account_scope_0401")
        let first = try stateObject()
        try sdk.recordAuthenticatedLogin(accountScope: "account_scope_0401")
        let second = try stateObject()

        XCTAssertEqual(first["loginEventId"] as? String, second["loginEventId"] as? String)
        XCTAssertEqual(first["loginOccurredAt"] as? String, second["loginOccurredAt"] as? String)
        XCTAssertEqual(second["deliveryAccountScope"] as? String, "account_scope_0401")
        XCTAssertEqual(second["deliveryAccountScopeTrusted"] as? Bool, true)
        XCTAssertNil(second["loginConfirmation"])
        XCTAssertNil(second["loginSubmissionAttemptedAt"])
        XCTAssertThrowsError(try sdk.recordAuthenticatedLogin(accountScope: "account_scope_0402"))
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: first, options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: second, options: [.sortedKeys])
        )
    }

    func testLostFinalResponseRetriesSameAttributionWithoutRecreatingInstallation() async throws {
        let attributionId = "00000000-0000-4000-8000-000000000501"
        let accountScope = "account_scope_0501"
        var installationCount = 0
        var getCount = 0
        ServerLoginTruthURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                installationCount += 1
                return try Self.provisionalResponse(request, attributionId: attributionId, sequence: 1)
            case "/v1/sdk/attributions/\(attributionId)":
                getCount += 1
                if getCount == 1 { throw URLError(.networkConnectionLost) }
                return try Self.matchedFinalResponse(request, attributionId: attributionId, sequence: 2, share: "response-loss")
            default:
                return try Self.response(request, status: 500, body: ["error": "unexpected"])
            }
        }

        let sdk = try makeSdk()
        try sdk.recordAuthenticatedLogin(accountScope: accountScope)
        _ = try await sdk.resolveInstallation()
        do {
            _ = try await sdk.getAttribution(attributionId: attributionId)
            XCTFail("首次响应丢失必须保留为可重试传输失败")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .network("transport"))
        }

        let relaunched = try makeSdk()
        do {
            _ = try await relaunched.getAttribution(attributionId: attributionId)
            XCTFail("可消费 FINAL 不得从旧查询入口直接返回")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .businessDeliveryRequired)
        }
        XCTAssertEqual(installationCount, 1)
        XCTAssertEqual(getCount, 2)
        XCTAssertEqual(
            try relaunched.pendingFinalDelivery(accountScope: accountScope)?.result.finalMatches.first?.externalIdentifier,
            "response-loss"
        )
    }

    func testLoginBindingDuringInstallationResponseIsMergedBeforeFinalValidation() async throws {
        let attributionId = "00000000-0000-4000-8000-000000000551"
        let responseStarted = expectation(description: "installation response is pending")
        let releaseResponse = DispatchSemaphore(value: 0)
        defer { releaseResponse.signal() }
        ServerLoginTruthURLProtocol.handler = { request in
            responseStarted.fulfill()
            XCTAssertEqual(releaseResponse.wait(timeout: .now() + 3), .success)
            return try Self.matchedFinalResponse(request, attributionId: attributionId, sequence: 1, share: "concurrent-binding")
        }

        let sdk = try makeSdk()
        let installation = Task { try await sdk.resolveInstallation() }
        await fulfillment(of: [responseStarted], timeout: 3)
        try sdk.recordAuthenticatedLogin(accountScope: "account_scope_0551")
        releaseResponse.signal()
        do {
            _ = try await installation.value
            XCTFail("业务 FINAL 应进入 outbox 而不是旧查询返回值")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .businessDeliveryRequired)
        }
        XCTAssertEqual(
            try sdk.pendingFinalDelivery(accountScope: "account_scope_0551")?.result.finalMatches.first?.externalIdentifier,
            "concurrent-binding"
        )
    }

    func testUnboundBusinessFinalCannotBeReopenedByLaterLocalBinding() async throws {
        let attributionId = "00000000-0000-4000-8000-000000000552"
        var requestCount = 0
        ServerLoginTruthURLProtocol.handler = { request in
            requestCount += 1
            return try Self.matchedFinalResponse(request, attributionId: attributionId, sequence: 1, share: "too-early")
        }
        let sdk = try makeSdk()
        do {
            _ = try await sdk.resolveInstallation()
            XCTFail("账号未绑定时必须 fail-closed")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .invalidResponse)
        }

        try sdk.recordAuthenticatedLogin(accountScope: "account_scope_0552")
        let outcome = try await sdk.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0)
        XCTAssertEqual(outcome.phase, .stopped)
        XCTAssertNil(try sdk.pendingFinalDelivery(accountScope: "account_scope_0552"))
        XCTAssertEqual(requestCount, 1, "事后绑定不得重新请求并认领已经越过本地边界的业务 FINAL")
    }

    func testCachedServerFinalRejectsDifferentLaterDecisionAndKeepsOriginalOutbox() async throws {
        let attributionId = "00000000-0000-4000-8000-000000000553"
        var requestCount = 0
        ServerLoginTruthURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                return try Self.matchedFinalResponse(request, attributionId: attributionId, sequence: 2, share: "frozen")
            }
            var reopened = Self.matchedFinalObject(attributionId: attributionId, sequence: 2, share: "frozen")
            reopened["decisionId"] = "20000000-0000-4000-8000-000000000553"
            return try Self.response(request, body: reopened)
        }
        let sdk = try makeSdk()
        try sdk.recordAuthenticatedLogin(accountScope: "account_scope_0553")
        do {
            _ = try await sdk.resolveInstallation()
            XCTFail("业务 FINAL 应进入 outbox")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .businessDeliveryRequired)
        }
        do {
            _ = try await sdk.getAttribution(attributionId: attributionId)
            XCTFail("服务端 FINAL 不得以另一 decisionId 重开")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertEqual(
            try sdk.pendingFinalDelivery(accountScope: "account_scope_0553")?.result.finalMatches.first?.externalIdentifier,
            "frozen"
        )
    }

    func testSdkKeyRotationKeepsLocalBindingAndStillUsesOnlyInstallationAndAttributionRoutes() async throws {
        let attributionId = "00000000-0000-4000-8000-000000000554"
        var observedKeys: [String] = []
        ServerLoginTruthURLProtocol.handler = { request in
            observedKeys.append(request.value(forHTTPHeaderField: "X-SDK-Key") ?? "")
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return try Self.provisionalResponse(request, attributionId: attributionId, sequence: 1)
            case "/v1/sdk/attributions/\(attributionId)":
                return try Self.matchedFinalResponse(request, attributionId: attributionId, sequence: 2, share: "rotated-key")
            default:
                return try Self.response(request, status: 500, body: ["error": "unexpected"])
            }
        }

        let first = try makeSdk(sdkKey: "ios-old-key")
        try first.recordAuthenticatedLogin(accountScope: "account_scope_0554")
        _ = try await first.resolveInstallation()
        let rotated = try makeSdk(sdkKey: "ios-new-key")
        let outcome = try await rotated.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0)

        XCTAssertEqual(outcome.phase, .final)
        XCTAssertEqual(observedKeys, ["ios-old-key", "ios-new-key"])
        XCTAssertEqual(
            try rotated.pendingFinalDelivery(accountScope: "account_scope_0554")?.result.finalMatches.first?.externalIdentifier,
            "rotated-key"
        )
    }

    func testClearGenerationDropsLateFinalAndPreservesReplacementBinding() async throws {
        let oldAttributionId = "00000000-0000-4000-8000-000000000601"
        let getStarted = expectation(description: "old attribution GET started")
        let releaseGet = DispatchSemaphore(value: 0)
        defer { releaseGet.signal() }
        ServerLoginTruthURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return try Self.provisionalResponse(request, attributionId: oldAttributionId, sequence: 1)
            case "/v1/sdk/attributions/\(oldAttributionId)":
                getStarted.fulfill()
                XCTAssertEqual(releaseGet.wait(timeout: .now() + 3), .success)
                return try Self.matchedFinalResponse(request, attributionId: oldAttributionId, sequence: 2, share: "stale")
            default:
                return try Self.response(request, status: 500, body: ["error": "unexpected"])
            }
        }

        let sdk = try makeSdk()
        try sdk.recordAuthenticatedLogin(accountScope: "account_scope_0601")
        _ = try await sdk.resolveInstallation()
        let oldTask = Task { try await sdk.getAttribution(attributionId: oldAttributionId) }
        await fulfillment(of: [getStarted], timeout: 3)

        sdk.clearLocalState()
        try sdk.recordAuthenticatedLogin(accountScope: "replacement_scope_0601")
        let replacement = try stateObject()
        releaseGet.signal()
        do {
            _ = try await oldTask.value
            XCTFail("旧代次响应不得进入新安装")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .invalidResponse)
        }

        let current = try stateObject()
        XCTAssertEqual(current["eventId"] as? String, replacement["eventId"] as? String)
        XCTAssertEqual(current["deliveryAccountScope"] as? String, "replacement_scope_0601")
        XCTAssertNil(current["attributionId"])
        XCTAssertNil(current["terminalResult"])
    }

    func testBusinessFinalWithoutLocalBindingFailsClosedAndPreLoginEmptyFinalsCannotBeClaimedLater() async throws {
        let matchedId = "00000000-0000-4000-8000-000000000701"
        ServerLoginTruthURLProtocol.handler = { request in
            try Self.matchedFinalResponse(request, attributionId: matchedId, sequence: 1, share: "unbound")
        }
        let matched = try makeSdk(storageNamespace: "server-truth-matched")
        do {
            _ = try await matched.resolveInstallation()
            XCTFail("本地账号未绑定时不得接受可消费 FINAL")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertNil(try matched.pendingFinalDelivery(accountScope: "account_scope_0701"))

        let cases: [(suffix: Int, outcome: String, status: String, expected: AttributionOutcome)] = [
            (702, "NO_MATCH", "NO_MATCH", .noMatch),
            (703, "UNRESOLVED", "AMBIGUOUS", .unresolved),
            (704, "RISK_BLOCKED", "MANUAL_REJECT", .riskBlocked),
            (705, "EXPIRED", "EXPIRED", .expired),
        ]
        for item in cases {
            let attributionId = String(format: "00000000-0000-4000-8000-%012d", item.suffix)
            let namespace = "server-truth-prelogin-empty-\(item.suffix)"
            let accountScope = "account_scope_prelogin_\(item.suffix)"
            ServerLoginTruthURLProtocol.handler = { request in
                try Self.emptyFinalResponse(request, attributionId: attributionId, outcome: item.outcome, status: item.status)
            }

            let sdk = try makeSdk(storageNamespace: namespace)
            let diagnostic = try await sdk.resolveInstallation()
            XCTAssertTrue(diagnostic.isFinal)
            XCTAssertEqual(diagnostic.outcome, item.expected)
            XCTAssertTrue(diagnostic.finalMatches.isEmpty)
            XCTAssertNil(try sdk.pendingFinalDelivery(accountScope: accountScope))

            try sdk.recordAuthenticatedLogin(accountScope: accountScope)
            XCTAssertNil(try sdk.pendingFinalDelivery(accountScope: accountScope), "登录前形成的空 FINAL 不得被后来账号追认")
            let relaunched = try makeSdk(storageNamespace: namespace)
            XCTAssertNil(try relaunched.pendingFinalDelivery(accountScope: accountScope), "抑制边界必须跨进程持久化")
            XCTAssertFalse(try relaunched.isFinalBound(to: accountScope))
        }
    }

    func testAuthenticatedEmptyFinalsPersistAcrossRestartAndAck() async throws {
        let cases: [(suffix: Int, outcome: String, status: String, expected: AttributionOutcome)] = [
            (711, "NO_MATCH", "NO_MATCH", .noMatch),
            (712, "UNRESOLVED", "AMBIGUOUS", .unresolved),
            (713, "RISK_BLOCKED", "MANUAL_REJECT", .riskBlocked),
            (714, "EXPIRED", "EXPIRED", .expired),
        ]
        for item in cases {
            let attributionId = String(format: "00000000-0000-4000-8000-%012d", item.suffix)
            let namespace = "server-truth-authenticated-empty-\(item.suffix)"
            let accountScope = "account_scope_authenticated_\(item.suffix)"
            ServerLoginTruthURLProtocol.handler = { request in
                try Self.emptyFinalResponse(request, attributionId: attributionId, outcome: item.outcome, status: item.status)
            }

            let sdk = try makeSdk(storageNamespace: namespace)
            try sdk.recordAuthenticatedLogin(accountScope: accountScope)
            let diagnostic = try await sdk.resolveInstallation()
            XCTAssertEqual(diagnostic.outcome, item.expected)
            XCTAssertTrue(diagnostic.finalMatches.isEmpty)
            XCTAssertEqual(diagnostic.finalMatchesVersion, 1)

            let delivery = try XCTUnwrap(sdk.pendingFinalDelivery(accountScope: accountScope))
            XCTAssertEqual(delivery.deliveryId, "\(attributionId):1")
            XCTAssertEqual(delivery.result.decisionId, Self.decisionId(for: attributionId))
            XCTAssertEqual(delivery.result.finalMatchesVersion, 1)
            XCTAssertTrue(delivery.result.finalMatches.isEmpty)
            XCTAssertEqual(delivery.result.outcome, item.expected)

            let relaunched = try makeSdk(storageNamespace: namespace)
            XCTAssertEqual(try relaunched.pendingFinalDelivery(accountScope: accountScope)?.deliveryId, delivery.deliveryId)
            XCTAssertThrowsError(
                try relaunched.acknowledgeFinalDelivery(deliveryId: delivery.deliveryId, accountScope: "wrong_account_scope_\(item.suffix)")
            )
            try relaunched.acknowledgeFinalDelivery(deliveryId: delivery.deliveryId, accountScope: accountScope)
            XCTAssertNil(try relaunched.pendingFinalDelivery(accountScope: accountScope))
            XCTAssertTrue(try relaunched.isFinalBound(to: accountScope))
        }
    }

    func testV3MigrationRevokesMobileConfirmationAndSuppressesHistoricalBusinessFinal() throws {
        let accountScope = "account_scope_0801"
        let sdk = try makeSdk()
        try sdk.recordAuthenticatedLogin(accountScope: accountScope)
        var legacy = try stateObject()
        var final = Self.matchedFinalObject(
            attributionId: "00000000-0000-4000-8000-000000000801",
            sequence: 9,
            share: "legacy-mobile-confirmed"
        )
        final.removeValue(forKey: "decisionId")
        legacy["storageVersion"] = 3
        legacy["attributionId"] = final["attributionId"]
        legacy["terminalResult"] = final
        legacy["pendingLoginFinal"] = final
        legacy["loginSubmissionAttemptedAt"] = "2026-08-30T08:00:01Z"
        legacy["loginConfirmation"] = [
            "confirmationId": "00000000-0000-4000-8000-000000000899",
            "status": "RECORDED",
            "source": "LEGACY_MOBILE",
            "occurredAt": "2026-08-30T08:00:00Z",
            "reportedAt": "2026-08-30T08:00:01Z",
        ]
        legacy["loginConfirmationPermanentlyRejected"] = true
        legacy["loginRejectionCredentialScope"] = "legacy"
        legacy["recoveryPermanentlyStopped"] = true
        legacy["recoveryCredentialScope"] = "legacy"

        let currentKey = try storageKey(suffix: ".installation.v4")
        let legacyKey = currentKey.replacingOccurrences(of: ".installation.v4", with: ".installation.v3")
        defaults.removeObject(forKey: currentKey)
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: legacyKey)

        let migratedSDK = try makeSdk()
        XCTAssertTrue(migratedSDK.hasRecordedLoginCompletedFact)
        let migrated = try stateObject()
        XCTAssertEqual(migrated["storageVersion"] as? Int, 4)
        XCTAssertNil(migrated["loginConfirmation"])
        XCTAssertNil(migrated["pendingLoginFinal"])
        XCTAssertNil(migrated["loginSubmissionAttemptedAt"])
        XCTAssertEqual(migrated["loginConfirmationPermanentlyRejected"] as? Bool, false)
        XCTAssertNil(migrated["loginRejectionCredentialScope"])
        XCTAssertEqual(migrated["recoveryPermanentlyStopped"] as? Bool, false)
        XCTAssertNil(migrated["terminalResult"], "缺少 decisionId 的旧业务 FINAL 只能保留抑制账本，不能继续作为可提交结果")
        XCTAssertEqual(
            migrated["suppressedUnboundDeliveryId"] as? String,
            "00000000-0000-4000-8000-000000000801:9"
        )
        XCTAssertNil(try migratedSDK.pendingFinalDelivery(accountScope: accountScope))
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains(legacyKey))
    }

    private func makeSdk(
        storageNamespace: String = "server-login-truth-tests",
        sdkKey: String = "ios-test-key"
    ) throws -> LinkAttribution {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServerLoginTruthURLProtocol.self]
        return try LinkAttribution(
            configuration: .init(
                apiBaseURL: URL(string: "https://api.example.test")!,
                sdkKey: sdkKey,
                appVersion: "2.10.4",
                cacheScope: "project-a/test/ios",
                storageNamespace: storageNamespace,
                userProvidedEvidenceEnabled: true
            ),
            session: URLSession(configuration: configuration),
            userDefaults: defaults
        )
    }

    private func storageKey(suffix: String = ".installation.v4") throws -> String {
        try XCTUnwrap(defaults.dictionaryRepresentation().keys.first { $0.hasSuffix(suffix) })
    }

    private func stateData() throws -> Data {
        try XCTUnwrap(defaults.data(forKey: storageKey()))
    }

    private func stateObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: stateData()) as? [String: Any])
    }

    private static func provisionalResponse(
        _ request: URLRequest,
        attributionId: String,
        sequence: Int
    ) throws -> (HTTPURLResponse, Data) {
        try response(request, body: [
            "attributionId": attributionId,
            "decisionId": decisionId(for: attributionId),
            "processState": "PROVISIONAL",
            "isFinal": false,
            "outcome": NSNull(),
            "status": "PENDING",
            "resolverType": "IOS_PROBABILISTIC_INSTALL",
            "decisionSequence": sequence,
            "occurredAt": "2026-08-30T08:00:00Z",
            "reportedAt": "2026-08-30T08:00:01Z",
            "finalizedAt": NSNull(),
            "retryAfterMs": 1,
            "finalMatches": [],
            "matches": [],
            "matchCount": 0,
        ])
    }

    private static func matchedFinalResponse(
        _ request: URLRequest,
        attributionId: String,
        sequence: Int,
        share: String
    ) throws -> (HTTPURLResponse, Data) {
        try response(request, body: matchedFinalObject(attributionId: attributionId, sequence: sequence, share: share))
    }

    private static func matchedFinalObject(
        attributionId: String,
        sequence: Int,
        share: String
    ) -> [String: Any] {
        let match: [String: Any] = [
            "linkId": "00000000-0000-4000-8000-000000000901",
            "ruleKey": "project_share",
            "externalIdentifier": share,
            "confidenceBand": "HIGH",
            "route": "/card/1",
            "attributedAt": "2026-08-30T08:00:02Z",
        ]
        return [
            "attributionId": attributionId,
            "decisionId": decisionId(for: attributionId),
            "processState": "FINAL",
            "isFinal": true,
            "outcome": "MATCHED",
            "status": "PROBABILISTIC_MATCH",
            "resolverType": "IOS_PROBABILISTIC_INSTALL",
            "decisionSequence": sequence,
            "occurredAt": "2026-08-30T08:00:00Z",
            "reportedAt": "2026-08-30T08:00:02Z",
            "finalizedAt": "2026-08-30T08:00:02Z",
            "retryAfterMs": 0,
            "finalMatches": [match],
            "matches": [match],
            "matchCount": 1,
        ]
    }

    private static func emptyFinalResponse(
        _ request: URLRequest,
        attributionId: String,
        outcome: String,
        status: String
    ) throws -> (HTTPURLResponse, Data) {
        try response(request, body: [
            "attributionId": attributionId,
            "decisionId": decisionId(for: attributionId),
            "processState": "FINAL",
            "isFinal": true,
            "outcome": outcome,
            "status": status,
            "resolverType": "IOS_PROBABILISTIC_INSTALL",
            "decisionSequence": 1,
            "occurredAt": "2026-08-30T08:00:00Z",
            "reportedAt": "2026-08-30T08:00:02Z",
            "finalizedAt": "2026-08-30T08:00:02Z",
            "retryAfterMs": 0,
            "finalMatches": [],
            "matches": [],
            "matchCount": 0,
        ])
    }

    private static func decisionId(for installInstanceId: String) -> String {
        "10000000-0000-4000-8000-\(installInstanceId.suffix(12))"
    }

    private static func response(
        _ request: URLRequest,
        status: Int = 200,
        body: [String: Any]
    ) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )
        return (response, try JSONSerialization.data(withJSONObject: body))
    }
}

private final class ServerLoginTruthURLProtocol: URLProtocol {
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
