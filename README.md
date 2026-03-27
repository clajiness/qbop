![qbop logo](https://github.com/clajiness/qbop/blob/main/public/images/light/apple-touch-icon-light.png)

# qbop
A tool for maintaining a ProtonVPN forwarded port, with optional integration for OPNsense and qBittorrent. qbop provides a simple web UI and API at `http://<host_ip>:4567/`.

This container must be routed through ProtonVPN (via a VPN container or network namespace) for port forwarding to work.

qbop is built with Ruby and available as a Docker image.

## What qbop does
- Maintains an active ProtonVPN forwarded port
- Automatically updates OPNsense firewall aliases
- Keeps qBittorrent in sync with the active port
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

The container image is available [here](https://github.com/clajiness/qbop/pkgs/container/qbop). The sample docker-compose.yml file is available [here](https://github.com/clajiness/qbop/blob/main/docker-compose/docker-compose.yml). There is also a [community compose directory](https://github.com/clajiness/qbop/blob/main/docker-compose/community/). Feel free to open a pull request to share your own compose files.

Image tags are published as follows:
- `latest` → most recent release
- `v2` → latest `v2.x.x` release
- `v2.5` → latest `v2.5.x` release
- `v2.5.8` → exact version

### Requirements
* AMD64 or ARM64/v8 architecture - If you need support for a different architecture, file an issue.
* [Docker Engine](https://docs.docker.com/engine/install/)
* [OPNsense](https://docs.opnsense.org/)
    * [Selective routing](https://docs.opnsense.org/manual/how-tos/wireguard-selective-routing.html)
    * [API](https://docs.opnsense.org/development/how-tos/api.html)
* [qBittorrent](https://www.qbittorrent.org/)
* [ProtonVPN](https://protonvpn.com/support/port-forwarding)

### ENV variables
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
| `QBIT_SKIP` | `false` | [`true`/`false`] Skip qBittorrent. If `true`, subsequent qBittorrent environment variables are not required. |
| `QBIT_ADDR` | | The IP address of your qBittorrent app. Requires `http(s)://` and no trailing slash. |
| `QBIT_USER` | | qBittorrent username |
| `QBIT_PASS` | | qBittorrent password |
| `BASIC_AUTH_ENABLED` | `false` | Enable basic auth. If `true`, subsequent `BASIC_AUTH` variables are used. |
| `BASIC_AUTH_USER` | `admin` | Set basic auth username |
| `BASIC_AUTH_PASS` | `admin` | Set basic auth password |
