// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Allspot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Allspot", targets: ["Allspot"]),
        .executable(name: "allspot-cli", targets: ["allspot-cli"]),
        .executable(name: "allspot-tool", targets: ["AllspotTool"]),
    ],
    targets: [
        .target(name: "AllspotCore"),
        .executableTarget(name: "Allspot", dependencies: ["AllspotCore"]),
        .executableTarget(name: "allspot-cli", dependencies: ["AllspotCore"]),
        // AI용 명령줄 도구. 이름이 앱(Allspot)과 대소문자만 다르면 빌드 폴더에서 겹치므로 allspot-tool로 만들고,
        // 앱 안에는 Contents/Helpers/allspot으로 넣는다.
        .executableTarget(name: "AllspotTool", dependencies: ["AllspotCore"]),
    ]
)
