// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LinkAttributionSDK",
    // SDK 以 iOS 15 为宿主基线；macOS 目标仅用于 SwiftPM 单测和无 UIKit 的信号采集分支。
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "LinkAttributionSDK", targets: ["LinkAttributionSDK"])],
    targets: [
        .target(name: "LinkAttributionSDK", resources: [.process("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "LinkAttributionSDKTests", dependencies: ["LinkAttributionSDK"]),
    ],
    // 使用 Swift 5 语言模式保持宿主兼容，构建工具版本升级不应隐式改变并发语义。
    swiftLanguageModes: [.v5]
)
