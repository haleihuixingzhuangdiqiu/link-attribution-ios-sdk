import Foundation

/// SDK 跨网络和本地缓存使用的 JSON 值模型；保持类型信息，避免业务参数被桥接成不安全的 `Any`。
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

/// 平台协议值必须与服务端枚举完全一致，不使用客户端展示名称代替。
public enum Platform: String, Codable, Sendable { case iOS = "IOS"; case android = "ANDROID"; case web = "WEB" }

/// 服务端按项目与应用配置批准的跳转目标；SDK 不自行拼装商店或 Universal Link 地址。
public struct LinkDestination: Codable, Equatable, Sendable {
    public let platform: Platform
    public let url: URL
}

/// 已发布 Link Revision 的解析快照，仅含当前应用可见的规范业务参数。
public struct ResolvedLink: Codable, Equatable, Sendable {
    public let linkId: String
    public let revisionId: String
    public let route: String?
    /// 平台已交付业务路由时生成；仅用于回报该次路由是否真正落地。
    public let navigationSessionId: String?
    public let schemaVersion: Int
    public let params: [String: JSONValue]
    public let destinations: [LinkDestination]
}

/// 短期点击会话。`clickToken` 是一次性归因凭据，不应写日志、埋点或持久业务模型。
public struct ClickSession: Codable, Equatable, Sendable {
    public let clickId: String
    public let clickToken: String
    public let linkId: String
    public let expiresAt: String
}

/// 兼容服务端历史状态枚举；业务是否可消费结果必须只看 `AttributionProcessState.final`。
public enum AttributionStatus: String, Codable, Sendable {
    case pending = "PENDING"
    case deterministicMatch = "DETERMINISTIC_MATCH"
    case probabilisticMatch = "PROBABILISTIC_MATCH"
    case ambiguous = "AMBIGUOUS"
    case noMatch = "NO_MATCH"
    case expired = "EXPIRED"
    case riskHold = "RISK_HOLD"
    case reviewRequired = "REVIEW_REQUIRED"
    case manualMatch = "MANUAL_MATCH"
    case manualReject = "MANUAL_REJECT"

    /// 旧协议兼容判断；V3 缓存与业务交付只使用 `AttributionResult.isFinal`。
    public var isTerminal: Bool { self != .pending && self != .reviewRequired && self != .riskHold }
}

/// 归因事实从收集到冻结的公开阶段；只有 `final` 可以触发业务侧不可逆动作。
public enum AttributionProcessState: String, Codable, Sendable {
    case collecting = "COLLECTING"
    case pending = "PENDING"
    case provisional = "PROVISIONAL"
    case settling = "SETTLING"
    case final = "FINAL"
}

/// `AttributionProcessState.final` 时冻结的业务结论。
public enum AttributionOutcome: String, Codable, Sendable {
    case matched = "MATCHED"
    case multipleMatches = "MULTIPLE_MATCHES"
    case noMatch = "NO_MATCH"
    case unresolved = "UNRESOLVED"
    case riskBlocked = "RISK_BLOCKED"
    case expired = "EXPIRED"
}

/// 对业务公开的粗粒度置信分级，不暴露原始分数、阈值或内部证据权重。
public enum AttributionConfidenceBand: String, Codable, Sendable {
    case high = "HIGH"
    case medium = "MEDIUM"
    case low = "LOW"
}

/// 表示实际使用的解析通道；iOS 商店安装始终是概率归因，不伪造确定性商店桥。
public enum ResolverType: String, Codable, Sendable {
    case iOSUniversalLink = "IOS_UNIVERSAL_LINK"
    case iOSUserProvidedLink = "IOS_USER_PROVIDED_LINK"
    case iOSProbabilisticInstall = "IOS_PROBABILISTIC_INSTALL"
    case androidAppLink = "ANDROID_APP_LINK"
    case androidInstallReferrer = "ANDROID_INSTALL_REFERRER"
    case androidProbabilisticInstall = "ANDROID_PROBABILISTIC_INSTALL"
}

/**
 一个达到当前项目门槛、并允许交付给本 Application 的业务匹配。

 数组顺序由服务端冻结。这里只包含业务找回与路由字段；原始分数、详细证据、网络信号、
 风险结论和策略阈值不会进入客户端模型。
 */
public struct AttributionMatch: Codable, Equatable, Sendable {
    public let linkId: String
    public let ruleKey: String
    public let externalIdentifier: String
    public let confidenceBand: AttributionConfidenceBand
    public let route: String?
    public let schemaVersion: Int?
    public let params: [String: JSONValue]?
    public let attributedAt: String?

