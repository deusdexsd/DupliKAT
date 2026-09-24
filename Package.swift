// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dubel",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "Vendor/MidniteUIKit")],
    targets: [
        // Logika bez UI: przeglądanie dysków, porównywanie zawartości, podobne zdjęcia/wideo/audio, backup, pliki FCP.
        .target(name: "DubelCore"),
        .executableTarget(name: "Dubel", dependencies: ["DubelCore", "MidniteUIKit"]),
        // Narzędzie deweloperskie: uruchamia skany z terminala na prawdziwych folderach (tylko odczyt).
        .executableTarget(name: "dubel-probe", dependencies: ["DubelCore"]),
        .testTarget(name: "DubelCoreTests", dependencies: ["DubelCore"]),
    ]
)
