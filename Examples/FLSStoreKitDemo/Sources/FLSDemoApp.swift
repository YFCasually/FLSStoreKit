import FLSStoreKit
import StoreKit
import SwiftUI

@main
struct FLSDemoApp: App {
    var body: some Scene { WindowGroup { FLSDemoView() } }
}

/// 外部参数输入示例。真实 App 应由自己的接口提供商品、账户及优惠签名。
struct FLSDemoView: View {
    @StateObject private var manager = FLSStoreKitManager(finishPolicy: .manual)
    @State private var productID = "com.fls.demo.coins"
    @State private var accountToken = ""
    @State private var quantity = 1
    @State private var useOffer = false
    @State private var offerID = ""
    @State private var compactJWS = ""
    @State private var message = "使用本地 StoreKit 配置测试；账户 UUID 由宿主提供。"

    var body: some View {
        NavigationStack {
            Form {
                Section("宿主购买参数") {
                    TextField("Apple 商品 ID", text: $productID).textInputAutocapitalization(.never)
                    TextField("appAccountToken UUID（可选）", text: $accountToken).textInputAutocapitalization(.never)
                    Stepper("数量：\(quantity)", value: $quantity, in: 1...10)
                    Toggle("使用 JWS 促销优惠", isOn: $useOffer)
                    if useOffer {
                        TextField("offerID", text: $offerID)
                        SecureField("服务端 compactJWS", text: $compactJWS)
                    }
                    Button("购买") { Task { await buy() } }.disabled(manager.isLoading)
                    Button("恢复购买") { Task { await perform { _ = try await manager.restoreTransactions() } } }
                    Button("重新读取未完成交易") { Task { _ = await manager.unfinishedTransactions() } }
                    FLSOfferCodeView { Text("兑换优惠码") }
                }
                Section("待交付交易") {
                    ForEach(manager.pendingTransactions) { transaction in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(transaction.productID)
                            Text("交易：\(transaction.id)；原始：\(transaction.originalTransactionID)").font(.caption)
                            Text("数量：\(transaction.quantity)；账户：\(transaction.appAccountToken?.uuidString ?? "未传入")").font(.caption)
                            // 仅演示 StoreKit 本地测试的交付确认；真实宿主必须先确认服务器已发放权益。
                            Button("本地测试：确认已交付并结束交易") {
                                Task { await perform { try await manager.finish(transactionID: transaction.id) } }
                            }
                        }
                    }
                }
                Section("状态") { Text(message) }
                Section { Text("Demo 不连接业务服务器。真实 App 必须先完成后端验签和幂等交付，再调用 finish；失败时保留交易，重启后通过 unfinishedTransactions 重试。") }
            }
            .navigationTitle("FLSStoreKit Demo")
            .task { _ = await manager.unfinishedTransactions() }
        }
    }

    @MainActor private func buy() async {
        await perform {
            let token: UUID?
            if accountToken.isEmpty { token = nil }
            else if let value = UUID(uuidString: accountToken) { token = value }
            else { throw FLSStoreKitError.invalidPurchaseRequest("账户 Token 必须为有效 UUID。") }
            let offer: FLSOfferConfiguration = useOffer
                ? .init(kind: .promotionalJWS(offerID: offerID, compactJWS: compactJWS)) : .standard
            let result = try await manager.purchase(FLSPurchaseRequest(productID: productID,
                appAccountToken: token, quantity: quantity, offer: offer))
            switch result {
            case .purchased: message = "StoreKit 验签通过；等待宿主交付确认。"
            case .pending: message = "等待系统批准。"
            case .cancelled: message = "用户已取消。"
            }
        }
    }

    @MainActor private func perform(_ action: () async throws -> Void) async {
        do { try await action() }
        catch { message = error.localizedDescription }
    }
}
