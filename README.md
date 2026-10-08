![qbop logo](https://github.com/clajiness/qbop/blob/main/public/images/light/apple-touch-icon-light.png)

# qbop

A tool for synchronizing a forwarded port from ProtonVPN/NAT-PMP or Gluetun, with optional integration for OPNsense and qBittorrent. qbop provides a web UI and API at `http://<host_ip>:4567/`.

qbop is built with Ruby and available as a Docker image. **Proton mode remains the default and requires the container to be routed through ProtonVPN** (via a VPN container or network namespace). In Gluetun mode, qbop observes the control API; Gluetun owns the VPN connection and forwarded-port lease.

Upgrading an existing installation? See [Upgrading to v3.6.0](#upgrading-to-v360). If you are coming from 2.x, also read [Upgrading from qbop 2.x to 3.0](#upgrading-from-qbop-2x-to-30) for the browser and API authentication changes.

## What qbop does

- Maintains an active ProtonVPN forwarded port or observes Gluetun's current assignment
- Automatically updates OPNsense firewall aliases
- Keeps qBittorrent in sync with the active port
- Imports new ProtonVPN WireGuard configuration values into an existing OPNsense instance and peer
- Retains the 500 most recent port transitions and downstream synchronization status
- Provides a simple web UI and API

## Contents

- [Requirements and integrations](#requirements-and-integrations)
- [Quick Start](#quick-start)
- [Installation](#installation)
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

* AMD64 or ARM64/v8 architecture - If you need support for a different architecture, file an issue.
* [Docker Engine](https://docs.docker.com/engine/install/)
* [ProtonVPN](https://protonvpn.com/support/port-forwarding) for the default NAT-PMP source, or an existing [Gluetun](https://github.com/qdm12/gluetun) deployment with port forwarding enabled
* Optional: [OPNsense](https://docs.opnsense.org/). Set `OPN_SKIP` to `true` in Settings to run without this integration.
    * [Selective routing](https://docs.opnsense.org/manual/how-tos/wireguard-selective-routing.html)
    * [API](https://docs.opnsense.org/development/how-tos/api.html)
* Optional: [qBittorrent](https://www.qbittorrent.org/). Set `QBIT_SKIP` to `true` in Settings to run without this integration.

## Quick Start

1. Clone the repository and open the Compose directory:

   ```bash
   git clone https://github.com/clajiness/qbop
   cd qbop/docker-compose
   ```

2. Review `docker-compose.yml` and your networking. The sample does not set up VPN routing: the default Proton source requires routing through ProtonVPN, while Gluetun mode requires access to its control API. See [Integration setup](#integration-setup). Leave integration settings out of Compose to manage them through the UI.
3. Start qbop:

   ```bash
   docker compose up -d
   ```

4. Open `http://<host_ip>:4567/`. With the default browser authentication, the first request redirects to `/setup`, where you create the qbop administrator account.
5. Open **settings** at `/settings`. Use the default Proton source and configure its gateway if needed, or select `PORT_SOURCE=gluetun` and enter the control API address and credentials. Configure OPNsense and qBittorrent, or save `OPN_SKIP=true` and/or `QBIT_SKIP=true` for integrations you do not use.
6. Apply synchronization settings:

   ```bash
   docker compose restart qbop
   ```

Before configuration and VPN/control-API access are ready, the status indicators may be unhealthy and synchronization logs may report unavailable gateways or integrations. The web UI remains available for setup; authenticated `/api/health` requests return `503` until enabled services have recent successful checks.

## Installation

Use the provided [Docker Compose example](docker-compose/docker-compose.yml) to set up qbop. The [container image](https://github.com/clajiness/qbop/pkgs/container/qbop) is published on GitHub Container Registry.

The sample keeps browser authentication enabled; local login is enabled and OIDC is disabled by default. Optional OIDC settings remain in the [authentication reference](#authentication-and-oidc-settings).

The sample mounts persistent `data` and `log` volumes at `/opt/qbop/data/` and `/opt/qbop/log/`. Keep the `data` volume across container replacements: it contains the database, browser session secret, and settings encryption key when generated. See [Encrypted credentials and backups](#encrypted-credentials-and-backups).

### Image tags

Available tags:

- `latest` → most recent release
- `main` → most recent build from the main branch
- `<branch>` → latest branch build; `/` and other invalid tag characters become `-`
- `sha-<12-character commit SHA>` → build for that commit
- `v<major>` → latest release for that major version, e.g. `v3`
- `v<major>.<minor>` → latest patch release for that minor version, e.g. `v3.0`
- `v<major>.<minor>.<patch>` → exact release, e.g. `v3.0.0`

The legacy `v2` tag remains available for installations that have not yet upgraded.

The app displays `main` for main-branch images and the exact version for release images.

## Configuration

New installations can configure the 25 application, integration, and logging settings through **settings** at `/settings`; values are saved in qbop's SQLite database. Environment variables remain fully supported for users who prefer Compose-managed configuration. Authentication and OIDC settings remain environment-only.

qbop uses an authoritative environment variable first, then a saved qbop setting, then the built-in default. Environment-managed controls are read-only in Settings. Removing the ENV assignment and recreating the container allows the saved value or default to take effect.

**Save** writes a database override. Saving the displayed default also creates an explicit override, pinning that value until cleared. **Clear qbop override** removes only the saved value; it never edits Compose or the process environment. An inactive override can also be cleared while ENV manages the setting. Existing ENV values are not automatically imported into SQLite.

Ordinary empty or whitespace-only ENV placeholders allow saved settings to take precedence; some retain their legacy blank behavior when no saved value exists. A present blank `PORT_SOURCE` is authoritative and invalid. Explicit `false` boolean ENV values are authoritative. For the firewall alias, populated `OPN_ALIAS_NAME` takes precedence over legacy `OPN_PROTON_ALIAS_NAME`, which takes precedence over the saved alias.

### Restart behavior

Settings labeled **Restart required** take effect in the synchronization job and its integration clients after qbop restarts. Saving a changed value does not update the running job or its clients. With the sample deployment, use `docker compose restart qbop` after saving these settings. `UI_MODE`, `LOG_LINES`, and `LOG_REVERSE` apply on the next request without a job restart.

Status and health use the running source, skip flags, and loop frequency rather than pending values. The About page shows effective configured values, which may still be awaiting a restart. See [API](#api) for the limited scope of its pending-restart metadata.

### Moving from ENV to Settings

Working ENV-based installations need no migration. To manage a setting through the UI instead:

1. Identify the ENV variable shown as managing the setting; for aliases, check both `OPN_ALIAS_NAME` and `OPN_PROTON_ALIAS_NAME`.
2. Remove that assignment from Compose or the environment source supplying it.
3. Recreate qbop with the updated environment, preserving its volumes:

   ```bash
   docker compose up -d --force-recreate qbop
   ```

4. Sign in and save the desired value in Settings. For credentials, enter the original credential in its password field; saved credentials are not displayed for copying.
5. Restart qbop if the setting is marked **Restart required**.

Removing the assignment may temporarily expose a default or missing configuration before you save the desired value. A plain Compose restart does not apply changes to the container environment; [recreate it](https://docs.docker.com/reference/cli/docker/compose/up/) after editing Compose. The UI field remains locked while an authoritative ENV assignment is present.

### Encrypted credentials and backups

Integration API keys, usernames, and passwords saved in Settings are encrypted in SQLite using AES-256-GCM. Their application-managed key is stored separately in `data/settings_encryption_key.txt` (`/opt/qbop/data/settings_encryption_key.txt` in the container). It is distinct from `data/session_secret.txt`, which protects browser sessions. The settings key is generated on the first saved credential; ordinary settings and ENV-only credentials do not generate it. Clearing credentials does not delete the key.

**Back up and restore `data/qbop.sqlite3` and its associated `data/settings_encryption_key.txt` together.** Stop qbop before copying the persistent `data` volume, keep the whole volume in the backup, then start it again. For restore, stop qbop and restore that volume from the same backup. Preserve writable ownership for the container's qbop user (UID/GID `1234`) and mode `0600` for the key and its `.lock` file. The database alone cannot recover encrypted credentials without the original key. Keep backups private.

If the key is missing, corrupt, or does not match the encrypted rows, restore the original key from backup. qbop will not silently regenerate a missing key while saved credentials depend on it, or overwrite a corrupt key. Login and Settings remain available for recovery, but the synchronization job can fail initialization and credential replacement can fail until the key issue is resolved.

If the original key cannot be restored, clear **every saved integration credential, including usernames**, through Settings. If a corrupt key file remains, stop qbop and remove that unusable `settings_encryption_key.txt` from the data volume after clearing the credentials. Restart qbop and re-enter the credentials. With no key file and no dependent encrypted rows, the first credential save generates a new key; a valid existing key is reused. Restart again to apply the new credentials. Do not delete a valid key or substitute the browser session secret. ENV-managed credentials are unaffected.

### ENV Variables

A blank default means no default value is provided; defaults apply when neither an authoritative ENV value nor a saved setting supplies the value. All variables below remain supported. OPNsense and qBittorrent credentials are required unless those integrations are skipped. Gluetun authentication depends on the control-server role; API key, HTTP Basic, and explicitly permitted unauthenticated access are supported. OIDC requirements apply only when OIDC and browser authentication are enabled.

The UI validates saved values: booleans must be `true` or `false`, integers must be complete numbers in the listed range, and credentials must be nonblank without control characters. Saved HTTP(S) URLs require a host and a valid port, with no userinfo, query, or fragment. Only `GLUETUN_ADDR` supports a path prefix; OPNsense and qBittorrent saved URLs must be origins/root URLs, optionally ending in `/`. Legacy ENV parsing remains unchanged.

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
| `GLUETUN_ADDR` | `http://gluetun:8000` | Gluetun control server base URL, including `http(s)://`. An optional reverse proxy path prefix is preserved. Query strings and fragments are rejected. Must be reachable from qbop. Use the dedicated authentication variables; legacy ENV URL userinfo is ignored and masked in configuration displays, while saved URLs reject it. |
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

For OPNsense, follow its [WireGuard selective-routing guide](https://docs.opnsense.org/manual/how-tos/wireguard-selective-routing.html) and [API setup guide](https://docs.opnsense.org/development/how-tos/api.html). In Settings, save the OPNsense address and API credentials, and set `OPN_ALIAS_NAME` to the firewall alias used for the forwarded port. Existing `OPN_PROTON_ALIAS_NAME` ENV configurations remain supported as a fallback. Restart qbop to apply synchronization settings; it updates that alias as the forwarded port changes.

To rotate an existing tunnel using a new ProtonVPN configuration, see the [WireGuard importer](#protonvpn-wireguard-importer).

### Gluetun

With qBittorrent enabled, qbop reads Gluetun's current forwarded port and keeps qBittorrent's listening port synchronized with it.

Use an existing Gluetun deployment with VPN port forwarding enabled and exactly one forwarded port. In Settings, select `PORT_SOURCE=gluetun`, save the reachable `GLUETUN_ADDR` (for example, `http://gluetun:8000`), and enter the control API credentials if required. Configure the enabled downstream integrations and restart qbop. Users who prefer ENV management can supply the same setting names in Compose; see the [Gluetun settings reference](#gluetun-settings).

Configure Gluetun's authentication role to allow `GET /v1/portforward`, following its [control server documentation](https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/control-server.md#authentication). A populated `GLUETUN_API_KEY` takes precedence and is sent as `X-API-Key`, regardless of Basic settings. Without an API key, HTTP Basic requires both `GLUETUN_USER` and `GLUETUN_PASS`; supplying only one prevents synchronization job initialization. For ENV credentials, unset, empty, and whitespace-only values count as absent; the UI rejects blank saves, so use Clear to remove a saved credential. If neither authentication method is configured, requests are unauthenticated; Gluetun must explicitly permit unauthenticated access for that to work.

`GLUETUN_ADDR` accepts a path prefix such as `https://vpn.example/control/`, but no query string or fragment; query-based authentication is unsupported. Explicit endpoint ports must be within `1..65535`; omitted ports use the HTTP/HTTPS defaults. Active API-key or Basic credentials must be valid strings without control characters, including newlines. Invalid configuration fails initialization with a secret-free error. Configuration displays show `[invalid URL]` for malformed URLs, invalid endpoint ports, or URLs containing a query string or fragment.

qbop does not perform NAT-PMP in this mode and does not manage Gluetun's VPN. It only needs network access to the control API and enabled qBittorrent/OPNsense integrations. No Gluetun volume mounts, Docker socket, or shell hooks are required. The torrent client's VPN routing remains your deployment's responsibility.

The supported response is a JSON object containing an integer `port` in `1..65535`, for example `{"port":51820}`. A supplementary `ports` array must contain exactly that one integer. Multiple ports, missing values, strings, `0`, and malformed responses are rejected. API or transport failures leave the last valid source and downstream state intact, skip downstream checks for that loop, and retry on the next scheduled loop. The same configured confirmation attempts apply to both sources; Gluetun continues owning negotiation and lease maintenance.

To synchronize OPNsense in this mode, set `OPN_ALIAS_NAME` for the target firewall alias. `OPN_PROTON_ALIAS_NAME` remains supported when the preferred variable is unset or blank.

### qBittorrent

Save the connection and authentication settings listed under [qBittorrent settings](#qbittorrent-settings), then restart qbop. ENV configuration remains supported. qbop updates qBittorrent's listening port to match the selected source's forwarded port.

## Authentication

Browser sign-in and API keys are configured separately. Local browser login is enabled by default; OIDC is optional.

<a id="browser-authentication"></a>

### Local authentication

`WEB_AUTH_ENABLED=true` is the default. A fresh or upgraded instance with no account redirects normal browser traffic to `/setup`, which creates and signs in the single qbop administrator. qbop supports one administrator account; after it exists, `/setup` is unavailable. Use `/login` to sign in, `/account` to manage email and password, and the UI to sign out.

Set `WEB_AUTH_ENABLED=false` to bypass browser authentication when another trusted access layer protects the UI. In this mode `/setup` and `/account` are unavailable. API authentication remains mandatory; see [API keys](#api-keys).

Browser sessions use a secret generated automatically in the persistent `data/session_secret.txt` file, so no additional session configuration is required.

### OpenID Connect

OIDC is optional and disabled by default; local email/password login remains enabled by default. OIDC does not provision users. Create the single local administrator at `/setup` before signing in through OIDC.

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

qbop is provider-neutral; Pocket ID is optional. In Pocket ID, create a confidential client, generate a secret, enable Authorization Code flow with PKCE, and register:

```text
Callback URL:        https://qbop.example.com/auth/openid_connect/callback
Logout callback URL: https://qbop.example.com/logged-out
Scopes:              openid email
```

Set `OIDC_ISSUER` to Pocket ID's discovered issuer (for example, `https://id.example.com`). Configure the generated client ID and secret, and set `OIDC_PUBLIC_URL=https://qbop.example.com`. Keep local login enabled until the first verified-email link and provider logout have both been tested.

### Account recovery

If the administrator password is lost, reset it from the host with the running container:

```bash
docker exec -it qbop bundle exec rake user:reset-password
```

From a shell already inside the container, run:

```bash
bundle exec rake user:reset-password
```

The command resets the existing administrator password; it does not create another user. SMTP or email recovery is not required. If the container has a different name, replace `qbop` in the host command.

<a id="api-authentication"></a>

### API keys

Every API endpoint requires a valid qbop API key, including `/api/health`. Inbound HTTP Basic Auth is not supported, and browser sessions or cookies are not accepted by API routes. This requirement applies even with `WEB_AUTH_ENABLED=false`.

To configure an API client:

1. Sign in to qbop and open `/api-keys`, directly or through the **API Keys** link on `/api-docs` (**api docs** in the navigation).
2. Create a named key and copy the complete `qbop_...` value immediately.
3. Send it in the `Authorization` header:

   ```http
   Authorization: Bearer qbop_xxxxxxxxx
   ```

4. Revoke the old key from `/api-keys` when it is no longer needed.

API-key secrets are shown only once and cannot be recovered. When rotating credentials, create a replacement before revoking the old key.

When browser authentication is disabled, `/api-keys` is accessible with the rest of the web UI, so protect that UI with a trusted external access layer.

## ProtonVPN WireGuard importer

Use the first tool on `/tools` to import a ProtonVPN `.conf` file into an existing OPNsense WireGuard instance and peer. qbop preserves OPNsense-local network settings and attempts to roll back failed imports. You only need this tool when replacing an existing tunnel's ProtonVPN configuration.

### Before importing

- Generate the ProtonVPN configuration as described in [Integration setup](#protonvpn-and-opnsense).
- Both the selected instance and peer must be enabled and dedicated to each other, with no other peer or instance associations.
- The configured OPNsense API key needs the **VPN: WireGuard: Configuration** privilege in addition to the permissions used by the firewall-alias integration.

Select the associated instance and peer, then upload or paste the configuration. qbop does not log, persist, or return uploaded and pasted configurations.

### What changes and what is preserved

qbop updates Proton WireGuard credentials, tunnel addresses within the adopted tunnel's existing address-family policy, and the peer endpoint/AllowedIPs. OPNsense-local DNS, gateway, routing behavior, firewall rules, NAT, and interface assignments are preserved, as is the peer's existing instance association.

You can optionally rename the peer using a validated name derived from Proton's server identifier comment: for example, `# US-IL#661` becomes `Proton_US-IL661`. Without that option, the existing peer name is preserved exactly.

### Import sequence and rollback

Imports run synchronously and exclusively. The request waits for each OPNsense apply and reports the completed result or any rollback failure. A lock file in the persistent `data` volume prevents overlapping rotations; a competing request receives a conflict response.

During an import, qbop:

1. Disables the instance and applies that state.
2. Verifies that its interface is absent from OPNsense's WireGuard runtime state.
3. Updates the peer first and the instance second.
4. Applies the new configuration while the instance remains disabled.
5. Re-enables the instance and applies again.
6. Verifies that the runtime instance and peer use the imported public keys, without requiring a fresh handshake.

If a step fails after changes begin, qbop attempts to restore the changed peer and instance fields, in that order, while the instance is disabled. It applies the restored configuration, restores and applies the original enabled state, and verifies that the previous instance and peer keys are active. Any incomplete rollback is reported in the result.

## API

qbop exposes a JSON API for status, history, logs, and tools. Open `/api-docs` through **api docs** in the navigation for endpoint descriptions, request/response examples, and status codes. Configure [API keys](#api-keys) before sending requests.

The log and history endpoints share the web UI's [query parameters](#query-parameters). Monitoring checks of `/api/health` also require Bearer authentication; skipped integrations are excluded from health failures.

`/api/stats` and `/api/health` include a `port_source` field identifying the startup statistics source, `proton` or `gluetun`. If the configured source or skip flags differ, they add `configured_port_source` and `restart_required: true`; those fields disappear when the source/skip values match again or after restart. This metadata does not track every unapplied setting, such as `LOOP_FREQ` or credentials. For compatibility, the existing `protonvpn` status key and `records.longest_time_on_same_port.proton` key continue representing the startup port source. History entries include a `source` identity. Proton-specific WireGuard tools retain their existing names and behavior.

Health freshness uses the running loop frequency and the last successful check within three loop intervals. It is not a job-liveness check: recent persisted statistics can briefly remain healthy after initialization fails. Before statistics exist, enabled services are unhealthy.

The browser About page shows effective configured values. `/api/about` preserves its historical response representation, including legacy raw ENV-derived fields and credential masking; it does not return decrypted database credentials.

## Upgrading to v3.6.0

v3.6.0 adds migration 010 and the optional database-backed Settings interface. Startup applies migrations automatically. Existing supported ENV configuration continues working unchanged, with no automatic copying of ENV values into SQLite. Keep a working Compose configuration; replacing it with the minimal sample would remove its overrides. Moving settings into the UI is [optional](#moving-from-env-to-settings).

Before upgrading, back up the persistent data volume and your Compose configuration. Pull your selected image and recreate qbop while retaining the existing volumes. If encrypted credentials have been saved, include the original settings encryption key in every [backup and restore](#encrypted-credentials-and-backups).

Rolling back migration 010 drops the settings table and removes saved settings. Simply changing an image tag does not guarantee a migration rollback: an image with migration files only through 009 rejects a database already at 010. Back up data before downgrading, and use a compatible pre-upgrade backup and configuration for the older version. Saved settings are not converted back into ENV assignments automatically.

## Upgrading from qbop 2.x to 3.0

qbop 3.0 changes both browser and API authentication. Review these breaking changes before upgrading:

- Browser authentication is new and enabled by default. When 3.0 starts with an existing 2.x database, the first normal browser request redirects to `/setup` because the database has no administrator account. Create the single qbop administrator there. To keep browser authentication behind an existing trusted access layer instead, set `WEB_AUTH_ENABLED=false` before starting 3.0.
- Inbound API HTTP Basic Auth has been removed. Every API endpoint now requires a qbop API key sent with Bearer authentication, including `/api/health`. Browser sessions are not accepted by the API, and API authentication remains mandatory when `WEB_AUTH_ENABLED=false`.

Recommended upgrade sequence:

1. Back up the qbop database, persistent configuration, and Compose configuration.
2. Update the image and configuration for 3.0.
3. Remove obsolete `BASIC_AUTH_*` environment variables.
4. Start the 3.0 image normally. qbop runs its database migrations automatically during startup; no manual database editing is required.
5. Create the administrator at `/setup`, unless browser authentication is disabled.
6. Open `/api-keys` and create an API key.
7. Update every API client and monitoring check to send `Authorization: Bearer qbop_...`, including checks of `/api/health`.
8. Restart qbop and verify the web UI, history, integrations, and authenticated API requests.

<a id="usage"></a>

## Operational details and troubleshooting

Migration 008 adds port-source attribution to transition history; migration 009 adds persisted OPNsense pending-apply metadata. Downgrading across these migrations removes that metadata, and re-upgrading cannot reconstruct all of it accurately. If a downgrade is required, restore a pre-upgrade database backup as the safe rollback path.

### History and synchronization status

History records forwarded-port assignments with their source identity and retains the 500 most recent transitions across sources. Existing history is labeled `proton` during migration; existing Proton source records and state are preserved. Gluetun uses a separate `gluetun` source record. Fresh installations include the initial assignment; upgraded installations begin with the next port change. Existing logs are not backfilled, and the oldest record is removed when a 501st transition is added.

Stats and history show downstream synchronization status for OPNsense and qBittorrent:

| Status | Meaning |
| :--- | :--- |
| `pending` | Synchronization has not completed. |
| `synced` | The integration is synchronized with the forwarded port. |
| `error` | The most recent synchronization write failed; check the logs for the detailed reason. |
| `skipped` | The integration was skipped. |

The status panel shows OPNsense as `pending` whenever persisted apply work remains, including during port-source outages. History continues to show each transition's recorded result.

### Live web updates

Stats, history, and logs update automatically. No manual refresh configuration is needed.

History page/page-size choices and log line-count/direction choices survive live updates. Forms and direct page loads work without JavaScript. If a connection drops, the page remains usable; reconnecting sends a `refresh` notification to fetch current state, including changes missed offline. If your browser session expires, the next live update takes you to the login page. Old `refresh` query parameters are ignored.

The About page shows server-rendered uptime and other information as of page load. Reload the page in your browser to get current values.

### Query Parameters

Query parameters are per-request overrides and do not change saved settings or environment variables.

Examples:

- `/logs?lines=500&direction=desc`
- `/logs?lines=500&direction=asc`
- `/api/logs?lines=500&direction=desc`
- `/history?page=2&per_page=50`
- `/api/history?page=2&per_page=50`

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

The default server allows eight live browser connections; additional connections retry automatically. Custom Puma launch configurations must retain a single process and more request threads than the eight-subscriber cap. See [Server process and event limits](#server-process-and-event-limits) for the implementation details.

## Architecture and implementation

These details matter when changing the server launch configuration or investigating live updates. Normal Docker deployments use the included configuration.

### Server-rendered live updates

The UI uses locally served HTMX 2 and its SSE extension. Each live page opens one `/events` connection using the same browser authentication as normal navigation. Events contain only notification names; authenticated HTML partials read the current database or log file:

```text
job -> committed model change / log write -> publish event -> SSE -> HTMX GET -> server-rendered partial
```

Live logs use the centralized file logger. During bursts, the browser debounces log refreshes until 500ms after the last event; reconnect refreshes remain immediate.

### Server process and event limits

The broadcaster is bounded and process-local; synchronization status configuration is also process-local. Run one Puma process with SuckerPunch. The included `config/puma.rb` allows up to 16 request threads and permits up to eight live browser connections, leaving capacity for ordinary requests.

Duplicate pending events coalesce, and publishers never write to browser sockets. Healthy SSE connections stay open, with a heartbeat every 15 seconds. Disconnects release subscriptions.

Puma shutdown waits at most five seconds for requests before terminating them.

## License

qbop is available under the [MIT License](LICENSE).
