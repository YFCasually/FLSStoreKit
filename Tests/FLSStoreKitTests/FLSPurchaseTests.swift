import Combine
import StoreKit
import XCTest
@testable import FLSStoreKit

/// 在真实管理器入口替换系统边界，验证参数及交易时序，不发起真实扣款。
@MainActor
final class FLSPurchaseTests: XCTestCase {
    private func transaction(_ id: UInt64 = 10, expired: Bool = false, revoked: Bool = false) -> FLSTransactionInfo {
        FLSTransactionInfo(id: id, originalTransactionID: 1, productID: "product",
            appAccountToken: UUID(uuidString: "C3C38FB7-2D13-4213-AD99-9C452689FA01"),
            purchaseDate: Date(timeIntervalSince1970: 1700000000), expirationDate: expired ? .distantPast : nil,
            revocationDate: revoked ? Date() : nil, quantity: 2, jwsRepresentation: "test-only-jws")
    }

    func testPurchaseForwardsAccountQuantityAndAdditionalOptions() async throws {
        let backend = FLSFakeStoreKitBackend()
        let value = transaction()
        backend.results = [.success(.verified(value))]
        let manager = FLSStoreKitManager(finishPolicy: .manual, backend: backend)
        let extra = Product.PurchaseOption.simulatesAskToBuyInSandbox(true)
        let outcome = try await manager.purchase(FLSPurchaseRequest(productID: "product",
            appAccountToken: value.appAccountToken, quantity: 2, additionalOptions: [extra]))
        XCTAssertEqual(outcome, .purchased(value))
        XCTAssertEqual(backend.requests.first?.0, "product")
        let options = try XCTUnwrap(backend.requests.first?.1)
        XCTAssertTrue(options.contains(.appAccountToken(try XCTUnwrap(value.appAccountToken))))
        XCTAssertTrue(options.contains(.quantity(2)))
        XCTAssertTrue(options.contains(extra))
        XCTAssertEqual(manager.pendingTransactions, [value])
        XCTAssertTrue(backend.finished.isEmpty)
    }

    func testLegacyAPIAutomaticallyFinishesAndStillReturnsLegacyResult() async throws {
        let backend = FLSFakeStoreKitBackend()
        backend.results = [.success(.verified(transaction()))]
        let manager = FLSStoreKitManager(finishPolicy: .automatic, backend: backend)
        guard case .purchased(let id, let transactionID) = try await manager.purchase(productID: "product") else {
            return XCTFail("旧接口应继续返回原枚举")
        }
        XCTAssertEqual(id, "product")
        XCTAssertEqual(transactionID, 10)
        XCTAssertEqual(backend.finished, [10])
    }

    func testLegacySignatureAndJWSAreForwarded() async throws {
        let backend = FLSFakeStoreKitBackend()
        backend.results = [.pending, .pending]
        let manager = FLSStoreKitManager(finishPolicy: .manual, backend: backend)
        let signature = FLSPromotionalOfferSignature(offerID: "promo", keyID: "key", nonce: UUID(),
            signature: Data([1, 2]), timestamp: 123)
        _ = try await manager.purchase(FLSPurchaseRequest(productID: "product", offer: .init(kind: .promotional(signature))))
        XCTAssertTrue(backend.requests[0].1.contains(.promotionalOffer(offerID: signature.offerID,
            keyID: signature.keyID, nonce: signature.nonce, signature: signature.signature, timestamp: signature.timestamp)))
        _ = try await manager.purchase(FLSPurchaseRequest(productID: "product",
            offer: .init(kind: .promotionalJWS(offerID: "promo", compactJWS: "header.payload.signature"))))
        for option in Product.PurchaseOption.promotionalOffer("promo", compactJWS: "header.payload.signature") {
            XCTAssertTrue(backend.requests[1].1.contains(option))
        }
    }

    func testInvalidInputNeverReachesSystemPurchase() async {
        let backend = FLSFakeStoreKitBackend()
        let manager = FLSStoreKitManager(finishPolicy: .manual, backend: backend)
        let requests: [FLSPurchaseRequest] = [
            .init(productID: " "), .init(productID: "product", quantity: 0),
            .init(productID: "product", offer: .init(kind: .promotionalJWS(offerID: "p", compactJWS: "invalid"))),
            .init(productID: "product", offer: .init(kind: .offerCode(referenceName: "code"))),
            .init(productID: "product", offer: .init(kind: .winBack))
        ]
        for request in requests {
            do { _ = try await manager.purchase(request); XCTFail("无效参数不能发起购买") }
            catch { XCTAssertNotNil(error as? FLSStoreKitError) }
        }
        XCTAssertTrue(backend.requests.isEmpty)
    }

