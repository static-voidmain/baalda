// swift-tools-version:5.3
// SPDX-License-Identifier: Apache-2.0
import PackageDescription

let package = Package(
    name: "tauri-plugin-cloud-drive",
    platforms: [.iOS(.v14)],
    products: [.library(name: "tauri-plugin-cloud-drive", type: .static, targets: ["CloudDrive"])],
    dependencies: [.package(name: "Tauri", path: "../.tauri/tauri-api")],
    targets: [.target(name: "CloudDrive", dependencies: ["Tauri"], path: "Sources")]
)