    private enum CodingKeys: String, CodingKey {
        case linkId, ruleKey, externalIdentifier, confidenceBand, route, schemaVersion, params, attributedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        linkId = try container.decode(String.self, forKey: .linkId)
        ruleKey = try container.decode(String.self, forKey: .ruleKey)
        externalIdentifier = try container.decode(String.self, forKey: .externalIdentifier)
        guard linkId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              ruleKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              externalIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw DecodingError.dataCorruptedError(
                forKey: .externalIdentifier,
                in: container,
                debugDescription: "final match requires business identity"
            )
        }
        confidenceBand = try container.decode(AttributionConfidenceBand.self, forKey: .confidenceBand)
        route = try container.decodeIfPresent(String.self, forKey: .route)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        params = try container.decodeIfPresent([String: JSONValue].self, forKey: .params)
        attributedAt = try container.decodeIfPresent(String.self, forKey: .attributedAt)
    }
}

/// 客户端可消费的脱敏归因结果；只有 `processState == .final` 时 `finalMatches` 才允许非空。
public struct AttributionResult: Codable, Equatable, Sendable {
    /// 与平台策略 `maximumCandidates` 的公开上限保持一致。
    private static let maximumFinalMatches = 100

    public let attributionId: String
    public let processState: AttributionProcessState
    public let outcome: AttributionOutcome?
    public let status: AttributionStatus
    public let resolverType: ResolverType
    /// 服务端已经冻结的 share-code/link；处理中候选永远不进入 SDK。
    public let finalMatches: [AttributionMatch]
    public let decisionSequence: Int
    public let occurredAt: String
    public let reportedAt: String
    public let finalizedAt: String?
    public let retryAfterMs: Int?
    public let linkId: String?
    public let route: String?
    /// 匹配结果同时交付业务路由时生成；没有路由或项目关闭诊断时为空。
    public let navigationSessionId: String?
    public let schemaVersion: Int?
    public let params: [String: JSONValue]?
    public let attributedAt: String?

    /// 兼容旧客户端命名；它只镜像 `finalMatches`，不包含处理中候选。
    @available(*, deprecated, renamed: "finalMatches")
    public var matches: [AttributionMatch] { finalMatches }

    /// 只有服务端冻结的 FINAL 结果才可进入本地终态缓存或交给业务权益接口。
    public var isFinal: Bool { processState == .final }

    /// 只有包含冻结匹配的 FINAL 才属于业务可消费结果；无匹配、过期等 FINAL 可在登录前用于诊断。
    var isConsumableFinal: Bool {
        processState == .final && (outcome == .matched || outcome == .multipleMatches)
    }

