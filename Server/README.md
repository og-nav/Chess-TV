# Notification service

The Swift service in `follow-server/` uses Hummingbird, SQLite and APNSwift. Build and test with `scripts/server-build.sh` and `scripts/server-test.sh` from the repository root. `Server/Dockerfile` builds an independent Linux image from the required source packages.

`Sources/FollowServer/ServerConfig.swift` defines the supported environment settings. Provide your own `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_KEY_PATH` and `APNS_TOPIC` to enable delivery. The private key must be mounted from a protected file outside the repository. With APNs settings absent, the service uses its non-delivery mode. Optional Lichess credentials must also stay outside source control.

Place the service behind a TLS reverse proxy, bind its internal listener appropriately, and configure persistent database storage, backups and retention for your own environment. No production host, proxy routing configuration, deployment credentials or operational runbook is included.