    func testPendingAndCancelledDoNotCreateTransactions() async throws {
        let backend = FLSFakeStoreKitBackend()
        backend.results = [.pending, .cancelled]
        let manager = FLSStoreKitManager(finishPolicy: .manual, backend: backend)
        let pending = try await manager.purchase(.init(productID: "product"))
        let cancelled = try await manager.purchase(.init(productID: "product"))
        XCTAssertEqual(pending, .pending(productID: "product"))
        XCTAssertEqual(cancelled, .cancelled(productID: "product"))
        XCTAssertTrue(manager.pendingTransactions.isEmpty)
        XCTAssertTrue(backend.finished.isEmpty)
    }

    func testUnverifiedTransactionIsRejectedWithoutFinish() async {
        let backend = FLSFakeStoreKitBackend()
        backend.results = [.success(.unverified("test verification failure"))]
        let manager = FLSStoreKitManager(finishPolicy: .manual, backend: backend)
        do { _ = try await manager.purchase(.init(productID: "product")); XCTFail("不能返回未验签交易") }
        catch { XCTAssertEqual(error as? FLSStoreKitError, .unverifiedTransaction("test verification failure")) }
        XCTAssertTrue(backend.finished.isEmpty)
        XCTAssertTrue(manager.pendingTransactions.isEmpty)
    }

    func testManualUpdatesRefreshAndRestoreNeverFinishValidTransactions() async throws {
        let backend = FLSFakeStoreKitBackend()
        let value = transaction()
        backend.current = [.verified(value)]
        backend.unfinishedValues = [.verified(value)]
        let ready = expectation(description: "监听已安装")
        backend.onSubscribe = { ready.fulfill() }
        let manager = FLSStoreKitManager(finishPolicy: .manual, backend: backend)
        await fulfillment(of: [ready], timeout: 2)
        let received = expectation(description: "收到详细交易")
        let subscription = manager.transactionPublisher.sink { item in
            XCTAssertEqual(item.originalTransactionID, 1)
            XCTAssertEqual(item.jwsRepresentation, "test-only-jws")
            received.fulfill()
        }
        backend.continuation?.yield(.verified(value))
        await fulfillment(of: [received], timeout: 2)
        subscription.cancel()
        await manager.refreshEntitlements()
        XCTAssertEqual(manager.entitledProductIDs, ["product"])
        let restored = try await manager.restoreTransactions()
        XCTAssertEqual(restored, [value]) // 权益和未完成队列同一交易去重。
        XCTAssertEqual(backend.syncCount, 1)
        XCTAssertEqual(manager.pendingTransactions, [value])
        XCTAssertTrue(backend.finished.isEmpty)
    }

    func testAutomaticUpdatesAndRestoreFinishValidTransactions() async throws {
        let backend = FLSFakeStoreKitBackend()
        let ready = expectation(description: "监听已安装")
        backend.onSubscribe = { ready.fulfill() }
        let manager = FLSStoreKitManager(finishPolicy: .automatic, backend: backend)
        await fulfillment(of: [ready], timeout: 2)
        let received = expectation(description: "自动监听完成")
        let subscription = manager.transactionPublisher.sink { _ in received.fulfill() }
        backend.continuation?.yield(.verified(transaction()))
        await fulfillment(of: [received], timeout: 2)
        subscription.cancel()
        backend.current = [.verified(transaction(11))]
        _ = try await manager.restoreTransactions()
        XCTAssertEqual(backend.finished, [10, 11])
    }

    func testExplicitFinishIsIdempotentAndCanRetryAfterFailure() async throws {
        let backend = FLSFakeStoreKitBackend()
        backend.unfinishedValues = [.verified(transaction())]
        let manager = FLSStoreKitManager(finishPolicy: .manual, backend: backend)
        _ = await manager.unfinishedTransactions()
        backend.finishFailures = 1
        do { try await manager.finish(transactionID: 10); XCTFail("首次模拟失败") } catch {}
        XCTAssertEqual(manager.pendingTransactions.count, 1)
        async let first: Void = manager.finish(transactionID: 10)
        async let second: Void = manager.finish(transactionID: 10)
        _ = try await (first, second)
        try await manager.finish(transactionID: 10)
        XCTAssertEqual(backend.finishAttempts, 2)
        XCTAssertEqual(backend.finished, [10])
        XCTAssertTrue(manager.pendingTransactions.isEmpty)
    }

    func testNewManagerCanReadAndFinishUnfinishedTransaction() async throws {
        let backend = FLSFakeStoreKitBackend()
        backend.unfinishedValues = [.verified(transaction())]
        let manager = FLSStoreKitManager(finishPolicy: .manual, backend: backend)
        let values = await manager.unfinishedTransactions()
        XCTAssertEqual(values.map(\.id), [10])
        XCTAssertTrue(backend.finished.isEmpty)
        try await manager.finish(transactionID: 10)
        XCTAssertEqual(backend.finished, [10])
    }

