# FLSStoreKit Demo

这是实际可编译的 SwiftUI 宿主示例，演示外部商品 ID、账户 UUID、数量、JWS 优惠，以及手动交付、恢复和未完成交易读取。不含业务后端，不输出 JWS。

## 运行

1. 安装 Xcode 及 XcodeGen；在本目录执行 `xcodegen generate`。
2. 打开 `FLSStoreKitDemo.xcodeproj`，选择同名 scheme 和 iOS 模拟器。
3. Scheme 的 Run 应使用随附 `Demo.storekit`，运行后购买默认的本地消耗型商品。
4. 账户 Token 为空时不设置系统账户选项；填写时必须为宿主提供的稳定 UUID。
5. 购买成功后交易留在待交付列表。仅在本地测试确认交付后点击结束交易；也可以重启并重新读取未完成交易。

本地配置未配置真实订阅优惠，不能验证生产 JWS、优惠资格、Sandbox 续订或后端发放。实际优惠需匹配 App Store Connect 商品、后端签名与测试账户。

`project.yml` 使用包本地路径，便于开发组件；Vograin 使用 GitHub 远程 SPM，二者用途不同。