    private enum CodingKeys: String, CodingKey {
        case attributionId, processState, isFinal, outcome, status, resolverType, finalMatches, matches, matchCount, decisionSequence
        case occurredAt, reportedAt, finalizedAt, retryAfterMs
        case linkId, route, navigationSessionId, schemaVersion, params, attributedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attributionId = try container.decode(String.self, forKey: .attributionId)
        processState = try container.decode(AttributionProcessState.self, forKey: .processState)
        let wireIsFinal: Bool
        if container.contains(.isFinal) {
            wireIsFinal = try container.decode(Bool.self, forKey: .isFinal)
        } else if decoder.userInfo[.allowsLegacyAttributionCache] as? Bool == true {
            // 仅迁移旧版本本地缓存；真实网络响应没有该标记，必须显式携带 `isFinal`。
            wireIsFinal = processState == .final
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.isFinal,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "wire attribution must include isFinal")
            )
        }
        guard container.contains(.outcome) else {
            throw DecodingError.keyNotFound(
                CodingKeys.outcome,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "wire attribution must include outcome, including null")
            )
        }
        outcome = try container.decodeIfPresent(AttributionOutcome.self, forKey: .outcome)
        status = try container.decode(AttributionStatus.self, forKey: .status)
        resolverType = try container.decode(ResolverType.self, forKey: .resolverType)
        finalMatches = try container.decode([AttributionMatch].self, forKey: .finalMatches)
        let mirroredMatches: [AttributionMatch]
        if container.contains(.matches) {
            mirroredMatches = try container.decode([AttributionMatch].self, forKey: .matches)
        } else if decoder.userInfo[.allowsLegacyAttributionCache] as? Bool == true {
            mirroredMatches = finalMatches
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.matches,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "wire attribution must include matches mirror")
            )
        }
        let matchCount: Int
        if container.contains(.matchCount) {
            matchCount = try container.decode(Int.self, forKey: .matchCount)
        } else if decoder.userInfo[.allowsLegacyAttributionCache] as? Bool == true {
            matchCount = finalMatches.count
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.matchCount,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "wire attribution must include matchCount")
            )
        }
        if container.contains(.decisionSequence) {
            decisionSequence = try container.decode(Int.self, forKey: .decisionSequence)
        } else if decoder.userInfo[.allowsLegacyAttributionCache] as? Bool == true {
            // 旧缓存缺少追加序号时只能作为诊断恢复；0 永远不能生成业务交付 ID。
            decisionSequence = 0
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.decisionSequence,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "wire attribution must include decisionSequence")
            )
        }
        occurredAt = try container.decode(String.self, forKey: .occurredAt)
        reportedAt = try container.decode(String.self, forKey: .reportedAt)
        guard container.contains(.finalizedAt) else {
            throw DecodingError.keyNotFound(
                CodingKeys.finalizedAt,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "wire attribution must include finalizedAt, including null")
            )
        }
        finalizedAt = try container.decodeIfPresent(String.self, forKey: .finalizedAt)
        if container.contains(.retryAfterMs) {
            retryAfterMs = try container.decode(Int.self, forKey: .retryAfterMs)
        } else if decoder.userInfo[.allowsLegacyAttributionCache] as? Bool == true {
            retryAfterMs = processState == .final ? 0 : nil
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.retryAfterMs,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "wire attribution must include retryAfterMs")
            )
        }
        guard wireIsFinal == (processState == .final) else {
            throw DecodingError.dataCorruptedError(forKey: .isFinal, in: container, debugDescription: "isFinal must match processState")
        }
        guard mirroredMatches == finalMatches, matchCount == finalMatches.count else {
            throw DecodingError.dataCorruptedError(forKey: .matches, in: container, debugDescription: "matches and matchCount must mirror finalMatches")
        }
        guard (processState == .final) == (outcome != nil), processState == .final || finalMatches.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .finalMatches, in: container, debugDescription: "non-final attribution cannot expose matches")
        }
        switch outcome {
        case .matched where finalMatches.count != 1:
            throw DecodingError.dataCorruptedError(forKey: .finalMatches, in: container, debugDescription: "matched outcome requires exactly one final match")
        case .multipleMatches where finalMatches.count < 2:
            throw DecodingError.dataCorruptedError(forKey: .finalMatches, in: container, debugDescription: "multiple match outcome requires at least two final matches")
        case .noMatch, .unresolved, .riskBlocked, .expired:
            guard finalMatches.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .finalMatches, in: container, debugDescription: "non-matched outcome cannot expose final matches")
            }
        default:
            break
        }
        guard finalMatches.count <= Self.maximumFinalMatches else {
            throw DecodingError.dataCorruptedError(forKey: .finalMatches, in: container, debugDescription: "finalMatches exceeds the public delivery limit")
        }
        guard Self.isValidUUID(attributionId), finalMatches.allSatisfy({ Self.isValidUUID($0.linkId) }) else {
            throw DecodingError.dataCorruptedError(forKey: .finalMatches, in: container, debugDescription: "attributionId and final match linkId must use UUID format")
        }
        guard finalMatches.allSatisfy({ match in
            match.ruleKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && match.externalIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && match.attributedAt.map(Self.isValidInstant) == true
                && (match.schemaVersion.map { $0 >= 1 } ?? true)
        }) else {
            throw DecodingError.dataCorruptedError(forKey: .finalMatches, in: container, debugDescription: "final match contains an invalid optional business identity or timestamp")
        }
        let linkIds = finalMatches.map { $0.linkId.lowercased() }
        guard Set(linkIds).count == linkIds.count else {
            throw DecodingError.dataCorruptedError(forKey: .finalMatches, in: container, debugDescription: "final matches must not repeat linkId")
        }
        let shareIdentities = finalMatches.map { match in
            "\(match.ruleKey)\u{0}\(match.externalIdentifier)"
        }
        guard Set(shareIdentities).count == shareIdentities.count else {
            throw DecodingError.dataCorruptedError(forKey: .finalMatches, in: container, debugDescription: "final matches must not repeat share identity")
        }
        if decisionSequence < 0 || processState == .final && decisionSequence < 1 {
            throw DecodingError.dataCorruptedError(forKey: .decisionSequence, in: container, debugDescription: "decisionSequence is outside the public contract")
        }
        guard Self.isValidInstant(occurredAt), Self.isValidInstant(reportedAt), finalizedAt.map(Self.isValidInstant) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .occurredAt, in: container, debugDescription: "attribution timestamps must use RFC3339")
        }
        if let retryAfterMs, retryAfterMs < 0 {
            throw DecodingError.dataCorruptedError(forKey: .retryAfterMs, in: container, debugDescription: "retryAfterMs must not be negative")
        }
        guard processState == .final ? (finalizedAt != nil && retryAfterMs == 0) : finalizedAt == nil else {
            throw DecodingError.dataCorruptedError(forKey: .finalizedAt, in: container, debugDescription: "finalizedAt and retryAfterMs must match processState")
        }
        let primary = finalMatches.first
        // 旧单结果字段只镜像 FINAL 第一项；网络即使误带顶层候选字段也不会向业务泄露。
        linkId = primary?.linkId
        route = primary?.route
        navigationSessionId = processState == .final ? try container.decodeIfPresent(String.self, forKey: .navigationSessionId) : nil
        if let navigationSessionId, Self.isValidUUID(navigationSessionId) == false {
            throw DecodingError.dataCorruptedError(
                forKey: .navigationSessionId,
                in: container,
                debugDescription: "navigationSessionId must use UUID format"
            )
        }
        schemaVersion = primary?.schemaVersion
        params = primary?.params
        attributedAt = primary?.attributedAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attributionId, forKey: .attributionId)
        try container.encode(processState, forKey: .processState)
        try container.encode(isFinal, forKey: .isFinal)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(status, forKey: .status)
        try container.encode(resolverType, forKey: .resolverType)
        try container.encode(finalMatches, forKey: .finalMatches)
        try container.encode(finalMatches, forKey: .matches)
        try container.encode(finalMatches.count, forKey: .matchCount)
        try container.encode(decisionSequence, forKey: .decisionSequence)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(reportedAt, forKey: .reportedAt)
        try container.encode(finalizedAt, forKey: .finalizedAt)
        try container.encode(retryAfterMs ?? 0, forKey: .retryAfterMs)
        try container.encodeIfPresent(linkId, forKey: .linkId)
        try container.encodeIfPresent(route, forKey: .route)
        try container.encodeIfPresent(navigationSessionId, forKey: .navigationSessionId)
        try container.encodeIfPresent(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(params, forKey: .params)
        try container.encodeIfPresent(attributedAt, forKey: .attributedAt)
    }

    /// 接受带或不带毫秒的小写/大写时区 RFC3339；拒绝本地时区字符串和无法解析的自由文本。
    private static func isValidInstant(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: value) != nil { return true }
        let seconds = ISO8601DateFormatter()
        seconds.formatOptions = [.withInternetDateTime]
        return seconds.date(from: value) != nil
    }

    /// 服务端公开 ID 均使用规范 UUID；拒绝空白、花括号和其他看似可解析但不属于公开 wire 的形式。
    private static func isValidUUID(_ value: String) -> Bool {
        value.count == 36 && UUID(uuidString: value) != nil
    }
}

