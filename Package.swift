// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacMonitorWidget",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacMonitorWidget", targets: ["MacMonitorWidget"])
    ],
    targets: [
        .target(
            name: "MacMonitorWidget",
            path: "Sources",
            exclude: [
                "Assets.xcassets",
                "Info.plist",
                "MacMonitorApp.entitlements",
                "MacMonitorApp.swift",
                "MacMonitorWidget.swift",
                "MacMonitorWidgetExtension.entitlements",
                "WidgetViews.swift",
                "DynamicIslandView.swift",
                "DynamicIslandPanel.swift",
                "DashboardView.swift",
                "MenuBarPanel.swift",
                "SettingsView.swift",
                "PulseDesign.swift"
            ]
        ),
        .testTarget(name: "MacMonitorWidgetTests", dependencies: ["MacMonitorWidget"])
    ]
)
