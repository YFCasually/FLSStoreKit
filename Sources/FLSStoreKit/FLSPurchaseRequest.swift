import Foundation
import StoreKit

/// 一次购买的可扩展参数。商品与账户由宿主提供，组件不识别业务订单字段。
public struct FLSPurchaseRequest: Sendable {
    public var productID: String
    /// 后端为应用账户生成的稳定 UUID，不应每次购买随机生成。
    public var appAccountToken: UUID?
    /// StoreKit 最终决定该商品是否允许此数量；组件先拒绝小于 1 的值。
    public var quantity: Int
    public var offer: FLSOfferConfiguration
    /// 系统购买选项扩展口。不要重复传入已由上方字段设置的账户、数量或优惠选项。
    /// 新系统专属选项由调用方使用 #available 检查；组件不会将业务字典伪装成系统参数。
    public var additionalOptions: Set<Product.PurchaseOption>

    public init(productID: String, appAccountToken: UUID? = nil, quantity: Int = 1,
                offer: FLSOfferConfiguration = .standard,
                additionalOptions: Set<Product.PurchaseOption> = []) {
        self.productID = productID
        self.appAccountToken = appAccountToken
        self.quantity = quantity
        self.offer = offer
        self.additionalOptions = additionalOptions
    }

    /// 在调用 StoreKit 前集中校验；不静默降级优惠，也不丢弃外部系统选项。
    func purchaseOptions() throws -> Set<Product.PurchaseOption> {
        guard !productID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FLSStoreKitError.invalidPurchaseRequest("商品 ID 不能为空。")
        }
        guard quantity > 0 else {
            throw FLSStoreKitError.invalidPurchaseRequest("购买数量必须大于 0。")
        }
        var options = additionalOptions
        options.insert(.quantity(quantity))
        if let appAccountToken { options.insert(.appAccountToken(appAccountToken)) }
        switch offer.kind {
        case .standard, .introductory:
            break // 首购优惠是否生效仍由 App Store 判断。
        case .promotional(let signature):
            guard !signature.offerID.isEmpty, !signature.keyID.isEmpty,
                  !signature.signature.isEmpty, signature.timestamp > 0 else {
                throw FLSStoreKitError.invalidPurchaseRequest("促销优惠签名参数不完整。")
            }
            options.insert(.promotionalOffer(offerID: signature.offerID, keyID: signature.keyID,
                nonce: signature.nonce, signature: signature.signature, timestamp: signature.timestamp))
        case .promotionalJWS(let offerID, let compactJWS):
            guard !offerID.isEmpty, compactJWS.split(separator: ".", omittingEmptySubsequences: false).count == 3,
                  compactJWS.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }) else {
                throw FLSStoreKitError.invalidPurchaseRequest("JWS 优惠参数不完整。")
            }
            // SDK 提供向旧系统回部署的实现；真实性由 StoreKit 验证。
            options.formUnion(Product.PurchaseOption.promotionalOffer(offerID, compactJWS: compactJWS))
        case .offerCode(let name):
            throw FLSStoreKitError.unsupportedOffer("优惠码 \(name) 请通过 FLSOfferCodeView 兑换。")
        case .winBack:
            throw FLSStoreKitError.unsupportedOffer("请在支持的系统中通过 additionalOptions 传入 .winBackOffer。")
        }
        return options
    }
}

/// 交易完成策略在管理器创建时确定，统一约束购买、恢复与交易监听。
public enum FLSTransactionFinishPolicy: Sendable, Equatable {
    /// 兼容原有行为：验证成功的交易由组件完成，适用于无需后端确认的宿主。
    case automatic
    /// 有效交易等待宿主交付/后端确认后调用 finish；失效旧单可被购买流程清理。
    case manual
}

/// 已通过 StoreKit 验签的交易快照，不代表业务服务器已经发放权益。
public struct FLSTransactionInfo: Sendable, Equatable, Identifiable {
    public let id: UInt64
    public let originalTransactionID: UInt64
    public let productID: String
    public let appAccountToken: UUID?
    public let purchaseDate: Date
    public let expirationDate: Date?
    public let revocationDate: Date?
    public let quantity: Int
    /// 可提交后端独立验签；请勿写入日志或聊天。
    public let jwsRepresentation: String

    /// 非订阅没有到期时间；撤销或到期的交易不能作为一次新购成功。
    public func isStale(at date: Date = Date()) -> Bool {
        revocationDate != nil || expirationDate.map { $0 <= date } == true
    }
}

/// 新购买接口的详细结果；保留旧 FLSPurchaseResult，避免破坏原调用方的枚举匹配。
public enum FLSPurchaseOutcome: Sendable, Equatable {
    case purchased(FLSTransactionInfo)
    case pending(productID: String)
    case cancelled(productID: String)
}
