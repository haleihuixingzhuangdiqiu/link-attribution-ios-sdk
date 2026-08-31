# iOS Swift SDK

支持项目自有 Universal Link、首次启动的 iOS 概率归因、登录门槛、持久重试、FINAL 待交付队列和 `UserDefaults` 本地恢复。Swift Package 最低 iOS 15；SDK 不要求项目把原有链接改成平台固定路径。

公开 Swift Package 仓库为 [haleihuixingzhuangdiqiu/link-attribution-ios-sdk](https://github.com/haleihuixingzhuangdiqiu/link-attribution-ios-sdk)。已发布 tag 不得移动或覆盖；任何行为修复都必须发布新 tag，并在匿名 SwiftPM 消费工程中重新解析验证。本 SDK 使用 [Apache License 2.0](./LICENSE)，归属声明见 [NOTICE](./NOTICE)。

当前源码对应已公开的不可变发布 `0.6.3`；tag `v0.6.3` 已通过无凭据匿名浅克隆、精确提交核对与 `swift test`。宿主使用：

```swift
.package(url: "https://github.com/haleihuixingzhuangdiqiu/link-attribution-ios-sdk.git", exact: "0.6.3")
```

```swift
let sdk = try LinkAttribution(configuration: .init(
    apiBaseURL: URL(string: "https://api.example.com")!,
    sdkKey: "ios-production-key",
    // 可选的宿主侧二次收紧；URL 的 Path/Query 格式由管理平台的 Application 规则决定。
    allowedLinkHosts: ["share.example.com"],
    // 默认读取 CFBundleShortVersionString；可显式覆盖用于测试。
    appVersion: "2.10.4",
    // 必填且非密钥；跨 SDK key 轮换保持稳定，测试/生产环境必须使用不同值。
    cacheScope: "tenant-a/project-a/production/sample-ios"
))

// scene(_:continue:)
if let result = try await sdk.handle(userActivity: userActivity) {
    let startedAt = Date()
    let opened = router.open(result.route, params: result.params)
    if let sessionId = result.navigationSessionId {
        // 旁路上报失败不能改变或回滚原有路由结果。
        _ = try? await sdk.trackNavigationOutcome(.init(
            navigationSessionId: sessionId,
            outcome: opened ? .destinationViewed : .routeFailed,
            failureReason: opened ? nil : .hostRouterRejected,
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1_000)
        ))
    }
}

// 可在登录前旁路预取，但只暂存在归因接入层，绝不能加入原登录请求或登录 DTO。
let preparedAttribution = try? await sdk.resolveInstallation()

// 原登录接口、请求/响应 DTO 和认证流程保持零修改；归因不可成为登录参数或成功条件。
let loginResult = try await businessAPI.login(credentials: credentials)
try sessionStore.persist(loginResult)

// 业务登录已成功落库后，在同步栈一次性绑定本地脱敏账号作用域并冻结登录事实。
// accountScope 不上传；不要传邮箱、手机号、Token 或其他明文身份。
do {
    try sdk.recordAuthenticatedLogin(accountScope: localOpaqueAccountScope)
} catch {
    // 归因本地缓存异常不回滚、不阻塞已经成功的业务登录。
}

// 登录成功后单独调用业务 bind；Bearer 当前会话决定 user/session，正文只有两个平台 ID。
// 200/202 必须精确回显；失败独立持久重试，绝不回滚或注销已经成功的登录。
if let preparedAttribution,
   preparedAttribution.decisionSequence > 0,
   let decisionId = preparedAttribution.decisionId {
    do {
        let bound = try await businessAPI.bindReferralAttribution(
            installInstanceId: preparedAttribution.attributionId,
            decisionId: decisionId
        )
        guard bound.installInstanceId == preparedAttribution.attributionId,
              bound.decisionId == decisionId else {
            throw AttributionIntegrationError.responseMismatch
        }
    } catch {
        bindRetryQueue.enqueue(preparedAttribution.attributionId, decisionId)
    }
}

// 宿主只转发生命周期/网络信号；SDK 统一恢复主动证据、安装查询和同一 attribution 的 FINAL 轮询。
Task {
    do {
        let recovery = try await sdk.resumePendingAttribution(
            trigger: .appForeground,
            pollingTimeout: 15
        )
        if let nextRetryAt = recovery.nextRetryAt {
            scheduleOneShotWake(at: nextRetryAt)
        }
    } catch is CancellationError {
        // 当前生命周期结束；持久事实仍由下次启动/前台/网络恢复继续。
    } catch {
        // 归因失败旁路，不影响登录、启动或既有路由。
    }
}

// 所有合法 FINAL（包括空匹配终态）都进入本地 outbox；空匹配只结束待办，绝不发放权益。
if let delivery = try sdk.pendingFinalDelivery(accountScope: localOpaqueAccountScope),
   let decisionId = delivery.result.decisionId {
    let finalMatchesVersion = delivery.result.decisionSequence
    let claimed = try await businessBackend.claimReferralAttribution(
        attributionId: delivery.result.attributionId,
        decisionId: decisionId,
        finalMatchesVersion: finalMatchesVersion
    )
    // 只有 Server Key 验签、业务幂等处理完成并精确回显三个定位值后才 ack。
    if claimed.processed,
       claimed.attributionId == delivery.result.attributionId,
       claimed.decisionId == decisionId,
       claimed.finalMatchesVersion == finalMatchesVersion {
        try sdk.acknowledgeFinalDelivery(
            deliveryId: delivery.deliveryId,
            accountScope: localOpaqueAccountScope
        )
    }
}
```

## 独立 bind 与 FINAL claim 契约

原登录 API、登录请求/响应 DTO、Token 签发和会话落库保持不变。登录成功后 App 才调用接入方业务后端的 `POST /api/v1/referral-attributions/bind`；这不是移动端直连归因平台。Bearer 当前会话决定 user/session，请求只能包含 canonical lowercase `installInstanceId + decisionId`。业务后端返回 `200`（已处理）或 `202`（已持久受理）并精确回显两个 ID，在自身事务中幂等生成 UUIDv4 `loginTransactionId` 与 outbox；App 不传 user、session、transaction、用户哈希或登录时间。bind 只建立可信登录关联，不代表 FINAL 已形成。

后续业务 `claim` 的请求和成功响应都必须精确包含 `attributionId + decisionId + finalMatchesVersion`，其中 `attributionId` 的值等于 SDK 的 `installInstanceId`。本地 `deliveryId` 只用于确认 SDK outbox，禁止发送给业务后端。业务后端使用 bind 时保存的登录绑定调用 Go SDK `ResolveFinal`，验签且幂等完成业务处理（空匹配只关闭待办）后 App 才 ack。版本不一致、superseded、202 处理中或回显不一致都不得 ack 或自动跟随另一 Decision。

公开查询结果必须同时满足 `processState == .final`、`isFinal == true`，并通过 `outcome`、`finalMatches`、兼容镜像 `matches`、`matchCount` 和追加式 `decisionSequence` 的一致性校验；非终态按 `retryAfterMs` 有界轮询。多个达到门槛的分享码会以 `MULTIPLE_MATCHES` 一次返回，SDK 不替业务挑选其中一个。移动端 SDK Key 只允许查询当前项目/环境/Application 的脱敏结果，不是业务权益凭据；客户端可即时展示结果，但权益、邀请关系或返佣完全由业务系统负责。平台 SDK 不实现奖励、奖励回执或业务对账。

## 持久恢复与 FINAL 交付

- `recordAuthenticatedLogin(accountScope:)` 必须在真实登录成功并落库后的同步回调中执行；它在同一临界区绑定本地脱敏账号作用域并冻结随机本地 `eventId + occurredAt`，不触网、不读取或上传账号。平台只信任业务后端用 Server Key 上报的 `SERVER_CONFIRMED` 登录事实，移动端不能上报或解锁登录门槛。
- App 可在登录前从非 FINAL `AttributionResult` 预取 `attributionId + decisionId`，但必须等原登录成功并落库后再调用独立业务 bind；原登录接口和 DTO 不携带归因字段。业务后端从当前会话建立可信上下文并用 Server Key 确认。若期间 Worker 已推进 Decision，平台只接受同安装、同冻结策略且 sequence 连续、未跨 FINAL 的 supplied 祖先；断链或策略漂移失败关闭。App 不生成登录证明，也不接触 Server Key。
- `trackLoginCompleted()`、`retryPendingLoginConfirmation()`、`recordLoginCompletedOccurrence()` 和 `bindAuthenticatedAccount(scope:)` 仅为源码/ABI 兼容保留：前者返回稳定停用错误，重试固定返回 `nil`，拆分式同步入口固定拒绝；四者都不触网、不改写本地登录事实。新接入只调用原子 `recordAuthenticatedLogin(accountScope:)`。
- `resumePendingAttribution(trigger:pollingTimeout:)` 是可选的统一恢复入口。宿主只转发 App 启动、前台、网络恢复和定时信号；SDK 内部按“用户主动证据 → 安装查询 → 同一 attribution 的 FINAL 轮询”排序。临时失败使用 1 秒起步、最多 5 分钟、带抖动的跨进程指数退避；冷启动遵守既有退避，真实前台/网络恢复可提前唤醒一次。
- 同一 `storageNamespace + 规范 API origin + 规范 cacheScope` 的多个 SDK 实例共享进程内状态锁、请求门禁和恢复门禁；API origin 会统一 scheme/host 大小写、默认端口和尾部斜杠，`cacheScope` 会去除首尾空白，等价配置不会分裂出两次安装。状态中同时保存完整规范作用域，哈希键碰撞或配置漂移时 fail-closed。即使宿主为同一 suite 创建多个 `UserDefaults` 对象，也不会把一次失败重复计成多次退避。`clearLocalState()` 会切换本地安装代次，所有迟到请求或完整性结果都不得复活、发送或改写旧代次。
- 当前本地状态为显式 v4。首次建档会在任何网络请求前一起冻结 `eventId + occurredAt + IOS + appVersion + 无 deterministicClickToken`；安装响应丢失后即使 App 已升级，POST 正文和 `X-App-Version` 仍逐字复用首次版本。v3 迁移会清除历史移动端登录确认、待解封 FINAL 与登录永久拒绝；历史可交付 FINAL 会标记为不可再次交付。旧 v1/v2 只有在已有 `attributionId`、能够证明平台已经登记安装时才迁移；无法还原首次请求身份的旧待发送状态或任何核心字段损坏都会返回稳定 `storage` 错误，绝不删除后伪造新安装。
- 只有网络、超时、HTTP 408/425/429/5xx 自动重试。鉴权、参数、契约和普通 409 属于永久失败，自动恢复会跨进程停止；修复配置或升级 SDK 后才能显式调用 `resetAutomaticRecovery()`。
- `pendingFinalDelivery(accountScope:)` 返回本地原子绑定同一账号、由业务后端 Server Key 确认后在平台形成、且尚未 ack 的全部合法 FINAL。`deliveryId` 由 `attributionId + decisionSequence` 稳定生成，重启后不丢失；`MATCHED/MULTIPLE_MATCHES` 携带冻结匹配，`NO_MATCH/UNRESOLVED/RISK_BLOCKED/EXPIRED` 携带空 `finalMatches`，同样必须可靠 claim 以关闭待办，但绝不能据此发放权益。
- `AttributionResult.attributionId` 是安装实例定位值，即 Server Key 契约的 `installInstanceId`；`decisionId` 是当前精确 Decision，二者都是 UUID 且不得互换。Decision 尚未创建时 `decisionId` 为空；一旦 `decisionSequence > 0`，网络响应必须携带它。旧缓存缺失 `decisionId` 的业务 FINAL 不会进入 outbox，也不能提交给业务后端。
- `resolveInstallation`、`getAttribution` 和 `waitForAttribution` 遇到含业务匹配的 FINAL 时抛出稳定的 `businessDeliveryRequired`；空匹配 FINAL 可返回脱敏诊断结果。`resumePendingAttribution` 对含业务匹配的 FINAL 返回 `.final` 且不附带结果，对空匹配 FINAL 可附带诊断结果；两类结果都必须从账号绑定的 `pendingFinalDelivery` 完成 claim/ack，避免旧查询入口绕过账号边界。
- `accountScope` 仅存本机并且首次绑定后禁止换绑；应由宿主把内部账号 ID 转成不可逆、非明文、至少 16 字符的稳定作用域。账号绑定前形成的任何可交付 FINAL 都会持久抑制，不允许事后认领给任意账号；历史移动端确认也不能替代这一绑定。
- FINAL Decision/Match 是不可变历史。用户明确提交的主动证据在本机已有可信登录绑定时仍可于资格窗内持久上报，平台再独立校验 Server Key 登录链并进入 reconciliation；SDK 保留原 FINAL/outbox，不把对账产生的新 Decision 直接交给移动端、回滚或重复发放权益。未绑定、历史越权 FINAL 或普通后台流程仍不得在终态后自动补造证据。
- `apiBaseURL` 必须是纯 HTTP(S) origin，不能带业务路径、userinfo、query 或 fragment；非 localhost 必须 HTTPS。SDK 禁止 HTTP 重定向并校验最终响应仍为配置的同 origin；归因 GET 强制绕过本地 URL 缓存并发送 `no-store`，避免旧决策或 SDK Key 被重定向、缓存复用。
- 2xx 响应必须显式使用 `application/json` 或 `application/*+json`、正文必须是合法 UTF-8 且不得超过 2 MiB；错误 MIME、超限、非法编码或模型契约不一致统一返回 `invalidResponse`，不会把服务端正文透传给业务或日志。

## App Attest 边界

通过 `IntegrityTokenProvider` 注入由业务服务端挑战流程生成的 App Attest 证明：

```swift
let sdk = try LinkAttribution(configuration: config, integrityProvider: MyAppAttestProvider())
```

它只用于证明请求来自合法 App 实例和降低伪造/重放风险，不能把安装前 H5 点击与安装后 App 确定性连接。SDK 最多独立等待 1 秒，provider 超时或失败、空 token、超过 16 KiB 的 token 都会安全降级为无证明并继续基础归因；宿主取消仍原样终止当前任务。SDK 不生成设备指纹，也不返回评分、候选、IP、策略或风险证据。

`clearLocalState()` 仅用于退出测试环境/隐私清除；不要在普通冷启动调用，否则会破坏首启幂等。

用户主动证据默认关闭。SDK 没有剪贴板读取 API，也不会调用 `UIPasteboard`；宿主必须让用户把内容粘贴到可见输入框。若内容是“标题 + 空格/换行 + 完整业务链接”，宿主只能在内存中寻找允许域名下的第一个候选，并且仅在它能唯一解析为合法第一方 `linkToken` 或 `ruleKey + externalIdentifier` 时调用 `submitUserProvidedEvidence`；SDK 故意不提供原始文本/完整 URL 解析入口。禁止上传、日志记录或持久化标题、描述、完整 URL、原始剪贴板文本、来源 App 或歧义候选。

`resolveLink` 与 `createClick` 的 `runtimeParams` 只接受 `JSONValue`：非有限数字会被拒绝，深度最多 32、总节点最多 100,000、单个数组/对象最多 10,000 项，编码后的完整参数对象最多 1,000,000 UTF-8 字节。Swift 值类型 API 本身不允许循环引用或任意非 JSON 对象进入。兼容用 `resolveLink` 是 GET 接口，完整路径与查询不得超过 8 KiB；复杂或较大的业务参数应通过项目 URL 规则或正文接口承载。

`navigationSessionId` 只在平台已经向当前 App 返回业务路由且项目启用附属诊断时出现。宿主仍使用原 Router；只有 Router 明确成功后才报 `DESTINATION_VIEWED`，明确失败时使用固定失败分类。不要把按钮点击、Scene 激活或 SDK 解析成功当成目标页到达。

`allowedLinkHosts` 是可选的宿主侧精确 Host 白名单，只填写规范 host（不含 scheme、userinfo、端口、路径或查询）。SDK 不假设 `/l`、`/s` 或固定 Query 名，而是把完整 HTTPS URL 发送到固定 Platform API；服务端再按当前 Application 的项目规则匹配。非 HTTPS、带 userinfo/端口/fragment、Host 不在可选白名单或服务端没有匹配规则时返回 `nil`，SDK Key 不会发送到业务 URL Host。系统 Universal Link 关联仍应配置，但不能替代这层校验。

SDK 在每次 `/v1/sdk/*` 请求发送 `X-App-Version`；首次安装请求体同时发送同值 `appVersion`，并在首次触网前持久冻结两处的值。响应丢失、离线重试或 App 升级都不会改写该安装事实。iOS 首启请求从不发送 `deterministicClickToken`，本地状态也显式冻结“确定性 token 缺失”；Universal Link 只用于已安装的直接打开，不被冒充为 App Store 安装桥。

## 隐私与 App Store 申报

- SDK 不读取 IDFA、IDFV、定位、通讯录、相册、剪贴板或精确硬件标识，也不生成稳定设备指纹。
- iOS SDK 不发送登录确认请求。本地只保存随机回调事件 ID、真实登录发生时间和脱敏 `accountScope`，这些字段不上传；业务后端使用 Server Key 发送 `SERVER_CONFIRMED` 事实，平台据此推动同一 attribution 形成 FINAL。
- 默认首启信号只有主语言（如 `zh`）、系统主版本、设备大类、`COMPACT / MEDIUM / EXPANDED / LARGE` 固定 point 宽度区间和请求侧生成的项目级短期网络摘要；国家/地区和时区默认不采集。SDK 不发送原始屏幕尺寸、scale、分辨率或设备型号。
- 随包提供 `PrivacyInfo.xcprivacy`：声明产品交互、其他粗粒度归因数据，以及仅供 SDK 自身缓存使用的 `UserDefaults`（`CA92.1`）。宿主 App 仍须在 App Store Connect 中按实际用途合并申报自身及全部第三方 SDK 的数据实践。
- 平台默认把原始粗粒度信号保留 24 小时并由 Worker 清除；网络地址不会原文入库，而是使用租户、项目和服务端密钥域隔离的 HMAC 摘要。
- 业务链接会完整发送给平台解析。链接路径或 Query 中不得放手机号、邮箱、姓名、账户 ID 等个人或敏感信息；应只放短期随机业务标识，再由业务后端受控换取数据。
- 当前清单以“仅做自身 App 的邀请/安装归因，不与第三方广告数据拼接、不向数据经纪商共享”为前提。若未来用于跨公司广告定向或广告效果衡量，必须重新评估 Tracking 声明、ATT 与隐私政策，不能沿用当前非跟踪结论。
