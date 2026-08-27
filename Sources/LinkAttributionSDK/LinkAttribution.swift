import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// SDK 初始化配置。`sdkKey` 只发送到受鉴权的 `/v1/sdk/*`，`cacheScope` 必须使用稳定且非敏感的应用/环境标识。
public struct LinkAttributionConfiguration: Sendable {
    public let apiBaseURL: URL
    public let sdkKey: String
    /// 额外的宿主侧 Host 收紧。空集合表示由平台按当前应用的链接规则判定，不代表接受任意链接。
    /// SDK Key 始终只发送给 `apiBaseURL`，业务 URL 仅作为 JSON 字段交给平台解析。
    public let allowedLinkHosts: Set<String>
    public let appVersion: String
    public let cacheScope: String
    public let timeout: TimeInterval
    public let storageNamespace: String
    /** 用户主动粘贴证据默认关闭；宿主明确设计用户交互且平台策略允许时才打开。 */
    public let userProvidedEvidenceEnabled: Bool
    /// 仅为 0.1.x 源码兼容保留；项目链接路径由服务端规则决定。
    public let linkPathPrefix: String

    /// 构造配置但不发起网络请求；`cacheScope` 必须由宿主显式包含项目、环境与应用，禁止跨环境复用。
    /// `linkPathPrefix` 仅为 0.1.x 源码兼容保留，链接格式由管理平台的项目规则决定，不再参与匹配。
    public init(apiBaseURL: URL, sdkKey: String, allowedLinkHosts: Set<String> = [], appVersion: String? = nil, cacheScope: String, timeout: TimeInterval = 8, storageNamespace: String = "link-attribution", userProvidedEvidenceEnabled: Bool = false, linkPathPrefix: String = "/l/") {
        self.apiBaseURL = apiBaseURL
        self.sdkKey = sdkKey
        self.allowedLinkHosts = allowedLinkHosts
        self.appVersion = appVersion ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        self.cacheScope = cacheScope
        self.timeout = timeout
        self.storageNamespace = storageNamespace
        self.userProvidedEvidenceEnabled = userProvidedEvidenceEnabled
        self.linkPathPrefix = linkPathPrefix
    }
}

/// iOS 链接与安装归因客户端。
///
/// 实例以锁保护首次安装任务和本地状态，允许多个启动组件并发调用；网络响应只暴露稳定协议结果，
/// 不向宿主泄露候选证据、原始信号或归因分数。
public final class LinkAttribution: @unchecked Sendable {
    /// 决策尚未越过本地登录/证据时序门槛时的内部等待状态；公开单次查询映射为可重试超时。
    private struct DeferredAttributionDecision: Error {
        let retryAfterMs: Int?
    }

    /// 本地已冻结登录事实但确认响应尚未落盘；先幂等重放登录，不能把服务端已冻结 FINAL 当成未登录违例。
    private struct PendingLoginConfirmationDecision: Error {
        let retryAfterMs: Int?
    }

    /** 只保存服务端允许的第一方引用，不保存原始剪贴板文本、完整 URL 或来源 App。 */
    private struct PendingUserProvidedEvidence: Codable, Equatable {
        let eventId: String
        let occurredAt: String
        let linkToken: String?
        let ruleKey: String?
        let externalIdentifier: String?
    }

    /// 跨进程恢复首次安装所需的最小状态；终态结果一旦缓存便不再重复创建安装事件。
    private struct InstallationState: Codable {
        /// 本地状态协议显式版本；升级只能按已知版本迁移，禁止把未知结构当成一次新安装。
        var storageVersion: Int
        /// 规范 API origin 与宿主显式 cacheScope 的完整绑定；哈希键碰撞或配置漂移时必须拒绝复用。
        var scopeIdentity: String?
        let eventId: String
        /// 首次启动事实时间与 eventId 一起冻结；网络重试不得改写。
        var occurredAt: String?
        /// 首次安装触网前冻结的请求身份；响应丢失、App 升级或冷启动都必须逐字重放。
        var installationPlatform: Platform?
        var installationAppVersion: String?
        /// iOS 安装请求不接受确定性 click token；显式冻结“缺失”状态，避免未来版本静默改变幂等请求。
        var deterministicClickTokenAbsent: Bool?
        var attributionId: String?
        var terminalResult: AttributionResult?
        var loginEventId: String?
        /// 宿主真实登录成功的发生时间；与 loginEventId 一起冻结。
        var loginOccurredAt: String?
        /// 登录请求首次真正开始发送的本地时间；只有该事实存在，响应丢失后的服务端 FINAL 才可暂缓恢复。
        var loginSubmissionAttemptedAt: String?
        var loginConfirmation: LoginConfirmation?
        /// 登录确认响应丢失时先隔离服务端不可变 FINAL；确认恢复后只允许完全相同结果进入业务 outbox。
        var pendingLoginFinal: AttributionResult?
        /// 当前登录事实已被平台永久拒绝；保留事实用于阻止冷启动重复上报，下一次真实登录可创建新事件。
        var loginConfirmationPermanentlyRejected: Bool
        /// 登录永久拒绝所属的 SDK 凭据摘要；Key 轮换后可幂等重放同一登录事实。
        var loginRejectionCredentialScope: String?
        var pendingUserProvidedEvidence: PendingUserProvidedEvidence?
        /// 已接受的最高追加式决策序号；网络重试不得让迟到旧响应覆盖新结果。
        var lastDecisionSequence: Int?
        /// 登录或新证据受理前已见到的序号；后续结果必须越过该序号才可重新交付。
        var invalidatedThroughDecisionSequence: Int?
        /// 平台若在登录门槛前误发可消费 FINAL，违反 FINAL 不可重开契约；本安装永久禁止交付该归因。
        var preLoginConsumableFinalRejected: Bool
        /// 宿主传入的本地脱敏账号作用域；只用于把 FINAL 交付给触发登录事实的同一账号。
        var deliveryAccountScope: String?
        /// 账号作用域是否由当前或兼容版本显式绑定；缺失/损坏的旧缓存必须按未绑定处理。
        var deliveryAccountScopeTrusted: Bool
        /// 在账号绑定前已经形成的可消费 FINAL；仅保留诊断，不得在事后绑定给任意账号。
        var suppressedUnboundDeliveryId: String?
        /// 宿主已经确认业务消费的最后一条稳定交付 ID；不清除 SDK 的终态诊断缓存。
        var acknowledgedDeliveryId: String?
        /// 连续临时失败次数；用于跨进程保持指数退避，而不是每次冷启动从零开始重试。
        var recoveryAttempt: Int
        /// 下一次计划恢复时间。前台或网络恢复信号可提前唤醒，定时触发必须遵守该时间。
        var nextRecoveryAt: String?
        /// 永久错误会停止自动恢复；新的真实登录/主动证据或宿主显式重置后才重新开放。
        var recoveryPermanentlyStopped: Bool
        /// 触发当前退避/停止的 SDK 凭据本地摘要；Key 轮换后旧失败不能阻断新凭据恢复。
        var recoveryCredentialScope: String?

        private enum CodingKeys: String, CodingKey {
            case storageVersion, scopeIdentity, eventId, occurredAt, installationPlatform, installationAppVersion, deterministicClickTokenAbsent
            case attributionId, terminalResult, loginEventId, loginOccurredAt, loginSubmissionAttemptedAt
            case pendingLoginFinal
            case loginConfirmation, loginConfirmationPermanentlyRejected, loginRejectionCredentialScope, pendingUserProvidedEvidence
            case lastDecisionSequence, invalidatedThroughDecisionSequence, preLoginConsumableFinalRejected
            case deliveryAccountScope, deliveryAccountScopeTrusted, suppressedUnboundDeliveryId, acknowledgedDeliveryId
            case recoveryAttempt, nextRecoveryAt, recoveryPermanentlyStopped, recoveryCredentialScope
        }

        init(eventId: String, occurredAt: String, scopeIdentity: String, appVersion: String) {
            storageVersion = LinkAttribution.currentStorageVersion
            self.scopeIdentity = scopeIdentity
            self.eventId = eventId
            self.occurredAt = occurredAt
            installationPlatform = .iOS
            installationAppVersion = appVersion
            deterministicClickTokenAbsent = true
            attributionId = nil
            terminalResult = nil
            loginEventId = nil
            loginOccurredAt = nil
            loginSubmissionAttemptedAt = nil
            loginConfirmation = nil
            pendingLoginFinal = nil
            loginConfirmationPermanentlyRejected = false
            loginRejectionCredentialScope = nil
            pendingUserProvidedEvidence = nil
            lastDecisionSequence = nil
            invalidatedThroughDecisionSequence = nil
            preLoginConsumableFinalRejected = false
            deliveryAccountScope = nil
            deliveryAccountScopeTrusted = false
            suppressedUnboundDeliveryId = nil
            acknowledgedDeliveryId = nil
            recoveryAttempt = 0
            nextRecoveryAt = nil
            recoveryPermanentlyStopped = false
            recoveryCredentialScope = nil
        }

