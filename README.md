# qbop
A tool for keeping ProtonVPN, OPNsense, and qBittorrent forwarded ports in sync.

> [!WARNING]
> I'm not responsible for improper use of this script.

## Purpose
This tool helps automate port forwarding from ProtonVPN to qBittorrent via OPNsense. The tool polls ProtonVPN for the given forwarded port, checks the port set in OPNsense and qBittorrent, and updates it if necessary. You can ignore qBittorrent by using the `QBIT_SKIP` environment variable.

Version v0.5 and later allows you to skip qBittorrent and just sync Proton's forwarded port to OPNsense.

## Docker Install (recommended)
I recommend using the provided Docker container to simplify the set up of qbop. An example Docker Compose file is provided.

The Docker container is available here: https://github.com/clajiness/qbop/pkgs/container/qbop

#### Requirements
* Docker Engine - https://docs.docker.com/engine/install/
* OPNsense - This is the tutorial I used to set up selective routing to ProtonVPN. https://docs.opnsense.org/manual/how-tos/wireguard-selective-routing.html
* qBittorrent
* ProtonVPN subscription

#### Config

I'd recommend using Docker Compose to configure and run your instance of qbop. The given environment variables are required.

1. `LOOP_FREQ:` This value determines how often the script runs. The default value is 45 seconds. This probably shouldn't be changed.
2. `PROTON_GATEWAY:` The IP address of your ProtonVPN gateway. For example, `10.2.0.1`.
3. `OPN_INTERFACE_ADDR:` The IP address of your OPNsense interface. For example, `https://10.1.1.1`.
4. `OPN_API_KEY:` Your OPNsense API key - https://docs.opnsense.org/development/how-tos/api.html
5. `OPN_API_SECRET:` Your OPNsense API secret
6. `OPN_PROTON_ALIAS_NAME:` The firewall alias that you use for ProtonVPN's forwarded port. For example, `proton_vpn_forwarded_port`.
7. `QBIT_SKIP:` [true/false] Skip qBittorrent. If true, subsequent qBit environment variables are not necessary.
8. `QBIT_ADDR:` The IP address of your qBittorrent app. For example, `http://10.1.1.100:8080`.
9. `QBIT_USER:` Your qBittorrent username
10. `QBIT_PASS:` Your qBittorrent password

---

## Native Install (not recommended, but go nuts if you're comfortable with Ruby)

#### Requirements
* Linux distro such as Debian, Ubuntu, etc, or a Mac.
* Ruby 3+ (tested with 3.3.6)
* natpmpc (Linux - `apt install natpmpc` or similar) or libnatpmp (Mac - `brew install libnatpmp`)
* OPNsense - This is the tutorial I used to set up selective routing to ProtonVPN. https://docs.opnsense.org/manual/how-tos/wireguard-selective-routing.html
* qBittorrent
* ProtonVPN subscription

#### Config

Clone the qbop repo to your machine. Remove the existing file `config.yml`. Copy the file `config.yml.example`, rename it to `config.yml` with `cp config.yml.example config.yml`, and enter the required values.
1. `loop_freq:` This value determines how often the script runs. The default value is 45 seconds. This probably shouldn't be changed.
2. `proton_gateway:` The IP address of your ProtonVPN gateway. For example, `10.2.0.1`.
3. `opnsense_interface_addr:` The IP address of your OPNsense interface. For example, `https://10.1.1.1`.
4. `opnsense_api_key:` Your OPNsense API key - https://docs.opnsense.org/development/how-tos/api.html
5. `opnsense_api_secret:` Your OPNsense API secret
6. `opnsense_alias_name:` The firewall alias that you use for ProtonVPN's forwarded port. For example, `proton_vpn_forwarded_port`.
7. `qbit_skip:` [true/false] Skip qBittorrent. If true, subsequent qBit environment variables are not necessary.
8. `qbit_addr:` The IP address of your qBittorrent app. For example, `http://10.1.1.100:8080`.
9. `qbit_user:` Your qBittorrent username
10. `qbit_pass:` Your qBittorrent password

Next, you must start the script. You can manually start it, if you wish, with `ruby qbop.rb`. I'd recommend setting it up to start on boot, though. I've included an example systemd service file for those on Linux.
