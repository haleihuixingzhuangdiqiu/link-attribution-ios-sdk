import Foundation

/// App Attest 等完整性证明的可插拔边界。证明仅进入风控，不是安装归因桥，也不得编码稳定设备指纹。
public protocol IntegrityTokenProvider: Sendable {
    /// 为一次安装解析事件生成短期完整性证明。
    ///
    /// `eventId` 只用于绑定服务端本次请求，provider 不应从中派生可跨安装追踪的设备标识；
    /// 返回 `nil` 表示当前环境不提供证明，归因仍按服务端策略继续执行。
    func token(forEventId eventId: String) async throws -> String?
}

/// 标记由服务端 challenge + App Attest 流程实现的 provider，便于接入方显式区分普通完整性实现。
public protocol AppAttestTokenProvider: IntegrityTokenProvider {}

/// 默认空实现：不采集额外设备信号，也不阻断基础安装归因链路。
public struct NoIntegrityTokenProvider: IntegrityTokenProvider {
    /// 创建无完整性证明的 provider。
    public init() {}

    /// 明确返回 `nil`，由服务端在无证明场景下独立评估风险。
    public func token(forEventId eventId: String) async throws -> String? { nil }
}

/**
 在不等待失败任务退出的前提下，只恢复一次完整性证明结果。

 `IntegrityTokenProvider` 由宿主实现，不能假设它一定响应 Task cancellation；因此这里不能用会等待
 所有子任务退出的结构化 TaskGroup 做超时竞争，否则一个不协作的 provider 仍会占住归因串行门禁。
 本对象只保存短期 continuation/result，不记录 token 或 provider 错误。
 */
final class AsyncResultRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let completed: Result<Value, Error>? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let completed {
                continuation.resume(with: completed)
            }
        }
    }

    func complete(_ result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

/// 完整性证明沿用通用一次性竞争器；别名保留语义，避免把 token 暴露给其它状态对象。
typealias IntegrityTokenRace = AsyncResultRace<String?>

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
