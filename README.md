# qbop
A tool for keeping ProtonVPN, OPNsense, and qBittorrent forwarded ports in sync.

> [!WARNING]
> This is beta software. I'm not responsible for any issues you may encounter.

## Purpose
This tool helps automate port forwarding from ProtonVPN to qBittorrent via OPNsense. The tool polls ProtonVPN for the given forwarded port, checks the port set in OPNsense and qBittorrent, and updates it if necessary.

You can ignore qBittorrent by using the `QBIT_SKIP` environment variable.

## Installation
I recommend using the provided Docker Compose file to simplify the set up of qbop.

The Docker container is available here: https://github.com/clajiness/qbop/pkgs/container/qbop

### Requirements
* Docker Engine - https://docs.docker.com/engine/install/
* OPNsense - This is the tutorial I used to set up selective routing to ProtonVPN. https://docs.opnsense.org/manual/how-tos/wireguard-selective-routing.html
* qBittorrent
* ProtonVPN subscription

### Config
The given environment variables are required.

1. `LOOP_FREQ:` This value determines how often the script runs. The default value is 45 seconds. This probably shouldn't be changed.
2. `PROTON_GATEWAY:` Usually 10.2.0.1. Do not use http(s):// or a trailing slash.
3. `OPN_INTERFACE_ADDR:` OPNsense Interface Address. Requires http(s):// and no trailing slash.
4. `OPN_API_KEY:` OPNsense API Key - https://docs.opnsense.org/development/how-tos/api.html
5. `OPN_API_SECRET:` OPNsense API Secret
6. `OPN_PROTON_ALIAS_NAME:` The firewall alias that you use for ProtonVPN's forwarded port. For example, `proton_vpn_forwarded_port`.
7. `QBIT_SKIP:` [true/false] Skip qBittorrent. If true, subsequent qBit environment variables are not required.
8. `QBIT_ADDR:` The IP address of your qBittorrent app. Requires http(s):// and no trailing slash.
9. `QBIT_USER:` qBittorrent username
10. `QBIT_PASS:` qBittorrent password
