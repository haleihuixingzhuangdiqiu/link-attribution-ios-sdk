# iOS Swift SDK

## License

Licensed under the [Apache License, Version 2.0](./LICENSE). See [NOTICE](./NOTICE) for attribution information.

支持项目自有 Universal Link、首次启动的 iOS 概率归因、登录门槛、持久重试、FINAL 待交付队列和 `UserDefaults` 本地恢复。Swift Package 最低 iOS 15；SDK 不要求项目把原有链接改成平台固定路径。

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

// 首次启动旁路执行；归因临时失败、配置错误或业务 FINAL 待交付都不能中断 App 启动。
Task {
    do {
        let attribution = try await sdk.resolveInstallation()
        if attribution.decisionSequence > 0, let decisionId = attribution.decisionId {
            // 只把这两个平台定位值随真实业务登录请求交给业务后端；App 不持有 Server Key。
            businessLoginDraft.attributionReference = .init(
                installInstanceId: attribution.attributionId,
                decisionId: decisionId
            )
        }
    } catch is CancellationError {
        // 宿主生命周期取消保持原语义，不改写为归因失败。
    } catch {
        // 可按 LinkAttributionError 稳定分类记录诊断；不要展示或依赖自由文本错误。
    }
}

// 业务登录已成功落库后，在同步栈一次性绑定本地脱敏账号作用域并冻结登录事实。
// accountScope 不上传；不要传邮箱、手机号、Token 或其他明文身份。
do {
    try sdk.recordAuthenticatedLogin(accountScope: localOpaqueAccountScope)
} catch {
    // 归因本地缓存异常不回滚、不阻塞已经成功的业务登录。
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

// SDK 把全部 FINAL.finalMatches 作为一条本地 outbox 记录交付，不替业务挑一个候选。
if let delivery = try sdk.pendingFinalDelivery(accountScope: localOpaqueAccountScope),
   let decisionId = delivery.result.decisionId {
    try await businessBackend.processAttribution(
        // attributionId 是 installInstanceId；decisionId 是精确 Decision，二者不能互换。
        // 业务后端应使用 Server Key 重读该 Decision，不能信任客户端自报奖励对象。
        installInstanceId: delivery.result.attributionId,
        decisionId: decisionId
    )
    // 只有业务后端真实处理成功后才 ack；展示 Toast 或收到 FINAL 都不等于业务成功。
    try sdk.acknowledgeFinalDelivery(
        deliveryId: delivery.deliveryId,
        accountScope: localOpaqueAccountScope
    )
}
```

公开查询结果必须同时满足 `processState == .final`、`isFinal == true`，并通过 `outcome`、`finalMatches`、兼容镜像 `matches`、`matchCount` 和追加式 `decisionSequence` 的一致性校验；非终态按 `retryAfterMs` 有界轮询。多个达到门槛的分享码会以 `MULTIPLE_MATCHES` 一次返回，SDK 不替业务挑选其中一个。移动端 SDK Key 只允许查询当前项目/环境/Application 的脱敏结果，不是业务权益凭据；客户端可即时展示结果，但权益、邀请关系或返佣完全由业务系统负责。平台 SDK 不实现奖励、奖励回执或业务对账。

## 持久恢复与 FINAL 交付

- `recordAuthenticatedLogin(accountScope:)` 必须在真实登录成功并落库后的同步回调中执行；它在同一临界区绑定本地脱敏账号作用域并冻结随机本地 `eventId + occurredAt`，不触网、不读取或上传账号。平台只信任业务后端用 Server Key 上报的 `SERVER_CONFIRMED` 登录事实，移动端不能上报或解锁登录门槛。
- App 在登录请求前从非 FINAL `AttributionResult` 读取 `attributionId + decisionId`，只把这两个平台定位值随业务登录 claim 交给业务后端；业务后端在自身登录事务提交后用 Server Key 确认。若期间 Worker 已推进 Decision，平台只接受同安装、同冻结策略且 sequence 连续、未跨 FINAL 的 supplied 祖先，并在账本保留 supplied ID；断链或策略漂移失败关闭。App 不生成登录证明，也不接触 Server Key。
- `trackLoginCompleted()`、`retryPendingLoginConfirmation()`、`recordLoginCompletedOccurrence()` 和 `bindAuthenticatedAccount(scope:)` 仅为源码/ABI 兼容保留：前者返回稳定停用错误，重试固定返回 `nil`，拆分式同步入口固定拒绝；四者都不触网、不改写本地登录事实。新接入只调用原子 `recordAuthenticatedLogin(accountScope:)`。
- `resumePendingAttribution(trigger:pollingTimeout:)` 是可选的统一恢复入口。宿主只转发 App 启动、前台、网络恢复和定时信号；SDK 内部按“用户主动证据 → 安装查询 → 同一 attribution 的 FINAL 轮询”排序。临时失败使用 1 秒起步、最多 5 分钟、带抖动的跨进程指数退避；冷启动遵守既有退避，真实前台/网络恢复可提前唤醒一次。
- 同一 `storageNamespace + 规范 API origin + 规范 cacheScope` 的多个 SDK 实例共享进程内状态锁、请求门禁和恢复门禁；API origin 会统一 scheme/host 大小写、默认端口和尾部斜杠，`cacheScope` 会去除首尾空白，等价配置不会分裂出两次安装。状态中同时保存完整规范作用域，哈希键碰撞或配置漂移时 fail-closed。即使宿主为同一 suite 创建多个 `UserDefaults` 对象，也不会把一次失败重复计成多次退避。`clearLocalState()` 会切换本地安装代次，所有迟到请求或完整性结果都不得复活、发送或改写旧代次。
- 当前本地状态为显式 v4。首次建档会在任何网络请求前一起冻结 `eventId + occurredAt + IOS + appVersion + 无 deterministicClickToken`；安装响应丢失后即使 App 已升级，POST 正文和 `X-App-Version` 仍逐字复用首次版本。v3 迁移会清除历史移动端登录确认、待解封 FINAL 与登录永久拒绝；历史可消费 FINAL 会标记为不可再次交付。旧 v1/v2 只有在已有 `attributionId`、能够证明平台已经登记安装时才迁移；无法还原首次请求身份的旧待发送状态或任何核心字段损坏都会返回稳定 `storage` 错误，绝不删除后伪造新安装。
- 只有网络、超时、HTTP 408/425/429/5xx 自动重试。鉴权、参数、契约和普通 409 属于永久失败，自动恢复会跨进程停止；修复配置或升级 SDK 后才能显式调用 `resetAutomaticRecovery()`。
- `pendingFinalDelivery(accountScope:)` 只返回本地原子绑定同一账号、由业务后端 Server Key 确认后在平台形成、且尚未 ack 的 `MATCHED/MULTIPLE_MATCHES` FINAL。`deliveryId` 由 `attributionId + decisionSequence` 稳定生成，重启后不丢失；`NO_MATCH/EXPIRED` 等空 FINAL 不要求本地账号绑定，仅供诊断，不进入业务 outbox。
- `AttributionResult.attributionId` 是安装实例定位值，即 Server Key 契约的 `installInstanceId`；`decisionId` 是当前精确 Decision，二者都是 UUID 且不得互换。Decision 尚未创建时 `decisionId` 为空；一旦 `decisionSequence > 0`，网络响应必须携带它。旧缓存缺失 `decisionId` 的业务 FINAL 不会进入 outbox，也不能提交给业务后端。
- `resolveInstallation`、`getAttribution` 和 `waitForAttribution` 遇到含分享码的可消费 FINAL 时抛出稳定的 `businessDeliveryRequired`，`resumePendingAttribution` 返回 `.final` 但不附带结果；完整多候选只能从账号绑定的 `pendingFinalDelivery` 读取，避免旧查询入口绕过账号边界。
- `accountScope` 仅存本机并且首次绑定后禁止换绑；应由宿主把内部账号 ID 转成不可逆、非明文、至少 16 字符的稳定作用域。账号绑定前形成的可消费 FINAL 会 fail-closed，不允许事后认领给任意账号；历史移动端确认也不能替代这一绑定。
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
