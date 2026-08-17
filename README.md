![qbop logo](https://github.com/clajiness/qbop/blob/main/public/images/light/apple-touch-icon-light.png)

# qbop
A tool for maintaining a ProtonVPN forwarded port, with optional integration for OPNsense and qBittorrent. qbop provides a simple web UI and API at `http://<host_ip>:4567/`.

This container must be routed through ProtonVPN (via a VPN container or network namespace) for port forwarding to work.

qbop is built with Ruby and available as a Docker image.

## What qbop does
- Maintains an active ProtonVPN forwarded port
- Automatically updates OPNsense firewall aliases
- Keeps qBittorrent in sync with the active port
- Retains the 500 most recent port transitions and downstream synchronization status
- Provides a simple web UI and API

## Quick Start

```bash
git clone https://github.com/clajiness/qbop
cd qbop/docker-compose
docker compose up -d
```
Then open: `http://<host_ip>:4567/`

## Installation
I recommend using the provided sample Docker Compose files to simplify setting up qbop.

You can ignore OPNsense and/or qBittorrent by using the `OPN_SKIP` and/or `QBIT_SKIP` environment variables. This is handy if you're using a firewall and routing platform like a Unifi gateway or a different BitTorrent client.

The container image is available [here](https://github.com/clajiness/qbop/pkgs/container/qbop). The sample docker-compose.yml file is available [here](https://github.com/clajiness/qbop/blob/main/docker-compose/docker-compose.yml).

Image tags are published as follows:
- `latest` → most recent release
- `main` → most recent build from the main branch
- `<branch>` → most recent build from any pushed branch; invalid Docker tag characters such as `/` are replaced with `-`
- `sha-<12-character commit SHA>` → exact commit used for any published image build
- `v2` → latest `v2.x.x` release
- `v2.minor` → latest patch release for that minor version, e.g. `v2.7`
- `v2.minor.patch` → exact version, e.g. `v2.7.0`

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
| `BASIC_AUTH_ENABLED` | `false` | Enable HTTP Basic Auth for the API. If `true`, the subsequent `BASIC_AUTH` variables are used. |
| `BASIC_AUTH_USER` | `admin` | Set the API Basic Auth username. |
| `BASIC_AUTH_PASS` | `admin` | Set the API Basic Auth password. |

## Authentication development status

Browser authentication is enabled by default. On the first browser visit, qbop prompts you to create the single administrator account at `/setup`. Successful setup signs you in automatically. Subsequent visits require the administrator email and password at `/login`, and the web UI provides a sign-out control.

The authentication schema deliberately supports one administrator account. A database check plus a unique fixed account key enforce that invariant even if setup attempts race. After the account is created, `/setup` is unavailable. Set `WEB_AUTH_ENABLED=false` to disable browser authentication; this also makes `/setup` unavailable and does not change API authentication.

Browser sessions use an encrypted `qbop.session` cookie with `HttpOnly` and `SameSite=Lax`. The persisted secret in `data/session_secret.txt` is generated automatically with restrictive permissions, so there is no new required configuration. Cookies are also marked `Secure` when Rack identifies the request as HTTPS, including through `X-Forwarded-Proto: https`; HTTPS reverse proxies must forward the original scheme.

During qbop 3.0 development, the Grape API continues to use the existing optional HTTP Basic Auth controlled by `BASIC_AUTH_ENABLED`, `BASIC_AUTH_USER`, and `BASIC_AUTH_PASS`. Its behavior and default-disabled setting are unchanged. API authentication will move to revocable API keys before the final qbop 3.0 release; WebAuthn/passkeys remain a separate future enhancement.

## Usage
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

The history records only Proton port assignments. Fresh installations include the initial assignment; upgraded installations begin with the next port change. Each transition tracks whether OPNsense and qBittorrent are pending, synchronized, or skipped. Existing logs are not backfilled, and the oldest record is removed when a 501st transition is added.

Notes:
- `refresh` only applies to the web UI.
- Invalid `lines` values fall back to `LOG_LINES`, then `50`.
- Invalid `direction` values fall back to `LOG_REVERSE`, then `asc`.
- Invalid history pagination values fall back to page `1` and `25` transitions per page.
