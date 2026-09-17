# OpenCourt iOS

SwiftUI app (iOS 17+) that shows live court status: which courts are open, how many people
are waiting, and roughly how long the wait is.

```
ios/
├── OpenCourt.xcodeproj     app project (sources folder is synced automatically)
├── OpenCourt/              app: SwiftUI views, theme, entry point
├── OpenCourtKit/           Swift package
│   ├── OpenCourtKit        models, decoding, freshness, formatting, SiteStore, demo feed
│   └── OpenCourtSupabase   live repository (supabase-swift): fetch + Realtime "poke"
└── Config/                 xcconfig + Info.plist (backend host/key)
```

## Run

1. Accept the Xcode license once: `sudo xcodebuild -license accept`.
2. Open `OpenCourt.xcodeproj`, choose an iPhone simulator, and run.
   - Without a backend configured, the app shows **demo data** (it says so on screen).
   - To use a real backend: `cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig`,
     then fill in the host (no `https://`) and the anon key.
   - The `-demo` launch argument forces demo data even when a backend is configured.
3. On your own iPhone, set a Team under Signing & Capabilities. A free Apple account works
   for personal devices. TestFlight needs the paid developer program.

## Test

```bash
cd OpenCourtKit && swift test          # models, decoding, formatting, store, demo feed
```

or from the command line with Xcode:

```bash
xcodebuild -project OpenCourt.xcodeproj -scheme OpenCourt \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## Design notes

- **Live updates.** The app refetches whenever Realtime reports a change, and polls every
  20 s as a backup. Fetching is the only source of truth, so a dropped Realtime connection
  can only make the data older, never wrong.
- **Staleness.** A site that hasn't reported for 60 s shows a banner, and its numbers are
  greyed out.
- **Wording.** The amber state reads *"Time up"*. A test fails if any state title contains
  accusatory wording.
- **Clocks.** Between updates, court clocks count up locally from the last `updated_at`.
