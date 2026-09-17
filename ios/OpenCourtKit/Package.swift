// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenCourtKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OpenCourtKit", targets: ["OpenCourtKit"]),
        .library(name: "OpenCourtSupabase", targets: ["OpenCourtSupabase"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
    ],
    targets: [
        // Models, formatting, freshness, the repository protocol and the demo feed. No deps.
        .target(name: "OpenCourtKit"),
        // Live data from the OpenCourt Supabase backend.
        .target(
            name: "OpenCourtSupabase",
            dependencies: [
                "OpenCourtKit",
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
        .testTarget(name: "OpenCourtKitTests", dependencies: ["OpenCourtKit"]),
    ]
)
