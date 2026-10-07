## 4.92.3

- Update Fleet server to [v4.92.3](https://github.com/fleetdm/fleet/releases/tag/fleet-v4.92.3)

## 4.92.1.2

- Generate and configure the Windows MDM WSTEP certificate/key on first start (`/data/secrets`)

## 4.92.1.1

- Generate a self-signed cert (SANs from `tls_hostnames`) when `ssl: true` and no cert exists in `/ssl`
- Validate TLS before starting MySQL; any startup failure now shuts mysqld down cleanly
- Tighten `/run/mysqld` permissions

## 4.92.1

- Initial release: Fleet server [v4.92.1](https://github.com/fleetdm/fleet/releases/tag/fleet-v4.92.1) with bundled MySQL 8.4 LTS and Redis
