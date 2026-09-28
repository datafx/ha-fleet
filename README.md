# Fleet for Home Assistant

A Home Assistant app that runs [Fleet](https://fleetdm.com) (osquery/fleetd device management) with bundled MySQL 8.4 LTS and Redis.

[![Add repository](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fdatafx%2Fha-fleet)

Architecture: amd64 only (Fleet does not publish an arm64 server binary).

## How updates flow

1. `fleet-bump.yml` checks fleetdm/fleet daily. When a newer `fleet-vX.Y.Z` release exists, it bumps `FLEET_VERSION` in the Dockerfile, sets the app `version` to match, prepends a CHANGELOG entry, test-builds the image, and opens a PR.
2. Merging to `main` triggers `build.yml`, which pushes `ghcr.io/datafx/amd64-ha-fleet:<version>`.
3. Home Assistant sees the new `version` in `config.yaml` and offers the update; the app runs `fleet prepare db` on start, so migrations apply automatically.

For packaging-only changes (run.sh, MySQL config), bump `version` in `fleet/config.yaml` yourself, e.g. `4.92.1.1`.