extension CodingUserInfoKey {
    /// 仅用于读取已落盘的旧 SDK 终态；网络解码绝不设置该标记。
    static let allowsLegacyAttributionCache = CodingUserInfoKey(rawValue: "link-attribution.allows-legacy-cache")!
}

/**
 宿主已经从用户主动输入中解析并验证的第一方链接引用。

 SDK 不提供剪贴板读取 API，也不接收原始剪贴板文本或完整 URL。即使用户粘贴的是
 “标题 + 空格/换行 + 完整业务链接”，宿主也必须只在内存中提取允许域名下唯一合法的第一方
 link token/share code，再传平台 link token 或项目自己的 `ruleKey + externalIdentifier`；这些值
 仍会由服务端按四级作用域复核。原始整段文本不得传入、日志记录或持久化。
 */
public enum IOSUserProvidedEvidence: Equatable, Sendable {
    case linkToken(String)
    case externalIdentifier(ruleKey: String, externalIdentifier: String)
}

/// 用户主动粘贴证据属于可跳过旁路；只允许在归因冻结前补强，FINAL 后拒绝且不会触网。
public enum IOSUserProvidedEvidenceSubmission: Equatable, Sendable {
    case disabled
    case rejected
    case deferred
    /**
     平台已幂等受理该证据。

     受理响应使用完整 AttributionResult wire，但 SDK 不从该 POST 直接交付业务结果。新证据会
     触发同一 attribution 的后续求值；调用方统一通过 `resolveInstallation()`、
     `resumePendingAttribution(...)` 或 `getAttribution(attributionId:)` 获取并持久化 FINAL。
     */
    case accepted
}

