// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "音频切换",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "YinPinQieHuan", targets: ["YinPinQieHuan"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "YinPinQieHuan",
            dependencies: ["RealtimeCore"],
            path: "Sources/音频切换",
            exclude: ["Resources"]
        ),
        .target(
            name: "RealtimeCore",
            path: "RealtimeCore",
            publicHeadersPath: "include",
            cSettings: [
                .define("ENABLE_SINC_FAST_CONVERTER"),
                .define("HAVE_STDBOOL_H"),
                .define("PACKAGE", to: "\"libsamplerate\""),
                .define("VERSION", to: "\"0.2.2\""),
                .headerSearchPath("Vendor/libsamplerate/include"),
                .headerSearchPath("Vendor/libsamplerate/src"),
            ],
            cxxSettings: [
                .headerSearchPath("Vendor/libsamplerate/include"),
                .headerSearchPath("Vendor/libsamplerate/src"),
            ]
        ),
        .testTarget(
            name: "YinPinQieHuanTests",
            dependencies: ["YinPinQieHuan", "RealtimeCore"],
            path: "Tests/YinPinQieHuanTests"
        ),
    ],
    swiftLanguageVersions: [.v5],
    cxxLanguageStandard: .cxx17
)
