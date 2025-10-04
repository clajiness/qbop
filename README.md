# qbop
A tool for maintaining a forwarded port from ProtonVPN, while optionally keeping OPNsense and qBittorrent in sync. The tool offers a simple web UI and API with stats and logging via `http://<host_ip>:4567/`.

qbop is built with Ruby and available as a Docker image.

## Purpose
This tool helps automate port forwarding from ProtonVPN to qBittorrent via OPNsense. The tool polls ProtonVPN for the forwarded port, checks the ports set in OPNsense and qBittorrent, and updates them if necessary.

You can ignore OPNsense and/or qBittorrent by using the `OPN_SKIP` and `QBIT_SKIP` environment variables.

## Installation
> [!CAUTION]
> Due to changes to the OPNsense API, do not update beyond qbop v1.13.2 if you are not running OPNsense 25.7.0 or later. If you are a Business Edition user, you must wait for 25.10.0 or later.

I recommend using the provided sample Docker Compose files to simplify the set up of qbop. This container must be connected to ProtonVPN due to the required `natpmpc` dependency.

The container image is available [here](https://github.com/clajiness/qbop/pkgs/container/qbop). The sample docker-compose.yml file is available [here](https://github.com/clajiness/qbop/blob/main/docker-compose/docker-compose.yml).

There is also a community compose directory that currently contains a compose file set up to run the tool on Synology devices. Feel free to open a pull request and add your own compose files. The community-created compose files are available [here](https://github.com/clajiness/qbop/blob/main/docker-compose/community/).

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
| `REQUIRED_ATTEMPTS` | `3` | The number of loops with a new forwarded port before updating OPNsense and qBit. The min is 1, and max is 10. |
| `LOG_LINES` | `50` | The number of log lines displayed on the "logs" page |
| `LOG_REVERSE` | `false` | Reverse the display order of log lines, showing newest logs at the top when enabled. |
| `PROTON_GATEWAY` | `10.2.0.1` | ProtonVPN provided gateway IP address. Do not use `http(s)://` or a trailing slash. |
| `OPN_SKIP` | `false` | [`true`/`false`] Skip OPNsense. If `true`, subsequent OPNsense environment variables are not required. |
| `OPN_INTERFACE_ADDR` | | OPNsense Interface Address. Requires `http(s)://` and no trailing slash. |
| `OPN_API_KEY` | | OPNsense API Key |
| `OPN_API_SECRET` | | OPNsense API Secret |
| `OPN_PROTON_ALIAS_NAME` | | The firewall alias that you use for ProtonVPN's forwarded port. For example, `proton_vpn_forwarded_port`. |
| `QBIT_SKIP` | `false` | [`true`/`false`] Skip qBittorrent. If `true`, subsequent qBit environment variables are not required. |
| `QBIT_ADDR` | | The IP address of your qBittorrent app. Requires `http(s)://` and no trailing slash. |
| `QBIT_USER` | | qBittorrent username |
| `QBIT_PASS` | | qBittorrent password |