/// 归因路由附属诊断只允许真实到达或明确失败，不能扩展为任意业务事件。
public enum NavigationOutcomeType: String, Codable, Sendable {
    case destinationViewed = "DESTINATION_VIEWED"
    case routeFailed = "ROUTE_FAILED"
}

/// 固定失败分类；SDK 不接受自由文本错误、页面标题、URL 或业务参数。
public enum NavigationFailureReason: String, Codable, Sendable {
    case routeNotRegistered = "ROUTE_NOT_REGISTERED"
    case parameterRejected = "PARAMETER_REJECTED"
    case destinationUnavailable = "DESTINATION_UNAVAILABLE"
    case hostRouterRejected = "HOST_ROUTER_REJECTED"
    case navigationTimeout = "NAVIGATION_TIMEOUT"
    case unknown = "UNKNOWN"
}

/// 宿主现有 Router 给出的最终旁路诊断；耗时单位为毫秒。
public struct NavigationOutcomeInput: Equatable, Sendable {
    public let navigationSessionId: String
    public let outcome: NavigationOutcomeType
    public let failureReason: NavigationFailureReason?
    public let durationMs: Int?

    public init(navigationSessionId: String, outcome: NavigationOutcomeType, failureReason: NavigationFailureReason? = nil, durationMs: Int? = nil) {
        self.navigationSessionId = navigationSessionId
        self.outcome = outcome
        self.failureReason = failureReason
        self.durationMs = durationMs
    }
}

/// 服务端保存的首个最终路由结果；相同会话重试只返回既有事实。
public struct NavigationOutcomeResult: Codable, Equatable, Sendable {
    public let outcomeId: String
    public let navigationSessionId: String
    public let outcome: NavigationOutcomeType
    public let failureReason: NavigationFailureReason?
    public let durationMs: Int?
    public let occurredAt: String
    /// 新版服务端可选的接收时间；当前/旧服务仅返回 `occurredAt` 时仍必须成功解码。
    public let reportedAt: String?
}

/**
 宿主真实登录成功后登记的首次登录事实。

 SDK 在登录成功时持久化 `occurredAt`，网络重试保持它不变并刷新 `reportedAt`；
 服务端校验时间边界后冻结首次事实，响应返回冻结的发生时间和服务端接收时间。
 该契约不包含账号、业务 Token、用户 ID 或稳定设备标识。
 */
public struct LoginConfirmation: Codable, Equatable, Sendable {
    /// 服务端生成的登录确认记录 ID。
    public let confirmationId: String
    /// 服务端稳定状态，当前成功值为 `RECORDED`。
    public let status: String
    /// 登录事实来源，当前 SDK 上报值为 `SDK_REPORTED`。
    public let source: String
    /// 宿主记录、服务端校验并冻结的首次登录真实发生时间。
    public let occurredAt: String
    /// 服务端接收本次上报的时间；与首次发生时间分开，便于校验离线重试没有改写事实时间。
    public let reportedAt: String

    private enum CodingKeys: String, CodingKey {
        case confirmationId, status, source, occurredAt, reportedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        confirmationId = try container.decode(String.self, forKey: .confirmationId)
        status = try container.decode(String.self, forKey: .status)
        source = try container.decode(String.self, forKey: .source)
        occurredAt = try container.decode(String.self, forKey: .occurredAt)
        reportedAt = try container.decode(String.self, forKey: .reportedAt)
        guard UUID(uuidString: confirmationId) != nil,
              status == "RECORDED",
              source == "SDK_REPORTED",
              Self.isValidInstant(occurredAt),
              Self.isValidInstant(reportedAt) else {
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: container,
                debugDescription: "login confirmation is outside the public wire contract"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(confirmationId, forKey: .confirmationId)
        try container.encode(status, forKey: .status)
        try container.encode(source, forKey: .source)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(reportedAt, forKey: .reportedAt)
    }

    private static func isValidInstant(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: value) != nil { return true }
        let seconds = ISO8601DateFormatter()
        seconds.formatOptions = [.withInternetDateTime]
        return seconds.date(from: value) != nil
    }
}

