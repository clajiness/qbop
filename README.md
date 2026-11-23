![qbop logo](public/images/light/apple-touch-icon-light.png)

# qbop

qbop synchronizes a forwarded port from ProtonVPN or Gluetun with OPNsense and qBittorrent. Its Docker image provides a web UI and API at `http://<host_ip>:4567/`.

See [Quick Start](#quick-start) for a new installation or [Updating qbop](#updating-qbop) for an existing one.

## What qbop does

- Maintains a ProtonVPN NAT-PMP lease or reads the forwarded port from Gluetun
- Updates OPNsense firewall aliases and qBittorrent's listening port when those integrations are enabled
- Imports a ProtonVPN WireGuard configuration into an existing OPNsense instance and peer
- Keeps the 500 most recent port transitions and their synchronization status

## Contents

- [Requirements and integrations](#requirements-and-integrations)
- [Quick Start](#quick-start)
- [Installation](#installation)
- [Updating qbop](#updating-qbop)
- [Configuration](#configuration)
- [Integration setup](#integration-setup)
- [Authentication](#authentication)
- [ProtonVPN WireGuard importer](#protonvpn-wireguard-importer)
- [API](#api)
- [Upgrading to v3.6.0](#upgrading-to-v360)
- [Upgrading from qbop 2.x to 3.0](#upgrading-from-qbop-2x-to-30)
- [Operational details and troubleshooting](#operational-details-and-troubleshooting)
- [Architecture and implementation](#architecture-and-implementation)

## Requirements and integrations

- [Docker Engine](https://docs.docker.com/engine/install/) running Linux containers on AMD64 or ARM64
- [ProtonVPN](https://protonvpn.com/support/port-forwarding) for the default NAT-PMP source, or [Gluetun](https://github.com/passteque/gluetun) with port forwarding enabled
- Optional [OPNsense](https://docs.opnsense.org/) and [qBittorrent](https://www.qbittorrent.org/) integrations. Use `OPN_SKIP=true` or `QBIT_SKIP=true` to skip an integration.

## Quick Start

1. Clone the repository and open the Compose directory:

   ```bash
   git clone https://github.com/clajiness/qbop
   cd qbop/docker-compose
   ```

2. Review `docker-compose.yml` and your networking. Route qbop through ProtonVPN in the default mode, or give it access to Gluetun's control API in Gluetun mode. The sample expects that network access to be configured separately. See [Integration setup](#integration-setup).
3. Start qbop:

   ```bash
   docker compose up -d
   ```

4. Open `http://<host_ip>:4567/` and create the administrator at `/setup`.
5. In **Settings**, use Proton and adjust its gateway if needed, or select Gluetun and enter its control API settings. Configure or skip OPNsense and qBittorrent.
6. Restart qbop to apply the synchronization settings.

   ```bash
   docker compose restart qbop
   ```

The UI stays available during setup. Status indicators and `/api/health` reflect [successful synchronization checks](#api) as they complete.

## Installation

The [Compose sample](docker-compose/docker-compose.yml) uses the [published image](https://github.com/clajiness/qbop/pkgs/container/qbop) and enables local browser login. It mounts `data` at `/opt/qbop/data/` and `log` at `/opt/qbop/log/`. Keep the data volume across replacements to retain the database, session secret, and settings encryption key. See [Encrypted credentials and backups](#encrypted-credentials-and-backups).

### Updating qbop

Back up your Compose file and data volume. Update any pinned release tag when moving to a new release, or select the updated digest if you pin by digest.

```bash
docker compose pull qbop
docker compose up -d --force-recreate qbop
```

For older installations, see the notes for [v3.6.0 settings and migrations](#upgrading-to-v360) and [2.x to 3.0 authentication changes](#upgrading-from-qbop-2x-to-30).

### Image tags

- `latest` tracks the newest stable release.
- `v3` tracks the newest 3.x release, `v3.7` tracks the newest 3.7.x patch, and a tag such as `v3.7.2` selects that release.
- `main` and [branch tags](docs/image-publishing.md#development-branch-names) track development builds.
- `build-<commit-sha12>-<run-id>-<attempt>` identifies an immutable, validated build.
- Legacy `v2` and `sha-<commit-sha12>` tags remain available for older deployments.

### Automated container security rebuilds

**Upstream security rebuild** checks the latest stable release daily and builds a fresh image when its Ruby base-image digest changes or publication is incomplete. It refreshes Debian packages using the released source, pinned Ruby version, and locked gems. Changes to Ruby or gem versions ship in a new qbop release.

After AMD64 and ARM64 checks pass, the workflow refreshes the current release's exact, minor, major, and `latest` tags. [Update qbop](#updating-qbop) to pick up the refreshed image. See the [publishing runbook](docs/image-publishing.md) for forced refreshes and recovery from interrupted publication.

## Configuration

Use **Settings** at `/settings` to save application, integration, and logging values in SQLite, or manage them through Compose environment variables. Authentication and OIDC use environment variables.

An authoritative environment variable takes precedence over a saved setting, which takes precedence over the default. Environment-managed controls are read-only.

**Save** creates a database override, even when you save the displayed default. **Clear qbop override** removes the saved value even while an ENV variable takes precedence. Manage environment variables separately in Compose.

Empty ENV placeholders generally let saved values take effect. Some retain their legacy blank behavior when no saved value exists. An explicitly blank `PORT_SOURCE` fails startup, and an explicit boolean `false` overrides the saved value. For firewall aliases, qbop uses the first populated value from `OPN_ALIAS_NAME`, `OPN_PROTON_ALIAS_NAME`, and the saved alias, in that order.

### Restart behavior

Run `docker compose restart qbop` after saving a setting marked **Restart required**. `UI_MODE`, `LOG_LINES`, and `LOG_REVERSE` apply on the next request.

Status and health use the running job's settings. The About page shows configured values, including changes awaiting a restart. See [API](#api) for pending-restart metadata.

### Moving from ENV to Settings

To move an ENV-managed setting into the UI:

1. Remove the assignment shown in Settings from Compose or its environment source. For aliases, check both `OPN_ALIAS_NAME` and `OPN_PROTON_ALIAS_NAME`.
2. Recreate qbop to apply the new environment and retain its volumes.

   ```bash
   docker compose up -d --force-recreate qbop
   ```

3. Save the value in Settings. Re-enter credentials from their original source, since the UI masks saved credentials. Restart qbop for settings marked **Restart required**.

qbop may use a default or lack a required value until you save the new setting. Transfer any ENV values you want to keep by entering them in Settings.

### Encrypted credentials and backups

qbop encrypts integration API keys, usernames, and passwords saved in SQLite with AES-256-GCM. The first credential save creates `data/settings_encryption_key.txt`. Browser sessions use a separate `data/session_secret.txt`.

**Stop qbop before backing up or restoring the entire data volume.** Restore the SQLite database and its original encryption key from the same backup. Keep backups private and preserve writable ownership for UID/GID `1234` and mode `0600` for the key and its `.lock` file.

If the key is missing, corrupt, or mismatched, restore the original from backup. Login and Settings remain available, but synchronization and credential replacement can fail until recovery.

If you cannot recover the original key, clear **every saved integration credential, including usernames**, in Settings. After clearing them, stop qbop and remove any corrupt settings key file. Start qbop, re-enter the credentials, then restart to apply them. qbop reuses a valid settings key or generates one when the key file and dependent records are both absent. Keep the browser session secret separate.

### ENV Variables

A blank default means you must supply a value when the integration requires it. See [Integration setup](#integration-setup) and [Authentication](#authentication) for those requirements.

Settings validates booleans, integer ranges, and nonblank credentials without control characters. Saved HTTP(S) URLs require a host and a valid port and reject userinfo, query strings, and fragments. Use root URLs for OPNsense and qBittorrent. `GLUETUN_ADDR` also accepts a path prefix.

#### Core application settings

| Variable | Default | Description |
| :--- | :--- | :--- |
| `UI_MODE` | `dark` | Web UI mode: `dark` or `light`. |
| `LOOP_FREQ` | `45` | Seconds between job loops. Must be a positive integer; the default is recommended by ProtonVPN. |
| `REQUIRED_ATTEMPTS` | `3` | Number of loops in which a downstream port differs from the selected source's forwarded port before updating that integration. Range: 1–10; shared by both sources. |
| `PORT_SOURCE` | `proton` | Forwarded-port source: `proton` or `gluetun`. A present blank ENV value or unsupported source fails startup. |

#### ProtonVPN settings

| Variable | Default | Description |
| :--- | :--- | :--- |
| `PROTON_GATEWAY` | `10.2.0.1` | ProtonVPN provided gateway IP address. Do not use `http(s)://` or a trailing slash. |

#### Gluetun settings

These settings apply only when `PORT_SOURCE=gluetun`.

| Variable | Default | Description |
| :--- | :--- | :--- |
| `GLUETUN_ADDR` | `http://gluetun:8000` | Reachable HTTP(S) control server URL. Supports a reverse proxy path prefix. Use the dedicated authentication variables. Legacy ENV URL userinfo is ignored and masked in configuration displays. |
| `GLUETUN_API_KEY` | | Control API key sent as `X-API-Key`. Takes precedence over Basic credentials. |
| `GLUETUN_USER` | | HTTP Basic username; requires `GLUETUN_PASS` when no API key is configured. |
| `GLUETUN_PASS` | | HTTP Basic password; requires `GLUETUN_USER` when no API key is configured. If neither authentication method is configured, requests are unauthenticated. |
| `GLUETUN_SSL_VERIFY` | `false` | [`true`/`false`] Verify certificates for the Gluetun client only. |

#### OPNsense settings

| Variable | Default | Description |
| :--- | :--- | :--- |
| `OPN_SKIP` | `false` | [`true`/`false`] Skip OPNsense synchronization and WireGuard import. If `true`, its connection settings are not required. |
| `OPN_INTERFACE_ADDR` | | Root HTTP(S) URL for the OPNsense API. A trailing `/` is accepted for saved values. |
| `OPN_API_KEY` | | OPNsense API Key |
| `OPN_API_SECRET` | | OPNsense API Secret |
| `OPN_ALIAS_NAME` | | Preferred firewall alias used for the selected source's forwarded port. A populated value takes precedence over `OPN_PROTON_ALIAS_NAME`. For example, `vpn_forwarded_port`. |
| `OPN_PROTON_ALIAS_NAME` | | Supported backwards-compatible fallback when `OPN_ALIAS_NAME` is unset, empty, or whitespace-only. Existing configurations continue working. |
| `OPN_SSL_VERIFY` | `false` | [`true`/`false`] Verify OPNsense TLS certificates. Defaults to `false` for self-signed/private deployments. |

The About page displays the effective alias under `OPN_ALIAS_NAME`, and `/api/about` returns it as `opn_alias_name`. The existing `opn_proton_alias_name` API field continues showing the configured legacy value.

#### qBittorrent settings

| Variable | Default | Description |
| :--- | :--- | :--- |
| `QBIT_SKIP` | `false` | [`true`/`false`] Skip qBittorrent synchronization. If `true`, its connection settings are not required. |
| `QBIT_ADDR` | | Root HTTP(S) URL for the qBittorrent Web API. A trailing `/` is accepted for saved values. |
| `QBIT_API_KEY` | | qBittorrent API key. If set, this is used instead of `QBIT_USER` and `QBIT_PASS`. Requires qBittorrent 5.2.0 or newer. |
| `QBIT_USER` | | qBittorrent username. Used when `QBIT_API_KEY` is not set. |
| `QBIT_PASS` | | qBittorrent password. Used when `QBIT_API_KEY` is not set. |
| `QBIT_SSL_VERIFY` | `false` | [`true`/`false`] Verify qBittorrent TLS certificates. Defaults to `false` for self-signed/private deployments. |

#### Authentication and OIDC settings

| Variable | Default | Description |
| :--- | :--- | :--- |
| `WEB_AUTH_ENABLED` | `true` | Require browser authentication for the web UI. Disable only if the UI is protected by another trusted access layer. |
| `LOCAL_LOGIN_ENABLED` | `true` | Offer and accept local password login. This does not remove the local account, setup, account management, or password recovery. |
| `OIDC_ENABLED` | `false` | Enable optional OpenID Connect browser authentication. OIDC is not initialized when disabled. |
| `OIDC_ISSUER` | | HTTPS issuer URL used for standard OIDC discovery, such as `https://id.example.com`. Required when OIDC and browser authentication are enabled. HTTP issuers are rejected, including on loopback. |
| `OIDC_CLIENT_ID` | | Confidential OIDC client identifier. Required when OIDC and browser authentication are enabled. |
| `OIDC_CLIENT_SECRET` | | Confidential OIDC client secret. Required when OIDC and browser authentication are enabled. |
| `OIDC_PUBLIC_URL` | | Externally reachable qbop origin, such as `https://qbop.example.com`, without a path. Used for fixed callback URLs and required when OIDC and browser authentication are enabled. |
| `OIDC_AUTO_REDIRECT` | `false` | Automatically submit the CSRF-protected OIDC sign-in form at `/login` when local login is disabled. Requires `OIDC_ENABLED=true` when browser authentication is enabled. |

#### Logging settings

| Variable | Default | Description |
| :--- | :--- | :--- |
| `LOG_LINES` | `50` | Default number of log lines displayed on `/logs` and `/api/logs`. Saved values: 1–5000. |
| `LOG_REVERSE` | `false` | Reverse the display order of log lines, showing newest logs at the top when enabled. |
| `LOG_TO_STDOUT` | `false` | Log to stdout instead of the default log directory. See [Logging](#logging) for the effect on `/logs`. |

## Integration setup

### ProtonVPN and OPNsense

Route qbop through ProtonVPN so it can reach `PROTON_GATEWAY` and request a forwarded port. Generate ProtonVPN WireGuard configurations with NAT-PMP (Port Forwarding) enabled and Moderate NAT disabled.

For OPNsense, follow its [WireGuard selective-routing guide](https://docs.opnsense.org/manual/how-tos/wireguard-selective-routing.html) and [API setup guide](https://docs.opnsense.org/development/how-tos/api.html). Save the OPNsense address and API credentials, set `OPN_ALIAS_NAME` to the forwarded-port firewall alias, and restart qbop.

To rotate an existing tunnel using a new ProtonVPN configuration, see the [WireGuard importer](#protonvpn-wireguard-importer).

### Gluetun

Enable port forwarding for exactly one port in Gluetun. Select `PORT_SOURCE=gluetun`, enter a reachable `GLUETUN_ADDR` and any credentials, configure the downstream integrations, then restart qbop. Use [Gluetun settings](#gluetun-settings) for the same configuration in Compose.

Allow `GET /v1/portforward` in Gluetun's [control server authentication](https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/control-server.md#authentication). An API key takes precedence. Basic auth requires both username and password. With neither configured, Gluetun must explicitly allow unauthenticated access. Invalid URLs or credentials prevent the synchronization job from starting.

Gluetun manages the VPN and lease. qbop needs network access to its control API and the enabled downstream integrations. Configure qBittorrent's VPN routing separately.

The API must return an integer `port` from 1 to 65535, such as `{"port":51820}`. If it includes a `ports` array, that array must contain just the same port. On a failed check, qbop retains the last valid state and retries on the next loop.

### qBittorrent

Save the [qBittorrent connection and authentication settings](#qbittorrent-settings) and restart qbop. qbop updates its listening port to match the selected source.

## Authentication

Browser sign-in and API keys are configured separately. Local login is enabled by default, with optional OIDC.

<a id="browser-authentication"></a>

### Local authentication

An instance without an administrator redirects browser requests to `/setup`. Create the single administrator there, then use `/login` to sign in and `/account` to manage email and password.

Set `WEB_AUTH_ENABLED=false` only when another trusted access layer protects the UI. This disables `/setup` and `/account`. [API keys](#api-keys) are still required.

qbop generates the browser session secret in the persistent data volume.

### OpenID Connect

Create the local administrator at `/setup` before signing in with OIDC.

#### Provider setup

qbop uses standard discovery and Authorization Code flow with PKCE S256, state, nonce, and the `openid email` scopes. Create a confidential provider client and register these exact URLs, using `OIDC_PUBLIC_URL` as the origin:

```text
Callback URL:        https://qbop.example.com/auth/openid_connect/callback
Logout callback URL: https://qbop.example.com/logged-out
```

Generic configuration example:

```yaml
environment:
  OIDC_ENABLED: "true"
  OIDC_ISSUER: "https://id.example.com"
  OIDC_CLIENT_ID: "qbop-client"
  OIDC_CLIENT_SECRET: "replace-with-provider-generated-secret"
  OIDC_PUBLIC_URL: "https://qbop.example.com"
  OIDC_AUTO_REDIRECT: "false"
  LOCAL_LOGIN_ENABLED: "true"
```

Set `OIDC_PUBLIC_URL` to qbop's external origin; qbop does not infer it from proxy headers. Only loopback development origins may use HTTP. The issuer must use HTTPS and serve its discovery document without redirects.

Discovered authorization, token, userinfo, JWKS, and logout endpoints must use HTTPS; qbop rejects URLs with credentials or fragments. These endpoints may use different HTTPS hosts.

#### Identity linking

The first successful sign-in requires the administrator's email, explicitly marked as verified by the provider. qbop stores only the provider issuer, immutable `sub` subject, and local account ID.

Later sign-ins use the issuer-and-subject link, so email changes at qbop or the provider do not replace the linked identity. A different subject for an already-linked issuer is denied even if its email matches.

#### Local login and automatic redirect

`OIDC_AUTO_REDIRECT=true` starts CSRF-protected OIDC sign-in automatically when local login is disabled. `LOCAL_LOGIN_ENABLED=true` takes precedence to preserve break-glass access. Error and logged-out pages require deliberate user action.

Set `LOCAL_LOGIN_ENABLED=false` to hide the local password form and reject password-login POSTs. With browser authentication enabled, this requires `OIDC_ENABLED=true`. `/setup`, `/account`, the local password hash, and `bundle exec rake user:reset-password` remain intact.

For break-glass access, set `LOCAL_LOGIN_ENABLED=true`, restart or redeploy qbop, and sign in locally. If invalid OIDC settings prevent startup, fix them or temporarily set `OIDC_ENABLED=false`.

#### Sign-out

OIDC sign-out clears qbop's session and uses the provider's discovered logout endpoint with an `id_token_hint` and the fixed `/logged-out` callback. Without that endpoint, qbop signs out locally but leaves the provider session active.

#### Pocket ID example

In Pocket ID, create a confidential client with Authorization Code flow, PKCE, and the `openid email` scopes. Register the [callback URLs above](#provider-setup), use Pocket ID's discovery issuer as `OIDC_ISSUER`, and enter the client ID and secret in qbop. Keep local login enabled until you've tested identity linking and provider logout.

### Account recovery

If the administrator password is lost, reset it from the host with the running container:

```bash
docker exec -it qbop bundle exec rake user:reset-password
```

From a shell already inside the container, run:

```bash
bundle exec rake user:reset-password
```

The command resets the existing administrator password. Replace `qbop` in the host command if your container has a different name.

<a id="api-authentication"></a>

### API keys

Every API endpoint, including `/api/health`, requires a Bearer API key even with `WEB_AUTH_ENABLED=false`.

To configure an API client:

1. Open `/api-keys` from the web UI.
2. Create a named key and copy the complete `qbop_...` value. qbop shows it once.
3. Send it in the `Authorization` header.

   ```http
   Authorization: Bearer qbop_xxxxxxxxx
   ```

4. When rotating a key, verify the replacement before revoking the old one.

If you disable browser authentication, protect `/api-keys` and the rest of the UI with your external access layer.

## ProtonVPN WireGuard importer

Use `/tools` to import a ProtonVPN `.conf` file when rotating an existing OPNsense WireGuard instance and peer.

### Before importing

- Generate the ProtonVPN configuration as described in [Integration setup](#protonvpn-and-opnsense).
- Both the selected instance and peer must be enabled and dedicated to each other, with no other peer or instance associations.
- The configured OPNsense API key needs the **VPN: WireGuard: Configuration** privilege in addition to the permissions used by the firewall-alias integration.

Select the associated instance and peer, then upload or paste the configuration. qbop does not log, persist, or return uploaded and pasted configurations.

### What changes and what is preserved

qbop updates Proton WireGuard credentials, tunnel addresses within the adopted tunnel's existing address-family policy, and the peer endpoint/AllowedIPs. OPNsense-local DNS, gateway, routing behavior, firewall rules, NAT, and interface assignments are preserved, as is the peer's existing instance association.

You can optionally rename the peer using a validated name derived from Proton's server identifier comment: for example, `# US-IL#661` becomes `Proton_US-IL661`. Without that option, the existing peer name is preserved exactly.

### Import sequence and rollback

The import waits for each OPNsense apply and reports the result. A lock in the data volume prevents overlapping imports. Competing requests receive a conflict response.

During an import, qbop:

1. Disables the instance and applies that state.
2. Verifies that its interface is absent from OPNsense's WireGuard runtime state.
3. Updates the peer first and the instance second.
4. Applies the new configuration while the instance remains disabled.
5. Re-enables the instance and applies again.
6. Verifies that the runtime instance and peer use the imported public keys, without requiring a fresh handshake.

If an import fails after changes begin, qbop tries to restore the peer and instance configuration while the instance is disabled. It reapplies the original enabled state, verifies the previous runtime keys, and reports any incomplete rollback.

## API

Open `/api-docs` for endpoint descriptions, examples, and status codes. Create an [API key](#api-keys) before sending requests. Logs and history accept the web UI's [query parameters](#query-parameters).

`/api/stats` and `/api/health` return the running `port_source`. If the configured source or integration skip flags differ, they also return `configured_port_source` and `restart_required: true`. Other pending settings, such as `LOOP_FREQ` or credentials, are outside that check. The legacy `protonvpn` and `records.longest_time_on_same_port.proton` fields represent the running source. History entries identify their own source.

`/api/health` returns `503` if an enabled service lacks a successful check within the last three loop intervals. Skipped integrations are excluded. Recent checks can still count as healthy briefly after job initialization fails.

`/api/about` retains legacy ENV-derived fields and masks credentials. The browser About page shows configured values.

## Upgrading to v3.6.0

v3.6.0 adds database-backed Settings through migration 010, which qbop applies at startup. Keep your existing Compose configuration and [update qbop](#updating-qbop). You can [move settings into the UI](#moving-from-env-to-settings) when you want to manage them there.

Rolling back migration 010 drops saved settings. An image with migrations up to 009 rejects a database already at 010. For a downgrade, use the older image with a compatible pre-upgrade data backup and Compose configuration.

## Upgrading from qbop 2.x to 3.0

qbop 3.0 enables browser login by default and replaces inbound API Basic Auth with Bearer keys.

1. Back up the data volume and Compose configuration and remove obsolete `BASIC_AUTH_*` variables. If another trusted access layer protects the UI, you can set `WEB_AUTH_ENABLED=false` before starting qbop.
2. [Update qbop](#updating-qbop). Startup applies the migrations. With browser authentication enabled, create the administrator at `/setup`.
3. Create an [API key](#api-keys) and update every client and health check to send `Authorization: Bearer qbop_...`, even when browser authentication is disabled.
4. Verify the web UI, history, integrations, and authenticated API.

<a id="usage"></a>

## Operational details and troubleshooting

Downgrading across migrations 008 or 009 removes port-source history metadata or saved OPNsense pending-apply state. Restore a pre-upgrade backup when downgrading.

### History and synchronization status

History keeps the last 500 forwarded-port transitions across sources. Migration labels existing history `proton`, and Gluetun uses a separate source record. New installations record the initial assignment. Upgraded installations add entries from the next change.

Stats and history show downstream synchronization status for OPNsense and qBittorrent:

| Status | Meaning |
| :--- | :--- |
| `pending` | Synchronization has not completed. |
| `synced` | The integration is synchronized with the forwarded port. |
| `error` | The most recent synchronization write failed; check the logs for the detailed reason. |
| `skipped` | The integration was skipped. |

The status panel shows OPNsense as `pending` whenever persisted apply work remains, including during port-source outages. History continues to show each transition's recorded result.

### Live web updates

Stats, history, and logs update automatically and keep your pagination and log display choices. Reconnecting fetches the latest state. An expired browser session redirects to login on the next update. Forms and direct page loads also work without JavaScript.

Reload About for current uptime.

### Query Parameters

Query parameters are per-request overrides and do not change saved settings or environment variables.

Examples:

- `/logs?lines=500&direction=desc`
- `/history?page=2&per_page=50`

#### Log parameters

Applies to `/logs` and `/api/logs`.

| Parameter | Default | Description |
| :--- | :--- | :--- |
| `lines` | Resolved `LOG_LINES` (built-in `50`) | Number of log lines to show, from 1 to 5000. |
| `direction` | `desc` if resolved `LOG_REVERSE` is true, otherwise `asc` | `asc` shows oldest first, `desc` shows newest first. |

Invalid values use the defaults above. Log counts are capped at 5000.

#### History parameters

Applies to `/history` and `/api/history`.

| Parameter | Default | Description |
| :--- | :--- | :--- |
| `page` | `1` | Page of port transitions to return. Pages beyond the available history use the final page. |
| `per_page` | `25` | Number of transitions per page. Supported values are `25`, `50`, and `100`. |

Invalid pagination values use the defaults above.

### Logging

With `LOG_TO_STDOUT=true`, new entries go to container stdout, so `/logs` continues to show only the existing `log/qbop.log` contents. File changes made outside qbop do not publish notifications.

### Reverse proxies and live connections

Reverse proxies should allow streaming `/events`, disable response buffering/caching there, and use a read timeout longer than the 15-second heartbeat interval. qbop sends `X-Accel-Buffering: no` and `Cache-Control: no-cache`; HTML partials use `no-store`.

The default server allows eight live browser connections. Additional connections retry automatically. See [Server process and event limits](#server-process-and-event-limits) for custom Puma configurations.

## Architecture and implementation

### Server-rendered live updates

The UI uses locally served HTMX 2 and its SSE extension. Each live page opens one `/events` connection using the same browser authentication as normal navigation. Events contain only notification names; authenticated HTML partials read the current database or log file:

```text
job -> committed model change / log write -> publish event -> SSE -> HTMX GET -> server-rendered partial
```

Live logs use the centralized file logger. During bursts, the browser debounces log refreshes until 500ms after the last event; reconnect refreshes remain immediate.

### Server process and event limits

Run one Puma process with SuckerPunch because live events and synchronization state are process-local. The included `config/puma.rb` allows 16 request threads and eight live browser connections. Keep more request threads than the subscriber limit when customizing Puma.

Duplicate pending events coalesce, and publishers never write to browser sockets. Healthy SSE connections stay open, with a heartbeat every 15 seconds. Disconnects release subscriptions.

Puma shutdown waits at most five seconds for requests before terminating them.

## License

qbop is available under the [MIT License](LICENSE).
