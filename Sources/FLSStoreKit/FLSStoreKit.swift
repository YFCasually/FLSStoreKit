import Foundation
import StoreKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 基于 StoreKit 2 的独立购买组件。
///
/// 组件负责商品查询、交易验证、订阅权益刷新、恢复购买和优惠购买参数转换；
/// 商品 ID、服务端签名和业务订单字段由宿主 App 注入。
/// 商品购买优惠配置。
///
/// 组件只负责把业务层已经确认的优惠参数转换为 StoreKit 2 购买选项。
public struct FLSOfferConfiguration: Sendable, Equatable {
    /// 支持的购买优惠类型。
    public enum Kind: Sendable, Equatable {
        case standard
        case introductory
        case promotional(FLSPromotionalOfferSignature)
        case offerCode(referenceName: String)
        case winBack
    }

    public let kind: Kind

    public init(kind: Kind = .standard) { self.kind = kind }
    public static let standard = Self(kind: .standard)
    public static let introductory = Self(kind: .introductory)
}

/// 自动续订订阅 Promotional Offer 所需的签名参数。
public struct FLSPromotionalOfferSignature: Sendable, Equatable {
    public let offerID: String
    public let keyID: String
    public let nonce: UUID
    /// App Store Server 生成的签名二进制数据。
    public let signature: Data
    public let timestamp: Int

    public init(offerID: String, keyID: String, nonce: UUID, signature: Data, timestamp: Int) {
        self.offerID = offerID
        self.keyID = keyID
        self.nonce = nonce
        self.signature = signature
        self.timestamp = timestamp
    }

    /// 兼容后端常见的 Base64 字符串签名格式。
    public init?(offerID: String, keyID: String, nonce: UUID, base64Signature: String, timestamp: Int) {
        guard let data = Data(base64Encoded: base64Signature) else { return nil }
        self.init(offerID: offerID, keyID: keyID, nonce: nonce, signature: data, timestamp: timestamp)
    }
}

/// StoreKit 商品类型的统一表示。
public enum FLSProductKind: Sendable, Equatable {
    case consumable
    case nonConsumable
    case nonRenewingSubscription
    case autoRenewableSubscription
    case unknown
}

/// 订阅权益的客户端快照。
public struct FLSSubscriptionStatus: Sendable, Equatable {
    public let productID: String
    public let isEntitled: Bool
    public let expirationDate: Date?
    public let willAutoRenew: Bool
    public let isInGracePeriod: Bool

    public init(productID: String, isEntitled: Bool, expirationDate: Date?, willAutoRenew: Bool, isInGracePeriod: Bool) {
        self.productID = productID
        self.isEntitled = isEntitled
        self.expirationDate = expirationDate
        self.willAutoRenew = willAutoRenew
        self.isInGracePeriod = isInGracePeriod
    }
}

/// 一次购买操作的结果。
public enum FLSPurchaseResult: Sendable {
    case purchased(productID: String, transactionID: UInt64)
    case pending(productID: String)
    case cancelled(productID: String)
    case restored(productID: String, transactionID: UInt64)
    case fallbackToStandard(productID: String, reason: String)
}

/// StoreKit 组件对外暴露的错误。
public enum FLSStoreKitError: Error, LocalizedError, Sendable, Equatable {
    case productNotFound(String)
    case unverifiedTransaction(String)
    case unsupportedOffer(String)
    case missingScene
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .productNotFound(let id): "Product \(id) was not found."
        case .unverifiedTransaction(let message): "The transaction could not be verified: \(message)"
        case .unsupportedOffer(let message): message
        case .missingScene: "A window scene is required to manage subscriptions."
        case .failed(let message): message
        }
    }
}

@MainActor
/// 商品查询和排序服务。
public final class FLSProductStore: ObservableObject {
    @Published public private(set) var products: [Product] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: FLSStoreKitError?

    /// 创建商品查询服务。
    public init() {}

    @discardableResult
    /// 按商品 ID 查询 App Store 商品，并按价格升序发布结果。
    public func load(productIDs: [String]) async -> [Product] {
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: productIDs).sorted { $0.price < $1.price }
            lastError = nil
        } catch {
            lastError = .failed(error.localizedDescription)
        }
        return products
    }
}

@MainActor
/// StoreKit 2 购买、交易监听和权益刷新管理器。
public final class FLSStoreKitManager: ObservableObject {
    @Published public private(set) var products: [Product] = []
    @Published public private(set) var entitledProductIDs: Set<String> = []
    @Published public private(set) var subscriptionStatuses: [String: FLSSubscriptionStatus] = [:]
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: FLSStoreKitError?