    func testCleanupOnlyFinishesStaleMatchingTransactions() async throws {
        let backend = FLSFakeStoreKitBackend()
        let other = FLSTransactionInfo(id: 13, originalTransactionID: 1, productID: "other", appAccountToken: nil,
            purchaseDate: Date(), expirationDate: .distantPast, revocationDate: nil, quantity: 1, jwsRepresentation: "test")
        backend.unfinishedValues = [.verified(transaction()), .verified(transaction(11, expired: true)),
            .verified(transaction(12, revoked: true)), .verified(other)]
        let manager = FLSStoreKitManager(finishPolicy: .manual, backend: backend)
        try await manager.finishStaleTransactions(productID: "product")
        XCTAssertEqual(backend.finished, [11, 12])
    }

    func testStalePurchaseRetriesOnceWithIdenticalOptions() async throws {
        let backend = FLSFakeStoreKitBackend()
        backend.results = [.success(.verified(transaction(9, expired: true))), .success(.verified(transaction()))]
        let manager = FLSStoreKitManager(finishPolicy: .manual, backend: backend)
        let outcome = try await manager.purchase(.init(productID: "product", appAccountToken: transaction().appAccountToken))
        XCTAssertEqual(outcome, .purchased(transaction()))
        XCTAssertEqual(backend.requests.count, 2)
        XCTAssertEqual(backend.requests[0].1, backend.requests[1].1)
        XCTAssertEqual(backend.finished, [9])
    }

    func testRepeatedStalePurchaseFailsAfterOneRetry() async {
        let backend = FLSFakeStoreKitBackend()
        backend.results = [.success(.verified(transaction(8, expired: true))), .success(.verified(transaction(9, revoked: true)))]
        let manager = FLSStoreKitManager(finishPolicy: .manual, backend: backend)
        do { _ = try await manager.purchase(.init(productID: "product")); XCTFail("不能把失效历史单当作新购成功") }
        catch { XCTAssertEqual(error as? FLSStoreKitError, .staleTransaction(9)) }
        XCTAssertEqual(backend.requests.count, 2)
        XCTAssertEqual(backend.finished, [8, 9])
        XCTAssertTrue(manager.pendingTransactions.isEmpty)
    }

    func testConcurrentPurchaseIsRejected() async throws {
        let backend = FLSFakeStoreKitBackend()
        backend.results = [.pending]
        let started = expectation(description: "购买已开始")
        backend.purchaseHook = {
            started.fulfill()
            await withCheckedContinuation { backend.purchaseContinuation = $0 }
        }
        let manager = FLSStoreKitManager(finishPolicy: .manual, backend: backend)
        let first = Task { try await manager.purchase(FLSPurchaseRequest(productID: "product")) }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await manager.purchase(.init(productID: "product")); XCTFail("重复购买应被拦截") }
        catch { XCTAssertEqual(error as? FLSStoreKitError, .purchaseInProgress) }
        backend.purchaseContinuation?.resume()
        _ = try await first.value
        XCTAssertEqual(backend.requests.count, 1)
    }
}

@MainActor
private final class FLSFakeStoreKitBackend: FLSStoreKitBackend {
    var results: [FLSBackendPurchaseResult] = []
    var requests: [(String, Set<Product.PurchaseOption>)] = []
    var unfinishedValues: [FLSBackendVerification] = []
    var current: [FLSBackendVerification] = []
    var finished: [UInt64] = []
    var finishAttempts = 0
    var finishFailures = 0
    var syncCount = 0
    var continuation: AsyncStream<FLSBackendVerification>.Continuation?
    var onSubscribe: (() -> Void)?
    var purchaseHook: (() async -> Void)?
    var purchaseContinuation: CheckedContinuation<Void, Never>?

    func purchase(productID: String, options: Set<Product.PurchaseOption>) async throws -> FLSBackendPurchaseResult {
        requests.append((productID, options))
        await purchaseHook?()
        guard !results.isEmpty else { throw FLSStoreKitError.failed("测试结果队列为空") }
        return results.removeFirst()
    }
    func unfinished() async -> [FLSBackendVerification] { unfinishedValues }
    func entitlements() async -> [FLSBackendVerification] { current }
    func updates() -> AsyncStream<FLSBackendVerification> {
        AsyncStream { continuation in
            self.continuation = continuation
            onSubscribe?()
        }
    }
    func sync() async throws { syncCount += 1 }
    func finish(transactionID: UInt64) async throws {
        finishAttempts += 1
        await Task.yield()
        if finishFailures > 0 {
            finishFailures -= 1
            throw FLSStoreKitError.failed("测试完成失败")
        }
        finished.append(transactionID)
    }
}
