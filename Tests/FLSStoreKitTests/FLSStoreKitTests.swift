import XCTest
@testable import FLSStoreKit

/// 验证支付组件的值类型配置，不依赖真实 App Store 环境。
final class FLSStoreKitTests: XCTestCase {
    /// 标准购买和首购优惠配置应保持可比较且不共享可变状态。
    func testOfferConfigurationIsValueTyped() {
        XCTAssertEqual(FLSOfferConfiguration.standard, FLSOfferConfiguration(kind: .standard))
        XCTAssertEqual(FLSOfferConfiguration.introductory, FLSOfferConfiguration(kind: .introductory))
    }
}