    private var updatesTask: Task<Void, Never>?
    private var productIDs: [String] = []
    public let productStore: FLSProductStore

    /// 创建管理器并开始监听 StoreKit 交易更新。
    public init(productStore: FLSProductStore? = nil) {
        self.productStore = productStore ?? FLSProductStore()
        updatesTask = Task { [weak self] in await self?.observeTransactions() }
    }

    deinit { updatesTask?.cancel() }

    /// 配置商品 ID，完成商品查询并刷新当前权益。
    public func configure(productIDs: [String]) async {
        self.productIDs = productIDs
        products = await productStore.load(productIDs: productIDs)
        await refreshEntitlements()
    }

    /// 根据商品 ID 读取已经查询到的商品。
    public func product(id: String) -> Product? { products.first { $0.id == id } }

    /// 查询自动续订订阅是否满足 Introductory Offer 条件。
    ///
    /// 是否符合资格由 StoreKit 根据当前 Apple ID 的历史权益判断，业务层不应自行缓存结论。
    public func isEligibleForIntroOffer(productID: String) async -> Bool {
        guard let product = product(id: productID), let subscription = product.subscription else { return false }
        return await subscription.isEligibleForIntroOffer
    }

    /// 发起一次商品购买；优惠签名必须由宿主 App 或后端提供。
    public func purchase(productID: String, offer: FLSOfferConfiguration = .standard) async throws -> FLSPurchaseResult {
        guard let product = product(id: productID) else { throw FLSStoreKitError.productNotFound(productID) }
        isLoading = true
        defer { isLoading = false }
        do {
            var options = Set<Product.PurchaseOption>()
            switch offer.kind {
            case .standard, .introductory:
                break
            case .promotional(let signature):
                options.insert(.promotionalOffer(offerID: signature.offerID, keyID: signature.keyID, nonce: signature.nonce, signature: signature.signature, timestamp: signature.timestamp))
            case .offerCode(let referenceName):
                throw FLSStoreKitError.unsupportedOffer("Offer code \(referenceName) must be redeemed through FLSOfferCodeView.")
            case .winBack:
                throw FLSStoreKitError.unsupportedOffer("Win-back offers require an App Store configuration supported by the current OS version.")
            }
            return try await purchase(product: product, options: options)
        } catch let error as FLSStoreKitError {
            lastError = error
            throw error
        } catch {
            let mapped = FLSStoreKitError.failed(error.localizedDescription)
            lastError = mapped
            throw mapped
        }
    }

    /// 请求 App Store 同步当前 Apple ID 的历史购买记录。
    public func restorePurchases() async throws {
        try await AppStore.sync()
        await refreshEntitlements()
    }

    /// 读取当前有效权益，并刷新自动续订订阅状态。
    public func refreshEntitlements() async {
        var entitled: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if let transaction = try? verifiedTransaction(result) {
                entitled.insert(transaction.productID)
                await transaction.finish()
            }
        }
        entitledProductIDs = entitled
        await refreshSubscriptionStatuses()
    }

    /// 刷新每个自动续订订阅的续订、过期和宽限期状态。
    public func refreshSubscriptionStatuses() async {
        var statuses: [String: FLSSubscriptionStatus] = [:]
        for product in products {
            guard let subscription = product.subscription else { continue }
            guard let statusResults = try? await subscription.status else { continue }
            for statusResult in statusResults {
                guard let status = try? verifiedSubscriptionStatus(statusResult) else { continue }
                let expiration = status.transaction.productID == product.id ? status.transaction.expirationDate : nil
                let isEntitled = status.state == Product.SubscriptionInfo.RenewalState.subscribed || status.state == Product.SubscriptionInfo.RenewalState.inGracePeriod
                let isInGracePeriod = status.state == Product.SubscriptionInfo.RenewalState.inGracePeriod
                statuses[product.id] = FLSSubscriptionStatus(productID: product.id, isEntitled: isEntitled, expirationDate: expiration, willAutoRenew: status.renewalInfo.willAutoRenew, isInGracePeriod: isInGracePeriod)
            }
        }
        subscriptionStatuses = statuses
    }

    /// 打开系统订阅管理页面。
    public func manageSubscriptions() async throws {
#if canImport(UIKit)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw FLSStoreKitError.missingScene }
        try await AppStore.showManageSubscriptions(in: scene)
#else
        throw FLSStoreKitError.missingScene
#endif
    }

    private func purchase(product: Product, options: Set<Product.PurchaseOption>) async throws -> FLSPurchaseResult {
        switch try await product.purchase(options: options) {
        case .success(let verification):
            let transaction = try verifiedTransaction(verification)
            await transaction.finish()
            await refreshEntitlements()
            return .purchased(productID: transaction.productID, transactionID: transaction.id)
        case .userCancelled:
            return .cancelled(productID: product.id)
        case .pending:
            return .pending(productID: product.id)
        @unknown default:
            throw FLSStoreKitError.failed("StoreKit returned an unknown purchase result.")
        }
    }

    private func observeTransactions() async {
        for await result in Transaction.updates {
            guard let transaction = try? verifiedTransaction(result) else { continue }
            await transaction.finish()
            await refreshEntitlements()
        }
    }

    private func verifiedTransaction(_ result: VerificationResult<StoreKit.Transaction>) throws -> StoreKit.Transaction {
        switch result {
        case .verified(let transaction): return transaction
        case .unverified(_, let error): throw FLSStoreKitError.unverifiedTransaction(error.localizedDescription)
        }
    }

    private func verifiedSubscriptionStatus(_ result: Product.SubscriptionInfo.Status) throws -> (state: Product.SubscriptionInfo.RenewalState, renewalInfo: Product.SubscriptionInfo.RenewalInfo, transaction: StoreKit.Transaction) {
        let renewalInfo = try verified(result.renewalInfo)
        let transaction = try verified(result.transaction)
        return (result.state, renewalInfo, transaction)
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified(_, let error): throw FLSStoreKitError.unverifiedTransaction(error.localizedDescription)
        }
    }
}

