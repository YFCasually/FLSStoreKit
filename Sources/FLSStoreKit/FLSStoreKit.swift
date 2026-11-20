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
        /// 后端使用 JWS 签名的促销优惠，签名内容由后端生成。
        case promotionalJWS(offerID: String, compactJWS: String)
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
    case invalidPurchaseRequest(String)
    case purchaseInProgress
    case staleTransaction(UInt64)
    case transactionNotFound(UInt64)
    case missingScene
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .productNotFound(let id): "Product \(id) was not found."
        case .unverifiedTransaction(let message): "The transaction could not be verified: \(message)"
        case .unsupportedOffer(let message): message
        case .invalidPurchaseRequest(let message): message
        case .purchaseInProgress: "Another purchase is already in progress."
        case .staleTransaction(let id): "Transaction \(id) has expired or been revoked."
        case .transactionNotFound(let id): "Verified unfinished transaction \(id) was not found."
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
    private let purchaseRequest: (Product) -> FLSPurchaseRequest
    private let onPurchaseResult: ((Result<FLSPurchaseOutcome, Error>) -> Void)?

    /// 宿主可按商品注入账户与优惠参数；结果回调不等于服务器已发放权益。
    public init(manager: FLSStoreKitManager, productIDs: [String],
                purchaseRequest: @escaping (Product) -> FLSPurchaseRequest = { .init(productID: $0.id) },
                onPurchaseResult: ((Result<FLSPurchaseOutcome, Error>) -> Void)? = nil) {
        self.manager = manager
        self.productIDs = productIDs
        self.purchaseRequest = purchaseRequest
        self.onPurchaseResult = onPurchaseResult
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
                                Task {
                                    do {
                                        let result = try await manager.purchase(purchaseRequest(product))
                                        onPurchaseResult?(.success(result))
                                    }
                                    catch { onPurchaseResult?(.failure(error)) }
                                }
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
    private let purchaseRequest: (Product) -> FLSPurchaseRequest
    private let onPurchaseResult: ((Result<FLSPurchaseOutcome, Error>) -> Void)?

    /// 宿主可按商品注入账户与优惠参数；结果回调不等于服务器已发放权益。
    public init(manager: FLSStoreKitManager, productIDs: [String],
                purchaseRequest: @escaping (Product) -> FLSPurchaseRequest = { .init(productID: $0.id) },
                onPurchaseResult: ((Result<FLSPurchaseOutcome, Error>) -> Void)? = nil) {
        self.manager = manager
        self.productIDs = productIDs
        self.purchaseRequest = purchaseRequest
        self.onPurchaseResult = onPurchaseResult
    }

    public var body: some View {
        VStack(spacing: 16) {
            FLSProductPurchaseView(manager: manager, productIDs: productIDs,
                                   purchaseRequest: purchaseRequest, onPurchaseResult: onPurchaseResult)
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