        /// 所有会影响请求幂等、账号绑定或 FINAL 交付的字段都严格读取；类型错误不能被降级成字段缺失。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            storageVersion = try container.decodeIfPresent(Int.self, forKey: .storageVersion) ?? 2
            eventId = try container.decode(String.self, forKey: .eventId)
            if storageVersion == LinkAttribution.currentStorageVersion {
                scopeIdentity = try container.decode(String.self, forKey: .scopeIdentity)
                occurredAt = try container.decode(String.self, forKey: .occurredAt)
                installationPlatform = try container.decode(Platform.self, forKey: .installationPlatform)
                installationAppVersion = try container.decode(String.self, forKey: .installationAppVersion)
                deterministicClickTokenAbsent = try container.decode(Bool.self, forKey: .deterministicClickTokenAbsent)
            } else {
                scopeIdentity = try container.decodeIfPresent(String.self, forKey: .scopeIdentity)
                occurredAt = try container.decodeIfPresent(String.self, forKey: .occurredAt)
                installationPlatform = try container.decodeIfPresent(Platform.self, forKey: .installationPlatform)
                installationAppVersion = try container.decodeIfPresent(String.self, forKey: .installationAppVersion)
                deterministicClickTokenAbsent = try container.decodeIfPresent(Bool.self, forKey: .deterministicClickTokenAbsent)
            }
            attributionId = try container.decodeIfPresent(String.self, forKey: .attributionId)
            terminalResult = try container.decodeIfPresent(AttributionResult.self, forKey: .terminalResult)
            loginEventId = try container.decodeIfPresent(String.self, forKey: .loginEventId)
            loginOccurredAt = try container.decodeIfPresent(String.self, forKey: .loginOccurredAt)
            loginSubmissionAttemptedAt = try container.decodeIfPresent(String.self, forKey: .loginSubmissionAttemptedAt)
            loginConfirmation = try container.decodeIfPresent(LoginConfirmation.self, forKey: .loginConfirmation)
            pendingLoginFinal = try container.decodeIfPresent(AttributionResult.self, forKey: .pendingLoginFinal)
            loginConfirmationPermanentlyRejected = storageVersion == LinkAttribution.currentStorageVersion
                ? try container.decode(Bool.self, forKey: .loginConfirmationPermanentlyRejected)
                : try container.decodeIfPresent(Bool.self, forKey: .loginConfirmationPermanentlyRejected) ?? false
            loginRejectionCredentialScope = try container.decodeIfPresent(String.self, forKey: .loginRejectionCredentialScope)
            pendingUserProvidedEvidence = try container.decodeIfPresent(PendingUserProvidedEvidence.self, forKey: .pendingUserProvidedEvidence)
            lastDecisionSequence = try container.decodeIfPresent(Int.self, forKey: .lastDecisionSequence)
            invalidatedThroughDecisionSequence = try container.decodeIfPresent(Int.self, forKey: .invalidatedThroughDecisionSequence)
            preLoginConsumableFinalRejected = storageVersion == LinkAttribution.currentStorageVersion
                ? try container.decode(Bool.self, forKey: .preLoginConsumableFinalRejected)
                : try container.decodeIfPresent(Bool.self, forKey: .preLoginConsumableFinalRejected) ?? false
            deliveryAccountScope = try container.decodeIfPresent(String.self, forKey: .deliveryAccountScope)
            deliveryAccountScopeTrusted = storageVersion == LinkAttribution.currentStorageVersion
                ? try container.decode(Bool.self, forKey: .deliveryAccountScopeTrusted)
                : (try container.decodeIfPresent(Bool.self, forKey: .deliveryAccountScopeTrusted) ?? false) && deliveryAccountScope != nil
            suppressedUnboundDeliveryId = try container.decodeIfPresent(String.self, forKey: .suppressedUnboundDeliveryId)
            acknowledgedDeliveryId = try container.decodeIfPresent(String.self, forKey: .acknowledgedDeliveryId)
            recoveryAttempt = storageVersion == LinkAttribution.currentStorageVersion
                ? try container.decode(Int.self, forKey: .recoveryAttempt)
                : max(try container.decodeIfPresent(Int.self, forKey: .recoveryAttempt) ?? 0, 0)
            nextRecoveryAt = try container.decodeIfPresent(String.self, forKey: .nextRecoveryAt)
            recoveryPermanentlyStopped = storageVersion == LinkAttribution.currentStorageVersion
                ? try container.decode(Bool.self, forKey: .recoveryPermanentlyStopped)
                : try container.decodeIfPresent(Bool.self, forKey: .recoveryPermanentlyStopped) ?? false
            recoveryCredentialScope = try container.decodeIfPresent(String.self, forKey: .recoveryCredentialScope)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(storageVersion, forKey: .storageVersion)
            try container.encodeIfPresent(scopeIdentity, forKey: .scopeIdentity)
            try container.encode(eventId, forKey: .eventId)
            try container.encodeIfPresent(occurredAt, forKey: .occurredAt)
            try container.encodeIfPresent(installationPlatform, forKey: .installationPlatform)
            try container.encodeIfPresent(installationAppVersion, forKey: .installationAppVersion)
            try container.encodeIfPresent(deterministicClickTokenAbsent, forKey: .deterministicClickTokenAbsent)
            try container.encodeIfPresent(attributionId, forKey: .attributionId)
            try container.encodeIfPresent(terminalResult, forKey: .terminalResult)
            try container.encodeIfPresent(loginEventId, forKey: .loginEventId)
            try container.encodeIfPresent(loginOccurredAt, forKey: .loginOccurredAt)
            try container.encodeIfPresent(loginSubmissionAttemptedAt, forKey: .loginSubmissionAttemptedAt)
            try container.encodeIfPresent(loginConfirmation, forKey: .loginConfirmation)
            try container.encodeIfPresent(pendingLoginFinal, forKey: .pendingLoginFinal)
            try container.encode(loginConfirmationPermanentlyRejected, forKey: .loginConfirmationPermanentlyRejected)
            try container.encodeIfPresent(loginRejectionCredentialScope, forKey: .loginRejectionCredentialScope)
            try container.encodeIfPresent(pendingUserProvidedEvidence, forKey: .pendingUserProvidedEvidence)
            try container.encodeIfPresent(lastDecisionSequence, forKey: .lastDecisionSequence)
            try container.encodeIfPresent(invalidatedThroughDecisionSequence, forKey: .invalidatedThroughDecisionSequence)
            try container.encode(preLoginConsumableFinalRejected, forKey: .preLoginConsumableFinalRejected)
            try container.encodeIfPresent(deliveryAccountScope, forKey: .deliveryAccountScope)
            try container.encode(deliveryAccountScopeTrusted, forKey: .deliveryAccountScopeTrusted)
            try container.encodeIfPresent(suppressedUnboundDeliveryId, forKey: .suppressedUnboundDeliveryId)
            try container.encodeIfPresent(acknowledgedDeliveryId, forKey: .acknowledgedDeliveryId)
            try container.encode(recoveryAttempt, forKey: .recoveryAttempt)
            try container.encodeIfPresent(nextRecoveryAt, forKey: .nextRecoveryAt)
            try container.encode(recoveryPermanentlyStopped, forKey: .recoveryPermanentlyStopped)
            try container.encodeIfPresent(recoveryCredentialScope, forKey: .recoveryCredentialScope)
        }
    }

    private struct ClickRequest: Encodable {
        let linkToken: String; let eventId: String; let occurredAt: String; let signals: ClientSignals; let runtimeParams: [String: JSONValue]
    }
    private struct StoreClickRequest: Encodable { let clickToken: String; let eventId: String; let occurredAt: String }
    private struct InstallationRequest: Encodable {
        let eventId: String; let occurredAt: String; let reportedAt: String; let platform: Platform; let appVersion: String; let signals: ClientSignals; let integrityToken: String?
    }
    private struct ResolveURLRequest: Encodable {
        let url: String; let eventId: String; let occurredAt: String; let signals: ClientSignals
    }
    /// 路由结果请求只映射固定字段；不提供任意页面或业务属性容器。
    private struct NavigationOutcomeRequest: Encodable {
        let navigationSessionId: String
        let eventId: String
        let outcome: NavigationOutcomeType
        let failureReason: NavigationFailureReason?
        let durationMs: Int?
    }
    /// 登录确认只关联本安装与本次幂等写入；发生时间持久不变，本次上报时间逐次刷新。
    private struct LoginCompletedRequest: Encodable {
        let installationEventId: String
        let eventId: String
        let occurredAt: String
        let reportedAt: String
    }
    private struct UserProvidedEvidencePayload: Encodable {
        let source = "IOS_USER_PASTE"
        let linkToken: String?
        let ruleKey: String?
        let externalIdentifier: String?
    }
    private struct UserProvidedEvidenceRequest: Encodable {
        let installationEventId: String
        let eventId: String
        let occurredAt: String
        let reportedAt: String
        let evidence: UserProvidedEvidencePayload
    }
    private let configuration: LinkAttributionConfiguration
    /// 去除默认端口和尾部斜杠后的固定 API origin；SDK 不接受带路径的 API Base URL。
    private let apiBaseURL: URL
    /// 完整规范作用域随状态落盘，用于发现哈希碰撞或宿主配置漂移。
    private let cacheIdentity: String
    private let allowedLinkHosts: Set<String>
    private let integrityProvider: any IntegrityTokenProvider
    private let session: URLSession
    private let requestDelegate = NoRedirectURLSessionTaskDelegate()
    private let defaults: UserDefaults
    private let storageKey: String
    /// 只用于区分本地重试计划所属的 SDK Key，不上传、不记录原 Key，也不参与服务端鉴权。
    private let credentialScope: String
    /// 同一持久作用域的多个 SDK 实例共享状态锁、网络门禁和恢复任务，避免跨实例覆盖账号或 FINAL。
    private let synchronization: SDKScopeSynchronization
    private var lock: NSLock { synchronization.stateLock }
    /// 归因 GET/POST 与会改写决策版本的证据、登录请求必须串行，避免迟到旧响应重新写回旧 FINAL。
    private var stateNetworkGate: AsyncOperationGate { synchronization.networkGate }
    /// 与 Android 公共 SDK 对齐的轮询安全边界，避免 0 忙轮询、负数转换崩溃或超长休眠。
    private static let minimumPollInterval: TimeInterval = 0.25
    private static let maximumPollInterval: TimeInterval = 5
    /// 完整性证明是可选增强：最多独立等待 1 秒，且绝不允许超大证明扩大请求或本地内存边界。
    private static let maximumIntegrityWait: TimeInterval = 1
    private static let maximumIntegrityTokenBytes = 16 * 1_024
    private static let maximumResponseBytes = 2 * 1_024 * 1_024
    /// 与 Web SDK 的公开运行参数契约一致；避免超深/超大 JSON 在编码或 URL 拼装阶段放大资源占用。
    private static let maximumRuntimeParamsBytes = 1_000_000
    private static let maximumJSONValueNodes = 100_000
    private static let maximumJSONValueDepth = 32
    private static let maximumJSONCollectionItems = 10_000
    /// 历史 token GET 端点仍受常见代理请求行上限约束；新项目应优先使用正文承载参数的接口。
    private static let maximumLegacyResolvePathBytes = 8 * 1_024
    private static let currentStorageVersion = 3

    /// 校验并冻结安全边界，迁移旧缓存键；任何无效配置都在发起网络请求前失败。
    public init(configuration: LinkAttributionConfiguration, integrityProvider: any IntegrityTokenProvider = NoIntegrityTokenProvider(), session: URLSession? = nil, userDefaults: UserDefaults = .standard) throws {
        let apiScheme = configuration.apiBaseURL.scheme?.lowercased()
        let apiHost = configuration.apiBaseURL.host?.lowercased()
        guard apiScheme == "https" || apiScheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(apiHost ?? "") else {
            throw LinkAttributionError.invalidConfiguration("apiBaseURL must use HTTPS outside localhost")
        }
        guard apiHost?.isEmpty == false,
              configuration.apiBaseURL.user == nil,
              configuration.apiBaseURL.password == nil,
              configuration.apiBaseURL.query == nil,
              configuration.apiBaseURL.fragment == nil,
              let apiComponents = URLComponents(url: configuration.apiBaseURL, resolvingAgainstBaseURL: false),
              apiComponents.percentEncodedPath.isEmpty || apiComponents.percentEncodedPath == "/",
              let normalizedAPIBaseURL = Self.normalizedAPIOrigin(from: apiComponents)
        else {
            throw LinkAttributionError.invalidConfiguration(
                "apiBaseURL must be an absolute HTTP(S) origin without userinfo, path, query, or fragment"
            )
        }
        guard !configuration.sdkKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LinkAttributionError.invalidConfiguration("sdkKey is required") }
        let normalizedHosts = Set(configuration.allowedLinkHosts.compactMap(Self.normalizeLinkHost))
        guard normalizedHosts.count == configuration.allowedLinkHosts.count else {
            throw LinkAttributionError.invalidConfiguration("allowedLinkHosts must contain host names without scheme, port, userinfo, path, query, or fragment")
        }
        guard Self.isNumericAppVersion(configuration.appVersion) else { throw LinkAttributionError.invalidConfiguration("appVersion must contain one to four numeric dotted components") }
        let cacheScope = configuration.cacheScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cacheScope.isEmpty == false,
              cacheScope.utf8.count <= 256,
              cacheScope.split(separator: "/", omittingEmptySubsequences: false).count >= 3,
              cacheScope.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ component in
                  component.isEmpty == false && component.utf8.allSatisfy { byte in
                      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || [45, 46, 95].contains(byte)
                  }
              }) else {
            throw LinkAttributionError.invalidConfiguration("cacheScope must explicitly identify project/environment/application")
        }
        guard configuration.timeout.isFinite, (0.1...60).contains(configuration.timeout) else {
            throw LinkAttributionError.invalidConfiguration("timeout must be between 0.1 and 60 seconds")
        }
        let cacheIdentity = "\(normalizedAPIBaseURL.absoluteString)|\(cacheScope)"
        self.configuration = configuration
        self.apiBaseURL = normalizedAPIBaseURL
        self.cacheIdentity = cacheIdentity
        self.allowedLinkHosts = normalizedHosts
        self.integrityProvider = integrityProvider
        if let session { self.session = session }
        else { let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = configuration.timeout; self.session = URLSession(configuration: config) }
        self.defaults = userDefaults
        let stableStorageKey = "\(configuration.storageNamespace).\(Self.stableScope(cacheIdentity)).installation.v3"
        self.storageKey = stableStorageKey
        self.credentialScope = Self.stableScope("credential|\(configuration.sdkKey)")
        self.synchronization = SDKScopeSynchronizationRegistry.shared.synchronization(for: stableStorageKey)
        let legacyStorageKeys = [
            "\(configuration.storageNamespace).\(Self.stableScope("\(configuration.apiBaseURL.absoluteString)|\(configuration.cacheScope)")).installation.v2",
            "\(configuration.storageNamespace).\(Self.stableScope(cacheIdentity)).installation.v2",
            "\(configuration.storageNamespace).\(Self.stableScope("\(configuration.apiBaseURL.absoluteString)|\(configuration.sdkKey)")).installation.v1",
            "\(configuration.storageNamespace).\(Self.stableScope("\(normalizedAPIBaseURL.absoluteString)|\(configuration.sdkKey)")).installation.v1",
        ].reduce(into: [String]()) { keys, key in
            if key != stableStorageKey, keys.contains(key) == false { keys.append(key) }
        }
        // v1/v2 使用未规范化 URL，v1 还错误绑定可轮换 SDK Key。这里只移动原始字节；首次严格读取再显式校验或迁移结构。
        try synchronization.stateLock.withLock {
            if userDefaults.data(forKey: stableStorageKey) == nil {
                let legacyStates = legacyStorageKeys.compactMap { key in
                    userDefaults.data(forKey: key).map { (key, $0) }
                }
                if let first = legacyStates.first {
                    guard legacyStates.dropFirst().allSatisfy({ $0.1 == first.1 }) else {
                        // 规范化前的等价 URL/Scope 若已经分裂成不同安装历史，SDK 不能擅自挑选其中一个。
                        throw LinkAttributionError.storage("ambiguous_legacy_cache")
                    }
                    userDefaults.set(first.1, forKey: stableStorageKey)
                }
            }
            for legacyKey in legacyStorageKeys {
                userDefaults.removeObject(forKey: legacyKey)
            }
        }
    }

    /// 通过受鉴权端点解析已安装链接；运行参数仍由服务端 Schema 决定能否覆盖与投递。
    public func resolveLink(token: String, runtimeParams: [String: JSONValue] = [:]) async throws -> ResolvedLink {
        try validateOpaqueToken(token)
        try Self.validateRuntimeParams(runtimeParams)
        guard runtimeParams.keys.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 128 }) else {
            throw LinkAttributionError.invalidArgument("runtime parameter keys must contain 1...128 characters")
        }
        guard var components = URLComponents(url: endpoint("/v1/sdk/links/\(token)/resolve"), resolvingAgainstBaseURL: false) else {
            throw LinkAttributionError.invalidArgument("legacy resolve URL is invalid")
        }
        components.queryItems = try runtimeParams.sorted(by: { $0.key < $1.key }).map {
            URLQueryItem(name: $0.key, value: try Self.encodeQuery($0.value))
        }
        let querySuffix = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        guard "\(components.percentEncodedPath)\(querySuffix)".utf8.count <= Self.maximumLegacyResolvePathBytes,
              let url = components.url else {
            throw LinkAttributionError.invalidArgument("legacy resolve URL exceeds the 8 KiB transport limit")
        }
        return try await request(url: url, method: "GET")
    }

    /// 按当前项目在管理平台配置的 URL 模板解析完整业务链接。
    ///
    /// SDK 不假设 `/l/`、`/s/` 或任何 Query 名；同一套 SDK 可直接处理不同项目既有的链接格式。
    /// 业务 URL 只放在请求体中，鉴权 Key 不会发送到该 URL 的 Host。
    public func resolveURL(_ url: URL) async throws -> ResolvedLink {
        guard let businessURL = businessURL(from: url) else {
            throw LinkAttributionError.invalidArgument("url must be an absolute HTTPS business link allowed by the optional host restriction")
        }
        let eventId = UUID().uuidString.lowercased()
        return try await request(
            path: "/v1/sdk/links/resolve-url",
            method: "POST",
            body: ResolveURLRequest(url: businessURL.absoluteString, eventId: eventId, occurredAt: now(), signals: deviceSignals()),
            idempotencyKey: eventId
        )
    }

    /// 创建点击会话；每次调用生成独立 `eventId`，并以同值作为 `Idempotency-Key`。
    public func createClick(token: String, runtimeParams: [String: JSONValue] = [:]) async throws -> ClickSession {
        try validateOpaqueToken(token)
        try Self.validateRuntimeParams(runtimeParams)
        let eventId = UUID().uuidString.lowercased()
        return try await request(path: "/v1/sdk/clicks", method: "POST", body: ClickRequest(linkToken: token, eventId: eventId, occurredAt: now(), signals: deviceSignals(), runtimeParams: runtimeParams), idempotencyKey: eventId)
    }

    /// 将既有点击推进到商店点击事件，不创建或替换原点击身份。
    public func trackStoreClick(clickToken: String) async throws {
        try validateOpaqueToken(clickToken)
        let eventId = UUID().uuidString.lowercased()
        let _: StoreClickResponse = try await request(path: "/v1/sdk/events/store-click", method: "POST", body: StoreClickRequest(clickToken: clickToken, eventId: eventId, occurredAt: now()), idempotencyKey: eventId)
    }

    /**
     回报平台已交付的归因路由是否被宿主 Router 真正落地。

     该请求只有固定结果、失败分类和耗时，不接收页面或业务属性；宿主必须把异常隔离为旁路诊断失败，
     不能让上报结果参与或阻塞原有跳转。
     */
    public func trackNavigationOutcome(_ input: NavigationOutcomeInput) async throws -> NavigationOutcomeResult {
        guard Self.isValidNavigationSessionId(input.navigationSessionId) else {
            throw LinkAttributionError.invalidArgument("navigationSessionId must be a valid UUID")
        }
        switch input.outcome {
        case .destinationViewed where input.failureReason != nil:
            throw LinkAttributionError.invalidArgument("failureReason is forbidden when destination was viewed")
        case .routeFailed where input.failureReason == nil:
            throw LinkAttributionError.invalidArgument("route failure requires a supported failureReason")
        default:
            break
        }
        if let durationMs = input.durationMs, !(0...600_000).contains(durationMs) {
            throw LinkAttributionError.invalidArgument("durationMs must be between 0 and 600000")
        }
        let eventId = UUID().uuidString.lowercased()
        return try await request(
            path: "/v1/sdk/events/navigation-outcome",
            method: "POST",
            body: NavigationOutcomeRequest(
                navigationSessionId: input.navigationSessionId,
                eventId: eventId,
                outcome: input.outcome,
                failureReason: input.failureReason,
                durationMs: input.durationMs
            ),
            idempotencyKey: eventId
        )
    }

    /// 已安装链路：NSUserActivity 的完整 Universal Link 由服务端项目规则解析为规范业务 Payload。
    public func handle(userActivity: NSUserActivity) async throws -> ResolvedLink? {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL else { return nil }
        return try await handleUniversalLink(url)
    }

    /// 处理直接传入的 Universal Link；非 HTTPS 或不满足可选 Host 收紧的链接会被安全忽略。
    /// 平台返回 404 表示该 URL 不属于当前应用规则，也按“不是本 SDK 的链接”处理。
    public func handleUniversalLink(_ url: URL) async throws -> ResolvedLink? {
        guard businessURL(from: url) != nil else { return nil }
        do { return try await resolveURL(url) }
        catch LinkAttributionError.http(let status) where status == 404 { return nil }
    }

    /// 发起或恢复首次安装归因；可消费 FINAL 会写入账号 outbox 并抛出 `.businessDeliveryRequired`，不会从本入口暴露 share code。
    public func resolveInstallation(signals: ClientSignals? = nil) async throws -> AttributionResult {
        do {
            let result = try await stateNetworkGate.withLock {
                try await resolveInstallationOnce(signals: signals)
            }
            return try publicDiagnosticResult(result)
        } catch is DeferredAttributionDecision, is PendingLoginConfirmationDecision {
            // 公开错误保持稳定且可重试；不泄露登录或决策高水位等本地门槛。
            throw LinkAttributionError.timeout
        }
    }

    private func resolveInstallationOnce(
        signals: ClientSignals?,
        expectedEventId: String? = nil
    ) async throws -> AttributionResult {
        let state: InstallationState
        if let expectedEventId {
            guard let existing = try mutateExistingState(expectedEventId: expectedEventId, { state in
                if state.occurredAt == nil {
                    // 兼容只有 eventId 的旧缓存；补齐后先落盘，保证随后的失败重试仍使用相同发生时间。
                    state.occurredAt = now()
                }
            }) else { throw CancellationError() }
            state = existing
        } else {
            state = try mutateState { state in
                if state.occurredAt == nil {
                    state.occurredAt = now()
                }
            }
        }
        guard state.preLoginConsumableFinalRejected == false else {
            throw LinkAttributionError.invalidResponse
        }
        // 先恢复终态或既有 Attribution，再请求完整性证明；网络重试始终复用同一 eventId。
        if let terminal = state.terminalResult {
            do {
                try validateAttribution(terminal, for: state, expectedAttributionId: state.attributionId)
                return terminal
            } catch let pendingLogin as PendingLoginConfirmationDecision {
                // 兼容旧版本误缓存：已有登录事实时先移除可消费结果，等待同一登录幂等确认后再回源。
                try mutateExistingState(expectedEventId: state.eventId) { current in
                    current.terminalResult = nil
                    current.lastDecisionSequence = nil
                    current.invalidatedThroughDecisionSequence = nil
                    current.pendingLoginFinal = terminal
                }
                throw pendingLogin
            } catch {
                // 旧缓存或登录门槛不再合法时保留事件与发生时间，只清结果并回源同一 attribution。
                let rejectedPreLoginFinal = terminal.isConsumableFinal && state.loginConfirmation == nil
                try mutateExistingState(expectedEventId: state.eventId) { current in
                    current.terminalResult = nil
                    current.lastDecisionSequence = Self.maximumSequence(current.lastDecisionSequence, terminal.decisionSequence)
                    if state.preLoginConsumableFinalRejected || rejectedPreLoginFinal {
                        current.preLoginConsumableFinalRejected = true
                        current.nextRecoveryAt = nil
                        current.recoveryPermanentlyStopped = true
                        current.pendingUserProvidedEvidence = nil
                    }
                }
                if rejectedPreLoginFinal {
                    throw LinkAttributionError.invalidResponse
                }
            }
        }
        if let attributionId = state.attributionId {
            do {
                return try await getAttributionOnce(attributionId: attributionId)
            } catch is DeferredAttributionDecision, is PendingLoginConfirmationDecision {
                // 登录或主动证据已经使旧决策失效；等待服务端追加更高序号，而不是永久停止恢复。
                throw LinkAttributionError.timeout
            }
        }
        let integrity = try await optionalIntegrityToken(forEventId: state.eventId)
        // 完整性 provider 可能在宿主清理本地安装代次后才返回。发送安装事实前再次校验代次，
        // 避免把已清理安装的 eventId、时间和设备信号继续发到服务端。
        try ensureCurrentInstallation(state.eventId)
        guard let occurredAt = state.occurredAt,
              state.installationPlatform == .iOS,
              let frozenAppVersion = state.installationAppVersion,
              state.deterministicClickTokenAbsent == true else {
            throw LinkAttributionError.storage("invalid_install_identity")
        }
        let body = InstallationRequest(
            eventId: state.eventId,
            occurredAt: occurredAt,
            reportedAt: now(),
            platform: .iOS,
            appVersion: frozenAppVersion,
            signals: signals ?? deviceSignals(),
            integrityToken: integrity
        )
        let result: AttributionResult = try await request(
            path: "/v1/sdk/installations/resolve",
            method: "POST",
            body: body,
            idempotencyKey: state.eventId,
            appVersion: frozenAppVersion
        )
        do {
            try validateAttribution(result, for: state)
        } catch let pendingLogin as PendingLoginConfirmationDecision {
            // 登录 POST 可能已被服务端受理但响应丢失；只保存归因 ID，不能缓存 FINAL 或推进序号。
            try quarantinePendingLoginFinal(result, expectedEventId: state.eventId)
            throw pendingLogin
        } catch {
            // 合法 wire 即使越过本地登录门槛，也先保留 attributionId，登录确认仍可继续同一安装。
            let rejectedPreLoginFinal = result.isConsumableFinal && state.loginConfirmation == nil
            try mutateExistingState(expectedEventId: state.eventId) { current in
                current.attributionId = result.attributionId
                current.lastDecisionSequence = Self.maximumSequence(current.lastDecisionSequence, result.decisionSequence)
                if state.preLoginConsumableFinalRejected || rejectedPreLoginFinal {
                    current.preLoginConsumableFinalRejected = true
                    current.nextRecoveryAt = nil
                    current.recoveryPermanentlyStopped = true
                    current.pendingUserProvidedEvidence = nil
                }
            }
            throw error
        }
        guard try mutateExistingState(expectedEventId: state.eventId, { current in
            // `clearLocalState()` 可能在请求期间建立新安装代次；迟到响应不得复活旧代次。
            current.attributionId = result.attributionId
            current.lastDecisionSequence = Self.maximumSequence(current.lastDecisionSequence, result.decisionSequence)
            if result.isFinal {
                current.terminalResult = result
                current.pendingLoginFinal = nil
            }
        }) != nil else { throw CancellationError() }
        return result
    }

    /**
     有界获取可选完整性证明。

     provider 的超时、HTTP/网络异常和超长 token 都降级为无证明，让基础归因继续；宿主取消必须原样
     结束当前任务。使用非结构化短任务配合一次性竞争器，避免不响应 cancellation 的第三方 provider
     让归因串行门禁永久等待。竞争结束后仍会取消落败任务，但不会等待它退出。
     */
    private func optionalIntegrityToken(forEventId eventId: String) async throws -> String? {
        try Task.checkCancellation()
        let race = IntegrityTokenRace()
        let provider = integrityProvider
        let providerTask = Task {
            do {
                race.complete(.success(try await provider.token(forEventId: eventId)))
            } catch is CancellationError {
                race.complete(.failure(CancellationError()))
            } catch {
                // 完整性是可选增强；稳定降级且不向宿主暴露 provider 或网络实现细节。
                race.complete(.success(nil))
            }
        }
        let timeout = min(configuration.timeout, Self.maximumIntegrityWait)
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                race.complete(.success(nil))
            } catch {
                // 落败任务被取消是正常竞争收尾；结果由 provider 或父任务决定。
            }
        }

        return try await withTaskCancellationHandler {
            defer {
                providerTask.cancel()
                timeoutTask.cancel()
            }
            let token = try await race.value()
            try Task.checkCancellation()
            guard let token, token.isEmpty == false,
                  token.utf8.count <= Self.maximumIntegrityTokenBytes else {
                return nil
            }
            return token
        } onCancel: {
            providerTask.cancel()
            timeoutTask.cancel()
            race.complete(.failure(CancellationError()))
        }
    }

    /// 查询服务端最新追加决策；可消费 FINAL 只进入账号 outbox，本入口抛出 `.businessDeliveryRequired`。
    public func getAttribution(attributionId: String) async throws -> AttributionResult {
        do {
            let result = try await stateNetworkGate.withLock {
                try await getAttributionOnce(attributionId: attributionId)
            }
            return try publicDiagnosticResult(result)
        } catch is DeferredAttributionDecision, is PendingLoginConfirmationDecision {
            // 公开错误保持稳定且可重试；不把内部决策高水位暴露给宿主。
            throw LinkAttributionError.timeout
        }
    }

    /// 已持有 `stateNetworkGate` 时执行一次查询，避免安装恢复递归获取同一异步锁。
    private func getAttributionOnce(attributionId: String, requestTimeout: TimeInterval? = nil) async throws -> AttributionResult {
        try validate(attributionId)
        guard let expectedState = try loadStateStrict(),
              expectedState.attributionId == attributionId else {
            // SDK Key 可访问同 Application 的服务端资源，但客户端只能读取本安装持久化的归因会话。
            throw LinkAttributionError.invalidArgument("attributionId must match the current installation")
        }
        guard expectedState.preLoginConsumableFinalRejected == false else {
            throw LinkAttributionError.invalidResponse
        }
        let path = "/v1/sdk/attributions/\(attributionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? attributionId)"
        let result: AttributionResult = try await request(
            url: endpoint(path),
            method: "GET",
            timeoutInterval: requestTimeout
        )
        guard let currentState = try loadStateStrict(),
              currentState.eventId == expectedState.eventId,
              currentState.attributionId == attributionId else {
            // 清理/重建安装发生在请求期间时，迟到响应不得跨本地安装代次返回给宿主。
            throw LinkAttributionError.invalidResponse
        }
        do {
            try validateAttribution(result, for: currentState, expectedAttributionId: attributionId)
        } catch let pendingLogin as PendingLoginConfirmationDecision {
            // 登录事实已存在但确认响应未落盘时，同一 FINAL 只是待确认结果；不得缓存或推进任何序号。
            try quarantinePendingLoginFinal(result, expectedEventId: currentState.eventId)
            throw pendingLogin
        } catch let deferred as DeferredAttributionDecision {
            // 门槛未满足时只推进本地序号高水位，不缓存或返回含 share code 的结果。
            try mutateExistingState(expectedEventId: currentState.eventId) { state in
                guard state.attributionId == attributionId else { return }
                state.lastDecisionSequence = Self.maximumSequence(state.lastDecisionSequence, result.decisionSequence)
            }
            throw deferred
        } catch {
            if result.attributionId == attributionId,
               currentState.terminalResult?.isFinal != true {
                let rejectedPreLoginFinal = result.isConsumableFinal && currentState.loginConfirmation == nil
                let changedQuarantinedFinal = currentState.pendingLoginFinal.map {
                    result.isFinal && Self.sameFrozenAttribution($0, result) == false
                } ?? false
                try mutateExistingState(expectedEventId: currentState.eventId) { state in
                    guard state.attributionId == attributionId else { return }
                    state.lastDecisionSequence = Self.maximumSequence(state.lastDecisionSequence, result.decisionSequence)
                    if currentState.preLoginConsumableFinalRejected || rejectedPreLoginFinal || changedQuarantinedFinal {
                        state.preLoginConsumableFinalRejected = true
                        state.nextRecoveryAt = nil
                        state.recoveryPermanentlyStopped = true
                        state.pendingUserProvidedEvidence = nil
                    }
                }
            }
            throw error
        }
        guard try mutateExistingState(expectedEventId: currentState.eventId, { state in
            guard state.attributionId == attributionId else {
                throw LinkAttributionError.invalidResponse
            }
            state.lastDecisionSequence = Self.maximumSequence(state.lastDecisionSequence, result.decisionSequence)
            if result.isFinal {
                state.terminalResult = result
                state.pendingLoginFinal = nil
                state.recoveryAttempt = 0
                state.nextRecoveryAt = nil
            }
        }) != nil else { throw CancellationError() }
        return result
    }

    /// 轮询尚未冻结的归因；可消费 FINAL 只进入账号 outbox，本入口抛出 `.businessDeliveryRequired`。
    public func waitForAttribution(attributionId: String, timeout: TimeInterval = 15, interval: TimeInterval = 1) async throws -> AttributionResult {
        guard timeout.isFinite, timeout > 0, interval.isFinite, interval > 0 else {
            throw LinkAttributionError.invalidArgument("timeout and interval must be finite positive seconds")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var isFirstQuery = true
        while isFirstQuery || ProcessInfo.processInfo.systemUptime < deadline {
            isFirstQuery = false
            let requestRemaining = deadline - ProcessInfo.processInfo.systemUptime
            guard requestRemaining > 0 else { break }
            let retryAfterMs: Int?
            do {
                let result = try await stateNetworkGate.withLock {
                    try await getAttributionOnce(
                        attributionId: attributionId,
                        requestTimeout: min(configuration.timeout, requestRemaining)
                    )
                }
                if result.isFinal { return try publicDiagnosticResult(result) }
                retryAfterMs = result.retryAfterMs
            } catch let pendingLogin as PendingLoginConfirmationDecision {
                // 旧查询入口不能替代登录幂等恢复；立即返回可重试超时，让统一恢复先补登录确认。
                _ = pendingLogin.retryAfterMs
                throw LinkAttributionError.timeout
            } catch let deferred as DeferredAttributionDecision {
                // 迟到旧序号不是永久协议错误；保持原 attributionId 并继续等待服务端追加更高决策。
                retryAfterMs = deferred.retryAfterMs
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            let requested = retryAfterMs.map { TimeInterval($0) / 1_000 } ?? interval
            let bounded = min(max(requested, Self.minimumPollInterval), Self.maximumPollInterval)
            let sleepInterval = min(bounded, remaining)
            try await Task.sleep(nanoseconds: UInt64(sleepInterval * 1_000_000_000))
        }
        throw LinkAttributionError.timeout
    }

    /**
     提交一次用户主动提供的第一方链接证据。

     本方法绝不访问 `UIPasteboard`，也不接收原始剪贴板内容或完整 URL。功能默认关闭；
     “标题 + 换行 + 完整链接”的用户输入必须由宿主在可见交互中按允许域名解析，本方法只接收
     已提取的唯一 link token/share code，不提供原始文本解析或兜底上传入口。
     关闭时直接返回 `.disabled`。网络、安装登记或平台临时失败返回 `.deferred` 并保留同一
     `eventId + occurredAt`，宿主业务无需等待，可在后续启动调用 `retryPendingUserProvidedEvidence()`。
     */
    public func submitUserProvidedEvidence(_ evidence: IOSUserProvidedEvidence) async -> IOSUserProvidedEvidenceSubmission {
        guard configuration.userProvidedEvidenceEnabled else { return .disabled }
        guard let validated = validatedUserProvidedEvidence(evidence) else { return .rejected }
        do {
            var pending: PendingUserProvidedEvidence!
            let installationState = try mutateState { state in
                // 平台 FINAL 不可变；必须在写待办的同一临界区重查，不能让并发终态后重新打开证据。
                guard state.terminalResult?.isFinal != true,
                      state.pendingLoginFinal == nil,
                      state.preLoginConsumableFinalRejected == false else {
                    throw LinkAttributionError.invalidResponse
                }
                if let existing = state.pendingUserProvidedEvidence {
                    guard existing.linkToken == validated.linkToken,
                          existing.ruleKey == validated.ruleKey,
                          existing.externalIdentifier == validated.externalIdentifier
                    else { throw LinkAttributionError.invalidArgument("another user-provided evidence event is pending") }
                    pending = existing
                    return
                }
                let created = PendingUserProvidedEvidence(
                    eventId: UUID().uuidString.lowercased(),
                    occurredAt: now(),
                    linkToken: validated.linkToken,
                    ruleKey: validated.ruleKey,
                    externalIdentifier: validated.externalIdentifier
                )
                state.pendingUserProvidedEvidence = created
                state.recoveryAttempt = 0
                state.nextRecoveryAt = nil
                state.recoveryPermanentlyStopped = false
                pending = created
            }
            return await sendUserProvidedEvidence(pending, expectedEventId: installationState.eventId)
        } catch {
            // 证据是可选旁路；错误不向登录、页面路由或现有业务调用栈传播。
            guard let error = error as? LinkAttributionError else { return .rejected }
            return error.isRetryable ? .deferred : .rejected
        }
    }

    /// 只重试已经由用户明确操作创建的持久待办；无待办时返回 `nil`，不会主动读取或推断内容。
    public func retryPendingUserProvidedEvidence() async -> IOSUserProvidedEvidenceSubmission? {
        guard configuration.userProvidedEvidenceEnabled else { return .disabled }
        guard let state = loadState() else { return nil }
        if state.terminalResult?.isFinal == true || state.pendingLoginFinal != nil || state.preLoginConsumableFinalRejected {
            _ = try? mutateExistingState(expectedEventId: state.eventId) { $0.pendingUserProvidedEvidence = nil }
            return .rejected
        }
        guard let pending = state.pendingUserProvidedEvidence else { return nil }
        return await sendUserProvidedEvidence(pending, expectedEventId: state.eventId)
    }

    /// 恢复编排专用入口；旧安装代次被清理后立即取消，不能替新安装冲刷证据。
    private func retryPendingUserProvidedEvidence(expectedEventId: String) async throws -> IOSUserProvidedEvidenceSubmission? {
        try ensureCurrentInstallation(expectedEventId)
        guard configuration.userProvidedEvidenceEnabled else { return .disabled }
        guard let state = loadState(), state.eventId == expectedEventId else { throw CancellationError() }
        if state.terminalResult?.isFinal == true || state.preLoginConsumableFinalRejected {
            _ = try? mutateExistingState(expectedEventId: expectedEventId) { $0.pendingUserProvidedEvidence = nil }
            return .rejected
        }
        guard let pending = state.pendingUserProvidedEvidence else { return nil }
        let result = await sendUserProvidedEvidence(pending, expectedEventId: expectedEventId)
        try ensureCurrentInstallation(expectedEventId)
        return result
    }

    private func sendUserProvidedEvidence(
        _ pending: PendingUserProvidedEvidence,
        expectedEventId: String? = nil
    ) async -> IOSUserProvidedEvidenceSubmission {
        do {
            guard let invocationState = loadState(),
                  expectedEventId == nil || invocationState.eventId == expectedEventId else { return .deferred }
            let invocationEventId = invocationState.eventId
            if invocationState.terminalResult?.isFinal == true
                || invocationState.pendingLoginFinal != nil
                || invocationState.preLoginConsumableFinalRejected {
                _ = try? mutateExistingState(expectedEventId: invocationEventId) { state in
                    guard state.pendingUserProvidedEvidence?.eventId == pending.eventId else { return }
                    state.pendingUserProvidedEvidence = nil
                }
                return .rejected
            }
            return try await stateNetworkGate.withLock {
                try ensureCurrentInstallation(invocationEventId)
                guard let currentState = loadState(),
                      currentState.eventId == invocationEventId,
                      currentState.terminalResult?.isFinal != true,
                      currentState.pendingLoginFinal == nil,
                      currentState.preLoginConsumableFinalRejected == false else {
                    return .rejected
                }
                if currentState.attributionId == nil {
                    _ = try await resolveInstallationOnce(signals: nil, expectedEventId: invocationEventId)
                }
                return await sendUserProvidedEvidenceWhileHoldingNetworkGate(
                    pending,
                    expectedEventId: invocationEventId
                )
            }
        } catch is CancellationError {
            // App 退到后台、会话解绑或宿主主动撤销任务都不代表证据无效。
            // 保留首次冻结的 eventId/occurredAt，下一次恢复时继续幂等上报。
            return .deferred
        } catch let error as LinkAttributionError {
            return error.isRetryable ? .deferred : .rejected
        } catch {
            return .rejected
        }
    }

    /**
     在已经持有决策网络锁时冲刷一条用户主动证据。

     登录确认必须复用本入口，让离线队列中的主动证据先于登录到达平台；否则登录门槛可能先冻结 FINAL，
     导致真实且已落盘的第一方 share code 被迟到拒绝。临时失败保留原事件，永久失败只清本条待办。
     */
    private func sendUserProvidedEvidenceWhileHoldingNetworkGate(
        _ pending: PendingUserProvidedEvidence,
        expectedEventId: String
    ) async -> IOSUserProvidedEvidenceSubmission {
        do {
            guard let state = loadState(),
                  state.eventId == expectedEventId,
                  state.attributionId != nil else { return .deferred }
            // 同一 pending 的并发调用在首个请求成功后直接复用“已受理”事实，不重复触网。
            guard state.pendingUserProvidedEvidence?.eventId == pending.eventId else { return .accepted }
            if state.terminalResult?.isFinal == true || state.pendingLoginFinal != nil || state.preLoginConsumableFinalRejected {
                try discardPendingUserProvidedEvidence(pending, installationEventId: state.eventId)
                return .rejected
            }
            // 服务端响应遵循完整 AttributionResult wire。POST 不直接向调用方暴露业务结果，
            // 但其中的 FINAL 仍是不可变历史，必须在同一持久事务中冻结或明确永久拒绝。
            let response: AttributionResult = try await request(
                path: "/v1/sdk/installations/user-provided-evidence",
                method: "POST",
                body: UserProvidedEvidenceRequest(
                    installationEventId: state.eventId,
                    eventId: pending.eventId,
                    occurredAt: pending.occurredAt,
                    reportedAt: now(),
                    evidence: UserProvidedEvidencePayload(
                        linkToken: pending.linkToken,
                        ruleKey: pending.ruleKey,
                        externalIdentifier: pending.externalIdentifier
                    )
                ),
                idempotencyKey: pending.eventId
            )
            var disposition = IOSUserProvidedEvidenceSubmission.accepted
            guard try mutateExistingState(expectedEventId: state.eventId, { current in
                guard response.attributionId == state.attributionId else {
                    throw LinkAttributionError.invalidResponse
                }
                // 另一个 SDK 实例可能在证据请求期间已经冻结 FINAL；迟到响应只能清理本条待办，绝不能重开。
                if current.terminalResult?.isFinal == true || current.preLoginConsumableFinalRejected {
                    if current.pendingUserProvidedEvidence?.eventId == pending.eventId {
                        current.pendingUserProvidedEvidence = nil
                    }
                    disposition = .rejected
                    return
                }
                current.attributionId = response.attributionId
                if response.isFinal {
                    let sequenceIsInvalid = current.lastDecisionSequence.map { response.decisionSequence < $0 } ?? false
                        || current.invalidatedThroughDecisionSequence.map { response.decisionSequence <= $0 } ?? false
                    if sequenceIsInvalid {
                        // FINAL 不能以倒退/失效序号绕过门槛；业务 FINAL 违例后永久 fail-closed。
                        if response.isConsumableFinal {
                            current.preLoginConsumableFinalRejected = true
                        }
                        current.recoveryPermanentlyStopped = true
                        current.nextRecoveryAt = nil
                        disposition = .rejected
                    } else if response.isConsumableFinal, current.loginConfirmation == nil {
                        if current.loginEventId != nil,
                           current.loginOccurredAt != nil,
                           current.loginSubmissionAttemptedAt != nil {
                            // 登录可能已在服务端成功但确认响应丢失；不缓存/不推进 FINAL，先幂等恢复登录。
                            current.invalidatedThroughDecisionSequence = Self.maximumSequence(
                                current.invalidatedThroughDecisionSequence,
                                current.lastDecisionSequence
                            )
                            if let quarantined = current.pendingLoginFinal,
                               Self.sameFrozenAttribution(quarantined, response) == false {
                                current.preLoginConsumableFinalRejected = true
                                current.recoveryPermanentlyStopped = true
                                current.nextRecoveryAt = nil
                                disposition = .rejected
                            } else {
                                current.pendingLoginFinal = response
                            }
                        } else {
                            // 从未有本地登录事实却收到业务 FINAL 属于不可重开的服务端契约违例。
                            current.preLoginConsumableFinalRejected = true
                            current.recoveryPermanentlyStopped = true
                            current.nextRecoveryAt = nil
                            current.pendingUserProvidedEvidence = nil
                            disposition = .rejected
                        }
                    } else {
                        // 登录后业务 FINAL 或无匹配诊断 FINAL 都直接冻结；业务候选仍只从账号 outbox 读取。
                        current.terminalResult = response
                        current.pendingLoginFinal = nil
                        current.lastDecisionSequence = Self.maximumSequence(
                            current.lastDecisionSequence,
                            response.decisionSequence
                        )
                        current.nextRecoveryAt = nil
                        current.recoveryAttempt = 0
                        if response.isConsumableFinal == false {
                            disposition = .rejected
                        }
                    }
                } else {
                    // 证据在服务端看到的当前决策也属于时序门槛；后续必须严格高于该快照才能交付。
                    let acceptedThrough = Self.maximumSequence(current.lastDecisionSequence, response.decisionSequence)
                    current.lastDecisionSequence = acceptedThrough
                    current.invalidatedThroughDecisionSequence = Self.maximumSequence(
                        current.invalidatedThroughDecisionSequence,
                        acceptedThrough
                    )
                }
                if current.pendingUserProvidedEvidence?.eventId == pending.eventId {
                    current.pendingUserProvidedEvidence = nil
                }
            }) != nil else { return .rejected }
            return disposition
        } catch is CancellationError {
            return .deferred
        } catch let error as LinkAttributionError {
            if error.isRetryable { return .deferred }
            _ = try? discardPendingUserProvidedEvidence(pending, installationEventId: expectedEventId)
            return .rejected
        } catch {
            _ = try? discardPendingUserProvidedEvidence(pending, installationEventId: expectedEventId)
            return .rejected
        }
    }

    /**
     在宿主真实登录成功且业务会话已落库后登记首次登录。

     SDK 只复用当前安装的随机 `eventId`，不读取或上传账号、Token、用户 ID 或设备稳定标识。
     登录事件 ID 在发送前持久化；失败后可由 `retryPendingLoginConfirmation()` 复用同一幂等键重试。
     */
    public func trackLoginCompleted() async throws -> LoginConfirmation {
        let expectedEventId = try ensureLoginCompletedOccurrence().eventId
        return try await trackExistingLoginCompleted(expectedEventId: expectedEventId)
    }

    /// 只发送指定安装代次中已经冻结的登录事实，并统一处理永久失败；恢复入口不得经由会创建事实的公开 API。
    private func trackExistingLoginCompleted(expectedEventId: String) async throws -> LoginConfirmation {
        do {
            return try await trackLoginCompletedOnce(expectedEventId: expectedEventId)
        } catch let error as LinkAttributionError {
            if error.isRetryable == false {
                _ = try? mutateExistingState(expectedEventId: expectedEventId) { state in
                    guard state.loginConfirmation == nil, state.loginEventId != nil else { return }
                    if let pending = state.pendingLoginFinal,
                       let deliveryId = Self.deliveryId(for: pending) {
                        state.suppressedUnboundDeliveryId = deliveryId
                    }
                    state.pendingLoginFinal = nil
                    state.loginConfirmationPermanentlyRejected = true
                    state.loginRejectionCredentialScope = credentialScope
                    state.nextRecoveryAt = nil
                    state.recoveryPermanentlyStopped = true
                    state.recoveryCredentialScope = credentialScope
                }
            }
            throw error
        }
    }

    /// 仅重试先前已由真实登录成功信号创建的待发送事实；无待办时返回 `nil`。
    public func retryPendingLoginConfirmation() async throws -> LoginConfirmation? {
        guard let state = try loadStateStrict() else { return nil }
        // 已确认不再属于“待重试”；避免宿主每次冷启动都误判为刚恢复并重复刷新 FINAL。
        if state.loginConfirmation != nil { return nil }
        if state.loginConfirmationPermanentlyRejected { return nil }
        guard state.loginEventId != nil else { return nil }
        return try await trackExistingLoginCompleted(expectedEventId: state.eventId)
    }

    /// 恢复编排专用入口；直接复用已冻结登录事实，不通过兼容入口为新安装创建事实。
    private func retryPendingLoginConfirmation(expectedEventId: String) async throws -> LoginConfirmation? {
        guard let state = loadState(), state.eventId == expectedEventId else { throw CancellationError() }
        if state.loginConfirmation != nil { return nil }
        if state.loginConfirmationPermanentlyRejected { return nil }
        guard state.loginEventId != nil else { return nil }
        return try await trackExistingLoginCompleted(expectedEventId: expectedEventId)
    }

    /**
     在宿主登录成功回调的同步栈内原子绑定脱敏账号并冻结登录事实。

     本方法不触网、不上传账号作用域；绑定失败时不会留下半条登录事件。宿主随后调用
     `trackLoginCompleted()` 发送同一持久事实，业务 FINAL 只从 `pendingFinalDelivery(accountScope:)` 读取。
     */
    public func recordAuthenticatedLogin(accountScope: String) throws {
        let normalized = try validatedAccountScope(accountScope)
        try mutateState { state in
            try bindAuthenticatedAccount(normalized, to: &state)
            recordLoginCompletedOccurrence(in: &state)
        }
    }

    /**
     兼容旧宿主的拆分式登录事实入口；新接入应使用 `recordAuthenticatedLogin(accountScope:)`，
     避免登录事实与账号绑定之间出现可消费 FINAL 的竞态。
     */
    @available(*, deprecated, message: "请使用 recordAuthenticatedLogin(accountScope:) 原子绑定账号并记录登录事实")
    public func recordLoginCompletedOccurrence() throws {
        _ = try ensureLoginCompletedOccurrence()
    }

    /// 是否已经由宿主真实登录信号建立本地事实；仅供内部恢复调度，不代表平台已确认或匹配成功。
    public var hasRecordedLoginCompletedFact: Bool {
        loadState()?.loginEventId != nil
    }

    /// 是否仍可显示用户主动补强入口；配置关闭或平台结果已经 FINAL 时为 `false`。
    public var canSubmitUserProvidedEvidence: Bool {
        guard configuration.userProvidedEvidenceEnabled else { return false }
        let state = loadState()
        return state?.terminalResult?.isFinal != true
            && state?.pendingLoginFinal == nil
            && state?.preLoginConsumableFinalRejected != true
    }

    /**
     恢复当前安装尚未完成的归因工作。

     宿主只在启动、前台、网络恢复或 SDK 返回的计划时间调用本方法；SDK 内部按“主动证据 →
     登录事实 → 安装查询 → FINAL 轮询”顺序执行，并持久化指数退避。前台和网络恢复信号可提前
     唤醒一次，定时触发严格遵守 `nextRetryAt`。所有失败都旁路宿主原业务；只有合法 FINAL 会
     进入本地 outbox，业务仍须调用 `pendingFinalDelivery(accountScope:)` 并在真实处理成功后 ack。
     可消费 FINAL 的 `phase` 为 `.final`，但 `result` 固定为 `nil`，避免恢复入口绕过账号 outbox。

     - Parameters:
       - trigger: 宿主观察到的真实生命周期/网络触发，不由 SDK 猜测。
       - pollingTimeout: 本次前台允许持续轮询的最长秒数；0 表示只做一次查询并返回计划时间。
     */
    public func resumePendingAttribution(
        trigger: AttributionRecoveryTrigger,
        pollingTimeout: TimeInterval = 15
    ) async throws -> AttributionRecoveryOutcome {
        guard pollingTimeout.isFinite, (0...60).contains(pollingTimeout) else {
            throw LinkAttributionError.invalidArgument("pollingTimeout must be between 0 and 60 seconds")
        }
        let expectedEventId = try mutateState { _ in }.eventId
        let key = RecoveryTaskKey(
            eventId: expectedEventId,
            credentialScope: credentialScope,
            triggerClass: Self.recoveryTriggerClass(trigger),
            pollingTimeoutBitPattern: pollingTimeout.bitPattern,
            requestTimeoutBitPattern: configuration.timeout.bitPattern,
            appVersion: configuration.appVersion,
            userProvidedEvidenceEnabled: configuration.userProvidedEvidenceEnabled
        )
        let observedCompletion = lock.withLock { synchronization.recoveryCompletionGeneration }
        return try await synchronization.recoveryGate.withLock {
            try ensureCurrentInstallation(expectedEventId)
            if let completion = lock.withLock({ synchronization.lastRecoveryCompletion }),
               completion.generation > observedCompletion,
               completion.key == key {
                // 同一时刻到达的等价生命周期信号复用刚完成的结果，不能把一次 503 记成多次退避。
                return completion.outcome
            }
            let outcome = try await resumePendingAttributionOnce(
                trigger: trigger,
                pollingTimeout: pollingTimeout,
                expectedEventId: expectedEventId
            )
            try recordRecoveryCompletion(outcome, key: key, expectedEventId: expectedEventId)
            return outcome
        }
    }

    private func resumePendingAttributionOnce(
        trigger: AttributionRecoveryTrigger,
        pollingTimeout: TimeInterval,
        expectedEventId: String
    ) async throws -> AttributionRecoveryOutcome {
        try ensureCurrentInstallation(expectedEventId)
        let deadline = ProcessInfo.processInfo.systemUptime + pollingTimeout
        if let terminal = loadState()?.terminalResult, terminal.isFinal,
           loadState()?.preLoginConsumableFinalRejected != true {
            try clearRecoverySchedule(expectedEventId: expectedEventId)
            return AttributionRecoveryOutcome(
                phase: .final,
                result: terminal.isConsumableFinal ? nil : terminal
            )
        }
        if let state = loadState(), state.recoveryCredentialScope != nil,
           state.recoveryCredentialScope != credentialScope {
            // SDK Key 已轮换；旧凭据造成的退避/永久停止不能阻断新凭据自愈。
            try clearRecoverySchedule(expectedEventId: expectedEventId, clearPermanentStop: true)
        }
        if let state = loadState(), state.loginConfirmationPermanentlyRejected,
           state.loginRejectionCredentialScope != nil,
           state.loginRejectionCredentialScope != credentialScope {
            guard try mutateExistingState(expectedEventId: expectedEventId, { current in
                current.loginConfirmationPermanentlyRejected = false
                current.loginRejectionCredentialScope = nil
                current.recoveryPermanentlyStopped = false
                current.recoveryCredentialScope = nil
            }) != nil else { throw CancellationError() }
        } else if loadState()?.recoveryPermanentlyStopped == true {
            return AttributionRecoveryOutcome(phase: .stopped)
        }
        if trigger == .scheduled || trigger == .appLaunch,
           let nextRetryAt = loadState()?.nextRecoveryAt.flatMap(Self.date(from:)),
           nextRetryAt > Date() {
            return AttributionRecoveryOutcome(phase: .notDue, nextRetryAt: nextRetryAt)
        }

        do {
            if configuration.userProvidedEvidenceEnabled,
               let evidenceResult = try await retryPendingUserProvidedEvidence(expectedEventId: expectedEventId),
               evidenceResult == .deferred {
                // 若宿主在证据请求期间取消本次生命周期任务，不能把取消误记成一次网络失败并扩大退避。
                try Task.checkCancellation()
                let failure = LinkAttributionError.network("pending_user_evidence")
                return AttributionRecoveryOutcome(
                    phase: .retryScheduled,
                    nextRetryAt: try scheduleRetry(after: failure, expectedEventId: expectedEventId),
                    failure: failure
                )
            }

            if hasRecordedLoginCompletedFact {
                try ensureCurrentInstallation(expectedEventId)
                _ = try await retryPendingLoginConfirmation(expectedEventId: expectedEventId)
                try ensureCurrentInstallation(expectedEventId)
                if loadState()?.loginConfirmationPermanentlyRejected == true {
                    try stopAutomaticRecovery(expectedEventId: expectedEventId)
                    return AttributionRecoveryOutcome(phase: .stopped)
                }
            }

            let current: AttributionResult
            do {
                current = try await stateNetworkGate.withLock {
                    try ensureCurrentInstallation(expectedEventId)
                    return try await resolveInstallationOnce(signals: nil, expectedEventId: expectedEventId)
                }
                try ensureCurrentInstallation(expectedEventId)
            } catch LinkAttributionError.timeout
                where pollingTimeout > 0 && loadState()?.loginConfirmation != nil {
                guard let attributionId = loadState()?.attributionId else { throw LinkAttributionError.timeout }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw LinkAttributionError.timeout }
                // 登录/证据使旧序号失效时，优先利用本次前台预算等待更高决策，而不是立刻扩大指数退避。
                let final = try await waitForAttribution(
                    attributionId: attributionId,
                    timeout: remaining
                )
                try ensureCurrentInstallation(expectedEventId)
                try clearRecoverySchedule(expectedEventId: expectedEventId)
                return AttributionRecoveryOutcome(
                    phase: .final,
                    result: final.isConsumableFinal ? nil : final
                )
            }
            if current.isFinal {
                try clearRecoverySchedule(expectedEventId: expectedEventId)
                return AttributionRecoveryOutcome(
                    phase: .final,
                    result: current.isConsumableFinal ? nil : current
                )
            }
            guard hasRecordedLoginCompletedFact else {
                try clearRecoverySchedule(expectedEventId: expectedEventId)
                return AttributionRecoveryOutcome(phase: .waitingForLogin, result: current)
            }
            guard pollingTimeout > 0 else {
                let next = try scheduleNextEvaluation(retryAfterMs: current.retryAfterMs, expectedEventId: expectedEventId)
                return AttributionRecoveryOutcome(phase: .waitingForFinal, result: current, nextRetryAt: next)
            }

            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw LinkAttributionError.timeout }
            let final = try await waitForAttribution(
                attributionId: current.attributionId,
                timeout: remaining
            )
            try ensureCurrentInstallation(expectedEventId)
            try clearRecoverySchedule(expectedEventId: expectedEventId)
            return AttributionRecoveryOutcome(phase: .final, result: final)
        } catch LinkAttributionError.businessDeliveryRequired {
            try ensureCurrentInstallation(expectedEventId)
            try clearRecoverySchedule(expectedEventId: expectedEventId)
            return AttributionRecoveryOutcome(phase: .final)
        } catch is CancellationError {
            // App 转入后台或宿主结束当前代次时不制造失败次数；下次生命周期驱动继续原持久事实。
            throw CancellationError()
        } catch let failure as LinkAttributionError {
            if failure.isRetryable {
                return AttributionRecoveryOutcome(
                    phase: .retryScheduled,
                    nextRetryAt: try scheduleRetry(after: failure, expectedEventId: expectedEventId),
                    failure: failure
                )
            }
            try stopAutomaticRecovery(expectedEventId: expectedEventId)
            return AttributionRecoveryOutcome(phase: .stopped, failure: failure)
        } catch {
            let failure = LinkAttributionError.invalidResponse
            try stopAutomaticRecovery(expectedEventId: expectedEventId)
            return AttributionRecoveryOutcome(phase: .stopped, failure: failure)
        }
    }

    /**
     仅在宿主已修复配置、完成 SDK 升级或产生新的真实业务事实后显式解除永久停止。

     本方法不删除安装、登录、证据、FINAL 或 outbox，也不触网；普通前台切换不应调用。
     */
    public func resetAutomaticRecovery() throws {
        try clearRecoverySchedule(clearPermanentStop: true)
    }

    /**
     把当前安装的登录事实绑定到宿主本地脱敏账号作用域。

     SDK 不上传该值；首次绑定后禁止换绑，避免同一安装的冻结结果被另一个账号误消费。
     宿主应传入不可逆、非明文的稳定作用域，而不是邮箱、手机号或业务 Token。
     */
    @available(*, deprecated, message: "请使用 recordAuthenticatedLogin(accountScope:) 原子绑定账号并记录登录事实")
    public func bindAuthenticatedAccount(scope: String) throws {
        let normalized = try validatedAccountScope(scope)
        try mutateState { state in
            try bindAuthenticatedAccount(normalized, to: &state)
        }
    }

    /// 返回当前账号仍待业务确认的 FINAL；无匹配、账号不符或已 ack 时返回 `nil`。
    public func pendingFinalDelivery(accountScope: String) throws -> AttributionDelivery? {
        let normalized = try validatedAccountScope(accountScope)
        guard let state = try loadStateStrict(), state.deliveryAccountScopeTrusted,
              state.deliveryAccountScope == normalized,
              state.loginConfirmation != nil,
              state.preLoginConsumableFinalRejected == false,
              let result = state.terminalResult, result.isConsumableFinal,
              let deliveryId = Self.deliveryId(for: result),
              state.suppressedUnboundDeliveryId != deliveryId,
              state.acknowledgedDeliveryId != deliveryId else {
            return nil
        }
        return AttributionDelivery(deliveryId: deliveryId, result: result)
    }

    /**
     宿主真实业务处理成功后确认一条 FINAL 已消费。

     ack 同时校验账号作用域和当前冻结决策，迟到、跨账号或伪造 ID 都会被拒绝；
     SDK 仍保留终态结果用于路由和诊断，不把 ack 冒充为业务奖励回执。
     */
    public func acknowledgeFinalDelivery(deliveryId: String, accountScope: String) throws {
        let normalized = try validatedAccountScope(accountScope)
        guard try mutateExistingState({ state in
            guard state.deliveryAccountScopeTrusted,
                  state.deliveryAccountScope == normalized,
                  state.loginConfirmation != nil,
                  state.preLoginConsumableFinalRejected == false,
                  let result = state.terminalResult,
                  Self.deliveryId(for: result) == deliveryId,
                  state.suppressedUnboundDeliveryId != deliveryId else {
                throw LinkAttributionError.invalidArgument("final delivery does not belong to the current account scope")
            }
            state.acknowledgedDeliveryId = deliveryId
        }) != nil else {
            throw LinkAttributionError.invalidArgument("final delivery does not belong to the current account scope")
        }
    }

    /// 判断当前终态是否属于指定本地账号；不要求仍待 ack，也不返回分享码或路由。
    public func isFinalBound(to accountScope: String) throws -> Bool {
        let normalized = try validatedAccountScope(accountScope)
        guard let state = try loadStateStrict(), state.deliveryAccountScopeTrusted,
              state.deliveryAccountScope == normalized,
              state.loginConfirmation != nil,
              state.preLoginConsumableFinalRejected == false,
              let result = state.terminalResult,
              let deliveryId = Self.deliveryId(for: result),
              state.suppressedUnboundDeliveryId != deliveryId else { return false }
        return result.isFinal
    }

    /// 完成一次可恢复的登录确认；必要时先登记同一安装事件。
    private func trackLoginCompletedOnce(expectedEventId: String) async throws -> LoginConfirmation {
        // 登录事实已经由公开入口同步落盘；异步旧代次不得在 clear 后替新安装制造登录事实。
        let pendingState = try requireState()
        guard pendingState.eventId == expectedEventId else { throw CancellationError() }
        if let confirmation = pendingState.loginConfirmation { return confirmation }
        return try await stateNetworkGate.withLock {
            try ensureCurrentInstallation(expectedEventId)
            if loadState()?.attributionId == nil {
                do {
                    _ = try await resolveInstallationOnce(signals: nil, expectedEventId: expectedEventId)
                } catch LinkAttributionError.invalidResponse where loadState()?.attributionId != nil {
                    // 门槛违例也先保存 attributionId，便于平台记录同一登录事实；业务结果仍永久拒绝。
                } catch LinkAttributionError.timeout where loadState()?.attributionId != nil {
                    // 登录响应丢失恢复只保留 attributionId，后续先幂等确认登录。
                }
            }
            guard var registeredState = loadState(), registeredState.eventId == expectedEventId else {
                throw CancellationError()
            }
            guard registeredState.attributionId != nil else {
                throw LinkAttributionError.invalidArgument("installation must be registered before login confirmation")
            }
            if configuration.userProvidedEvidenceEnabled,
               let pendingEvidence = registeredState.pendingUserProvidedEvidence {
                let submission = await sendUserProvidedEvidenceWhileHoldingNetworkGate(
                    pendingEvidence,
                    expectedEventId: expectedEventId
                )
                // 证据入口将取消映射为 deferred；抛错式登录恢复仍须原样传播调用任务的取消。
                try Task.checkCancellation()
                // 证据请求期间可能被清理并建立新安装；成功或临时失败都不能让旧登录任务采用新代次。
                guard let refreshedState = loadState(), refreshedState.eventId == expectedEventId else {
                    throw CancellationError()
                }
                guard submission != .deferred else {
                    // 宿主业务登录已经完成；这里只延后平台登录事实，保持原 eventId/occurredAt 等待恢复。
                    throw LinkAttributionError.network("pending_user_evidence")
                }
                registeredState = refreshedState
            }
            guard let eventId = registeredState.loginEventId,
                  let occurredAt = registeredState.loginOccurredAt else {
                throw LinkAttributionError.invalidArgument("installation must be registered before login confirmation")
            }
            if let confirmation = registeredState.loginConfirmation { return confirmation }
            guard try mutateExistingState(expectedEventId: expectedEventId, { current in
                guard current.loginEventId == eventId else {
                    throw LinkAttributionError.invalidResponse
                }
                if current.loginSubmissionAttemptedAt == nil {
                    // 在真正触网前持久化发送尝试；仅凭“本地计划登录”不能合法化服务端提前 FINAL。
                    current.loginSubmissionAttemptedAt = now()
                }
            }) != nil else {
                throw CancellationError()
            }
            let confirmation: LoginConfirmation = try await request(
                path: "/v1/sdk/events/login-completed",
                method: "POST",
                body: LoginCompletedRequest(
                    installationEventId: expectedEventId,
                    eventId: eventId,
                    occurredAt: occurredAt,
                    reportedAt: now()
                ),
                idempotencyKey: eventId
            )
            guard try mutateExistingState(expectedEventId: expectedEventId, { current in
                guard current.loginEventId == eventId else { return }
                current.loginConfirmation = confirmation
                current.loginConfirmationPermanentlyRejected = false
                current.loginRejectionCredentialScope = nil
                // 登录受理前已经见到的决策只属于门槛前快照；后续必须收到更高追加序号才能交付。
                current.invalidatedThroughDecisionSequence = Self.maximumSequence(
                    current.invalidatedThroughDecisionSequence,
                    current.lastDecisionSequence
                )
                // 登录只推动尚未冻结的归因继续求值。FINAL 是不可变历史，客户端不会因迟到登录重开它。
            }) != nil else { throw CancellationError() }
            return confirmation
        }
    }

    /// 仅删除同一安装代次中的指定证据待办；并发创建的新事件不得被旧任务清除。
    private func discardPendingUserProvidedEvidence(
        _ pending: PendingUserProvidedEvidence,
        installationEventId: String?
    ) throws {
        guard let installationEventId else { return }
        try mutateExistingState(expectedEventId: installationEventId) { current in
            guard current.pendingUserProvidedEvidence?.eventId == pending.eventId else { return }
            current.pendingUserProvidedEvidence = nil
        }
    }

    /// 清除当前项目/环境范围的本地安装状态，不影响服务端不可变 Decision 历史。
    public func clearLocalState() {
        lock.withLock {
            defaults.removeObject(forKey: storageKey)
            synchronization.recoveryCompletionGeneration &+= 1
            synchronization.lastRecoveryCompletion = nil
        }
    }

    private func request<Response: Decodable>(path: String, method: String) async throws -> Response { try await request(url: endpoint(path), method: method) }
    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body,
        idempotencyKey: String? = nil,
        appVersion: String? = nil
    ) async throws -> Response {
        try await request(
            url: endpoint(path),
            method: method,
            body: try JSONEncoder().encode(body),
            idempotencyKey: idempotencyKey,
            appVersion: appVersion
        )
    }
    private func request<Response: Decodable>(
        url: URL,
        method: String,
        body: Data? = nil,
        idempotencyKey: String? = nil,
        timeoutInterval: TimeInterval? = nil,
        appVersion: String? = nil
    ) async throws -> Response {
        // SDK Key 仅绑定到固定 API Base URL 下的请求；错误响应体不会透传给业务调用方。
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = min(configuration.timeout, max(timeoutInterval ?? configuration.timeout, 0.001))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.sdkKey, forHTTPHeaderField: "X-SDK-Key")
        request.setValue(appVersion ?? configuration.appVersion, forHTTPHeaderField: "X-App-Version")
        if method == "GET" {
            // 追加式决策查询必须回源，不能让 URLCache 复用旧 provisional/FINAL 快照。
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        do {
            // 即使宿主注入自定义 URLSession，也由单请求 delegate 禁止重定向，避免 SDK Key/业务 URL 跨 origin。
            let (bytes, response) = try await session.bytes(for: request, delegate: requestDelegate)
            guard let http = response as? HTTPURLResponse else { throw LinkAttributionError.invalidResponse }
            guard let responseURL = http.url,
                  Self.sameOrigin(request.url, responseURL) else {
                throw LinkAttributionError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw LinkAttributionError.http(status: http.statusCode)
            }
            guard Self.isSupportedJSONContentType(http.value(forHTTPHeaderField: "Content-Type")),
                  http.expectedContentLength <= 0 || http.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
                throw LinkAttributionError.invalidResponse
            }
            var data = Data()
            if http.expectedContentLength > 0 {
                data.reserveCapacity(Int(http.expectedContentLength))
            }
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes else { throw LinkAttributionError.invalidResponse }
                data.append(byte)
            }
            guard String(data: data, encoding: .utf8) != nil else { throw LinkAttributionError.invalidResponse }
            do { return try JSONDecoder().decode(Response.self, from: data) } catch { throw LinkAttributionError.invalidResponse }
        } catch let error as LinkAttributionError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .timedOut { throw LinkAttributionError.timeout }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw LinkAttributionError.network("transport") }
    }

    /// 只读便捷入口用于非抛出式 UI 状态；损坏缓存返回 nil，但任何会创建或触网的入口都会走严格读取并 fail-closed。
    private func loadState() -> InstallationState? {
        try? loadStateStrict()
    }

    /// 严格读取并把可证明安全的旧终态/已登记状态迁移为当前结构；未完成登记的旧请求身份无法还原，必须拒绝猜测。
    private func loadStateStrict() throws -> InstallationState? {
        try lock.withLock {
            guard let data = defaults.data(forKey: storageKey) else { return nil }
            let (state, migrated) = try decodeStoredState(data)
            if migrated {
                do { defaults.set(try JSONEncoder().encode(state), forKey: storageKey) }
                catch { throw LinkAttributionError.storage("write_failed") }
            }
            return state
        }
    }

    private func decodeStoredState(_ data: Data) throws -> (InstallationState, Bool) {
        do {
            let decoder = JSONDecoder()
            decoder.userInfo[.allowsLegacyAttributionCache] = true
            var state = try decoder.decode(InstallationState.self, from: data)
            var migrated = false
            switch state.storageVersion {
            case Self.currentStorageVersion:
                break
            case 1, 2:
                // 旧版本未冻结首次安装的 appVersion/平台。只有已有 attributionId 时才证明服务端已登记，
                // 后续只会 GET；尚未获得 attributionId 的旧状态可能经历过“服务端成功、响应丢失”，不能用新版本猜测重放。
                guard state.attributionId != nil else {
                    throw LinkAttributionError.storage("legacy_install_identity_unavailable")
                }
                state.storageVersion = Self.currentStorageVersion
                state.scopeIdentity = cacheIdentity
                state.installationPlatform = .iOS
                state.installationAppVersion = configuration.appVersion
                state.deterministicClickTokenAbsent = true
                migrated = true
            default:
                throw LinkAttributionError.storage("unsupported_state_version")
            }
            guard state.scopeIdentity == cacheIdentity,
                  Self.isValidUUID(state.eventId),
                  let occurredAt = state.occurredAt,
                  Self.date(from: occurredAt) != nil,
                  state.installationPlatform == .iOS,
                  let appVersion = state.installationAppVersion,
                  Self.isNumericAppVersion(appVersion),
                  state.deterministicClickTokenAbsent == true,
                  state.attributionId.map(Self.isValidUUID) ?? true,
                  state.recoveryAttempt >= 0,
                  state.deliveryAccountScopeTrusted == false || state.deliveryAccountScope != nil
            else {
                throw LinkAttributionError.storage("invalid_state")
            }
            return (state, migrated)
        } catch let error as LinkAttributionError {
            throw error
        } catch {
            throw LinkAttributionError.storage("invalid_state")
        }
    }

    /// 在同一临界区内完成 decode → merge → encode，所有异步流程只能合并自己的字段，不能整对象旧快照回写。
    @discardableResult
    private func mutateState(_ operation: (inout InstallationState) throws -> Void) throws -> InstallationState {
        try lock.withLock {
            let stateData = defaults.data(forKey: storageKey)
            var state = try stateData.map { try decodeStoredState($0).0 }
                ?? InstallationState(
                    eventId: UUID().uuidString.lowercased(),
                    occurredAt: now(),
                    scopeIdentity: cacheIdentity,
                    appVersion: configuration.appVersion
                )
            try operation(&state)
            do {
                defaults.set(try JSONEncoder().encode(state), forKey: storageKey)
                return state
            } catch {
                throw LinkAttributionError.storage("write_failed")
            }
        }
    }

    /**
     只更新已经存在且仍属于预期安装代次的状态。

     网络响应、退避和清理回调必须使用本入口；若用户在请求期间调用 `clearLocalState()`，迟到任务只丢弃，
     不能由通用 `mutateState` 的默认值重新创建安装事实。
     */
    @discardableResult
    private func mutateExistingState(
        expectedEventId: String? = nil,
        _ operation: (inout InstallationState) throws -> Void
    ) throws -> InstallationState? {
        try lock.withLock {
            guard let data = defaults.data(forKey: storageKey) else { return nil }
            var state = try decodeStoredState(data).0
            guard expectedEventId == nil || state.eventId == expectedEventId else { return nil }
            try operation(&state)
            do {
                defaults.set(try JSONEncoder().encode(state), forKey: storageKey)
                return state
            } catch {
                throw LinkAttributionError.storage("write_failed")
            }
        }
    }
    /// 读取必须存在的安装状态；同步登录事实入口已经负责先建立并持久化。
    private func requireState() throws -> InstallationState {
        guard let state = try loadStateStrict() else { throw LinkAttributionError.storage("unavailable") }
        return state
    }

    /// 异步代次检查：clear/recreate 后旧任务按取消收尾，不把迟到结果记成新安装失败。
    private func ensureCurrentInstallation(_ expectedEventId: String) throws {
        guard try loadStateStrict()?.eventId == expectedEventId else { throw CancellationError() }
    }

    /// 在同一状态锁临界区核对安装代次并发布进程内恢复结果，clear 不能夹在二者之间复活旧完成记录。
    private func recordRecoveryCompletion(
        _ outcome: AttributionRecoveryOutcome,
        key: RecoveryTaskKey,
        expectedEventId: String
    ) throws {
        try lock.withLock {
            guard let data = defaults.data(forKey: storageKey) else { throw CancellationError() }
            let state = try decodeStoredState(data).0
            guard state.eventId == expectedEventId else { throw CancellationError() }
            synchronization.recoveryCompletionGeneration &+= 1
            synchronization.lastRecoveryCompletion = RecoveryCompletion(
                generation: synchronization.recoveryCompletionGeneration,
                key: key,
                outcome: outcome
            )
        }
    }

    /// 兼容异步旧入口的本地登录事实自愈；新宿主应先调用原子 `recordAuthenticatedLogin(accountScope:)`。
    private func ensureLoginCompletedOccurrence() throws -> InstallationState {
        try mutateState { state in
            recordLoginCompletedOccurrence(in: &state)
        }
    }

    /// 只在同一 `mutateState` 临界区内改写登录事实，供原子账号绑定与兼容入口复用。
    private func recordLoginCompletedOccurrence(in state: inout InstallationState) {
        if state.loginConfirmationPermanentlyRejected {
            // 只有宿主新的真实登录成功信号会进入本同步入口；为新会话创建新事实并解除旧登录上报失败。
            if let pending = state.pendingLoginFinal,
               let deliveryId = Self.deliveryId(for: pending) {
                state.suppressedUnboundDeliveryId = deliveryId
            }
            state.pendingLoginFinal = nil
            state.loginEventId = UUID().uuidString.lowercased()
            state.loginOccurredAt = now()
            state.loginSubmissionAttemptedAt = nil
            state.loginConfirmation = nil
            state.loginConfirmationPermanentlyRejected = false
            state.loginRejectionCredentialScope = nil
            state.recoveryAttempt = 0
            state.nextRecoveryAt = nil
            if state.preLoginConsumableFinalRejected == false {
                state.recoveryPermanentlyStopped = false
            }
            return
        }
        if state.loginEventId == nil {
            state.loginEventId = UUID().uuidString.lowercased()
            state.loginSubmissionAttemptedAt = nil
            state.recoveryAttempt = 0
            state.nextRecoveryAt = nil
            if state.preLoginConsumableFinalRejected == false {
                state.recoveryPermanentlyStopped = false
            }
        }
        if state.loginOccurredAt == nil {
            state.loginOccurredAt = now()
        }
    }

    /// 在本地绑定脱敏账号；绑定前已经形成的业务 FINAL 永久抑制，禁止任意后来账号认领。
    private func bindAuthenticatedAccount(_ normalized: String, to state: inout InstallationState) throws {
        if state.deliveryAccountScopeTrusted,
           let existing = state.deliveryAccountScope,
           existing != normalized {
            throw LinkAttributionError.invalidArgument("attribution delivery is already bound to another account scope")
        }
        if state.deliveryAccountScopeTrusted == false,
           let result = state.terminalResult,
           result.isConsumableFinal {
            state.suppressedUnboundDeliveryId = Self.deliveryId(for: result)
        }
        if state.deliveryAccountScopeTrusted == false,
           let pending = state.pendingLoginFinal,
           pending.isConsumableFinal {
            // 旧拆分 API 在账号绑定前看到的 FINAL 不能被任意后来账号认领。
            state.suppressedUnboundDeliveryId = Self.deliveryId(for: pending)
        }
        state.deliveryAccountScope = normalized
        state.deliveryAccountScopeTrusted = true
    }

    /// 隔离“登录请求已发送但确认响应丢失”期间看到的不可变 FINAL；不同结果视为终态重开并永久停止。
    private func quarantinePendingLoginFinal(_ result: AttributionResult, expectedEventId: String) throws {
        var contractViolation = false
        guard try mutateExistingState(expectedEventId: expectedEventId, { state in
            guard state.attributionId == nil || state.attributionId == result.attributionId else {
                contractViolation = true
                state.preLoginConsumableFinalRejected = true
                state.recoveryPermanentlyStopped = true
                state.nextRecoveryAt = nil
                return
            }
            state.attributionId = result.attributionId
            if let quarantined = state.pendingLoginFinal,
               Self.sameFrozenAttribution(quarantined, result) == false {
                contractViolation = true
                state.preLoginConsumableFinalRejected = true
                state.recoveryPermanentlyStopped = true
                state.nextRecoveryAt = nil
                return
            }
            state.pendingLoginFinal = result
        }) != nil else {
            throw LinkAttributionError.invalidResponse
        }
        if contractViolation { throw LinkAttributionError.invalidResponse }
    }

    /**
     校验结果属于当前安装且决策序号不倒退。登录前仅拒绝包含匹配关系的可消费 FINAL；
     `NO_MATCH/UNRESOLVED/RISK_BLOCKED/EXPIRED` 可用于诊断，但不会触发任何业务权益。
     */
    private func validateAttribution(
        _ result: AttributionResult,
        for state: InstallationState?,
        expectedAttributionId: String? = nil
    ) throws {
        if let expectedAttributionId, result.attributionId != expectedAttributionId {
            throw LinkAttributionError.invalidResponse
        }
        if state?.preLoginConsumableFinalRejected == true {
            // FINAL 不可重开；门槛前误发过可消费 FINAL 后，本安装后续任何决策都不再可信。
            throw LinkAttributionError.invalidResponse
        }
        var isExactCachedTerminal = false
        if let terminal = state?.terminalResult,
           terminal.isFinal {
            guard Self.sameFrozenAttribution(terminal, result) else {
                // 服务端已冻结的决策和 share-code 集合不可重开；迟到或错作用域响应不得覆盖本地真源。
                throw LinkAttributionError.invalidResponse
            }
            // 本地已保存同一冻结决策时，它自身的 sequence 就是真源；不受迟到失败响应的辅助高水位影响。
            isExactCachedTerminal = true
        }
        if isExactCachedTerminal == false,
           let state,
           state.attributionId == nil || state.attributionId == result.attributionId {
            if let previous = state.lastDecisionSequence,
               result.decisionSequence < previous {
                throw DeferredAttributionDecision(retryAfterMs: result.retryAfterMs)
            }
            if let invalidated = state.invalidatedThroughDecisionSequence,
               result.decisionSequence <= invalidated {
                throw DeferredAttributionDecision(retryAfterMs: result.retryAfterMs)
            }
        }
        if result.isConsumableFinal, state?.loginConfirmation == nil {
            if state?.loginEventId != nil,
               state?.loginOccurredAt != nil,
               state?.loginSubmissionAttemptedAt != nil {
                // 服务端可能已受理登录，但响应在弱网中丢失；同一 FINAL 必须等幂等确认恢复后再交付。
                throw PendingLoginConfirmationDecision(retryAfterMs: result.retryAfterMs)
            }
            throw LinkAttributionError.invalidResponse
        }
        if let quarantined = state?.pendingLoginFinal,
           Self.sameFrozenAttribution(quarantined, result) == false {
            // FINAL 首次被看到时即已不可变；登录确认恢复只能解封同一份冻结结果。
            throw LinkAttributionError.invalidResponse
        }
    }

    /// 旧查询入口只返回无业务匹配的诊断结果；含 share code 的 FINAL 必须从账号绑定 outbox 读取。
    private func publicDiagnosticResult(_ result: AttributionResult) throws -> AttributionResult {
        guard result.isConsumableFinal == false else {
            throw LinkAttributionError.businessDeliveryRequired
        }
        return result
    }

    /// 比较 FINAL 中真正冻结的业务字段；`reportedAt` 和每次路由交付新建的会话 ID 不属于决策身份。
    private static func sameFrozenAttribution(_ expected: AttributionResult, _ actual: AttributionResult) -> Bool {
        actual.isFinal
            && expected.attributionId == actual.attributionId
            && expected.processState == actual.processState
            && expected.outcome == actual.outcome
            && expected.status == actual.status
            && expected.resolverType == actual.resolverType
            && expected.finalMatches == actual.finalMatches
            && expected.decisionSequence == actual.decisionSequence
            && expected.occurredAt == actual.occurredAt
            && expected.finalizedAt == actual.finalizedAt
            && expected.retryAfterMs == actual.retryAfterMs
    }

    /// 合并可选决策序号，保持只增不减。
    private static func maximumSequence(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            return max(lhs, rhs)
        case let (.some(lhs), .none):
            return lhs
        case let (.none, .some(rhs)):
            return rhs
        case (.none, .none):
            return nil
        }
    }

    /// 前台与网络恢复都可提前唤醒；启动与定时信号都必须遵守既有计划，同类并发只执行一次恢复。
    private static func recoveryTriggerClass(_ trigger: AttributionRecoveryTrigger) -> String {
        switch trigger {
        case .appForeground, .networkAvailable:
            return "WAKE"
        case .appLaunch, .scheduled:
            return "DUE"
        }
    }

    private func endpoint(_ path: String) -> URL { apiBaseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
    private func businessURL(from url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let host = components.host.flatMap(Self.normalizeLinkHost),
              components.fragment == nil,
              url.absoluteString.utf8.count <= 2_048,
              allowedLinkHosts.isEmpty || allowedLinkHosts.contains(host)
        else { return nil }
        return url
    }
    private func validate(_ token: String) throws { if token.isEmpty || token.count > 2_048 { throw LinkAttributionError.invalidArgument("token is empty or too long") } }
    private func validateOpaqueToken(_ token: String) throws {
        guard token.range(of: #"^[A-Za-z0-9_-]{6,256}$"#, options: .regularExpression) != nil else {
            throw LinkAttributionError.invalidArgument("token must contain only URL-safe opaque characters")
        }
    }

    /// 校验本地账号作用域；只允许低熵协议字符，避免宿主误传邮箱、空白或任意用户文案。
    private func validatedAccountScope(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{15,127}$"#, options: .regularExpression) != nil else {
            throw LinkAttributionError.invalidArgument("account scope must be an opaque local identifier")
        }
        return normalized
    }

    /// 冻结决策的稳定交付 ID；缺少合法序号的旧缓存不得进入业务 outbox。
    private static func deliveryId(for result: AttributionResult) -> String? {
        guard result.isConsumableFinal, result.decisionSequence > 0 else { return nil }
        return "\(result.attributionId.lowercased()):\(result.decisionSequence)"
    }
    /// 运行参数使用值类型 JSON 枚举，循环引用和任意对象无法进入公共 API；这里再校验深度、节点、有限数值和实际 UTF-8 编码大小。
    private static func validateRuntimeParams(_ runtimeParams: [String: JSONValue]) throws {
        guard runtimeParams.count <= maximumJSONCollectionItems else {
            throw invalidRuntimeParams()
        }
        // 顶层 object 与已入栈的直属值都先占用预算，避免宽而深的输入在实际访问前把检查栈撑过上限。
        var nodeCount = 1 + runtimeParams.count
        guard nodeCount <= maximumJSONValueNodes else { throw invalidRuntimeParams() }
        var minimumUTF8Bytes = 0
        func consumeUTF8Bytes(_ count: Int) throws {
            guard count <= maximumRuntimeParamsBytes - minimumUTF8Bytes else { throw invalidRuntimeParams() }
            minimumUTF8Bytes += count
        }
        for key in runtimeParams.keys { try consumeUTF8Bytes(key.utf8.count) }
        var stack = runtimeParams.values.map { (value: $0, depth: 1) }
        while let current = stack.popLast() {
            guard current.depth <= maximumJSONValueDepth else {
                throw invalidRuntimeParams()
            }
            switch current.value {
            case let .number(value):
                guard value.isFinite else { throw invalidRuntimeParams() }
            case let .string(value):
                try consumeUTF8Bytes(value.utf8.count)
            case let .array(values):
                guard values.count <= maximumJSONCollectionItems,
                      nodeCount <= maximumJSONValueNodes - values.count else { throw invalidRuntimeParams() }
                nodeCount += values.count
                stack.append(contentsOf: values.map { (value: $0, depth: current.depth + 1) })
            case let .object(values):
                guard values.count <= maximumJSONCollectionItems,
                      nodeCount <= maximumJSONValueNodes - values.count else { throw invalidRuntimeParams() }
                nodeCount += values.count
                for key in values.keys { try consumeUTF8Bytes(key.utf8.count) }
                stack.append(contentsOf: values.values.map { (value: $0, depth: current.depth + 1) })
            case .bool, .null:
                break
            }
        }
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(runtimeParams)
        } catch {
            throw invalidRuntimeParams()
        }
        guard encoded.count <= maximumRuntimeParamsBytes else { throw invalidRuntimeParams() }
    }

    private static func invalidRuntimeParams() -> LinkAttributionError {
        .invalidArgument("runtimeParams must be finite JSON no larger than 1,000,000 UTF-8 bytes, depth 32 and 100,000 nodes")
    }

    private static func encodeQuery(_ value: JSONValue) throws -> String {
        if case let .string(value) = value { return value }
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(value)
        } catch {
            throw invalidRuntimeParams()
        }
        guard let value = String(data: encoded, encoding: .utf8) else { throw invalidRuntimeParams() }
        return value
    }
    /// 使用毫秒精度区分紧邻的离线重试；`occurredAt` 仍持久化且不会随重试变化。
    private func now() -> String {
        Self.instant(from: Date())
    }

    private static func instant(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let seconds = ISO8601DateFormatter()
        seconds.formatOptions = [.withInternetDateTime]
        return seconds.date(from: value)
    }

    /// 临时失败使用 1 秒起步、最多 5 分钟的指数退避；稳定事件 ID 派生 ±20% 抖动，跨进程保持一致。
    private func scheduleRetry(after failure: LinkAttributionError, expectedEventId: String) throws -> Date {
        guard failure.isRetryable else {
            throw LinkAttributionError.invalidArgument("only retryable failures can be scheduled")
        }
        var nextRetryAt = Date()
        guard try mutateExistingState(expectedEventId: expectedEventId, { state in
            let attempt = min(state.recoveryAttempt + 1, 32)
            let exponent = min(attempt - 1, 8)
            let base = min(pow(2, Double(exponent)), 300)
            let hash = UInt64(Self.stableScope("\(state.eventId)|\(attempt)"), radix: 16) ?? 0
            let jitter = 0.8 + Double(hash % 401) / 1_000
            let delay = min(max(base * jitter, 0.8), 300)
            nextRetryAt = Date().addingTimeInterval(delay)
            state.recoveryAttempt = attempt
            state.nextRecoveryAt = Self.instant(from: nextRetryAt)
            state.recoveryPermanentlyStopped = false
            state.recoveryCredentialScope = credentialScope
        }) != nil else { throw CancellationError() }
        return nextRetryAt
    }

    /// 平台仍在计算时遵守其有界建议；这不是失败次数，不扩大指数退避。
    private func scheduleNextEvaluation(retryAfterMs: Int?, expectedEventId: String) throws -> Date {
        let requested = retryAfterMs.map { TimeInterval($0) / 1_000 } ?? 1
        let delay = min(max(requested, Self.minimumPollInterval), 300)
        let nextRetryAt = Date().addingTimeInterval(delay)
        guard try mutateExistingState(expectedEventId: expectedEventId, { state in
            state.recoveryAttempt = 0
            state.nextRecoveryAt = Self.instant(from: nextRetryAt)
            state.recoveryPermanentlyStopped = false
            state.recoveryCredentialScope = credentialScope
        }) != nil else { throw CancellationError() }
        return nextRetryAt
    }

    private func clearRecoverySchedule(expectedEventId: String? = nil, clearPermanentStop: Bool = false) throws {
        guard let eventId = expectedEventId ?? loadState()?.eventId else { return }
        guard try mutateExistingState(expectedEventId: eventId, { state in
            state.recoveryAttempt = 0
            state.nextRecoveryAt = nil
            if clearPermanentStop {
                state.recoveryPermanentlyStopped = false
            }
            state.recoveryCredentialScope = nil
        }) != nil else { throw CancellationError() }
    }

    private func stopAutomaticRecovery(expectedEventId: String) throws {
        guard try mutateExistingState(expectedEventId: expectedEventId, { state in
            state.nextRecoveryAt = nil
            state.recoveryPermanentlyStopped = true
            state.recoveryCredentialScope = credentialScope
        }) != nil else { throw CancellationError() }
    }

    private func validatedUserProvidedEvidence(_ evidence: IOSUserProvidedEvidence) -> PendingUserProvidedEvidence? {
        switch evidence {
        case let .linkToken(value):
            let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.range(of: #"^[A-Za-z0-9_-]{6,256}$"#, options: .regularExpression) != nil else { return nil }
            return PendingUserProvidedEvidence(eventId: "", occurredAt: "", linkToken: token, ruleKey: nil, externalIdentifier: nil)
        case let .externalIdentifier(ruleKey, externalIdentifier):
            let rule = ruleKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let identifier = externalIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard rule.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$"#, options: .regularExpression) != nil,
                  identifier.range(of: #"^[A-Za-z0-9][A-Za-z0-9._~-]{0,255}$"#, options: .regularExpression) != nil
            else { return nil }
            return PendingUserProvidedEvidence(eventId: "", occurredAt: "", linkToken: nil, ruleKey: rule, externalIdentifier: identifier)
        }
    }
    private func deviceSignals() -> ClientSignals {
        // 默认只采集对断链匹配有实际区分度的低熵信号：主语言、系统主版本和设备大类。
        // 国家/地区与时区默认不采集，避免为极低权重扩大隐私面；业务如确有依据仍可显式传入 signals。
        let locale = Self.primaryLanguage(Locale.preferredLanguages.first)
        #if canImport(UIKit)
        return ClientSignals(locale: locale, osMajor: UIDevice.current.systemVersion.split(separator: ".").first.map(String.init), deviceClass: UIDevice.current.userInterfaceIdiom == .pad ? "TABLET" : "PHONE")
        #else
        return ClientSignals(locale: locale, osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion.description, deviceClass: "DESKTOP")
        #endif
    }

    private static func primaryLanguage(_ value: String?) -> String? {
        guard let value else { return nil }
        let primary = value.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-", maxSplits: 1).first.map(String.init)
        guard let primary, (2...3).contains(primary.count), primary.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return primary
    }

    private static func stableScope(_ value: String) -> String {
        // FNV-1a 只生成本地存储键的稳定后缀，不承担签名、加密或身份鉴别职责。
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    private static func isNumericAppVersion(_ value: String) -> Bool {
        guard value.count <= 32 else { return false }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return (1...4).contains(components.count) && components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    private static func isValidNavigationSessionId(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isValidUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value.lowercased()
    }

    /// 成功响应只接受显式 JSON 媒体类型；参数可存在，`application/*+json` 也属于标准 JSON 派生类型。
    private static func isSupportedJSONContentType(_ value: String?) -> Bool {
        guard let value,
              let mediaType = value.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              mediaType.isEmpty == false else { return false }
        return mediaType == "application/json"
            || mediaType.hasPrefix("application/") && mediaType.hasSuffix("+json")
    }

    /// 将配置 URL 收敛成 origin：scheme/host 小写、默认端口删除、路径固定为空。
    private static func normalizedAPIOrigin(from components: URLComponents) -> URL? {
        guard let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else { return nil }
        var normalized = URLComponents()
        normalized.scheme = scheme
        normalized.host = host
        if let port = components.port,
           !(scheme == "https" && port == 443),
           !(scheme == "http" && port == 80) {
            normalized.port = port
        }
        return normalized.url
    }

    private static func sameOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs,
              let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false),
              left.scheme?.lowercased() == right.scheme?.lowercased(),
              left.host?.lowercased() == right.host?.lowercased() else { return false }
        func effectivePort(_ components: URLComponents) -> Int? {
            if let port = components.port { return port }
            switch components.scheme?.lowercased() {
            case "https": return 443
            case "http": return 80
            default: return nil
            }
        }
        return effectivePort(left) == effectivePort(right)
    }

    private static func normalizeLinkHost(_ value: String) -> String? {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        guard !trimmed.isEmpty,
              !trimmed.contains(":"),
              let components = URLComponents(string: "https://\(trimmed)"),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              let host = components.host?.lowercased(),
              !host.isEmpty,
              host.utf8.count <= 253,
              isValidDNSHost(host)
        else { return nil }
        return host
    }

    private static func isValidDNSHost(_ value: String) -> Bool {
        value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" && label.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...122).contains(byte) || byte == 45
            }
        }
    }
}