/// 可选的粗粒度辅助信号。不得扩展为广告标识、稳定设备指纹或精确硬件特征。
public struct ClientSignals: Codable, Equatable, Sendable {
    public let countryCode: String?
    public let locale: String?
    public let timezoneOffsetMinutes: Int?
    public let osMajor: String?
    public let deviceClass: String?

    public init(countryCode: String? = nil, locale: String? = nil, timezoneOffsetMinutes: Int? = nil, osMajor: String? = nil, deviceClass: String? = nil) {
        self.countryCode = countryCode; self.locale = locale; self.timezoneOffsetMinutes = timezoneOffsetMinutes; self.osMajor = osMajor; self.deviceClass = deviceClass
    }
}

/**
 宿主尚未确认消费的冻结归因结果。

 `deliveryId` 由 `attributionId + decisionSequence` 稳定生成；SDK 只在本地绑定宿主传入的
 脱敏账号作用域，不会把账号作用域上传到归因平台。宿主业务处理成功后必须显式 ack，
 否则该结果会在进程重启后继续作为待交付结果恢复。
 */
public struct AttributionDelivery: Equatable, Sendable {
    public let deliveryId: String
    public let result: AttributionResult

    public init(deliveryId: String, result: AttributionResult) {
        self.deliveryId = deliveryId
        self.result = result
    }
}

/// 宿主只负责把真实生命周期或网络恢复信号交给 SDK；重试顺序、退避与持久事实由 SDK 统一管理。
public enum AttributionRecoveryTrigger: String, Equatable, Sendable {
    case appLaunch = "APP_LAUNCH"
    case appForeground = "APP_FOREGROUND"
    case networkAvailable = "NETWORK_AVAILABLE"
    case scheduled = "SCHEDULED"
}

/// 一次可恢复归因编排的稳定阶段；不包含服务端内部候选、分数、网络摘要或自由文本错误。
public enum AttributionRecoveryPhase: String, Equatable, Sendable {
    /// 持久退避尚未到期，本次没有触网。
    case notDue = "NOT_DUE"
    /// 安装已经登记，等待宿主产生真实登录成功事实。
    case waitingForLogin = "WAITING_FOR_LOGIN"
    /// 登录事实已经登记或确认，平台尚未返回不可变 FINAL。
    case waitingForFinal = "WAITING_FOR_FINAL"
    /// 已得到并持久化不可变 FINAL；可消费结果的 `result` 为空，只能通过 `pendingFinalDelivery(accountScope:)` 读取业务待办。
    case final = "FINAL"
    /// 仅遇到允许自动重试的临时失败，并已持久化下一次退避时间。
    case retryScheduled = "RETRY_SCHEDULED"
    /// 遇到永久错误，自动恢复停止；宿主原业务继续，不应无限后台重试。
    case stopped = "STOPPED"
}

/**
 一次恢复编排的脱敏结果。

 `failure` 只使用稳定 SDK 分类，不携带服务端正文、URL、账号、原始用户输入或底层
 `localizedDescription`。`nextRetryAt` 只在 `notDue/retryScheduled/waitingForFinal` 时可能存在。
 */
public struct AttributionRecoveryOutcome: Equatable, Sendable {
    public let phase: AttributionRecoveryPhase
    public let result: AttributionResult?
    public let nextRetryAt: Date?
    public let failure: LinkAttributionError?

    public init(
        phase: AttributionRecoveryPhase,
        result: AttributionResult? = nil,
        nextRetryAt: Date? = nil,
        failure: LinkAttributionError? = nil
    ) {
        self.phase = phase
        self.result = result
        self.nextRetryAt = nextRetryAt
        self.failure = failure
    }
}

/// 跨版本稳定的 SDK 失败分类；业务层应依据类别处理，不依赖底层响应体或鉴权细节。
public enum LinkAttributionError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidArgument(String)
    /// 已冻结可消费 FINAL，但业务只能通过账号绑定的 `pendingFinalDelivery` outbox 读取并 ack。
    case businessDeliveryRequired
    case timeout
    case network(String)
    case http(status: Int)
    case invalidResponse
    case storage(String)

    /// 仅网络、超时、限流和服务端临时错误允许自动重试；鉴权、契约与业务冲突必须停止后台循环。
    public var isRetryable: Bool {
        switch self {
        case .timeout, .network:
            return true
        case let .http(status):
            return status == 408 || status == 425 || status == 429 || (500...599).contains(status)
        case .invalidConfiguration, .invalidArgument, .businessDeliveryRequired, .invalidResponse, .storage:
            return false
        }
    }
}
