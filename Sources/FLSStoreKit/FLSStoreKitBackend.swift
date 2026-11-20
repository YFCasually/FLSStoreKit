import Foundation
import StoreKit

/// 可替换的系统边界，仅供组件内部和测试使用；不向宿主暴露未验证交易。
@MainActor
protocol FLSStoreKitBackend: AnyObject {
    func purchase(productID: String, options: Set<Product.PurchaseOption>) async throws -> FLSBackendPurchaseResult
    func unfinished() async -> [FLSBackendVerification]
    func entitlements() async -> [FLSBackendVerification]
    func updates() -> AsyncStream<FLSBackendVerification>
    func sync() async throws
    func finish(transactionID: UInt64) async throws
}

enum FLSBackendVerification: Sendable {
    case verified(FLSTransactionInfo)
    case unverified(String)
}

enum FLSBackendPurchaseResult: Sendable {
    case success(FLSBackendVerification)
    case pending
    case cancelled
}

/// StoreKit 真正调用入口。只保存已验证的原始交易，用于显式 finish。
@MainActor
final class FLSSystemStoreKitBackend: FLSStoreKitBackend {
    private var transactions: [UInt64: StoreKit.Transaction] = [:]

    func purchase(productID: String, options: Set<Product.PurchaseOption>) async throws -> FLSBackendPurchaseResult {
        guard let product = try await Product.products(for: [productID]).first(where: { $0.id == productID }) else {
            throw FLSStoreKitError.productNotFound(productID)
        }
        switch try await product.purchase(options: options) {
        case .success(let result): return .success(snapshot(result))
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw FLSStoreKitError.failed("StoreKit 返回未知购买状态。")
        }
    }

    func unfinished() async -> [FLSBackendVerification] {
        var values: [FLSBackendVerification] = []
        for await result in Transaction.unfinished { values.append(snapshot(result)) }
        return values
    }

    func entitlements() async -> [FLSBackendVerification] {
        var values: [FLSBackendVerification] = []
        for await result in Transaction.currentEntitlements { values.append(snapshot(result)) }
        return values
    }

    func updates() -> AsyncStream<FLSBackendVerification> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                for await result in Transaction.updates {
                    guard !Task.isCancelled, let self else { break }
                    continuation.yield(self.snapshot(result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func sync() async throws { try await AppStore.sync() }

    func finish(transactionID: UInt64) async throws {
        if transactions[transactionID] == nil { _ = await unfinished() }
        guard let transaction = transactions[transactionID] else {
            throw FLSStoreKitError.transactionNotFound(transactionID)
        }
        await transaction.finish()
        transactions.removeValue(forKey: transactionID)
    }

    private func snapshot(_ result: VerificationResult<StoreKit.Transaction>) -> FLSBackendVerification {
        switch result {
        case .unverified(_, let error): return .unverified(error.localizedDescription)
        case .verified(let transaction):
            transactions[transaction.id] = transaction
            return .verified(FLSTransactionInfo(id: transaction.id, originalTransactionID: transaction.originalID,
                productID: transaction.productID, appAccountToken: transaction.appAccountToken,
                purchaseDate: transaction.purchaseDate, expirationDate: transaction.expirationDate,
                revocationDate: transaction.revocationDate, quantity: transaction.purchasedQuantity,
                jwsRepresentation: result.jwsRepresentation))
        }
    }
}
