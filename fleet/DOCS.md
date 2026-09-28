# Fleet

Runs the Fleet server, MySQL 8.4 LTS and Redis in one container. All state lives in `/data`:

- `mysql/` – InnoDB datadir
- `secrets/` – generated MySQL passwords and `FLEET_SERVER_PRIVATE_KEY` (back this up; losing the key makes encrypted data such as MDM certs unrecoverable)
- `logs/` – osquery status/result logs and Fleet audit log (rotated)
- `tmp/` – locally stored software installers

## TLS

osquery/fleetd will only talk to Fleet over TLS, and the cert's CN/SAN must match the hostname agents use. Either:

- `ssl: true` with a cert/key in `/ssl` (e.g. from the Let's Encrypt or Nginx Proxy Manager apps), or
- `ssl: false` and terminate TLS at a reverse proxy that forwards to port 1337.

## First run

Open the web UI and complete setup to create the admin account. Then add hosts from **Hosts → Add hosts**, which generates fleetd packages pointing at this server's URL.
