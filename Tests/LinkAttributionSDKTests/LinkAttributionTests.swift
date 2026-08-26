import Foundation
import XCTest
@testable import LinkAttributionSDK

final class LinkAttributionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "LinkAttributionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testUniversalLinkResolvesCanonicalPayload() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-SDK-Key"), "ios-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-App-Version"), "2.10.4")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/sdk/links/resolve-url")
            let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
            XCTAssertEqual(payload["url"] as? String, "https://go.example.test/s/t_123?utm_source=douyin")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), payload["eventId"] as? String)
            XCTAssertNotNil(payload["occurredAt"] as? String)
            XCTAssertNotNil(payload["signals"] as? [String: Any])
            return Self.response(request, json: #"{"linkId":"l1","revisionId":"r1","route":"/invite","navigationSessionId":"00000000-0000-4000-8000-000000000031","schemaVersion":3,"params":{"inviter_id":"u1"},"destinations":[]}"#)
        }
        let sdk = try makeSdk()
        let result = try await sdk.handleUniversalLink(URL(string: "https://go.example.test/s/t_123?utm_source=douyin")!)
        XCTAssertEqual(result?.route, "/invite")
        XCTAssertEqual(result?.params["inviter_id"], .string("u1"))
        XCTAssertEqual(result?.navigationSessionId, "00000000-0000-4000-8000-000000000031")
    }

    func testNavigationOutcomeReportsOnlyFixedRouterResultFields() async throws {
        let navigationSessionId = "00000000-0000-4000-8000-000000000032"
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/v1/sdk/events/navigation-outcome")
            let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
            XCTAssertEqual(Set(payload.keys), ["navigationSessionId", "eventId", "outcome", "failureReason", "durationMs"])
            XCTAssertEqual(payload["navigationSessionId"] as? String, navigationSessionId)
            XCTAssertEqual(payload["outcome"] as? String, "ROUTE_FAILED")
            XCTAssertEqual(payload["failureReason"] as? String, "DESTINATION_UNAVAILABLE")
            XCTAssertNil(payload["url"])
            XCTAssertNil(payload["params"])
            XCTAssertNil(payload["attributes"])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), payload["eventId"] as? String)
            return Self.response(
                request,
                status: 201,
                json: #"{"outcomeId":"00000000-0000-4000-8000-000000000033","navigationSessionId":"00000000-0000-4000-8000-000000000032","outcome":"ROUTE_FAILED","failureReason":"DESTINATION_UNAVAILABLE","durationMs":96,"occurredAt":"2026-08-25T10:00:00Z"}"#
            )
        }
        let sdk = try makeSdk()

        let result = try await sdk.trackNavigationOutcome(
            .init(
                navigationSessionId: navigationSessionId,
                outcome: .routeFailed,
                failureReason: .destinationUnavailable,
                durationMs: 96
            )
        )

        XCTAssertEqual(result.failureReason, .destinationUnavailable)
        XCTAssertNil(result.reportedAt)
        do {
            _ = try await sdk.trackNavigationOutcome(
                .init(navigationSessionId: navigationSessionId, outcome: .destinationViewed, failureReason: .unknown)
            )
            XCTFail("successful route must not carry a failure reason")
        } catch let error as LinkAttributionError {
            guard case .invalidArgument = error else { return XCTFail("expected invalidArgument, got \(error)") }
        }
        XCTAssertEqual(requestCount, 1)
    }

    func testUniversalLinkRejectsUnsafeOrHostRestrictedURLsBeforeSendingSDKKey() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
        }
        let sdk = try makeSdk()
        let rejected = [
            "https://evil.example/s/t_123",
            "https://go.example.test.evil.example/s/t_123",
            "http://go.example.test/s/t_123",
            "https://user@go.example.test/s/t_123",
            "https://go.example.test:8443/s/t_123",
            "https://go.example.test/s/t_123#fragment",
        ]

        for value in rejected {
            let result = try await sdk.handleUniversalLink(URL(string: value)!)
            XCTAssertNil(result, value)
        }
        XCTAssertEqual(requestCount, 0)
    }

    func testRuntimeParamsAcceptFiniteJSONAndPreserveLegacyQueryValues() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
            let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
            XCTAssertEqual(values["message"]!, "中文 / +?")
            let nestedText = try XCTUnwrap(values["nested"] ?? nil)
            let nested = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(nestedText.utf8)) as? [String: Any])
            XCTAssertEqual(nested["enabled"] as? Bool, true)
            let items = try XCTUnwrap(nested["items"] as? [Any])
            XCTAssertEqual(items.first as? Double, 1)
            XCTAssertTrue(items.last is NSNull)
            return Self.response(
                request,
                json: #"{"linkId":"l1","revisionId":"r1","route":"/invite","schemaVersion":3,"params":{},"destinations":[]}"#
            )
        }
        let result = try await makeSdk().resolveLink(
            token: "token_123",
            runtimeParams: [
                "message": .string("中文 / +?"),
                "nested": .object(["enabled": .bool(true), "items": .array([.number(1), .null])]),
            ]
        )

        XCTAssertEqual(result.route, "/invite")
        XCTAssertEqual(requestCount, 1)
    }

    func testRuntimeParamsRejectNonFiniteDeepLargeAndOverBudgetJSONBeforeNetwork() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
        }
        let sdk = try makeSdk()
        var tooDeep: JSONValue = .null
        for _ in 0..<33 { tooDeep = .array([tooDeep]) }
        let tenThousandNulls = [JSONValue](repeating: .null, count: 10_000)
        let tooManyNodes = Dictionary(uniqueKeysWithValues: (0..<10).map { ("bucket_\($0)", JSONValue.array(tenThousandNulls)) })
        let invalidParams: [[String: JSONValue]] = [
            ["number": .number(.infinity)],
            ["deep": tooDeep],
            ["large": .string(String(repeating: "界", count: 333_334))],
            ["collection": .array([JSONValue](repeating: .null, count: 10_001))],
            tooManyNodes,
        ]

        for runtimeParams in invalidParams {
            do {
                _ = try await sdk.createClick(token: "token_123", runtimeParams: runtimeParams)
                XCTFail("无效运行参数必须在本地拒绝")
            } catch let error as LinkAttributionError {
                guard case .invalidArgument = error else {
                    return XCTFail("expected invalidArgument, got \(error)")
                }
            }
        }
        XCTAssertEqual(requestCount, 0)
    }

    func testLegacyResolveRejectsInvalidKeysAndPathBeyondEightKiBBeforeNetwork() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
        }
        let sdk = try makeSdk()
        let invalidParams: [[String: JSONValue]] = [
            ["": .string("value")],
            [String(repeating: "a", count: 129): .string("value")],
            ["payload": .string(String(repeating: "a", count: 8_200))],
        ]

        for runtimeParams in invalidParams {
            do {
                _ = try await sdk.resolveLink(token: "token_123", runtimeParams: runtimeParams)
                XCTFail("非法 key 或超长旧 GET 路径必须在本地拒绝")
            } catch let error as LinkAttributionError {
                guard case .invalidArgument = error else {
                    return XCTFail("expected invalidArgument, got \(error)")
                }
            }
        }
        XCTAssertEqual(requestCount, 0)
    }

    func testAllowedLinkHostsMayBeEmptyButConfiguredValuesMustBeHostOnly() throws {
        XCTAssertNoThrow(
            try LinkAttribution(
                configuration: .init(
                    apiBaseURL: URL(string: "https://api.example.test")!,
                    sdkKey: "ios-key",
                    allowedLinkHosts: [],
                    appVersion: "2.10.4",
                    cacheScope: "project-a/production/ios"
                ),
                userDefaults: defaults
            )
        )
        for hosts: Set<String> in [["https://go.example.test/s/"]] {
            XCTAssertThrowsError(
                try LinkAttribution(
                    configuration: .init(
                        apiBaseURL: URL(string: "https://api.example.test")!,
                        sdkKey: "ios-key",
                        allowedLinkHosts: hosts,
                        appVersion: "2.10.4",
                        cacheScope: "project-a/production/ios"
                    ),
                    userDefaults: defaults
                )
            ) { error in
                guard let attributionError = error as? LinkAttributionError,
                      case .invalidConfiguration = attributionError
                else {
                    return XCTFail("expected invalidConfiguration, got \(error)")
                }
            }
        }
    }

    func testAppVersionRejectsUnicodeDigits() throws {
        for appVersion in ["２.10.4", "٢.10.4"] {
            XCTAssertThrowsError(
                try LinkAttribution(
                    configuration: .init(
                        apiBaseURL: URL(string: "https://api.example.test")!,
                        sdkKey: "ios-key",
                        appVersion: appVersion,
                        cacheScope: "project-a/production/ios"
                    ),
                    userDefaults: defaults
                ),
                appVersion
            ) { error in
                guard let attributionError = error as? LinkAttributionError,
                      case .invalidConfiguration = attributionError
                else {
                    return XCTFail("expected invalidConfiguration, got \(error)")
                }
            }
        }
    }

    func testCacheScopeMustExplicitlySeparateProjectEnvironmentAndApplication() throws {
        for cacheScope in ["", "icarder", "icarder/test", "icarder//ios", "icarder/test/ios/含中文"] {
            XCTAssertThrowsError(
                try LinkAttribution(
                    configuration: .init(
                        apiBaseURL: URL(string: "https://api.example.test")!,
                        sdkKey: "ios-key",
                        appVersion: "2.10.4",
                        cacheScope: cacheScope
                    ),
                    userDefaults: defaults
                ),
                cacheScope
            )
        }
        XCTAssertNoThrow(
            try LinkAttribution(
                configuration: .init(
                    apiBaseURL: URL(string: "https://api.example.test")!,
                    sdkKey: "ios-key",
                    appVersion: "2.10.4",
                    cacheScope: "icarder/test/ios"
                ),
                userDefaults: defaults
            )
        )
    }

    func testWireRejectsMissingOrContradictoryFinalContract() throws {
        let invalidResponses = [
            #"{"attributionId":"00000000-0000-4000-8000-000000000201","processState":"FINAL","outcome":"NO_MATCH","status":"NO_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":1,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","finalMatches":[]}"#,
            #"{"attributionId":"00000000-0000-4000-8000-000000000201","processState":"FINAL","isFinal":false,"outcome":"NO_MATCH","status":"NO_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":1,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","finalMatches":[]}"#,
            #"{"attributionId":"00000000-0000-4000-8000-000000000201","processState":"PROVISIONAL","isFinal":false,"outcome":"MATCHED","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","finalMatches":[{"linkId":"00000000-0000-4000-8000-000000000301","confidenceBand":"HIGH"}]}"#,
            #"{"attributionId":"00000000-0000-4000-8000-000000000201","processState":"FINAL","isFinal":true,"outcome":"MATCHED","status":"PROBABILISTIC_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":1,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","finalMatches":[]}"#,
            #"{"attributionId":"00000000-0000-4000-8000-000000000201","processState":"PROVISIONAL","isFinal":false,"status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":-1,"finalMatches":[]}"#,
            #"{"attributionId":"00000000-0000-4000-8000-000000000201","processState":"PROVISIONAL","isFinal":false,"status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","finalMatches":[]}"#,
        ]

        for json in invalidResponses {
            XCTAssertThrowsError(try JSONDecoder().decode(AttributionResult.self, from: Data(json.utf8)), json)
        }
    }

    func testWireRequiresBusinessIdentityAndRejectsInvalidUUIDs() throws {
        let valid = #"{"attributionId":"00000000-0000-4000-8000-000000000221","processState":"FINAL","isFinal":true,"outcome":"MATCHED","status":"PROBABILISTIC_MATCH","resolverType":"IOS_USER_PROVIDED_LINK","decisionSequence":1,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","finalizedAt":"2026-08-24T08:00:01Z","retryAfterMs":0,"finalMatches":[{"linkId":"00000000-0000-4000-8000-000000000321","ruleKey":"icard_share","externalIdentifier":"share-123","confidenceBand":"HIGH","attributedAt":"2026-08-24T08:00:01Z"}],"matches":[{"linkId":"00000000-0000-4000-8000-000000000321","ruleKey":"icard_share","externalIdentifier":"share-123","confidenceBand":"HIGH","attributedAt":"2026-08-24T08:00:01Z"}],"matchCount":1,"navigationSessionId":"00000000-0000-4000-8000-000000000421"}"#

        let result = try JSONDecoder().decode(AttributionResult.self, from: Data(valid.utf8))
        XCTAssertEqual(result.finalMatches.first?.ruleKey, "icard_share")
        XCTAssertEqual(result.finalMatches.first?.externalIdentifier, "share-123")

        let invalidResponses = [
            valid.replacingOccurrences(of: "00000000-0000-4000-8000-000000000221", with: "invalid-attribution-id"),
            valid.replacingOccurrences(of: "00000000-0000-4000-8000-000000000321", with: "invalid-link-id"),
            valid.replacingOccurrences(of: "00000000-0000-4000-8000-000000000421", with: "invalid-navigation-id"),
            valid.replacingOccurrences(of: ",\"ruleKey\":\"icard_share\"", with: ""),
            valid.replacingOccurrences(of: ",\"externalIdentifier\":\"share-123\"", with: ""),
            valid.replacingOccurrences(of: "\"ruleKey\":\"icard_share\"", with: "\"ruleKey\":\"   \""),
            valid.replacingOccurrences(of: "\"externalIdentifier\":\"share-123\"", with: "\"externalIdentifier\":\"   \""),
        ]
        for json in invalidResponses {
            XCTAssertThrowsError(try JSONDecoder().decode(AttributionResult.self, from: Data(json.utf8)), json)
        }
    }

    func testWireAcceptsOneHundredFinalMatchesAndRejectsOneHundredOne() throws {
        func payload(matchCount: Int) throws -> Data {
            let matches: [[String: Any]] = (1...matchCount).map { index in
                [
                    "linkId": String(format: "00000000-0000-4000-8000-%012d", index),
                    "ruleKey": "icard_share",
                    "externalIdentifier": "share-\(index)",
                    "confidenceBand": "HIGH",
                    "attributedAt": "2026-08-24T08:00:01Z",
                ]
            }
            return try JSONSerialization.data(withJSONObject: [
                "attributionId": "00000000-0000-4000-8000-000000000221",
                "processState": "FINAL",
                "isFinal": true,
                "outcome": "MULTIPLE_MATCHES",
                "status": "PROBABILISTIC_MATCH",
                "resolverType": "IOS_PROBABILISTIC_INSTALL",
                "decisionSequence": 1,
                "occurredAt": "2026-08-24T08:00:00Z",
                "reportedAt": "2026-08-24T08:00:01Z",
                "finalizedAt": "2026-08-24T08:00:01Z",
                "retryAfterMs": 0,
                "finalMatches": matches,
                "matches": matches,
                "matchCount": matches.count,
            ])
        }

        XCTAssertNoThrow(try JSONDecoder().decode(AttributionResult.self, from: payload(matchCount: 100)))
        XCTAssertThrowsError(try JSONDecoder().decode(AttributionResult.self, from: payload(matchCount: 101)))
    }

    func testLoginConfirmationRejectsUntrustedSuccessPayload() throws {
        let invalidResponses = [
            #"{"confirmationId":"not-a-uuid","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z"}"#,
            #"{"confirmationId":"00000000-0000-4000-8000-000000000109","status":"IGNORED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z"}"#,
            #"{"confirmationId":"00000000-0000-4000-8000-000000000109","status":"RECORDED","source":"UNKNOWN","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z"}"#,
            #"{"confirmationId":"00000000-0000-4000-8000-000000000109","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"not-a-date","reportedAt":"2026-08-24T08:00:01Z"}"#,
        ]

        for json in invalidResponses {
            XCTAssertThrowsError(try JSONDecoder().decode(LoginConfirmation.self, from: Data(json.utf8)), json)
        }
    }

    func testConsumableFinalIsRejectedUntilLoginConfirmationIsPersisted() async throws {
        MockURLProtocol.handler = { request in
            Self.response(
                request,
                json: #"{"attributionId":"00000000-0000-4000-8000-000000000202","processState":"FINAL","outcome":"MATCHED","status":"PROBABILISTIC_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","finalizedAt":"2026-08-24T08:00:01Z","finalMatches":[{"linkId":"00000000-0000-4000-8000-000000000301","externalIdentifier":"share-1","confidenceBand":"HIGH"}]}"#
            )
        }
        let sdk = try makeSdk()

        do {
            _ = try await sdk.resolveInstallation()
            XCTFail("登录确认前不得交付可消费 FINAL")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testPollingClampsHugeRetryAfterToRemainingTimeout() async throws {
        var count = 0
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000203","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":60000,"finalMatches":[]}"#
                )
            case "/v1/sdk/attributions/00000000-0000-4000-8000-000000000203":
                count += 1
                XCTAssertGreaterThan(request.timeoutInterval, 0)
                XCTAssertLessThanOrEqual(request.timeoutInterval, 0.06, "单次请求不能越过本次轮询的总 deadline")
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000203","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:02Z","retryAfterMs":60000,"finalMatches":[]}"#
                )
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }
        let sdk = try makeSdk()
        _ = try await sdk.resolveInstallation()
        let startedAt = ProcessInfo.processInfo.systemUptime

        do {
            _ = try await sdk.waitForAttribution(attributionId: "00000000-0000-4000-8000-000000000203", timeout: 0.05, interval: 1)
            XCTFail("轮询应在总超时内结束")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .timeout)
        }

        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 0.5)
        XCTAssertEqual(count, 1, "超长 retryAfter 不得越过 deadline 后再发起请求")
    }

    func testTerminalInstallationResultIsCachedIdempotently() async throws {
        var count = 0
        MockURLProtocol.handler = { request in
            count += 1
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-App-Version"), "2.10.4")
            let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
            XCTAssertEqual(payload["appVersion"] as? String, "2.10.4")
            XCTAssertNil(payload["deterministicClickToken"])
            XCTAssertNotNil(payload["occurredAt"] as? String)
            XCTAssertNotNil(payload["reportedAt"] as? String)
            let signals = try XCTUnwrap(payload["signals"] as? [String: Any])
            XCTAssertNil(signals["countryCode"])
            XCTAssertNil(signals["timezoneOffsetMinutes"])
            let language = try XCTUnwrap(signals["locale"] as? String)
            XCTAssertTrue((2...3).contains(language.count))
            XCTAssertEqual(language, language.lowercased())
            XCTAssertTrue(language.allSatisfy { $0.isASCII && $0.isLetter })
            return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000204","processState":"FINAL","outcome":"EXPIRED","status":"EXPIRED","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","finalizedAt":"2026-08-24T08:00:02Z","finalMatches":[]}"#)
        }
        let sdk = try makeSdk()
        let first = try await sdk.resolveInstallation()
        let second = try await sdk.resolveInstallation()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.outcome, .expired)
        XCTAssertTrue(first.finalMatches.isEmpty)
        XCTAssertEqual(count, 1)
    }

    func testInstallationRetryKeepsEventAndOccurrenceTimeButRefreshesReportTime() async throws {
        var payloads: [[String: Any]] = []
        MockURLProtocol.handler = { request in
            let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
            payloads.append(payload)
            if payloads.count == 1 {
                return Self.response(request, status: 503, json: #"{"error":"temporary"}"#)
            }
            return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000205","processState":"FINAL","outcome":"NO_MATCH","status":"NO_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:03Z","finalizedAt":"2026-08-24T08:00:03Z","finalMatches":[]}"#)
        }

        do {
            _ = try await makeSdk().resolveInstallation()
            XCTFail("first request must fail")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .http(status: 503))
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = try await makeSdk().resolveInstallation()

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0]["eventId"] as? String, payloads[1]["eventId"] as? String)
        XCTAssertEqual(payloads[0]["occurredAt"] as? String, payloads[1]["occurredAt"] as? String)
        XCTAssertNotEqual(payloads[0]["reportedAt"] as? String, payloads[1]["reportedAt"] as? String)
    }

    func testLostInstallationResponseAfterUpgradeReplaysFrozenIdentity() async throws {
        var payloads: [[String: Any]] = []
        var headers: [String?] = []
        MockURLProtocol.handler = { request in
            payloads.append(try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any])
            headers.append(request.value(forHTTPHeaderField: "X-App-Version"))
            if payloads.count == 1 {
                // 模拟服务端可能已经提交、但响应在客户端收到前丢失；下一版本只能逐字重放首次请求身份。
                throw URLError(.networkConnectionLost)
            }
            return Self.response(
                request,
                json: #"{"attributionId":"00000000-0000-4000-8000-000000000206","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:03Z","retryAfterMs":1000,"finalMatches":[]}"#
            )
        }

        do {
            _ = try await makeSdk(appVersion: "2.10.4").resolveInstallation()
            XCTFail("first response must be lost")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .network("transport"))
        }
        _ = try await makeSdk(appVersion: "2.11.0").resolveInstallation()

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0]["eventId"] as? String, payloads[1]["eventId"] as? String)
        XCTAssertEqual(payloads[0]["occurredAt"] as? String, payloads[1]["occurredAt"] as? String)
        XCTAssertEqual(payloads[0]["appVersion"] as? String, "2.10.4")
        XCTAssertEqual(payloads[1]["appVersion"] as? String, "2.10.4")
        XCTAssertEqual(headers, ["2.10.4", "2.10.4"])
        XCTAssertNil(payloads[0]["deterministicClickToken"])
        XCTAssertNil(payloads[1]["deterministicClickToken"])
    }

    func testCompletedV2CacheMigratesExplicitlyButPendingV2FailsClosed() async throws {
        let completedEventId = "00000000-0000-4000-8000-000000000207"
        let attributionId = "00000000-0000-4000-8000-000000000208"
        let v2Key = Self.legacyV2StorageKey()
        defaults.set(
            Data(#"{"eventId":"00000000-0000-4000-8000-000000000207","occurredAt":"2026-08-24T08:00:00Z","attributionId":"00000000-0000-4000-8000-000000000208"}"#.utf8),
            forKey: v2Key
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/sdk/attributions/\(attributionId)")
            return Self.response(
                request,
                json: #"{"attributionId":"00000000-0000-4000-8000-000000000208","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
            )
        }
        let migrated = try makeSdk(appVersion: "2.11.0")
        _ = try await migrated.getAttribution(attributionId: attributionId)
        let migratedData = try XCTUnwrap(defaults.data(forKey: try currentInstallationStorageKey()))
        let migratedObject = try JSONSerialization.jsonObject(with: migratedData) as! [String: Any]
        XCTAssertEqual(migratedObject["storageVersion"] as? Int, 3)
        XCTAssertEqual(migratedObject["eventId"] as? String, completedEventId)
        XCTAssertEqual(migratedObject["installationAppVersion"] as? String, "2.11.0")
        XCTAssertEqual(migratedObject["installationPlatform"] as? String, "IOS")
        XCTAssertEqual(migratedObject["deterministicClickTokenAbsent"] as? Bool, true)

        migrated.clearLocalState()
        defaults.set(
            Data(#"{"eventId":"00000000-0000-4000-8000-000000000209","occurredAt":"2026-08-24T08:00:00Z"}"#.utf8),
            forKey: v2Key
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
        }
        let pending = try makeSdk(appVersion: "2.12.0")
        do {
            _ = try await pending.resolveInstallation()
            XCTFail("旧版未登记状态无法证明首次请求身份，必须 fail-closed")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .storage("legacy_install_identity_unavailable"))
        }
        XCTAssertEqual(requestCount, 0)
    }

    func testCorruptedCurrentInstallationCacheFailsClosedWithoutNewEvent() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            return Self.response(request, status: 503, json: #"{"error":"temporary"}"#)
        }
        do { _ = try await makeSdk().resolveInstallation() } catch { /* 先建立当前版本持久安装事实。 */ }
        let key = try currentInstallationStorageKey()
        let original = try XCTUnwrap(defaults.data(forKey: key))
        var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        object["installationAppVersion"] = 2104
        let corrupted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        defaults.set(corrupted, forKey: key)

        do {
            _ = try await makeSdk().resolveInstallation()
            XCTFail("损坏核心身份不得降级成一次新安装")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .storage("invalid_state"))
        }
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(defaults.data(forKey: key), corrupted)
    }

    func testValidIntegrityTokenIsIncludedInInstallationRequest() async throws {
        let token = "app-attest-short-lived-token"
        MockURLProtocol.handler = { request in
            let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
            XCTAssertEqual(payload["integrityToken"] as? String, token)
            return Self.response(
                request,
                json: #"{"attributionId":"00000000-0000-4000-8000-000000000501","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
            )
        }

        let sdk = try makeSdk(integrityProvider: FixedIntegrityTokenProvider(token: token))
        let result = try await sdk.resolveInstallation()

        XCTAssertEqual(result.processState, .provisional)
    }

    func testIntegrityProviderFailureDegradesWithoutBlockingInstallation() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
            XCTAssertNil(payload["integrityToken"])
            return Self.response(
                request,
                json: #"{"attributionId":"00000000-0000-4000-8000-000000000502","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
            )
        }

        let sdk = try makeSdk(integrityProvider: FailingIntegrityTokenProvider(error: .http(status: 503)))
        let result = try await sdk.resolveInstallation()

        XCTAssertEqual(result.processState, .provisional)
        XCTAssertEqual(requestCount, 1)
    }

    func testIntegrityProviderTimeoutDoesNotHoldInstallationGate() async throws {
        MockURLProtocol.handler = { request in
            let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
            XCTAssertNil(payload["integrityToken"])
            return Self.response(
                request,
                json: #"{"attributionId":"00000000-0000-4000-8000-000000000503","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
            )
        }

        let provider = BlockingIntegrityTokenProvider()
        defer { provider.release() }
        let sdk = try makeSdk(integrityProvider: provider)
        let startedAt = Date()
        let result = try await sdk.resolveInstallation()
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(result.processState, .provisional)
        XCTAssertGreaterThanOrEqual(elapsed, 0.8)
        XCTAssertLessThan(elapsed, 2.5)
    }

    func testOversizedIntegrityTokenIsDroppedBeforeInstallationRequest() async throws {
        MockURLProtocol.handler = { request in
            let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
            XCTAssertNil(payload["integrityToken"])
            return Self.response(
                request,
                json: #"{"attributionId":"00000000-0000-4000-8000-000000000504","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
            )
        }

        let oversized = String(repeating: "a", count: 16 * 1_024 + 1)
        let sdk = try makeSdk(integrityProvider: FixedIntegrityTokenProvider(token: oversized))
        let result = try await sdk.resolveInstallation()

        XCTAssertEqual(result.processState, .provisional)
    }

    func testIntegrityProviderCancellationPropagatesWithoutNetworkRequest() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
        }
        let sdk = try makeSdk(integrityProvider: CancelledIntegrityTokenProvider())

        do {
            _ = try await sdk.resolveInstallation()
            XCTFail("provider cancellation must cancel the current installation attempt")
        } catch is CancellationError {
            // Cancellation 是宿主生命周期控制信号，必须原样返回而不是降级或改写失败类别。
        }
        XCTAssertEqual(requestCount, 0)
    }

    func testHostCancellationStopsWaitingForNonCooperativeIntegrityProvider() async throws {
        let providerStarted = expectation(description: "integrity provider started")
        let provider = BlockingIntegrityTokenProvider(onStart: { providerStarted.fulfill() })
        defer { provider.release() }
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
        }
        let sdk = try makeSdk(integrityProvider: provider)
        let task = Task { try await sdk.resolveInstallation() }
        await fulfillment(of: [providerStarted], timeout: 2)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("宿主取消必须立即结束当前 waiter")
        } catch is CancellationError {
            // 非协作 provider 仍可稍后自行结束，但不得继续占住调用方或发起安装请求。
        }
        XCTAssertEqual(requestCount, 0)
    }

    func testClearLocalStateWhileIntegrityIsPendingPreventsOldInstallationRequest() async throws {
        let providerStarted = expectation(description: "integrity provider started")
        providerStarted.assertForOverFulfill = false
        let provider = BlockingIntegrityTokenProvider(onStart: { providerStarted.fulfill() })
        var installationPayloads: [[String: Any]] = []
        MockURLProtocol.handler = { request in
            installationPayloads.append(try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any])
            return Self.response(
                request,
                json: #"{"attributionId":"00000000-0000-4000-8000-000000000506","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
            )
        }
        let sdk = try makeSdk(integrityProvider: provider)
        let oldTask = Task { try await sdk.resolveInstallation() }
        await fulfillment(of: [providerStarted], timeout: 2)

        sdk.clearLocalState()
        provider.release()
        do {
            _ = try await oldTask.value
            XCTFail("清理后的旧安装不得继续发送")
        } catch is CancellationError {
            // 清理发生在可选完整性等待期间，旧代次在真正发网前被取消。
        }
        XCTAssertTrue(installationPayloads.isEmpty)

        _ = try await sdk.resolveInstallation()
        XCTAssertEqual(installationPayloads.count, 1)
    }

    func testIntegrityTokenUsesUtf8ByteBoundary() async throws {
        var payloads: [[String: Any]] = []
        MockURLProtocol.handler = { request in
            let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
            payloads.append(payload)
            return Self.response(
                request,
                json: #"{"attributionId":"00000000-0000-4000-8000-000000000505","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
            )
        }
        let exact = String(repeating: "a", count: 16 * 1_024)
        let exactSdk = try makeSdk(integrityProvider: FixedIntegrityTokenProvider(token: exact))
        _ = try await exactSdk.resolveInstallation()
        exactSdk.clearLocalState()

        let multibyteOversized = String(repeating: "你", count: 5_462)
        let oversizedSdk = try makeSdk(integrityProvider: FixedIntegrityTokenProvider(token: multibyteOversized))
        _ = try await oversizedSdk.resolveInstallation()

        XCTAssertEqual((payloads[0]["integrityToken"] as? String)?.utf8.count, 16 * 1_024)
        XCTAssertNil(payloads[1]["integrityToken"])
    }

    func testMultipleMatchesExposeOnlySafeBusinessDelivery() async throws {
        let result = try JSONDecoder().decode(
            AttributionResult.self,
            from: Data(#"{"attributionId":"00000000-0000-4000-8000-000000000206","processState":"FINAL","isFinal":true,"outcome":"MULTIPLE_MATCHES","status":"PROBABILISTIC_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":1,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","finalizedAt":"2026-08-24T08:00:02Z","retryAfterMs":0,"finalMatches":[{"linkId":"00000000-0000-4000-8000-000000000301","ruleKey":"icard_share","externalIdentifier":"share-1","confidenceBand":"HIGH","route":"/card/1","attributedAt":"2026-08-24T08:00:01Z"},{"linkId":"00000000-0000-4000-8000-000000000302","ruleKey":"icard_share","externalIdentifier":"share-2","confidenceBand":"HIGH","route":"/card/2","attributedAt":"2026-08-24T08:00:01Z"}],"matches":[{"linkId":"00000000-0000-4000-8000-000000000301","ruleKey":"icard_share","externalIdentifier":"share-1","confidenceBand":"HIGH","route":"/card/1","attributedAt":"2026-08-24T08:00:01Z"},{"linkId":"00000000-0000-4000-8000-000000000302","ruleKey":"icard_share","externalIdentifier":"share-2","confidenceBand":"HIGH","route":"/card/2","attributedAt":"2026-08-24T08:00:01Z"}],"matchCount":2,"linkId":"ignored-legacy","route":"/ignored-legacy"}"#.utf8)
        )

        XCTAssertEqual(result.finalMatches.map(\.externalIdentifier), ["share-1", "share-2"])
        XCTAssertEqual(result.linkId, "00000000-0000-4000-8000-000000000301")
        XCTAssertEqual(result.route, "/card/1")
        // Codable 模型没有 score/evidence/risk 成员，响应中的内部字段会在解码边界丢弃。
        let cached = try JSONEncoder().encode(result)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: cached) as? [String: Any])
        XCTAssertNil(encoded["score"])
        XCTAssertNil(encoded["risk"])
        let first = try XCTUnwrap((encoded["finalMatches"] as? [[String: Any]])?.first)
        XCTAssertNil(first["score"])
        XCTAssertNil(first["evidence"])
        XCTAssertNil(first["risk"])
    }

    func testTerminalCacheSurvivesSdkKeyRotation() async throws {
        var count = 0
        MockURLProtocol.handler = { request in
            count += 1
            return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000204","processState":"FINAL","outcome":"NO_MATCH","status":"NO_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","finalizedAt":"2026-08-24T08:00:02Z","finalMatches":[]}"#)
        }
        let first = try makeSdk(sdkKey: "ios-old-key")
        _ = try await first.resolveInstallation()
        let rotated = try makeSdk(sdkKey: "ios-rotated-key")
        _ = try await rotated.resolveInstallation()
        XCTAssertEqual(count, 1)
    }

    func testSdkKeyRotationRecoversPermanentLoginFailureWithSameFact() async throws {
        let attributionId = "00000000-0000-4000-8000-000000000261"
        let accountScope = "local_scope_000261"
        var loginPayloads: [[String: Any]] = []
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000261","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":3,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":0,"finalMatches":[]}"#
                )
            case "/v1/sdk/events/login-completed":
                let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
                loginPayloads.append(payload)
                if request.value(forHTTPHeaderField: "X-SDK-Key") == "old-ios-key" {
                    return Self.response(request, status: 401, json: #"{"error":"rotated"}"#)
                }
                return Self.response(
                    request,
                    status: 201,
                    json: #"{"confirmationId":"00000000-0000-4000-8000-000000000161","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:01:00Z","reportedAt":"2026-08-24T08:01:02Z"}"#
                )
            case "/v1/sdk/attributions/\(attributionId)":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000261","processState":"FINAL","outcome":"MATCHED","status":"PROBABILISTIC_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":4,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:01:03Z","finalizedAt":"2026-08-24T08:01:03Z","retryAfterMs":0,"finalMatches":[{"linkId":"00000000-0000-4000-8000-000000000361","ruleKey":"icard_share","externalIdentifier":"rotated-key-share","confidenceBand":"HIGH","attributedAt":"2026-08-24T08:01:03Z"}]}"#
                )
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
            }
        }
        let oldSdk = try makeSdk(sdkKey: "old-ios-key")
        try oldSdk.recordAuthenticatedLogin(accountScope: accountScope)
        do {
            _ = try await oldSdk.trackLoginCompleted()
            XCTFail("旧 Key 应被永久拒绝")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .http(status: 401))
        }

        try await Task.sleep(nanoseconds: 5_000_000)
        let newSdk = try makeSdk(sdkKey: "new-ios-key")
        let outcome = try await newSdk.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0)

        XCTAssertEqual(outcome.phase, .final)
        XCTAssertNil(outcome.result)
        XCTAssertEqual(try newSdk.pendingFinalDelivery(accountScope: accountScope)?.result.finalMatches.first?.externalIdentifier, "rotated-key-share")
        XCTAssertEqual(loginPayloads.count, 2)
        XCTAssertEqual(loginPayloads[0]["eventId"] as? String, loginPayloads[1]["eventId"] as? String)
        XCTAssertEqual(loginPayloads[0]["occurredAt"] as? String, loginPayloads[1]["occurredAt"] as? String)
        XCTAssertNotEqual(loginPayloads[0]["reportedAt"] as? String, loginPayloads[1]["reportedAt"] as? String)
    }

    func testPendingInstallationCanBePolledAndTerminalResultIsCached() async throws {
        var count = 0
        MockURLProtocol.handler = { request in
            count += 1
            switch count {
            case 1:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/v1/sdk/installations/resolve")
                return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000207","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":10,"finalMatches":[]}"#)
            case 2:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/v1/sdk/attributions/00000000-0000-4000-8000-000000000207")
                return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000207","processState":"SETTLING","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:02Z","retryAfterMs":10,"finalMatches":[]}"#)
            case 3:
                XCTAssertEqual(request.httpMethod, "GET")
                return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000207","processState":"FINAL","outcome":"NO_MATCH","status":"NO_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:03Z","finalizedAt":"2026-08-24T08:00:03Z","finalMatches":[]}"#)
            default:
                XCTFail("terminal result should be served from cache")
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }

        let sdk = try makeSdk()
        let initial = try await sdk.resolveInstallation()
        XCTAssertEqual(initial.status, .pending)
        let terminal = try await sdk.waitForAttribution(attributionId: initial.attributionId, timeout: 2, interval: 0.01)
        XCTAssertEqual(terminal.status, .noMatch)
        let cached = try await sdk.resolveInstallation()
        XCTAssertEqual(cached, terminal)
        XCTAssertEqual(count, 3)
    }

    func testAttributionQueriesRejectAnotherInstallationIdentifierBeforeNetwork() async throws {
        let currentAttributionId = "00000000-0000-4000-8000-000000000250"
        let foreignAttributionId = "00000000-0000-4000-8000-000000000251"
        var currentGetCount = 0
        var foreignGetCount = 0
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000250","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
                )
            case "/v1/sdk/attributions/\(currentAttributionId)":
                currentGetCount += 1
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000250","processState":"FINAL","outcome":"NO_MATCH","status":"NO_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":1,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:02Z","finalizedAt":"2026-08-24T08:00:02Z","finalMatches":[]}"#
                )
            case "/v1/sdk/attributions/\(foreignAttributionId)":
                foreignGetCount += 1
                return Self.response(request, status: 500, json: #"{"error":"foreign attribution must not be queried"}"#)
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }
        let sdk = try makeSdk()
        let initial = try await sdk.resolveInstallation()
        XCTAssertEqual(initial.attributionId, currentAttributionId)

        do {
            _ = try await sdk.getAttribution(attributionId: foreignAttributionId)
            XCTFail("公开单次查询不得访问同 Application 的其他安装归因")
        } catch let error as LinkAttributionError {
            guard case .invalidArgument = error else { return XCTFail("expected invalidArgument, got \(error)") }
        }
        do {
            _ = try await sdk.waitForAttribution(attributionId: foreignAttributionId, timeout: 0.5, interval: 0.01)
            XCTFail("公开轮询不得访问同 Application 的其他安装归因")
        } catch let error as LinkAttributionError {
            guard case .invalidArgument = error else { return XCTFail("expected invalidArgument, got \(error)") }
        }

        let current = try await sdk.getAttribution(attributionId: currentAttributionId)
        XCTAssertEqual(current.outcome, .noMatch)
        XCTAssertEqual(currentGetCount, 1)
        XCTAssertEqual(foreignGetCount, 0, "外部 attributionId 必须在触网前 fail-closed")
    }

    func testLoginCompletedBindsInstallationAndCachesServerTimeWithoutIdentityData() async throws {
        var loginRequestCount = 0
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000208","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#)
            case "/v1/sdk/events/login-completed":
                loginRequestCount += 1
                let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
                let installationEventId = try XCTUnwrap(payload["installationEventId"] as? String)
                let eventId = try XCTUnwrap(payload["eventId"] as? String)
                XCTAssertFalse(installationEventId.isEmpty)
                XCTAssertFalse(eventId.isEmpty)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), eventId)
                XCTAssertEqual(Set(payload.keys), ["installationEventId", "eventId", "occurredAt", "reportedAt"])
                XCTAssertNotNil(payload["occurredAt"])
                XCTAssertNotNil(payload["reportedAt"])
                XCTAssertNil(payload["account"])
                XCTAssertNil(payload["token"])
                XCTAssertNil(payload["userId"])
                XCTAssertNil(payload["signals"])
                return Self.response(request, status: 201, json: #"{"confirmationId":"00000000-0000-4000-8000-000000000101","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z"}"#)
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }
        let sdk = try makeSdk()

        let first = try await sdk.trackLoginCompleted()
        let second = try await sdk.trackLoginCompleted()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.occurredAt, "2026-08-24T08:00:00Z")
        XCTAssertEqual(first.reportedAt, "2026-08-24T08:00:01Z")
        XCTAssertEqual(loginRequestCount, 1)
    }

    func testLoginConfirmationWaitsForHigherDecisionAfterPreLoginProvisional() async throws {
        let attributionId = "00000000-0000-4000-8000-000000000252"
        let accountScope = "local_scope_000252"
        var attributionGetCount = 0
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000252","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":7,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":0,"finalMatches":[]}"#
                )
            case "/v1/sdk/events/login-completed":
                return Self.response(
                    request,
                    status: 201,
                    json: #"{"confirmationId":"00000000-0000-4000-8000-000000000152","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:01:00Z","reportedAt":"2026-08-24T08:01:01Z"}"#
                )
            case "/v1/sdk/attributions/\(attributionId)":
                attributionGetCount += 1
                if attributionGetCount <= 2 {
                    return Self.response(
                        request,
                        json: #"{"attributionId":"00000000-0000-4000-8000-000000000252","processState":"SETTLING","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":7,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:01:02Z","retryAfterMs":0,"finalMatches":[]}"#
                    )
                }
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000252","processState":"FINAL","outcome":"MATCHED","status":"PROBABILISTIC_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":8,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:01:03Z","finalizedAt":"2026-08-24T08:01:03Z","retryAfterMs":0,"finalMatches":[{"linkId":"00000000-0000-4000-8000-000000000353","ruleKey":"icard_share","externalIdentifier":"post-login-share","confidenceBand":"HIGH","attributedAt":"2026-08-24T08:01:03Z"}]}"#
                )
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }
        let sdk = try makeSdk()

        let provisional = try await sdk.resolveInstallation()
        XCTAssertEqual(provisional.decisionSequence, 7)
        try sdk.recordAuthenticatedLogin(accountScope: accountScope)
        _ = try await sdk.trackLoginCompleted()
        do {
            _ = try await sdk.waitForAttribution(attributionId: attributionId, timeout: 1, interval: 0.01)
            XCTFail("可消费 FINAL 不得从旧轮询入口暴露")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .businessDeliveryRequired)
        }

        XCTAssertEqual(attributionGetCount, 3, "门槛前旧 provisional 可重复到达，但只能等待更高追加决策")
        let delivery = try XCTUnwrap(sdk.pendingFinalDelivery(accountScope: accountScope))
        XCTAssertEqual(delivery.result.decisionSequence, 8)
        XCTAssertEqual(delivery.result.finalMatches.map(\.externalIdentifier), ["post-login-share"])
    }

    func testPreLoginConsumableFinalIsPermanentlyRejectedAndNeverReopened() async throws {
        let attributionId = "00000000-0000-4000-8000-000000000253"
        let accountScope = "local_scope_000253"
        var attributionGetCount = 0
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000253","processState":"FINAL","outcome":"MATCHED","status":"PROBABILISTIC_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":7,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","finalizedAt":"2026-08-24T08:00:01Z","retryAfterMs":0,"finalMatches":[{"linkId":"00000000-0000-4000-8000-000000000354","ruleKey":"icard_share","externalIdentifier":"invalid-pre-login-final","confidenceBand":"HIGH","attributedAt":"2026-08-24T08:00:01Z"}]}"#
                )
            case "/v1/sdk/events/login-completed":
                return Self.response(
                    request,
                    status: 201,
                    json: #"{"confirmationId":"00000000-0000-4000-8000-000000000153","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:01:00Z","reportedAt":"2026-08-24T08:01:01Z"}"#
                )
            case "/v1/sdk/attributions/\(attributionId)":
                attributionGetCount += 1
                return Self.response(request, status: 500, json: #"{"error":"rejected final must never reopen"}"#)
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }
        let sdk = try makeSdk()

        do {
            _ = try await sdk.resolveInstallation()
            XCTFail("登录门槛前的可消费 FINAL 是永久协议违例")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .invalidResponse)
        }
        try sdk.recordAuthenticatedLogin(accountScope: accountScope)
        _ = try await sdk.trackLoginCompleted()
        let stopped = try await sdk.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 1)

        XCTAssertEqual(stopped.phase, .stopped)
        XCTAssertNil(stopped.result)
        XCTAssertNil(try sdk.pendingFinalDelivery(accountScope: accountScope))
        XCTAssertEqual(attributionGetCount, 0, "FINAL 不可重开；登录后不得轮询或复活同一业务结果")
    }

    func testLoginCompletedDoesNotReopenPreLoginFinal() async throws {
        var attributionGetCount = 0
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000209","processState":"FINAL","outcome":"NO_MATCH","status":"NO_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","finalizedAt":"2026-08-24T08:00:01Z","finalMatches":[]}"#
                )
            case "/v1/sdk/events/login-completed":
                return Self.response(
                    request,
                    status: 201,
                    json: #"{"confirmationId":"00000000-0000-4000-8000-000000000102","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:02:00Z","reportedAt":"2026-08-24T08:02:01Z"}"#
                )
            case "/v1/sdk/attributions/00000000-0000-4000-8000-000000000209":
                attributionGetCount += 1
                return Self.response(request, status: 500, json: #"{"error":"final must not reopen"}"#)
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }
        let sdk = try makeSdk()

        let beforeLogin = try await sdk.resolveInstallation()
        _ = try await sdk.trackLoginCompleted()
        let afterLogin = try await sdk.resolveInstallation()

        XCTAssertEqual(beforeLogin.outcome, .noMatch)
        XCTAssertEqual(afterLogin, beforeLogin)
        XCTAssertEqual(attributionGetCount, 0, "迟到登录不得重开或覆盖已冻结 FINAL")
    }

    func testCachedFinalRejectsDifferentLaterFinal() async throws {
        let attributionId = "00000000-0000-4000-8000-000000000209"
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000209","processState":"FINAL","outcome":"NO_MATCH","status":"NO_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":1,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","finalizedAt":"2026-08-24T08:00:01Z","finalMatches":[]}"#
                )
            case "/v1/sdk/events/login-completed":
                return Self.response(
                    request,
                    status: 201,
                    json: #"{"confirmationId":"00000000-0000-4000-8000-000000000102","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:02:00Z","reportedAt":"2026-08-24T08:02:01Z"}"#
                )
            case "/v1/sdk/attributions/00000000-0000-4000-8000-000000000209":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000209","processState":"FINAL","outcome":"MATCHED","status":"PROBABILISTIC_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":2,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:02:02Z","finalizedAt":"2026-08-24T08:02:02Z","finalMatches":[{"linkId":"00000000-0000-4000-8000-000000000303","ruleKey":"icard_share","externalIdentifier":"share-after-login","confidenceBand":"HIGH","attributedAt":"2026-08-24T08:02:02Z"}]}"#
                )
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }
        let sdk = try makeSdk()

        let frozen = try await sdk.resolveInstallation()
        _ = try await sdk.trackLoginCompleted()
        do {
            _ = try await sdk.getAttribution(attributionId: attributionId)
            XCTFail("已冻结 FINAL 不得被后续不同结果覆盖")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .invalidResponse)
        }
        let recovered = try await sdk.resolveInstallation()
        XCTAssertEqual(recovered, frozen)
    }

    func testFinalDeliveryPersistsUntilMatchingAccountAcknowledges() async throws {
        let accountScope = String(repeating: "a", count: 64)
        let otherAccountScope = String(repeating: "b", count: 64)
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000239","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
                )
            case "/v1/sdk/events/login-completed":
                return Self.response(
                    request,
                    status: 201,
                    json: #"{"confirmationId":"00000000-0000-4000-8000-000000000139","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:01:00Z","reportedAt":"2026-08-24T08:01:01Z"}"#
                )
            case "/v1/sdk/attributions/00000000-0000-4000-8000-000000000239":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000239","processState":"FINAL","outcome":"MULTIPLE_MATCHES","status":"PROBABILISTIC_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":3,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:01:02Z","finalizedAt":"2026-08-24T08:01:02Z","finalMatches":[{"linkId":"00000000-0000-4000-8000-000000000339","externalIdentifier":"share-a","confidenceBand":"HIGH"},{"linkId":"00000000-0000-4000-8000-000000000340","externalIdentifier":"share-b","confidenceBand":"HIGH"}]}"#
                )
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }
        let first = try makeSdk()
        try first.recordAuthenticatedLogin(accountScope: accountScope)
        _ = try await first.resolveInstallation()
        _ = try await first.trackLoginCompleted()
        do {
            _ = try await first.resolveInstallation()
            XCTFail("resolve 不得直接暴露可消费 FINAL")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .businessDeliveryRequired)
        }
        do {
            _ = try await first.getAttribution(attributionId: "00000000-0000-4000-8000-000000000239")
            XCTFail("get 不得直接暴露可消费 FINAL")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .businessDeliveryRequired)
        }
        do {
            _ = try await first.waitForAttribution(
                attributionId: "00000000-0000-4000-8000-000000000239",
                timeout: 0.5,
                interval: 0.01
            )
            XCTFail("wait 不得直接暴露可消费 FINAL")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .businessDeliveryRequired)
        }
        let recoveryOutcome = try await first.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0)
        XCTAssertEqual(recoveryOutcome.phase, .final)
        XCTAssertNil(recoveryOutcome.result, "resume 只能通知 outbox 就绪，不能返回 share code")

        let firstDelivery = try XCTUnwrap(first.pendingFinalDelivery(accountScope: accountScope))
        XCTAssertEqual(firstDelivery.deliveryId, "00000000-0000-4000-8000-000000000239:3")
        XCTAssertEqual(firstDelivery.result.finalMatches.count, 2)
        XCTAssertNil(try first.pendingFinalDelivery(accountScope: otherAccountScope))

        let relaunched = try makeSdk()
        let recovered = try XCTUnwrap(relaunched.pendingFinalDelivery(accountScope: accountScope))
        XCTAssertEqual(recovered, firstDelivery, "未 ack 的 FINAL 必须跨进程实例恢复")
        XCTAssertThrowsError(
            try relaunched.acknowledgeFinalDelivery(deliveryId: recovered.deliveryId, accountScope: otherAccountScope)
        )
        try relaunched.acknowledgeFinalDelivery(deliveryId: recovered.deliveryId, accountScope: accountScope)
        XCTAssertNil(try relaunched.pendingFinalDelivery(accountScope: accountScope))
        XCTAssertNil(try first.pendingFinalDelivery(accountScope: accountScope), "ack 必须由共享持久状态对其他实例立即可见")
        XCTAssertTrue(try relaunched.isFinalBound(to: accountScope), "ack 只确认交付，不得删除终态诊断与路由真源")
        do {
            _ = try await relaunched.resolveInstallation()
            XCTFail("ack 后旧入口仍不得旁路 outbox 暴露 FINAL")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .businessDeliveryRequired)
        }
    }

    /// 未绑定账号时 raw 入口也不能暴露业务 FINAL；后来绑定的任意账号不得认领此前结果。
    func testUnboundRawEntrypointsHideConsumableFinalAndLateBindingIsSuppressed() async throws {
        let accountScope = String(repeating: "a", count: 64)
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000249","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
                )
            case "/v1/sdk/events/login-completed":
                return Self.response(
                    request,
                    status: 201,
                    json: #"{"confirmationId":"00000000-0000-4000-8000-000000000149","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:01:00Z","reportedAt":"2026-08-24T08:01:01Z"}"#
                )
            case "/v1/sdk/attributions/00000000-0000-4000-8000-000000000249":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000249","processState":"FINAL","outcome":"MATCHED","status":"PROBABILISTIC_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":2,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:01:02Z","finalizedAt":"2026-08-24T08:01:02Z","finalMatches":[{"linkId":"00000000-0000-4000-8000-000000000349","externalIdentifier":"legacy-unbound-share","confidenceBand":"HIGH"}]}"#
                )
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }

        let sdk = try makeSdk()
        _ = try await sdk.resolveInstallation()
        _ = try await sdk.trackLoginCompleted()
        do {
            _ = try await sdk.resolveInstallation()
            XCTFail("未绑定账号时 resolve 不得暴露业务 FINAL")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .businessDeliveryRequired)
        }
        do {
            _ = try await sdk.getAttribution(attributionId: "00000000-0000-4000-8000-000000000249")
            XCTFail("未绑定账号时 get 不得暴露业务 FINAL")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .businessDeliveryRequired)
        }
        do {
            _ = try await sdk.waitForAttribution(
                attributionId: "00000000-0000-4000-8000-000000000249",
                timeout: 0.5,
                interval: 0.01
            )
            XCTFail("未绑定账号时 wait 不得暴露业务 FINAL")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .businessDeliveryRequired)
        }
        let recoveryOutcome = try await sdk.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0)
        XCTAssertEqual(recoveryOutcome.phase, .final)
        XCTAssertNil(recoveryOutcome.result)
        XCTAssertNil(try sdk.pendingFinalDelivery(accountScope: accountScope))

        try sdk.recordAuthenticatedLogin(accountScope: accountScope)

        XCTAssertNil(try sdk.pendingFinalDelivery(accountScope: accountScope))
        XCTAssertFalse(try sdk.isFinalBound(to: accountScope))
        XCTAssertThrowsError(
            try sdk.acknowledgeFinalDelivery(
                deliveryId: "00000000-0000-4000-8000-000000000249:2",
                accountScope: accountScope
            )
        )
        do {
            _ = try await sdk.resolveInstallation()
            XCTFail("迟到账号绑定后 raw 入口仍不得暴露被抑制 FINAL")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .businessDeliveryRequired)
        }
    }

    func testFailedLoginConfirmationRetriesSameIdempotencyKeysAcrossInstances() async throws {
        var loginRequestCount = 0
        var installationEventIds: [String] = []
        var loginEventIds: [String] = []
        var loginOccurredAt: [String] = []
        var loginReportedAt: [String] = []
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000210","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#)
            case "/v1/sdk/events/login-completed":
                loginRequestCount += 1
                let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
                installationEventIds.append(try XCTUnwrap(payload["installationEventId"] as? String))
                loginEventIds.append(try XCTUnwrap(payload["eventId"] as? String))
                loginOccurredAt.append(try XCTUnwrap(payload["occurredAt"] as? String))
                loginReportedAt.append(try XCTUnwrap(payload["reportedAt"] as? String))
                if loginRequestCount == 1 {
                    return Self.response(request, status: 503, json: #"{"error":"temporary"}"#)
                }
                return Self.response(request, json: #"{"confirmationId":"00000000-0000-4000-8000-000000000103","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:01:00Z","reportedAt":"2026-08-24T08:01:02Z"}"#)
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }
        let first = try makeSdk()
        do {
            _ = try await first.trackLoginCompleted()
            XCTFail("expected temporary login confirmation failure")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .http(status: 503))
        }

        try await Task.sleep(nanoseconds: 5_000_000)
        let relaunched = try makeSdk()
        let confirmation = try await relaunched.retryPendingLoginConfirmation()

        XCTAssertEqual(confirmation?.confirmationId, "00000000-0000-4000-8000-000000000103")
        XCTAssertEqual(loginRequestCount, 2)
        XCTAssertEqual(Set(installationEventIds).count, 1)
        XCTAssertEqual(Set(loginEventIds).count, 1)
        XCTAssertEqual(Set(loginOccurredAt).count, 1)
        XCTAssertEqual(Set(loginReportedAt).count, 2)
    }

    func testLostLoginResponseDefersSameFinalUntilIdempotentConfirmationRecovers() async throws {
        let attributionId = "00000000-0000-4000-8000-000000000259"
        let accountScope = "local_scope_000259"
        var loginPayloads: [[String: Any]] = []
        var evidenceRequestCount = 0
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000259","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":7,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":0,"finalMatches":[]}"#
                )
            case "/v1/sdk/events/login-completed":
                let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
                loginPayloads.append(payload)
                if loginPayloads.count == 1 {
                    // 模拟服务端已受理，但客户端在响应到达前断网；下一次必须复用同一幂等事实。
                    throw URLError(.networkConnectionLost)
                }
                return Self.response(
                    request,
                    status: 201,
                    json: #"{"confirmationId":"00000000-0000-4000-8000-000000000159","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:01:00Z","reportedAt":"2026-08-24T08:01:02Z"}"#
                )
            case "/v1/sdk/attributions/\(attributionId)":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000259","processState":"FINAL","outcome":"MATCHED","status":"PROBABILISTIC_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":8,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:01:03Z","finalizedAt":"2026-08-24T08:01:03Z","retryAfterMs":0,"finalMatches":[{"linkId":"00000000-0000-4000-8000-000000000359","ruleKey":"icard_share","externalIdentifier":"lost-response-share","confidenceBand":"HIGH","attributedAt":"2026-08-24T08:01:03Z"}]}"#
                )
            case "/v1/sdk/installations/user-provided-evidence":
                evidenceRequestCount += 1
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }
        let sdk = try makeSdk(userProvidedEvidenceEnabled: true)
        try sdk.recordAuthenticatedLogin(accountScope: accountScope)

        do {
            _ = try await sdk.trackLoginCompleted()
            XCTFail("首次登录确认应模拟响应丢失")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .network("transport"))
        }
        do {
            _ = try await sdk.getAttribution(attributionId: attributionId)
            XCTFail("确认响应未恢复前不能暴露或缓存 FINAL")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .timeout)
        }
        XCTAssertFalse(sdk.canSubmitUserProvidedEvidence)
        let lateEvidence = await sdk.submitUserProvidedEvidence(.linkToken("first_party_token_259"))
        XCTAssertEqual(lateEvidence, .rejected)
        XCTAssertEqual(evidenceRequestCount, 0, "服务端已冻结的待确认 FINAL 不能再被主动证据重开")
        XCTAssertNil(try sdk.pendingFinalDelivery(accountScope: accountScope))

        try await Task.sleep(nanoseconds: 5_000_000)
        let relaunched = try makeSdk(userProvidedEvidenceEnabled: true)
        let outcome = try await relaunched.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0)
        let delivery = try relaunched.pendingFinalDelivery(accountScope: accountScope)

        XCTAssertEqual(outcome.phase, .final)
        XCTAssertNil(outcome.result)
        XCTAssertEqual(delivery?.result.finalMatches.map(\.externalIdentifier), ["lost-response-share"])
        XCTAssertEqual(loginPayloads.count, 2)
        XCTAssertEqual(loginPayloads[0]["eventId"] as? String, loginPayloads[1]["eventId"] as? String)
        XCTAssertEqual(loginPayloads[0]["occurredAt"] as? String, loginPayloads[1]["occurredAt"] as? String)
        XCTAssertNotEqual(loginPayloads[0]["reportedAt"] as? String, loginPayloads[1]["reportedAt"] as? String)
    }

    func testPermanentLoginFailureStopsRecoveryUntilANewRealLoginFact() async throws {
        var loginRequestCount = 0
        var loginEventIds: [String] = []
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000217","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#)
            case "/v1/sdk/events/login-completed":
                loginRequestCount += 1
                let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
                loginEventIds.append(try XCTUnwrap(payload["eventId"] as? String))
                if loginRequestCount == 1 {
                    return Self.response(request, status: 401, json: #"{"error":"invalid sdk key"}"#)
                }
                return Self.response(request, status: 201, json: #"{"confirmationId":"00000000-0000-4000-8000-000000000110","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:03:00Z","reportedAt":"2026-08-24T08:03:01Z"}"#)
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }
        let first = try makeSdk()
        do {
            _ = try await first.trackLoginCompleted()
            XCTFail("永久鉴权失败必须向显式调用方返回")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .http(status: 401))
        }

        let relaunched = try makeSdk()
        let firstRecovery = try await relaunched.retryPendingLoginConfirmation()
        let secondRecovery = try await relaunched.retryPendingLoginConfirmation()
        XCTAssertNil(firstRecovery)
        XCTAssertNil(secondRecovery)
        XCTAssertEqual(loginRequestCount, 1, "前台和重启恢复不得重复永久失败请求")

        let confirmation = try await relaunched.trackLoginCompleted()
        XCTAssertEqual(confirmation.confirmationId, "00000000-0000-4000-8000-000000000110")
        XCTAssertEqual(loginRequestCount, 2)
        XCTAssertEqual(Set(loginEventIds).count, 2, "新的真实登录必须创建新事件，而不是复活已被永久拒绝的事实")
    }

    func testUserProvidedEvidenceIsDisabledByDefaultAndNeverReadsOrSendsAnything() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
        }

        let result = await (try makeSdk()).submitUserProvidedEvidence(.linkToken("valid_token"))

        XCTAssertEqual(result, .disabled)
        XCTAssertEqual(requestCount, 0)
    }

    func testExplicitUserProvidedEvidenceSendsOnlyValidatedFirstPartyReference() async throws {
        var evidencePayload: [String: Any]?
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000211","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#)
            case "/v1/sdk/installations/user-provided-evidence":
                evidencePayload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as? [String: Any]
                return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000211","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:02Z","retryAfterMs":1000,"finalMatches":[]}"#)
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
            }
        }

        let result = await (try makeSdk(userProvidedEvidenceEnabled: true)).submitUserProvidedEvidence(
            .externalIdentifier(ruleKey: "icard_share", externalIdentifier: "share-123")
        )

        guard case .accepted = result else { return XCTFail("evidence should be accepted") }
        let payload = try XCTUnwrap(evidencePayload)
        XCTAssertEqual(Set(payload.keys), ["installationEventId", "eventId", "occurredAt", "reportedAt", "evidence"])
        let evidence = try XCTUnwrap(payload["evidence"] as? [String: Any])
        XCTAssertEqual(Set(evidence.keys), ["source", "ruleKey", "externalIdentifier"])
        XCTAssertEqual(evidence["source"] as? String, "IOS_USER_PASTE")
        XCTAssertEqual(evidence["ruleKey"] as? String, "icard_share")
        XCTAssertEqual(evidence["externalIdentifier"] as? String, "share-123")
        XCTAssertNil(evidence["clipboard"])
        XCTAssertNil(evidence["rawText"])
        XCTAssertNil(evidence["url"])
    }

    func testUserProvidedEvidenceDoesNotSendAfterFinal() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/v1/sdk/installations/resolve")
            return Self.response(
                request,
                json: #"{"attributionId":"00000000-0000-4000-8000-000000000218","processState":"FINAL","outcome":"NO_MATCH","status":"NO_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","finalizedAt":"2026-08-24T08:00:01Z","finalMatches":[]}"#
            )
        }
        let sdk = try makeSdk(userProvidedEvidenceEnabled: true)
        _ = try await sdk.resolveInstallation()

        let submission = await sdk.submitUserProvidedEvidence(.linkToken("link_token_123"))
        let recovery = await sdk.retryPendingUserProvidedEvidence()

        XCTAssertEqual(submission, .rejected)
        XCTAssertEqual(recovery, .rejected)
        XCTAssertEqual(requestCount, 1, "FINAL 后不得再创建或发送主动证据")
    }

    func testUserProvidedEvidenceStopsWhenInitialResolveBecomesFinal() async throws {
        var resolveRequestCount = 0
        var evidenceRequestCount = 0
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                resolveRequestCount += 1
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000219","processState":"FINAL","outcome":"NO_MATCH","status":"NO_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","finalizedAt":"2026-08-24T08:00:01Z","finalMatches":[]}"#
                )
            case "/v1/sdk/installations/user-provided-evidence":
                evidenceRequestCount += 1
                return Self.response(request, status: 500, json: #"{"error":"must not send after final"}"#)
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }
        let sdk = try makeSdk(userProvidedEvidenceEnabled: true)

        let submission = await sdk.submitUserProvidedEvidence(.linkToken("link_token_123"))
        let recovery = await sdk.retryPendingUserProvidedEvidence()

        XCTAssertEqual(submission, .rejected)
        XCTAssertEqual(recovery, .rejected)
        XCTAssertEqual(resolveRequestCount, 1)
        XCTAssertEqual(evidenceRequestCount, 0, "安装登记冻结 FINAL 后不得再触发主动证据接口")
    }

    func testUserProvidedEvidenceWaitsAcrossRelaunchForHigherFinalDecision() async throws {
        let accountScope = "local_scope_000212"
        var attributionGetCount = 0
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000212","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#)
            case "/v1/sdk/installations/user-provided-evidence":
                // 证据端点只确认受理并触发 Worker；返回当前旧决策，不得被当成内联归因结果。
                return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000212","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_USER_PROVIDED_LINK","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:02Z","retryAfterMs":0,"finalMatches":[]}"#)
            case "/v1/sdk/events/login-completed":
                return Self.response(
                    request,
                    status: 201,
                    json: #"{"confirmationId":"00000000-0000-4000-8000-000000000104","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:01:00Z","reportedAt":"2026-08-24T08:01:01Z"}"#
                )
            case "/v1/sdk/attributions/00000000-0000-4000-8000-000000000212":
                attributionGetCount += 1
                if attributionGetCount <= 2 {
                    return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000212","processState":"SETTLING","status":"PENDING","resolverType":"IOS_USER_PROVIDED_LINK","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:03Z","retryAfterMs":0,"finalMatches":[]}"#)
                }
                return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000212","processState":"FINAL","outcome":"MATCHED","status":"PROBABILISTIC_MATCH","resolverType":"IOS_USER_PROVIDED_LINK","decisionSequence":1,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:04Z","finalizedAt":"2026-08-24T08:00:04Z","finalMatches":[{"linkId":"00000000-0000-4000-8000-000000000305","externalIdentifier":"share-123","confidenceBand":"HIGH"}]}"#)
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
            }
        }

        let sdk = try makeSdk(userProvidedEvidenceEnabled: true)
        let submission = await sdk.submitUserProvidedEvidence(
            .externalIdentifier(ruleKey: "icard_share", externalIdentifier: "share-123")
        )
        guard case .accepted = submission else { return XCTFail("evidence should be accepted") }
        try sdk.recordAuthenticatedLogin(accountScope: accountScope)
        _ = try await sdk.trackLoginCompleted()

        let firstAttempt = try await sdk.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0)
        let relaunched = try makeSdk(userProvidedEvidenceEnabled: true)
        let secondAttempt = try await relaunched.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0)
        let recovered = try makeSdk(userProvidedEvidenceEnabled: true)
        let finalAttempt = try await recovered.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0)
        let delivery = try XCTUnwrap(recovered.pendingFinalDelivery(accountScope: accountScope))

        XCTAssertEqual(firstAttempt.phase, .retryScheduled)
        XCTAssertEqual(secondAttempt.phase, .retryScheduled)
        XCTAssertEqual(finalAttempt.phase, .final)
        XCTAssertNil(finalAttempt.result, "恢复入口不得绕过账号 outbox 暴露可消费 FINAL")
        XCTAssertEqual(attributionGetCount, 3)
        XCTAssertEqual(delivery.result.finalMatches.first?.externalIdentifier, "share-123")
        XCTAssertEqual(delivery.result.resolverType, .iOSUserProvidedLink)
    }

    func testUserProvidedEvidenceNetworkFailureDefersAndRetriesSameFactAcrossRelaunch() async throws {
        var evidencePayloads: [[String: Any]] = []
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000213","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#)
            case "/v1/sdk/installations/user-provided-evidence":
                evidencePayloads.append(try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any])
                if evidencePayloads.count == 1 {
                    return Self.response(request, status: 503, json: #"{"error":"temporary"}"#)
                }
                return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000213","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:03Z","retryAfterMs":1000,"finalMatches":[]}"#)
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
            }
        }

        let first = await (try makeSdk(userProvidedEvidenceEnabled: true)).submitUserProvidedEvidence(.linkToken("link_token_123"))
        XCTAssertEqual(first, .deferred)
        try await Task.sleep(nanoseconds: 5_000_000)
        let retried = await (try makeSdk(userProvidedEvidenceEnabled: true)).retryPendingUserProvidedEvidence()

        guard case .accepted = retried else { return XCTFail("pending evidence should retry") }
        XCTAssertEqual(evidencePayloads.count, 2)
        XCTAssertEqual(evidencePayloads[0]["eventId"] as? String, evidencePayloads[1]["eventId"] as? String)
        XCTAssertEqual(evidencePayloads[0]["occurredAt"] as? String, evidencePayloads[1]["occurredAt"] as? String)
        XCTAssertNotEqual(evidencePayloads[0]["reportedAt"] as? String, evidencePayloads[1]["reportedAt"] as? String)
    }

    func testCancelledUserProvidedEvidenceKeepsSameFactForRelaunchRecovery() async throws {
        var evidencePayloads: [[String: Any]] = []
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000215","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
                )
            case "/v1/sdk/installations/user-provided-evidence":
                evidencePayloads.append(try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any])
                if evidencePayloads.count == 1 {
                    throw URLError(.cancelled)
                }
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000215","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:03Z","retryAfterMs":1000,"finalMatches":[]}"#
                )
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
            }
        }

        let first = await (try makeSdk(userProvidedEvidenceEnabled: true)).submitUserProvidedEvidence(.linkToken("link_token_123"))
        XCTAssertEqual(first, .deferred)
        try await Task.sleep(nanoseconds: 5_000_000)
        let retried = await (try makeSdk(userProvidedEvidenceEnabled: true)).retryPendingUserProvidedEvidence()

        XCTAssertEqual(retried, .accepted)
        XCTAssertEqual(evidencePayloads.count, 2)
        XCTAssertEqual(evidencePayloads[0]["eventId"] as? String, evidencePayloads[1]["eventId"] as? String)
        XCTAssertEqual(evidencePayloads[0]["occurredAt"] as? String, evidencePayloads[1]["occurredAt"] as? String)
        XCTAssertNotEqual(evidencePayloads[0]["reportedAt"] as? String, evidencePayloads[1]["reportedAt"] as? String)
    }

    func testPermanentUserProvidedEvidenceFailureClearsPendingFact() async throws {
        var evidenceRequestCount = 0
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000214","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
                )
            case "/v1/sdk/installations/user-provided-evidence":
                evidenceRequestCount += 1
                return Self.response(request, status: 409, json: #"{"error":{"code":"ATTRIBUTION_ALREADY_FINAL","message":"already final"}}"#)
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }
        let sdk = try makeSdk(userProvidedEvidenceEnabled: true)

        let first = await sdk.submitUserProvidedEvidence(.linkToken("link_token_123"))
        let retry = await sdk.retryPendingUserProvidedEvidence()

        XCTAssertEqual(first, .rejected)
        XCTAssertNil(retry, "永久业务冲突必须清除待办，不能在后台无限触网")
        XCTAssertEqual(evidenceRequestCount, 1)
    }

    func testInvalidUserProvidedEvidenceIsRejectedWithoutNetworkOrPersistence() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
        }
        let sdk = try makeSdk(userProvidedEvidenceEnabled: true)

        let rejectedEvidence: [IOSUserProvidedEvidence] = [
            .linkToken("ICard 分享邀请\n https://go.example.test/s/link_token_123 \n立即打开"),
            .externalIdentifier(ruleKey: "icard_share", externalIdentifier: "分享码"),
            .externalIdentifier(ruleKey: "icard_share", externalIdentifier: "share:123"),
            .externalIdentifier(ruleKey: "icard_share", externalIdentifier: "-share"),
        ]
        for evidence in rejectedEvidence {
            let result = await sdk.submitUserProvidedEvidence(evidence)
            XCTAssertEqual(result, .rejected)
        }
        let pending = await sdk.retryPendingUserProvidedEvidence()

        XCTAssertNil(pending)
        XCTAssertEqual(requestCount, 0)
        XCTAssertFalse(
            defaults.dictionaryRepresentation().keys.contains(where: { $0.hasSuffix(".installation.v3") }),
            "标题、换行和完整业务链接必须由宿主在内存中解析；SDK 不得保存整段用户输入"
        )
    }

    func testLoginPendingIsPersistedBeforeInstallationFailureAndRecoveredAfterRelaunch() async throws {
        var installationRequestCount = 0
        var loginRequestCount = 0
        var installationEventIds: [String] = []
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                installationRequestCount += 1
                let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
                installationEventIds.append(try XCTUnwrap(payload["eventId"] as? String))
                if installationRequestCount == 1 {
                    return Self.response(request, status: 503, json: #"{"error":"temporary"}"#)
                }
                return Self.response(request, json: #"{"attributionId":"00000000-0000-4000-8000-000000000215","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:03Z","retryAfterMs":1000,"finalMatches":[]}"#)
            case "/v1/sdk/events/login-completed":
                loginRequestCount += 1
                return Self.response(request, json: #"{"confirmationId":"00000000-0000-4000-8000-000000000105","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:02:00Z","reportedAt":"2026-08-24T08:02:01Z"}"#)
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }
        let first = try makeSdk()
        do {
            _ = try await first.trackLoginCompleted()
            XCTFail("expected temporary installation registration failure")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .http(status: 503))
        }

        let relaunched = try makeSdk()
        let confirmation = try await relaunched.retryPendingLoginConfirmation()

        XCTAssertEqual(confirmation?.confirmationId, "00000000-0000-4000-8000-000000000105")
        XCTAssertEqual(installationRequestCount, 2)
        XCTAssertEqual(loginRequestCount, 1)
        XCTAssertEqual(Set(installationEventIds).count, 1)
    }

    func testConcurrentInstallationLoginAndUserEvidencePreserveBothDurableFacts() async throws {
        let installationStarted = expectation(description: "installation request started")
        let releaseInstallation = DispatchSemaphore(value: 0)
        let recorderLock = NSLock()
        var loginPayloads: [[String: Any]] = []
        var evidencePayloads: [[String: Any]] = []
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                installationStarted.fulfill()
                _ = releaseInstallation.wait(timeout: .now() + 2)
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000216","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
                )
            case "/v1/sdk/events/login-completed":
                let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
                recorderLock.lock()
                loginPayloads.append(payload)
                recorderLock.unlock()
                return Self.response(
                    request,
                    status: 201,
                    json: #"{"confirmationId":"00000000-0000-4000-8000-000000000106","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:01:00Z","reportedAt":"2026-08-24T08:01:02Z"}"#
                )
            case "/v1/sdk/installations/user-provided-evidence":
                let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
                recorderLock.lock()
                evidencePayloads.append(payload)
                let count = evidencePayloads.count
                recorderLock.unlock()
                if count == 1 {
                    return Self.response(request, status: 503, json: #"{"error":"temporary"}"#)
                }
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000216","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:01:03Z","retryAfterMs":1000,"finalMatches":[]}"#
                )
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }
        let sdk = try makeSdk(userProvidedEvidenceEnabled: true)
        let installationTask = Task { try await sdk.resolveInstallation() }
        await fulfillment(of: [installationStarted], timeout: 2)
        let loginTask = Task { try await sdk.trackLoginCompleted() }
        let evidenceTask = Task {
            await sdk.submitUserProvidedEvidence(
                .externalIdentifier(ruleKey: "icard_share", externalIdentifier: "share-concurrent")
            )
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        releaseInstallation.signal()

        _ = try await installationTask.value
        _ = try? await loginTask.value
        let firstEvidenceResult = await evidenceTask.value
        XCTAssertTrue(firstEvidenceResult == .deferred || firstEvidenceResult == .accepted)

        let relaunched = try makeSdk(userProvidedEvidenceEnabled: true)
        let recoveredEvidence = await relaunched.retryPendingUserProvidedEvidence()
        let recoveredLogin = try await relaunched.retryPendingLoginConfirmation()

        XCTAssertTrue(
            recoveredEvidence == nil || recoveredEvidence == .accepted,
            "unexpected recovered evidence result: \(String(describing: recoveredEvidence))"
        )
        XCTAssertTrue(recoveredLogin == nil || recoveredLogin?.confirmationId == "00000000-0000-4000-8000-000000000106")
        XCTAssertEqual(loginPayloads.count, 1)
        XCTAssertEqual(evidencePayloads.count, 2)
        XCTAssertEqual(evidencePayloads[0]["eventId"] as? String, evidencePayloads[1]["eventId"] as? String)
        XCTAssertEqual(evidencePayloads[0]["occurredAt"] as? String, evidencePayloads[1]["occurredAt"] as? String)
    }

    func testClearLocalStateDropsLateInstallationResponseWithoutRecreatingOldGeneration() async throws {
        let firstRequestStarted = expectation(description: "first installation request started")
        let releaseFirstRequest = DispatchSemaphore(value: 0)
        var installationPayloads: [[String: Any]] = []
        var installationCount = 0
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                installationCount += 1
                let payload = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
                installationPayloads.append(payload)
                if installationCount == 1 {
                    firstRequestStarted.fulfill()
                    _ = releaseFirstRequest.wait(timeout: .now() + 2)
                }
                let suffix = installationCount == 1 ? "000000000271" : "000000000272"
                return Self.response(
                    request,
                    json: "{\"attributionId\":\"00000000-0000-4000-8000-\(suffix)\",\"processState\":\"PROVISIONAL\",\"status\":\"PENDING\",\"resolverType\":\"IOS_PROBABILISTIC_INSTALL\",\"decisionSequence\":0,\"occurredAt\":\"2026-08-24T08:00:00Z\",\"reportedAt\":\"2026-08-24T08:00:01Z\",\"retryAfterMs\":1000,\"finalMatches\":[]}"
                )
            case "/v1/sdk/events/login-completed":
                return Self.response(
                    request,
                    status: 201,
                    json: #"{"confirmationId":"00000000-0000-4000-8000-000000000172","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:01:00Z","reportedAt":"2026-08-24T08:01:01Z"}"#
                )
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
            }
        }
        let sdk = try makeSdk()
        let oldTask = Task { try await sdk.resolveInstallation() }
        await fulfillment(of: [firstRequestStarted], timeout: 2)

        sdk.clearLocalState()
        try sdk.recordAuthenticatedLogin(accountScope: "local_scope_000272")
        releaseFirstRequest.signal()
        do {
            _ = try await oldTask.value
            XCTFail("旧安装迟到响应必须按取消丢弃")
        } catch is CancellationError {
            // 旧请求不能复活已清理代次。
        }

        let confirmation = try await sdk.trackLoginCompleted()
        XCTAssertEqual(confirmation.confirmationId, "00000000-0000-4000-8000-000000000172")
        XCTAssertEqual(installationPayloads.count, 2)
        XCTAssertNotEqual(installationPayloads[0]["eventId"] as? String, installationPayloads[1]["eventId"] as? String)
    }

    func testClearLocalStatePreventsLateRecoveryFailureFromSchedulingNewGeneration() async throws {
        let oldRequestStarted = expectation(description: "old recovery request started")
        let releaseOldRequest = DispatchSemaphore(value: 0)
        var installationCount = 0
        var attributionQueryCount = 0
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                installationCount += 1
                if installationCount == 1 {
                    oldRequestStarted.fulfill()
                    _ = releaseOldRequest.wait(timeout: .now() + 2)
                    return Self.response(request, status: 503, json: #"{"error":"late old failure"}"#)
                }
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000273","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
                )
            case "/v1/sdk/attributions/00000000-0000-4000-8000-000000000273":
                attributionQueryCount += 1
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000273","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
                )
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
            }
        }
        let sdk = try makeSdk()
        let oldRecovery = Task { try await sdk.resumePendingAttribution(trigger: .appLaunch, pollingTimeout: 0) }
        await fulfillment(of: [oldRequestStarted], timeout: 2)

        sdk.clearLocalState()
        try sdk.bindAuthenticatedAccount(scope: "local_scope_000273")
        releaseOldRequest.signal()
        do {
            _ = try await oldRecovery.value
            XCTFail("旧恢复失败不得给新安装写退避")
        } catch is CancellationError {
            // expected
        }

        _ = try await sdk.resolveInstallation()
        let outcome = try await sdk.resumePendingAttribution(trigger: .appLaunch, pollingTimeout: 0)
        XCTAssertEqual(outcome.phase, .waitingForLogin)
        XCTAssertEqual(installationCount, 2)
        XCTAssertEqual(attributionQueryCount, 1)
    }

    func testClearLocalStatePreventsLateLoginRejectionFromStoppingNewGeneration() async throws {
        let oldLoginStarted = expectation(description: "old login request started")
        let releaseOldLogin = DispatchSemaphore(value: 0)
        var installationCount = 0
        var loginCount = 0
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                installationCount += 1
                let suffix = installationCount == 1 ? "000000000274" : "000000000275"
                return Self.response(
                    request,
                    json: "{\"attributionId\":\"00000000-0000-4000-8000-\(suffix)\",\"processState\":\"PROVISIONAL\",\"status\":\"PENDING\",\"resolverType\":\"IOS_PROBABILISTIC_INSTALL\",\"decisionSequence\":0,\"occurredAt\":\"2026-08-24T08:00:00Z\",\"reportedAt\":\"2026-08-24T08:00:01Z\",\"retryAfterMs\":1000,\"finalMatches\":[]}"
                )
            case "/v1/sdk/events/login-completed":
                loginCount += 1
                if loginCount == 1 {
                    oldLoginStarted.fulfill()
                    _ = releaseOldLogin.wait(timeout: .now() + 2)
                    return Self.response(request, status: 401, json: #"{"error":"old login rejected"}"#)
                }
                return Self.response(
                    request,
                    status: 201,
                    json: #"{"confirmationId":"00000000-0000-4000-8000-000000000175","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:01:00Z","reportedAt":"2026-08-24T08:01:01Z"}"#
                )
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
            }
        }
        let sdk = try makeSdk()
        _ = try await sdk.resolveInstallation()
        try sdk.recordAuthenticatedLogin(accountScope: "local_scope_000274")
        let oldLogin = Task { try await sdk.trackLoginCompleted() }
        await fulfillment(of: [oldLoginStarted], timeout: 2)

        sdk.clearLocalState()
        try sdk.recordAuthenticatedLogin(accountScope: "local_scope_000275")
        releaseOldLogin.signal()
        do {
            _ = try await oldLogin.value
            XCTFail("旧登录应返回原永久失败")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .http(status: 401))
        }

        let confirmation = try await sdk.trackLoginCompleted()
        XCTAssertEqual(confirmation.confirmationId, "00000000-0000-4000-8000-000000000175")
        XCTAssertEqual(installationCount, 2)
        XCTAssertEqual(loginCount, 2)
    }

    func testPendingLoginRetryCannotCreateLoginFactAfterLocalStateWasCleared() async throws {
        let queryStarted = expectation(description: "old attribution query started")
        let releaseQuery = DispatchSemaphore(value: 0)
        var loginCount = 0
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000276","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
                )
            case "/v1/sdk/attributions/00000000-0000-4000-8000-000000000276":
                queryStarted.fulfill()
                _ = releaseQuery.wait(timeout: .now() + 2)
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000276","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:02Z","retryAfterMs":1000,"finalMatches":[]}"#
                )
            case "/v1/sdk/events/login-completed":
                loginCount += 1
                return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
            }
        }
        let sdk = try makeSdk()
        let provisional = try await sdk.resolveInstallation()
        try sdk.recordAuthenticatedLogin(accountScope: "local_scope_000276")
        let oldQuery = Task { try await sdk.getAttribution(attributionId: provisional.attributionId) }
        await fulfillment(of: [queryStarted], timeout: 2)
        let retry = Task { try await sdk.retryPendingLoginConfirmation() }
        try await Task.sleep(nanoseconds: 10_000_000)

        sdk.clearLocalState()
        releaseQuery.signal()
        _ = try? await oldQuery.value
        do {
            _ = try await retry.value
            XCTFail("旧安装登录重试不得在清理后创建新登录事实")
        } catch is CancellationError {
            // retry 冻结 A 的 eventId；释放网络门禁后发现代次已删除，必须取消而不是在 B 上造登录。
        }

        XCTAssertFalse(sdk.hasRecordedLoginCompletedFact)
        XCTAssertEqual(loginCount, 0)
    }

    func testPendingUserEvidenceIsFlushedBeforeLoginCanFreezeFinal() async throws {
        var evidenceRequestCount = 0
        var decisionInputOrder: [String] = []
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000217","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
                )
            case "/v1/sdk/installations/user-provided-evidence":
                evidenceRequestCount += 1
                decisionInputOrder.append("evidence")
                if evidenceRequestCount == 1 {
                    return Self.response(request, status: 503, json: #"{"error":"temporary"}"#)
                }
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000217","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_USER_PROVIDED_LINK","occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:03Z","retryAfterMs":1000,"finalMatches":[]}"#
                )
            case "/v1/sdk/events/login-completed":
                decisionInputOrder.append("login")
                return Self.response(
                    request,
                    status: 201,
                    json: #"{"confirmationId":"00000000-0000-4000-8000-000000000107","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:01:00Z","reportedAt":"2026-08-24T08:01:01Z"}"#
                )
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
            }
        }
        let sdk = try makeSdk(userProvidedEvidenceEnabled: true)

        let initialEvidence = await sdk.submitUserProvidedEvidence(
            .externalIdentifier(ruleKey: "icard_share", externalIdentifier: "share-before-login")
        )
        XCTAssertEqual(initialEvidence, .deferred)
        let confirmation = try await sdk.trackLoginCompleted()
        let remainingEvidence = await sdk.retryPendingUserProvidedEvidence()

        XCTAssertEqual(confirmation.confirmationId, "00000000-0000-4000-8000-000000000107")
        XCTAssertEqual(decisionInputOrder, ["evidence", "evidence", "login"])
        XCTAssertNil(remainingEvidence)
    }

    func testRetryWithoutPendingLoginDoesNotCreateLoginFactOrRequest() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            return Self.response(request, status: 500, json: #"{"error":"unexpected request"}"#)
        }
        let sdk = try makeSdk()

        let confirmation = try await sdk.retryPendingLoginConfirmation()

        XCTAssertNil(confirmation)
        XCTAssertEqual(requestCount, 0)
    }

    func testHTTPFailureHasStableTypedError() async throws {
        MockURLProtocol.handler = { request in
            Self.response(request, status: 401, json: #"{"error":"unauthorized"}"#)
        }
        let sdk = try makeSdk()

        do {
            _ = try await sdk.resolveLink(token: "token_123")
            XCTFail("expected HTTP error")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .http(status: 401))
        }
    }

    func testSuccessfulResponseRejectsWrongContentType() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            return (
                response,
                Data(#"{"linkId":"l1","revisionId":"r1","route":"/invite","schemaVersion":3,"params":{},"destinations":[]}"#.utf8)
            )
        }

        do {
            _ = try await makeSdk().resolveLink(token: "wrong-mime")
            XCTFail("2xx 非 JSON 媒体类型必须拒绝")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testSuccessfulResponseAcceptsJSONSuffixMediaType() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "Application/Vnd.Link+Json; Charset=UTF-8"]
            )!
            return (
                response,
                Data(#"{"linkId":"l1","revisionId":"r1","route":"/invite","schemaVersion":3,"params":{},"destinations":[]}"#.utf8)
            )
        }

        let resolved = try await makeSdk().resolveLink(token: "vendor-json")
        XCTAssertEqual(resolved.route, "/invite")
    }

    func testSuccessfulResponseRejectsBodyLargerThanTwoMiB() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(repeating: 0x20, count: 2 * 1_024 * 1_024 + 1))
        }

        do {
            _ = try await makeSdk().resolveLink(token: "large-response")
            XCTFail("超过 2 MiB 的成功正文必须拒绝")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testSuccessfulResponseRejectsInvalidUTF8BeforeJSONDecode() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data([0x7B, 0x22, 0x78, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D]))
        }

        do {
            _ = try await makeSdk().resolveLink(token: "invalid-utf8")
            XCTFail("非法 UTF-8 不得交给 JSON 模型容错")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testApiOriginAndCacheScopeAreCanonicalizedWithoutForkingInstallation() async throws {
        var payloads: [[String: Any]] = []
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString.hasPrefix("https://api.example.test/"), true)
            XCTAssertNil(request.url?.port)
            payloads.append(try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any])
            if payloads.count == 1 {
                return Self.response(request, status: 503, json: #"{"error":"temporary"}"#)
            }
            return Self.response(
                request,
                json: #"{"attributionId":"00000000-0000-4000-8000-000000000210","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
            )
        }
        do {
            _ = try await makeSdk(
                apiBaseURL: URL(string: "https://API.EXAMPLE.TEST:443/")!,
                cacheScope: "  project-a/production/ios  "
            ).resolveInstallation()
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .http(status: 503))
        }
        _ = try await makeSdk().resolveInstallation()

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0]["eventId"] as? String, payloads[1]["eventId"] as? String)
        XCTAssertEqual(payloads[0]["occurredAt"] as? String, payloads[1]["occurredAt"] as? String)
        XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasSuffix(".installation.v3") }.count, 1)
    }

    func testApiBaseURLRejectsPathBeforeAnyNetworkRequest() throws {
        XCTAssertThrowsError(
            try makeSdk(apiBaseURL: URL(string: "https://api.example.test/v1")!)
        ) { error in
            guard case LinkAttributionError.invalidConfiguration = error else {
                return XCTFail("expected invalidConfiguration, got \(error)")
            }
        }
    }

    func testOpaqueLinkTokensRejectPathInjectionBeforeNetwork() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
        }
        let sdk = try makeSdk()
        for token in ["../admin", "part/other", "%2Fsecret", "token?query", "token#fragment", "短链token"] {
            do {
                _ = try await sdk.resolveLink(token: token)
                XCTFail("非法路径 token 应在本地拒绝: \(token)")
            } catch let error as LinkAttributionError {
                guard case .invalidArgument = error else {
                    return XCTFail("expected invalidArgument, got \(error)")
                }
            }
        }
        XCTAssertEqual(requestCount, 0)
    }

    func testHTTP409AlwaysUsesStablePermanentCategoryWithoutLeakingBody() async throws {
        MockURLProtocol.handler = { request in
            Self.response(request, status: 409, json: #"{"error":{"code":"GENERIC_CONFLICT","message":"conflict"}}"#)
        }
        let sdk = try makeSdk()
        do {
            _ = try await sdk.resolveLink(token: "token_123")
            XCTFail("expected ordinary conflict")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .http(status: 409))
        }

        MockURLProtocol.handler = { request in
            Self.response(request, status: 409, json: #"{"error":{"code":"ATTRIBUTION_ALREADY_FINAL","message":"already final"}}"#)
        }
        do {
            _ = try await sdk.resolveLink(token: "token_123")
            XCTFail("expected permanent conflict")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .http(status: 409))
        }

        MockURLProtocol.handler = { request in
            Self.response(request, status: 409, json: #"{"code":"ATTRIBUTION_ALREADY_FINAL"}"#)
        }
        do {
            _ = try await sdk.resolveLink(token: "token_123")
            XCTFail("非平台 error envelope 不得触发终态特判")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .http(status: 409))
        }
    }

    func testSdkNeverFollowsRedirectAndRejectsMismatchedResponseOrigin() async throws {
        for location in ["https://evil.example/steal", "https://api.example.test/other"] {
            var requests: [URLRequest] = []
            MockURLProtocol.handler = { request in
                requests.append(request)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 302,
                    httpVersion: nil,
                    headerFields: ["Location": location]
                )!
                return (response, Data())
            }
            let sdk = try makeSdk()
            do {
                _ = try await sdk.resolveLink(token: "redirect-token")
                XCTFail("SDK 请求不得跟随重定向")
            } catch let error as LinkAttributionError {
                XCTAssertEqual(error, .http(status: 302))
            }
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.url?.host, "api.example.test")
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-SDK-Key"), "ios-key")
        }

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: URL(string: "https://evil.example/forged")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"linkId":"l1","revisionId":"r1","route":"/invite","navigationSessionId":"00000000-0000-4000-8000-000000000031","schemaVersion":3,"params":{},"destinations":[]}"#.utf8)
            )
        }
        let sdk = try makeSdk()
        do {
            _ = try await sdk.resolveLink(token: "forged-origin")
            XCTFail("最终响应 origin 不匹配时必须拒绝")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testAttributionGetAlwaysBypassesLocalCache() async throws {
        let attributionId = "00000000-0000-4000-8000-000000000462"
        var getCount = 0
        MockURLProtocol.handler = { request in
            if request.url?.path == "/v1/sdk/installations/resolve" {
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000462","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":1,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
                )
            }
            getCount += 1
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Pragma"), "no-cache")
            return Self.response(
                request,
                json: #"{"attributionId":"00000000-0000-4000-8000-000000000462","processState":"SETTLING","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":2,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:02Z","retryAfterMs":1000,"finalMatches":[]}"#
            )
        }
        let sdk = try makeSdk()
        _ = try await sdk.resolveInstallation()

        let result = try await sdk.getAttribution(attributionId: attributionId)

        XCTAssertEqual(result.decisionSequence, 2)
        XCTAssertEqual(getCount, 1)
    }

    func testOnlyTransientFailuresAreRetryableAndTransportDetailsAreRedacted() async throws {
        [408, 425, 429, 500, 503, 599].forEach {
            XCTAssertTrue(LinkAttributionError.http(status: $0).isRetryable, "\($0)")
        }
        [400, 401, 403, 404, 409, 422, 600].forEach {
            XCTAssertFalse(LinkAttributionError.http(status: $0).isRetryable, "\($0)")
        }
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let sdk = try makeSdk()
        do {
            _ = try await sdk.resolveLink(token: "token_123")
            XCTFail("expected network error")
        } catch let error as LinkAttributionError {
            XCTAssertEqual(error, .network("transport"))
            XCTAssertTrue(error.isRetryable)
        }
    }

    func testRecoveryBackoffPersistsAcrossRelaunchAndNetworkWakeBypassesDelay() async throws {
        var requestCount = 0
        var installationPayloads: [[String: Any]] = []
        MockURLProtocol.handler = { request in
            requestCount += 1
            installationPayloads.append(try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any])
            if requestCount == 1 {
                return Self.response(request, status: 503, json: #"{"error":{"code":"TEMPORARY","message":"retry"}}"#)
            }
            return Self.response(
                request,
                json: #"{"attributionId":"00000000-0000-4000-8000-000000000401","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:03Z","retryAfterMs":1000,"finalMatches":[]}"#
            )
        }

        let first = try makeSdk()
        let failed = try await first.resumePendingAttribution(trigger: .appLaunch, pollingTimeout: 0)
        XCTAssertEqual(failed.phase, .retryScheduled)
        XCTAssertEqual(failed.failure, .http(status: 503))
        XCTAssertNotNil(failed.nextRetryAt)

        let relaunched = try makeSdk()
        let notDue = try await relaunched.resumePendingAttribution(trigger: .appLaunch, pollingTimeout: 0)
        XCTAssertEqual(notDue.phase, .notDue)
        XCTAssertEqual(requestCount, 1, "冷启动必须延续持久退避，不能从零开始打接口")

        let recovered = try await relaunched.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0)
        XCTAssertEqual(recovered.phase, .waitingForLogin)
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(installationPayloads[0]["eventId"] as? String, installationPayloads[1]["eventId"] as? String)
        XCTAssertEqual(installationPayloads[0]["occurredAt"] as? String, installationPayloads[1]["occurredAt"] as? String)
        XCTAssertNotEqual(installationPayloads[0]["reportedAt"] as? String, installationPayloads[1]["reportedAt"] as? String)
    }

    func testEquivalentConcurrentRecoveryAcrossInstancesCountsOneFailure() async throws {
        let requestStarted = expectation(description: "shared recovery request started")
        let releaseRequest = DispatchSemaphore(value: 0)
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            requestStarted.fulfill()
            _ = releaseRequest.wait(timeout: .now() + 2)
            return Self.response(request, status: 503, json: #"{"error":"temporary"}"#)
        }
        let first = try makeSdk()
        let second = try makeSdk()
        let firstTask = Task { try await first.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0) }
        await fulfillment(of: [requestStarted], timeout: 2)
        let secondTask = Task { try await second.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0) }
        try await Task.sleep(nanoseconds: 10_000_000)
        releaseRequest.signal()

        let firstOutcome = try await firstTask.value
        let secondOutcome = try await secondTask.value

        XCTAssertEqual(firstOutcome.phase, .retryScheduled)
        XCTAssertEqual(secondOutcome, firstOutcome)
        XCTAssertEqual(requestCount, 1)
    }

    func testEquivalentRecoverySharesGateAcrossDistinctUserDefaultsObjectsForSameSuite() async throws {
        let requestStarted = expectation(description: "shared suite recovery request started")
        let releaseRequest = DispatchSemaphore(value: 0)
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            requestStarted.fulfill()
            _ = releaseRequest.wait(timeout: .now() + 2)
            return Self.response(request, status: 503, json: #"{"error":"temporary"}"#)
        }
        let firstDefaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        let first = try makeSdk(userDefaults: firstDefaults)
        let second = try makeSdk(userDefaults: secondDefaults)
        let firstTask = Task { try await first.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0) }
        await fulfillment(of: [requestStarted], timeout: 2)
        let secondTask = Task { try await second.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0) }
        try await Task.sleep(nanoseconds: 10_000_000)
        releaseRequest.signal()

        let firstOutcome = try await firstTask.value
        let secondOutcome = try await secondTask.value

        XCTAssertEqual(firstOutcome.phase, .retryScheduled)
        XCTAssertEqual(secondOutcome, firstOutcome)
        XCTAssertEqual(requestCount, 1)
    }

    func testConcurrentForegroundAndNetworkWakeSignalsCountOneFailure() async throws {
        let requestStarted = expectation(description: "wake recovery request started")
        let releaseRequest = DispatchSemaphore(value: 0)
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            requestStarted.fulfill()
            _ = releaseRequest.wait(timeout: .now() + 2)
            return Self.response(request, status: 503, json: #"{"error":"temporary"}"#)
        }
        let sdk = try makeSdk()
        let foregroundTask = Task { try await sdk.resumePendingAttribution(trigger: .appForeground, pollingTimeout: 0) }
        await fulfillment(of: [requestStarted], timeout: 2)
        let networkTask = Task { try await sdk.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0) }
        try await Task.sleep(nanoseconds: 10_000_000)
        releaseRequest.signal()

        let foregroundOutcome = try await foregroundTask.value
        let networkOutcome = try await networkTask.value

        XCTAssertEqual(foregroundOutcome.phase, .retryScheduled)
        XCTAssertEqual(networkOutcome, foregroundOutcome)
        XCTAssertEqual(requestCount, 1)
    }

    func testRecoveryOrchestratesLoginToFinalAndLeavesDurableDeliveryUntilAck() async throws {
        let accountScope = "local_scope_123456"
        var paths: [String] = []
        MockURLProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000402","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
                )
            case "/v1/sdk/events/login-completed":
                return Self.response(
                    request,
                    status: 201,
                    json: #"{"confirmationId":"00000000-0000-4000-8000-000000000403","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:00:02Z","reportedAt":"2026-08-24T08:00:03Z"}"#
                )
            case "/v1/sdk/attributions/00000000-0000-4000-8000-000000000402":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000402","processState":"FINAL","outcome":"MATCHED","status":"PROBABILISTIC_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":1,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:04Z","finalizedAt":"2026-08-24T08:00:04Z","retryAfterMs":0,"finalMatches":[{"linkId":"00000000-0000-4000-8000-000000000404","ruleKey":"share","externalIdentifier":"share-402","confidenceBand":"HIGH","attributedAt":"2026-08-24T08:00:04Z"}]}"#
                )
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
            }
        }
        let sdk = try makeSdk()
        try sdk.recordAuthenticatedLogin(accountScope: accountScope)

        let outcome = try await sdk.resumePendingAttribution(trigger: .appForeground, pollingTimeout: 0)
        let delivery = try sdk.pendingFinalDelivery(accountScope: accountScope)

        XCTAssertEqual(outcome.phase, .final)
        XCTAssertNil(outcome.result)
        XCTAssertEqual(delivery?.result.finalMatches.map(\.externalIdentifier), ["share-402"])
        XCTAssertEqual(paths, [
            "/v1/sdk/installations/resolve",
            "/v1/sdk/events/login-completed",
            "/v1/sdk/attributions/00000000-0000-4000-8000-000000000402",
        ])

        let relaunched = try makeSdk()
        XCTAssertEqual(try relaunched.pendingFinalDelivery(accountScope: accountScope)?.deliveryId, delivery?.deliveryId)
        try relaunched.acknowledgeFinalDelivery(
            deliveryId: try XCTUnwrap(delivery?.deliveryId),
            accountScope: accountScope
        )
        XCTAssertNil(try relaunched.pendingFinalDelivery(accountScope: accountScope))
    }

    func testRecoveryUsesForegroundBudgetAcrossRepeatedStaleDecision() async throws {
        let attributionId = "00000000-0000-4000-8000-000000000452"
        let accountScope = "local_scope_000452"
        var getCount = 0
        MockURLProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sdk/installations/resolve":
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000452","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":7,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":0,"finalMatches":[]}"#
                )
            case "/v1/sdk/events/login-completed":
                return Self.response(
                    request,
                    status: 201,
                    json: #"{"confirmationId":"00000000-0000-4000-8000-000000000453","status":"RECORDED","source":"SDK_REPORTED","occurredAt":"2026-08-24T08:00:02Z","reportedAt":"2026-08-24T08:00:03Z"}"#
                )
            case "/v1/sdk/attributions/\(attributionId)":
                getCount += 1
                if getCount <= 2 {
                    return Self.response(
                        request,
                        json: #"{"attributionId":"00000000-0000-4000-8000-000000000452","processState":"SETTLING","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":7,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:04Z","retryAfterMs":0,"finalMatches":[]}"#
                    )
                }
                return Self.response(
                    request,
                    json: #"{"attributionId":"00000000-0000-4000-8000-000000000452","processState":"FINAL","outcome":"MATCHED","status":"PROBABILISTIC_MATCH","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":8,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:05Z","finalizedAt":"2026-08-24T08:00:05Z","retryAfterMs":0,"finalMatches":[{"linkId":"00000000-0000-4000-8000-000000000454","ruleKey":"share","externalIdentifier":"stale-then-final","confidenceBand":"HIGH","attributedAt":"2026-08-24T08:00:05Z"}]}"#
                )
            default:
                return Self.response(request, status: 500, json: #"{"error":"unexpected"}"#)
            }
        }
        let sdk = try makeSdk()
        _ = try await sdk.resolveInstallation()
        try sdk.recordAuthenticatedLogin(accountScope: accountScope)

        let outcome = try await sdk.resumePendingAttribution(trigger: .appForeground, pollingTimeout: 1)

        XCTAssertEqual(outcome.phase, .final)
        XCTAssertNil(outcome.result)
        XCTAssertGreaterThanOrEqual(getCount, 3)
        XCTAssertEqual(
            try sdk.pendingFinalDelivery(accountScope: accountScope)?.result.finalMatches.map(\.externalIdentifier),
            ["stale-then-final"]
        )
    }

    func testPermanentRecoveryFailureStopsAcrossRelaunchUntilExplicitReset() async throws {
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                return Self.response(request, status: 401, json: #"{"error":{"code":"UNAUTHORIZED","message":"stop"}}"#)
            }
            return Self.response(
                request,
                json: #"{"attributionId":"00000000-0000-4000-8000-000000000405","processState":"PROVISIONAL","status":"PENDING","resolverType":"IOS_PROBABILISTIC_INSTALL","decisionSequence":0,"occurredAt":"2026-08-24T08:00:00Z","reportedAt":"2026-08-24T08:00:01Z","retryAfterMs":1000,"finalMatches":[]}"#
            )
        }

        let first = try makeSdk()
        let stopped = try await first.resumePendingAttribution(trigger: .appLaunch, pollingTimeout: 0)
        XCTAssertEqual(stopped.phase, .stopped)
        XCTAssertEqual(stopped.failure, .http(status: 401))

        let relaunched = try makeSdk()
        let stillStopped = try await relaunched.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0)
        XCTAssertEqual(stillStopped.phase, .stopped)
        XCTAssertEqual(requestCount, 1)

        try relaunched.resetAutomaticRecovery()
        let reset = try await relaunched.resumePendingAttribution(trigger: .networkAvailable, pollingTimeout: 0)
        XCTAssertEqual(reset.phase, .waitingForLogin)
        XCTAssertEqual(requestCount, 2)
    }

    private func makeSdk(
        sdkKey: String = "ios-key",
        apiBaseURL: URL = URL(string: "https://api.example.test")!,
        appVersion: String = "2.10.4",
        cacheScope: String = "project-a/production/ios",
        userProvidedEvidenceEnabled: Bool = false,
        integrityProvider: any IntegrityTokenProvider = NoIntegrityTokenProvider(),
        userDefaults: UserDefaults? = nil
    ) throws -> LinkAttribution {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return try LinkAttribution(
            configuration: .init(
                apiBaseURL: apiBaseURL,
                sdkKey: sdkKey,
                allowedLinkHosts: ["GO.EXAMPLE.TEST."],
                appVersion: appVersion,
                cacheScope: cacheScope,
                storageNamespace: "test",
                userProvidedEvidenceEnabled: userProvidedEvidenceEnabled
            ),
            integrityProvider: integrityProvider,
            session: URLSession(configuration: config),
            userDefaults: userDefaults ?? defaults
        )
    }

    private func currentInstallationStorageKey() throws -> String {
        try XCTUnwrap(
            defaults.dictionaryRepresentation().keys.first(where: {
                $0.hasPrefix("test.") && $0.hasSuffix(".installation.v3")
            })
        )
    }

    private static func legacyV2StorageKey() -> String {
        "test.\(stableScope("https://api.example.test|project-a/production/ios")).installation.v2"
    }

    private static func stableScope(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func response(_ request: URLRequest, status: Int = 200, json: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        guard status == 200,
              var object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              object["attributionId"] != nil,
              let processState = object["processState"] as? String else {
            return (response, Data(json.utf8))
        }
        // 测试主体只写与场景相关的字段；这里统一补齐当前 wire 必填镜像，矛盾/缺字段用例直接调用 JSONDecoder。
        if object["isFinal"] == nil {
            object["isFinal"] = processState == "FINAL"
        }
        if object["decisionSequence"] == nil {
            object["decisionSequence"] = processState == "FINAL" ? 1 : 0
        }
        if object["outcome"] == nil {
            object["outcome"] = NSNull()
        }
        var finalMatches = object["finalMatches"] as? [[String: Any]] ?? []
        for index in finalMatches.indices {
            if finalMatches[index]["ruleKey"] == nil {
                finalMatches[index]["ruleKey"] = "icard_share"
            }
            if finalMatches[index]["externalIdentifier"] == nil {
                finalMatches[index]["externalIdentifier"] = "test-share-\(index)"
            }
            if finalMatches[index]["attributedAt"] == nil {
                finalMatches[index]["attributedAt"] = object["reportedAt"] ?? "2026-08-24T08:00:01Z"
            }
        }
        object["finalMatches"] = finalMatches
        object["matches"] = finalMatches
        object["matchCount"] = finalMatches.count
        if object["finalizedAt"] == nil {
            object["finalizedAt"] = processState == "FINAL"
                ? (object["reportedAt"] ?? "2026-08-24T08:00:01Z")
                : NSNull()
        }
        if object["retryAfterMs"] == nil {
            object["retryAfterMs"] = processState == "FINAL" ? 0 : 1_000
        }
        return (response, (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(json.utf8))
    }

    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private struct FixedIntegrityTokenProvider: IntegrityTokenProvider {
    let token: String?

    func token(forEventId eventId: String) async throws -> String? { token }
}

private struct FailingIntegrityTokenProvider: IntegrityTokenProvider {
    let error: LinkAttributionError

    func token(forEventId eventId: String) async throws -> String? { throw error }
}

private final class BlockingIntegrityTokenProvider: IntegrityTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let onStart: (() -> Void)?
    private var continuation: CheckedContinuation<String?, Never>?
    private var released = false

    init(onStart: (() -> Void)? = nil) {
        self.onStart = onStart
    }

    func token(forEventId eventId: String) async throws -> String? {
        onStart?()
        return await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if released { return true }
                self.continuation = continuation
                return false
            }
            if resumeImmediately {
                continuation.resume(returning: "late-token")
            }
        }
    }

    func release() {
        let continuation: CheckedContinuation<String?, Never>? = lock.withLock {
            released = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: "late-token")
    }
}

private struct CancelledIntegrityTokenProvider: IntegrityTokenProvider {
    func token(forEventId eventId: String) async throws -> String? { throw CancellationError() }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { let (response, data) = try Self.handler!(request); client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
