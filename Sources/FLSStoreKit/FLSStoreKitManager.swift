import Combine
import Foundation
import StoreKit
#if canImport(UIKit)
import UIKit
#endif

/// StoreKit 2 购买、交易监听和权益刷新。每个 App 建议共享一个管理器。
@MainActor
public final class FLSStoreKitManager: ObservableObject {
    @Published public private(set) var products: [Product] = []
    @Published public private(set) var entitledProductIDs: Set<String> = []
    @Published public private(set) var subscriptionStatuses: [String: FLSSubscriptionStatus] = [:]
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: FLSStoreKitError?
    /// 手动模式下已知且尚未完成的交易；不将后端订单等数据写进组件。
    @Published public private(set) var pendingTransactions: [FLSTransactionInfo] = []
    public let finishPolicy: FLSTransactionFinishPolicy
    public let productStore: FLSProductStore
    /// 购买、恢复与监听的已验证有效交易，可能按同一 ID 重投，宿主须幂等确认。
    public var transactionPublisher: AnyPublisher<FLSTransactionInfo, Never> { transactionSubject.eraseToAnyPublisher() }

    private let backend: any FLSStoreKitBackend
    private let transactionSubject = PassthroughSubject<FLSTransactionInfo, Never>()
    private var updatesTask: Task<Void, Never>?
    private var finishedIDs: Set<UInt64> = []
    private var finishTasks: [UInt64: Task<Void, Error>] = [:]
    private var isPurchasing = false

    public convenience init(productStore: FLSProductStore? = nil,
                            finishPolicy: FLSTransactionFinishPolicy = .automatic) {
        self.init(productStore: productStore, finishPolicy: finishPolicy, backend: FLSSystemStoreKitBackend())
    }

    /// 测试替换系统边界；生产环境始终使用 StoreKit 验签结果。
    init(productStore: FLSProductStore? = nil, finishPolicy: FLSTransactionFinishPolicy,
         backend: any FLSStoreKitBackend) {
        self.productStore = productStore ?? FLSProductStore()
        self.finishPolicy = finishPolicy
        self.backend = backend
        updatesTask = Task { [weak self, backend] in
            for await result in backend.updates() {
                guard !Task.isCancelled, let self else { break }
                do {
                    let transaction = try self.verified(result)
                    if transaction.isStale() {
                        // 失效交易不发布为新购成功，允许清理系统旧队列。
                        try await self.finish(transactionID: transaction.id)
                    } else {
                        try await self.accept(transaction)
                    }
                    await self.refreshEntitlements()
                } catch { self.record(error) }
            }
        }
    }

    deinit { updatesTask?.cancel() }

    public func configure(productIDs: [String]) async {
        products = await productStore.load(productIDs: productIDs)
        await refreshEntitlements()
    }

    public func product(id: String) -> Product? { products.first { $0.id == id } }

    public func isEligibleForIntroOffer(productID: String) async -> Bool {
        guard let subscription = product(id: productID)?.subscription else { return false }
        return await subscription.isEligibleForIntroOffer
    }

    /// 原有调用方式保持可用；需要原始交易号/JWS 时使用 purchase(_ request:)。
    public func purchase(productID: String, offer: FLSOfferConfiguration = .standard,
                         appAccountToken: UUID? = nil, quantity: Int = 1,
                         additionalOptions: Set<Product.PurchaseOption> = []) async throws -> FLSPurchaseResult {
        let outcome = try await purchase(FLSPurchaseRequest(productID: productID, appAccountToken: appAccountToken,
            quantity: quantity, offer: offer, additionalOptions: additionalOptions))
        switch outcome {
        case .purchased(let transaction): return .purchased(productID: transaction.productID, transactionID: transaction.id)
        case .pending(let id): return .pending(productID: id)
        case .cancelled(let id): return .cancelled(productID: id)
        }
    }

    /// 自动查询商品并发起系统购买，不以本地权益替代 Product.purchase。
    /// 手动模式只返回有效交易，宿主确认交付后显式调用 finish。
    public func purchase(_ request: FLSPurchaseRequest) async throws -> FLSPurchaseOutcome {
        guard !isPurchasing else { throw FLSStoreKitError.purchaseInProgress }
        isPurchasing = true
        isLoading = true
        defer { isPurchasing = false; isLoading = false }
        do {
            let options = try request.purchaseOptions()
            try await finishStaleTransactions(productID: request.productID)
            // StoreKit 偶尔先返回历史失效未完成单；最多清理后重新购买一次。
            for attempt in 0...1 {
                switch try await backend.purchase(productID: request.productID, options: options) {
                case .pending: lastError = nil; return .pending(productID: request.productID)
                case .cancelled: lastError = nil; return .cancelled(productID: request.productID)
                case .success(let result):
                    let transaction = try verified(result)
                    if transaction.isStale() {
                        try await finish(transactionID: transaction.id)
                        if attempt == 0 { continue }
                        throw FLSStoreKitError.staleTransaction(transaction.id)
                    }
                    try await accept(transaction)
                    await refreshEntitlements()
                    lastError = nil
                    return .purchased(transaction)
                }
            }
            throw FLSStoreKitError.failed("未取得有效购买结果。")
        } catch {
            throw record(error)
        }
    }