/// 通用商品卡片示例视图。
public struct FLSProductCard: View {
    public let product: Product
    public let isPurchasing: Bool
    public let action: () -> Void

    public init(product: Product, isPurchasing: Bool = false, action: @escaping () -> Void) {
        self.product = product
        self.isPurchasing = isPurchasing
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(product.displayName).font(.headline)
            Text(product.description).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Text(product.displayPrice).font(.title3.bold())
                Spacer()
                Button("购买", action: action).disabled(isPurchasing)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 通用一次性商品购买示例视图。
public struct FLSProductPurchaseView: View {
    @ObservedObject private var manager: FLSStoreKitManager
    private let productIDs: [String]

    public init(manager: FLSStoreKitManager, productIDs: [String]) {
        self.manager = manager
        self.productIDs = productIDs
    }

    public var body: some View {
        Group {
            if manager.isLoading && manager.products.isEmpty { ProgressView() }
            else if manager.products.isEmpty {
                Label("暂无商品", systemImage: "cart")
                    .foregroundStyle(.secondary)
            }
            else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(manager.products, id: \.id) { product in
                            FLSProductCard(product: product, isPurchasing: manager.isLoading) {
                                Task { try? await manager.purchase(productID: product.id) }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .task { await manager.configure(productIDs: productIDs) }
    }
}

/// 通用订阅购买、恢复和管理示例视图。
public struct FLSSubscriptionView: View {
    @ObservedObject private var manager: FLSStoreKitManager
    private let productIDs: [String]

    public init(manager: FLSStoreKitManager, productIDs: [String]) {
        self.manager = manager
        self.productIDs = productIDs
    }

    public var body: some View {
        VStack(spacing: 16) {
            FLSProductPurchaseView(manager: manager, productIDs: productIDs)
            Button("恢复购买") { Task { try? await manager.restorePurchases() } }
            Button("管理订阅") { Task { try? await manager.manageSubscriptions() } }
        }
    }
}

/// 调起系统 Offer Code 兑换界面的包装视图。
public struct FLSOfferCodeView<Content: View>: View {
    @State private var isPresented = false
    private let content: Content
    private let onCompletion: ((Result<Void, Error>) -> Void)?

    public init(onCompletion: ((Result<Void, Error>) -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.onCompletion = onCompletion
    }

    public var body: some View {
#if os(iOS) || os(tvOS)
        content
            .onTapGesture { isPresented = true }
            .offerCodeRedemption(isPresented: $isPresented) { result in onCompletion?(result) }
#else
        content
#endif
    }
}

/// 将异步购买动作包装为 SwiftUI 按钮。
public struct FLSPurchaseButton: View {
    private let title: String
    private let action: () async -> Void

    public init(title: String = "购买", action: @escaping () async -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View { Button(title) { Task { await action() } } }
}

/// 展示订阅权益状态的示例视图。
public struct FLSSubscriptionStatusView: View {
    public let status: FLSSubscriptionStatus?

    public init(status: FLSSubscriptionStatus?) { self.status = status }

    public var body: some View {
        Group {
            if let status {
                Label(status.isEntitled ? "订阅有效" : "订阅已结束", systemImage: status.isEntitled ? "checkmark.seal.fill" : "xmark.seal")
            } else {
                Label("未订阅", systemImage: "person.crop.circle.badge.questionmark")
            }
        }
    }
}