private struct StoreClickResponse: Decodable { let clickId: String; let status: String }
private extension NSLock { func withLock<T>(_ operation: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try operation() } }

/// 串行化会读取或改写归因决策版本的异步网络操作；等待者按进入顺序恢复，不在锁内执行同步阻塞。
private actor AsyncOperationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        // 任务可能在等待上一条网络操作时已被宿主撤销；获得锁后必须先停止，不能让旧账号任务继续触网。
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard waiters.isEmpty == false else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

/// 同一存储作用域的进程内同步原语；不包含 SDK Key、账号或业务数据。
private final class SDKScopeSynchronization: @unchecked Sendable {
    let stateLock = NSLock()
    let networkGate = AsyncOperationGate()
    /// 整次恢复编排也必须串行，避免两个生命周期信号各自扩大同一安装的退避次数。
    let recoveryGate = AsyncOperationGate()
    var recoveryCompletionGeneration: UInt64 = 0
    var lastRecoveryCompletion: RecoveryCompletion?
}

private struct RecoveryTaskKey: Hashable {
    let eventId: String
    let credentialScope: String
    /// 前台/网络都属于可提前唤醒，启动/定时都属于遵守计划；同类并发信号必须复用一次恢复结果。
    let triggerClass: String
    let pollingTimeoutBitPattern: UInt64
    let requestTimeoutBitPattern: UInt64
    let appVersion: String
    let userProvidedEvidenceEnabled: Bool
}

private struct RecoveryCompletion {
    let generation: UInt64
    let key: RecoveryTaskKey
    let outcome: AttributionRecoveryOutcome
}

/// 以 stable storageKey 复用同步原语。两个独立 `UserDefaults(suiteName:)` 对象可能指向同一持久域，
/// 因此不能按对象身份分锁；不同 suite 即使恰好使用相同 key，额外串行也只影响性能，不改变各自存储内容。
private final class SDKScopeSynchronizationRegistry: @unchecked Sendable {
    static let shared = SDKScopeSynchronizationRegistry()

    private let lock = NSLock()
    private var scopes: [String: SDKScopeSynchronization] = [:]

    func synchronization(for storageKey: String) -> SDKScopeSynchronization {
        return lock.withLock {
            if let existing = scopes[storageKey] { return existing }
            let created = SDKScopeSynchronization()
            scopes[storageKey] = created
            return created
        }
    }
}

/// SDK 请求一律不跟随 HTTP 重定向；服务端应直接返回固定 API origin 的最终响应。
private final class NoRedirectURLSessionTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
