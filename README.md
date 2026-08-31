![qbop logo](https://github.com/clajiness/qbop/blob/main/public/images/light/apple-touch-icon-light.png)

# qbop
A tool for maintaining a ProtonVPN forwarded port, with optional integration for OPNsense and qBittorrent. qbop provides a simple web UI and API at `http://<host_ip>:4567/`.

This container must be routed through ProtonVPN (via a VPN container or network namespace) for port forwarding to work.

qbop is built with Ruby and available as a Docker image.

## What qbop does
- Maintains an active ProtonVPN forwarded port
- Automatically updates OPNsense firewall aliases
- Keeps qBittorrent in sync with the active port
- Imports new ProtonVPN WireGuard configuration values into an existing OPNsense instance and peer
- Retains the 500 most recent port transitions and downstream synchronization status
- Provides a simple web UI and API

## Quick Start

```bash
git clone https://github.com/clajiness/qbop
cd qbop/docker-compose
docker compose up -d
```
Then open: `http://<host_ip>:4567/`

The first browser request redirects to `/setup`, where you create the qbop administrator account.

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
6. Open `/api-docs` and create an API key.
7. Update every API client and monitoring check to send `Authorization: Bearer qbop_...`, including checks of `/api/health`.
8. Restart qbop and verify the web UI, history, integrations, and authenticated API requests.

## Installation
I recommend using the provided sample Docker Compose files to simplify setting up qbop.

You can ignore OPNsense and/or qBittorrent by using the `OPN_SKIP` and/or `QBIT_SKIP` environment variables. This is handy if you're using a firewall and routing platform like a Unifi gateway or a different BitTorrent client.

The container image is available [here](https://github.com/clajiness/qbop/pkgs/container/qbop). The sample docker-compose.yml file is available [here](https://github.com/clajiness/qbop/blob/main/docker-compose/docker-compose.yml).

Image tags are published as follows:
- `latest` → most recent release
- `main` → most recent build from the main branch
- `<branch>` → most recent build from any pushed branch; invalid Docker tag characters such as `/` are replaced with `-`
- `sha-<12-character commit SHA>` → exact commit used for any published image build
- `v<major>` → latest release for that major version, e.g. `v3`
- `v<major>.<minor>` → latest patch release for that minor version, e.g. `v3.0`
- `v<major>.<minor>.<patch>` → exact release, e.g. `v3.0.0`

The legacy `v2` tag remains available for installations that have not yet upgraded.

Pull requests are built without publishing an image. Main-branch builds identify themselves as `main` in the app, while images built from stable Git tags display their exact release version.

### Requirements
* AMD64 or ARM64/v8 architecture - If you need support for a different architecture, file an issue.
* [Docker Engine](https://docs.docker.com/engine/install/)
* [OPNsense](https://docs.opnsense.org/)
    * [Selective routing](https://docs.opnsense.org/manual/how-tos/wireguard-selective-routing.html)
    * [API](https://docs.opnsense.org/development/how-tos/api.html)
* [qBittorrent](https://www.qbittorrent.org/)
* [ProtonVPN](https://protonvpn.com/support/port-forwarding)

### ENV Variables
| Variable | Default | Description |
| :--- | :--- | :--- |
| `UI_MODE` | `dark` | [`dark`/`light`] This value sets the UI mode of the web app. The default value is `dark`. |
| `LOOP_FREQ` | `45` | This value, in seconds, determines how often the job runs. It must be a positive integer. The default value is recommended by ProtonVPN. |
| `REQUIRED_ATTEMPTS` | `3` | The number of loops with a new forwarded port before updating OPNsense and qBittorrent. The min is 1, and max is 10. |
| `LOG_LINES` | `50` | The number of log lines displayed on the "logs" page |
| `LOG_REVERSE` | `false` | Reverse the display order of log lines, showing newest logs at the top when enabled. |
| `LOG_TO_STDOUT` | `false` | Log to STDOUT instead of the default log directory |
| `PROTON_GATEWAY` | `10.2.0.1` | ProtonVPN provided gateway IP address. Do not use `http(s)://` or a trailing slash. |
| `OPN_SKIP` | `false` | [`true`/`false`] Skip OPNsense. If `true`, subsequent OPNsense environment variables are not required. |
| `OPN_INTERFACE_ADDR` | | OPNsense Interface Address. Requires `http(s)://` and no trailing slash. |
| `OPN_API_KEY` | | OPNsense API Key |
| `OPN_API_SECRET` | | OPNsense API Secret |
| `OPN_PROTON_ALIAS_NAME` | | The firewall alias that you use for ProtonVPN's forwarded port. For example, `proton_vpn_forwarded_port`. |
| `OPN_SSL_VERIFY` | `false` | [`true`/`false`] Verify OPNsense TLS certificates. Defaults to `false` for self-signed/private deployments. |
| `QBIT_SKIP` | `false` | [`true`/`false`] Skip qBittorrent. If `true`, subsequent qBittorrent environment variables are not required. |
| `QBIT_ADDR` | | The IP address of your qBittorrent app. Requires `http(s)://` and no trailing slash. |
| `QBIT_API_KEY` | | qBittorrent API key. If set, this is used instead of `QBIT_USER` and `QBIT_PASS`. Requires qBittorrent 5.2.0 or newer. |
| `QBIT_USER` | | qBittorrent username. Used when `QBIT_API_KEY` is not set. |
| `QBIT_PASS` | | qBittorrent password. Used when `QBIT_API_KEY` is not set. |
| `QBIT_SSL_VERIFY` | `false` | [`true`/`false`] Verify qBittorrent TLS certificates. Defaults to `false` for self-signed/private deployments. |
| `WEB_AUTH_ENABLED` | `true` | Require browser authentication for the web UI. Disable only if the UI is protected by another trusted access layer. |
| `OIDC_ENABLED` | `false` | Enable optional OpenID Connect browser authentication. OIDC is not initialized when disabled. |
| `OIDC_ISSUER` | | HTTPS issuer URL used for standard OIDC discovery, such as `https://id.example.com`. Required when OIDC and browser authentication are enabled. HTTP issuers are rejected, including on loopback. |
| `OIDC_CLIENT_ID` | | Confidential OIDC client identifier. Required when OIDC and browser authentication are enabled. |
| `OIDC_CLIENT_SECRET` | | Confidential OIDC client secret. Required when OIDC and browser authentication are enabled. |
| `OIDC_PUBLIC_URL` | | Externally reachable qbop origin, such as `https://qbop.example.com`, without a path. Used for fixed callback URLs and required when OIDC and browser authentication are enabled. |
| `OIDC_AUTO_REDIRECT` | `false` | Automatically submit the CSRF-protected OIDC sign-in form when an unauthenticated browser reaches `/login`. |
| `LOCAL_LOGIN_ENABLED` | `true` | Offer and accept local password login. This does not remove the local account, setup, account management, or password recovery. |

## Authentication

### Browser authentication

`WEB_AUTH_ENABLED=true` is the default. A fresh or upgraded instance with no account redirects normal browser traffic to `/setup`, which creates and signs in the single qbop administrator. After that account exists, `/setup` is unavailable. Subsequent authentication uses `/login`; email and password management is available at `/account`; and sign-out is available from the normal UI. qbop intentionally supports one administrator account.

Set `WEB_AUTH_ENABLED=false` to bypass browser authentication when another trusted access layer protects the UI. In this mode `/setup` and `/account` are unavailable. Disabling browser authentication does not disable API authentication.

Browser sessions use a secret generated automatically in the persistent `data/session_secret.txt` file, so no additional session configuration is required.

### OpenID Connect

OIDC is an optional browser sign-in method and is disabled by default. Existing installations do not need to configure it, and local email/password login remains enabled by default. OIDC does not provision qbop users: create the single local administrator through `/setup` before attempting OIDC sign-in.

The first successful OIDC sign-in must provide the same email as the existing administrator and explicitly report that email as verified. qbop then stores only the provider issuer, immutable `sub` subject, and local account ID. Later sign-ins use that issuer-and-subject link, so a later email change at qbop or the provider does not silently replace the identity. A different subject for an already-linked issuer is denied even if its email matches.

qbop uses standard discovery, Authorization Code flow, PKCE S256, state, nonce, and the `openid email` scopes. Configure a confidential client at the provider with exactly these application URLs, replacing the example origin with `OIDC_PUBLIC_URL`:

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

Set `OIDC_PUBLIC_URL` to the external origin seen by users; qbop does not infer it from proxy headers. HTTP is accepted only for loopback development URLs. The issuer and discovered provider endpoints must use HTTPS, and the issuer must serve its discovery document without redirects.

qbop rejects discovery documents whose authorization, token, userinfo, JWKS, or logout endpoints contain credentials or fragments or would use plaintext HTTP. Those endpoints may use different HTTPS hosts when required by a standards-compliant provider.

`OIDC_AUTO_REDIRECT=true` automatically starts the CSRF-protected OIDC flow when local login is disabled. Error and logged-out pages require deliberate user action. Enabling `LOCAL_LOGIN_ENABLED` takes precedence so break-glass access remains usable.

Set `LOCAL_LOGIN_ENABLED=false` to remove the local password form and make server-side password-login POSTs unavailable. `/setup`, `/account`, the local password hash, and `bundle exec rake user:reset-password` remain intact. For break-glass access, set `LOCAL_LOGIN_ENABLED=true`, redeploy or restart qbop, and sign in locally. If the OIDC settings themselves are deliberately broken, also correct them or temporarily set `OIDC_ENABLED=false` so startup validation can succeed.

For OIDC-authenticated sessions, qbop clears its local session and uses the provider's discovered logout endpoint with an `id_token_hint` and the fixed `/logged-out` callback. If discovery provides no logout endpoint, qbop still signs out locally, but the provider session remains active.

#### Pocket ID example

Pocket ID is not required; qbop remains provider-neutral. In Pocket ID, create a confidential OIDC client, generate a client secret, enable Authorization Code flow with PKCE, and register:

```text
Callback URL:        https://qbop.example.com/auth/openid_connect/callback
Logout callback URL: https://qbop.example.com/logged-out
Scopes:              openid email
```

Then set `OIDC_ISSUER` to the issuer shown by Pocket ID discovery (for example, `https://id.example.com`), set the generated client ID and secret, and set `OIDC_PUBLIC_URL=https://qbop.example.com`. Leave local login enabled until the first verified-email link and provider logout have both been tested.

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

### API authentication

Every API endpoint requires a valid qbop API key, including `/api/health`. Inbound HTTP Basic Auth is not supported. API authentication is independent of `WEB_AUTH_ENABLED`, and browser sessions or cookies are not accepted by API routes.

To configure an API client:

1. Sign in to qbop and open `/api-docs` through **api** in the navigation.
2. Review the endpoint documentation and scroll to **api keys**.
3. Create a named API key.
4. Copy the complete `qbop_...` value immediately.
5. Send it in the `Authorization` header:

   ```http
   Authorization: Bearer qbop_xxxxxxxxx
   ```

6. Revoke the old key from the same page when it is no longer needed.

`/api-docs` combines the current endpoint documentation with API-key creation and revocation. API-key secrets are shown only once and cannot be recovered later. Create a replacement before revoking a key when rotating credentials. When browser authentication is disabled, `/api-docs` and its key-management section are accessible with the rest of the web UI, so protect that UI with a trusted external access layer.

## Usage

### ProtonVPN WireGuard importer

The first tool on `/tools` updates an existing OPNsense WireGuard instance and peer from a ProtonVPN `.conf` file. Select the associated instance and peer, then upload or paste a configuration generated with NAT-PMP (Port Forwarding) enabled.

qbop updates Proton WireGuard credentials, tunnel addresses within the adopted tunnel's existing address-family policy, peer endpoint/AllowedIPs, and optionally the peer name. OPNsense-local settings such as DNS, gateway, routing behavior, firewall rules, NAT, and interface assignments are preserved. The peer's existing instance association is also preserved. A peer rename uses a validated name derived from Proton's server identifier comment (for example, `# US-IL#661` becomes `Proton_US-IL661`); without that option, the existing peer name is preserved exactly. The selected instance must be enabled, and the selected instance and peer must be dedicated to each other with no other peer or instance associations. During import, qbop disables the instance and applies that state, verifies that its interface is absent from OPNsense's WireGuard runtime state, updates the peer first and the instance second, applies the new configuration while it remains disabled, then re-enables the instance and applies again. It verifies that the re-enabled runtime instance and peer use the imported public keys without requiring a fresh handshake. If any step fails, qbop restores the peer first and instance second while disabled, applies the restored configuration, then restores the original enabled state, applies again, and verifies that the previous instance and peer keys are active.

Imports run synchronously and exclusively. The request waits for each OPNsense apply before advancing to the next state, so it reports the completed result or any rollback failure immediately. A lock file in the persistent `data` volume prevents overlapping rotations, and a competing request is rejected with a conflict response.

The configured OPNsense API key needs the **VPN: WireGuard: Configuration** privilege in addition to the permissions used by qbop's firewall-alias integration. Uploaded and pasted configurations are not logged or retained.

### Query Parameters
The stats, logs, and history pages can auto-refresh by passing `refresh` in seconds. Use `refresh=0` or omit the parameter to disable it.

Query parameters are per-request overrides and do not change environment variables.

Examples:
- `/?refresh=5`
- `/?refresh=0`
- `/logs?lines=500&direction=desc&refresh=5`
- `/logs?lines=500&direction=asc&refresh=0`
- `/api/logs?lines=500&direction=desc`
- `/history?page=2&per_page=50`
- `/history?page=2&per_page=50&refresh=5`
- `/api/history?page=2&per_page=50`

Stats, logs, and history UI parameters:
| Parameter | Default | Description |
| :--- | :--- | :--- |
| `refresh` | `0` | Auto-refresh interval in seconds, from 0 to 3600. |

Logs UI and API parameters:
| Parameter | Default | Description |
| :--- | :--- | :--- |
| `lines` | `LOG_LINES` or `50` | Number of log lines to show, from 1 to 5000. |
| `direction` | `LOG_REVERSE` or `asc` | `asc` shows oldest first, `desc` shows newest first. |

History UI and API parameters:
| Parameter | Default | Description |
| :--- | :--- | :--- |
| `page` | `1` | Page of port transitions to return. Pages beyond the available history use the final page. |
| `per_page` | `25` | Number of transitions per page. Supported values are `25`, `50`, and `100`. |

The history records only Proton port assignments. Fresh installations include the initial assignment; upgraded installations begin with the next port change. Each transition reports `pending`, `synced`, `error`, or `skipped` for OPNsense and qBittorrent. Pending means synchronization has not completed; error means the most recent synchronization write failed, with the detailed reason remaining in the logs. Existing logs are not backfilled, and the oldest record is removed when a 501st transition is added.

Notes:
- `refresh` only applies to the web UI.
- Invalid `lines` values fall back to `LOG_LINES`, then `50`.
- Invalid `direction` values fall back to `LOG_REVERSE`, then `asc`.
- Invalid history pagination values fall back to page `1` and `25` transitions per page.