    /// 只枚举未完成的已验证交易；即使自动模式也不会在读取时 finish。
    /// 可在订阅交易监听后、App 启动时调用，以恢复上次未完成的后端确认。
    public func unfinishedTransactions() async -> [FLSTransactionInfo] {
        var values: [FLSTransactionInfo] = []
        for result in await backend.unfinished() {
            do { values.append(try verified(result)) }
            catch { record(error) }
        }
        pendingTransactions = values.filter { !finishedIDs.contains($0.id) }
        return pendingTransactions
    }

    /// 仅清理失效旧交易；有效未完成单留待宿主确认，不能因无网络而丢失。
    public func finishStaleTransactions(productID: String? = nil) async throws {
        for result in await backend.unfinished() {
            guard case .verified(let transaction) = result,
                  productID == nil || transaction.productID == productID,
                  transaction.isStale() else { continue }
            try await finish(transactionID: transaction.id)
        }
    }

    /// 显式完成已验证交易。同一管理器内并发/重复调用合并，失败后允许重试。
    public func finish(transactionID: UInt64) async throws {
        if finishedIDs.contains(transactionID) { return }
        if let task = finishTasks[transactionID] { return try await task.value }
        let task = Task { [backend] in try await backend.finish(transactionID: transactionID) }
        finishTasks[transactionID] = task
        defer { finishTasks.removeValue(forKey: transactionID) }
        try await task.value
        finishedIDs.insert(transactionID)
        pendingTransactions.removeAll { $0.id == transactionID }
    }

    public func restorePurchases() async throws { _ = try await restoreTransactions() }

    /// 用户主动恢复：同步、读取有效权益及未完成单，按相同策略处理并返回交易详情。
    @discardableResult
    public func restoreTransactions() async throws -> [FLSTransactionInfo] {
        do {
            try await backend.sync()
            var values: [UInt64: FLSTransactionInfo] = [:]
            let results = await backend.entitlements() + backend.unfinished()
            for result in results {
                let transaction = try verified(result)
                guard !transaction.isStale() else { continue }
                values[transaction.id] = transaction
            }
            let transactions = values.values.sorted { $0.id < $1.id }
            for transaction in transactions { try await accept(transaction) }
            await refreshEntitlements()
            lastError = nil
            return transactions
        } catch { throw record(error) }
    }

    /// 权益查询是只读动作，不能在手动模式下绕过后端确认并 finish。
    /// 这是 Apple 本地权益快照；业务 VIP 状态仍由宿主服务器决定。
    public func refreshEntitlements() async {
        entitledProductIDs = Set(await backend.entitlements().compactMap {
            if case .verified(let transaction) = $0, transaction.revocationDate == nil { return transaction.productID }
            return nil
        })
        await refreshSubscriptionStatuses()
    }

    public func refreshSubscriptionStatuses() async {
        var statuses: [String: FLSSubscriptionStatus] = [:]
        for product in products {
            guard let subscription = product.subscription, let results = try? await subscription.status else { continue }
            for result in results {
                guard case .verified(let transaction) = result.transaction,
                      case .verified(let renewal) = result.renewalInfo else { continue }
                let entitled = result.state == .subscribed || result.state == .inGracePeriod
                statuses[product.id] = FLSSubscriptionStatus(productID: product.id, isEntitled: entitled,
                    expirationDate: transaction.expirationDate, willAutoRenew: renewal.willAutoRenew,
                    isInGracePeriod: result.state == .inGracePeriod)
            }
        }
        subscriptionStatuses = statuses
    }

    public func manageSubscriptions() async throws {
#if canImport(UIKit)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw FLSStoreKitError.missingScene
        }
        try await AppStore.showManageSubscriptions(in: scene)
#else
        throw FLSStoreKitError.missingScene
#endif
    }

    private func accept(_ transaction: FLSTransactionInfo) async throws {
        if finishPolicy == .automatic {
            try await finish(transactionID: transaction.id)
        } else if !finishedIDs.contains(transaction.id) {
            pendingTransactions.removeAll { $0.id == transaction.id }
            pendingTransactions.append(transaction)
        }
        transactionSubject.send(transaction)
    }

    private func verified(_ result: FLSBackendVerification) throws -> FLSTransactionInfo {
        switch result {
        case .verified(let transaction): return transaction
        case .unverified(let reason): throw FLSStoreKitError.unverifiedTransaction(reason)
        }
    }

    @discardableResult
    private func record(_ error: Error) -> FLSStoreKitError {
        let mapped = (error as? FLSStoreKitError) ?? .failed(error.localizedDescription)
        lastError = mapped
        return mapped
    }
}
