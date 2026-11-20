# FLSStoreKit

iOS 17+、StoreKit 2、SwiftUI 的独立 SPM 组件。无第三方依赖，所有类型使用 FLS 前缀。商品、账户、订单与后端协议由宿主负责。

## SPM

在 Xcode 中添加 `https://github.com/YFCasually/FLSStoreKit.git`，选择已包含本次变更的提交。App 仅依赖 `FLSStoreKit` 产品。

## 外部参数

```swift
import FLSStoreKit

// 创建并持有一个共享实例；需要后端确认的 App 明确选择 manual。
let manager = FLSStoreKitManager(finishPolicy: .manual)
let request = FLSPurchaseRequest(
    productID: productIDFromServer,
    appAccountToken: accountUUIDFromServer,
    quantity: 1,
    offer: .standard
)
let outcome = try await manager.purchase(request)
if case .purchased(let transaction) = outcome {
    // 由宿主将交易信息发到自己的服务端，确认幂等交付成功之后再执行：
    // try await manager.finish(transactionID: transaction.id)
    // 失败保留交易，后续通过监听和 unfinishedTransactions() 重试。
}
```

`appAccountToken` 是可选 UUID，应稳定关联应用账户，禁止为每次购买随意生成。数量必须大于零，最终合法范围由 StoreKit 按商品判断。商品自动查询，无需先 configure；configure 用于展示和资格查询。

`additionalOptions: Set<Product.PurchaseOption>` 是原生扩展口，供宿主传入新的系统选项。新系统 API 必须由宿主做可用性检查，例如 iOS 18+ 的 `.winBackOffer`。不要与强类型字段重复设置账户、数量、优惠：PurchaseOption 是系统不透明值，组件不能识别和消除冲突。

`payJson`、业务订单号、自定义字典不属于 StoreKit 参数，宿主自己保留，不能混入 additionalOptions。

## 优惠

- 标准和首购：`.standard`、`.introductory`；首购资格由 Apple 决定，不能强制开启。
- 旧签名促销：`.init(kind: .promotional(FLSPromotionalOfferSignature(...)))`，原签名 API 保留。
- JWS 促销：`.init(kind: .promotionalJWS(offerID: offerID, compactJWS: signedJWS))`。只检查结构，StoreKit 验证真实性，不在客户端签名或打印 JWS。需要支持该系统 API 的 Xcode SDK 编译；当前 SDK 提供 iOS 17 回部署实现。
- 优惠码：使用 `FLSOfferCodeView` 调起系统兑换；不能作为普通 purchase 参数。
- 挽回优惠：在支持的系统传入原生 `.winBackOffer`；旧 `.winBack` 枚举仍明确报不支持，不静默降级为原价。

## 结果与交易生命周期

新接口 `purchase(_ request:) -> FLSPurchaseOutcome` 返回 purchased/pending/cancelled。已验签交易含 id、originalTransactionID、productID、appAccountToken、数量、时间及 jwsRepresentation。pending 和取消不能视为购买成功。JWS 和账户关联数据应按敏感信息处理。

旧 `purchase(productID:offer:)` 继续返回原来的 `FLSPurchaseResult`，新增参数均有默认值，也可直接传 appAccountToken、quantity、additionalOptions。

- `.automatic`（默认）：保留旧用法，购买、监听和恢复中验证通过的有效交易自动 finish。
- `.manual`：三条路径都保留有效交易，宿主确认交付后显式 `finish(transactionID:)`；同一管理器重复/并发完成会合并，失败可以重试。
- `transactionPublisher` 发布有效已验证交易，可能重复；宿主按交易 ID 幂等，先订阅再读取 `unfinishedTransactions()`，覆盖重启后的补单。
- `pendingTransactions` 是内存快照；StoreKit 未完成交易队列才是重启恢复来源。`unfinishedTransactions()` 本身不 finish，不表示后端确认成功。
- `refreshEntitlements()` 只读 Apple 权益，不发放服务端 VIP，不结束交易。
- 失效历史交易（已撤销或已到期）不会作为新购成功；购买前仅清理同商品失效旧单。购买返回失效旧单时清理后只重试一次，再次失效报错。**此清理不受 manual 延后交付策略约束**，未失效且未交付的交易不会被清理。
- 恢复返回有效交易快照；后端补单应另外读取 unfinished，包括已到期历史交易。订阅宽限期权益以 currentEntitlements/订阅状态为准，不以一次 purchase 结果取代权益查询。

`FLSProductPurchaseView` 和 `FLSSubscriptionView` 支持 `purchaseRequest` 闭包按商品注入参数，以及 `onPurchaseResult` 处理结果；默认调用保持兼容。

## 示例与验证

可运行 Demo 见 `Examples/FLSStoreKitDemo`，包含本地 StoreKit 配置及 XcodeGen 工程描述。

```sh
xcodebuild -scheme FLSStoreKit -destination 'platform=iOS Simulator,name=iPhone 17' test
```

测试在系统边界注入替身，验证参数转发、手动/自动交易完成、监听、恢复、重试和错误。它们不能代替真机、Sandbox 或真实后端验证。
