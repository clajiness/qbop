# qbop
A tool for keeping ProtonVPN, OPNsense, and qBittorrent forwarded ports in sync.

> [!WARNING]
> This is beta software. I'm not responsible for any issues you may encounter.

## Purpose
This tool helps automate port forwarding from ProtonVPN to qBittorrent via OPNsense. The tool polls ProtonVPN for the given forwarded port, checks the port set in OPNsense and qBittorrent, and updates it if necessary.

You can ignore qBittorrent by using the `QBIT_SKIP` environment variable.

## Installation
I recommend using the provided Docker Compose file to simplify the set up of qbop. This container must be connected to ProtonVPN due to the required `natpmpc` command to work properly.

The Docker container is available here: https://github.com/clajiness/qbop/pkgs/container/qbop

### Requirements
* Docker Engine - https://docs.docker.com/engine/install/
* OPNsense
    * Selective routing: https://docs.opnsense.org/manual/how-tos/wireguard-selective-routing.html
    * API: https://docs.opnsense.org/development/how-tos/api.html
* qBittorrent
* ProtonVPN subscription

### ENV variables for Docker Compose file

1. `LOOP_FREQ:` This value, in seconds, determines how often the script runs. The default is `45`. This value is recommended by ProtonVPN
2. `REQUIRED_ATTEMPTS` The number of loops with a new forwarded port before updating OPNsense and qBit. The default is 3, min is 1, and max is 10.
3. `PROTON_GATEWAY:` Default is `10.2.0.1`. Do not use http(s):// or a trailing slash.
4. `OPN_INTERFACE_ADDR:` OPNsense Interface Address. Requires http(s):// and no trailing slash.
5. `OPN_API_KEY:` OPNsense API Key
6. `OPN_API_SECRET:` OPNsense API Secret
7. `OPN_PROTON_ALIAS_NAME:` The firewall alias that you use for ProtonVPN's forwarded port. For example, `proton_vpn_forwarded_port`.
8. `QBIT_SKIP:` [`true`/`false`] Skip qBittorrent. If `true`, subsequent qBit environment variables are not required.
9. `QBIT_ADDR:` The IP address of your qBittorrent app. Requires http(s):// and no trailing slash.
10. `QBIT_USER:` qBittorrent username
11. `QBIT_PASS:` qBittorrent password
