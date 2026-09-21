# Chess TV

Live chess viewers for Apple TV, iPhone, iPad and Apple Watch. Watch Lichess channels, arenas and broadcasts with on-device Stockfish analysis. The phone supports follows, notifications and a pinned Live Activity; the Watch shows followed games and clocks.

## Build

Requires Xcode 27 with iOS, tvOS and watchOS SDKs, deployment targets 26, and XcodeGen.

```sh
scripts/fetch-net.sh
xcodegen generate
scripts/build.sh
scripts/build-ios.sh
scripts/build-watch.sh
```

For a physical device, configure your own Apple Developer team and bundle/App Group identifiers. The published project has no developer team selected. For signed release exports, set `DEVELOPMENT_TEAM` and an explicit `BUILD_NUMBER`, then use `scripts/archive-tv.sh` or `scripts/archive-ios.sh`. Signing credentials belong outside this repository. `IOS_DEVICE_ID` and `WATCH_DEVICE_ID` are required by their install scripts.

## Test

```sh
scripts/test.sh
scripts/test-ios.sh
scripts/test-ui-tv.sh
scripts/test-ui-ios.sh
scripts/server-test.sh
```

Simulator IDs can be overridden using the environment variables described in each script. Engine tests locate the NNUE relative to this checkout; `ENGINEKIT_NNUE_PATH` overrides that location.

## Layout

- `Apps/`: the platform apps, notifications, Live Activity, Watch widget and UI tests.
- `Packages/`: chess parsing, UI, feeds, image loading, engine integration, shared sessions and follow contracts.
- `Server/follow-server/`: optional notification service implementation and tests. Configure a separate deployment with environment variables documented in `Server/README.md`.
- `Fixtures/`: public chess captures used by deterministic tests.
- `scripts/`: build, test and asset-generation tools.

## Licences and attribution

Chess TV is licensed under GPLv3; see `LICENSE`. It statically includes Stockfish 19, with its original notices in `Packages/EngineKit/Vendor/stockfish/` and modifications documented in `Packages/EngineKit/Vendor/PATCHES.md`. `scripts/fetch-net.sh` retrieves the exact `nn-1a298aa575a0.nnue` network from the Stockfish project and verifies its SHA-256 hash.

Piece sets and their licences are documented in `Packages/ChessUI/LICENSES.md`; the apps bundle GPLv2, GPLv3 and Apache-2.0 texts and show credits in Settings. Move, capture, check and game-over audio are original deterministic synthesis: run `python3 scripts/make-sounds.py`. The move is the Wood audition; the other production sounds retain their previous synthesis.

Games, broadcasts, arenas and player portraits are supplied by Lichess. Chess TV is not affiliated with Lichess, FIDE or Stockfish. Apple Music is optional and requires the viewer's subscription.

Corresponding source: https://github.com/og-nav/Chess-TV

## Security

Do not commit private keys, tokens, environment files, device data, signing profiles, databases or build logs. Build products and private configuration are ignored. Report a security issue privately to the maintainer at zzzlabshq@gmail.com; do not include credentials in a public issue.
