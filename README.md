# WireGuard VPN Docker Container

[![GitHub release][github-release]][github-releases]
[![GitHub release date][github-releasedate]][github-releases]
[![GitHub build][github-build]][github-actions]<br>
[![GitHub stars][github-stars]][github-link]
[![GitHub forks][github-forks]][github-link]
[![Open issues][github-issues]][github-issues-link]
[![GitHub last commit][github-lastcommit]][github-link]<br>
[![Docker pulls][dockerhub-pulls]][dockerhub-link]
[![Docker stars][dockerhub-stars]][dockerhub-link]
[![Docker image size][dockerhub-size]][dockerhub-link]<br>
[![Multi-arch][multiarch-badge]][dockerhub-link]

A WireGuard **node** in a small self-configuring Docker container: a server for your devices with zero-config peer provisioning (keys, addresses, configs and QR codes generated for you), **per-peer exits** - straight out, through an upstream VPN container, through a WireGuard provider, or through **another peer** such as a home router - a fail-closed nftables kill switch on every path, and hot reload of everything without dropping tunnels. The same image is a WireGuard **sidecar** for other containers.

> **Part of a family.** [**azinchen/ocserv-server**](https://github.com/azinchen/ocserv-server) (OpenConnect server) shares this image's gateway-mode contract; [**azinchen/nordvpn**](https://github.com/azinchen/nordvpn) and [**azinchen/nordvpn-wg**](https://github.com/azinchen/nordvpn-wg) plug in as upstream gateways; [**azinchen/openconnect-client**](https://github.com/azinchen/openconnect-client) is the OpenConnect sidecar counterpart.

## ✨ Key Features

- **🧩 Zero-config peers** - `PEERS=alice,bob` is a complete setup: keys, pre-shared keys, stable addresses, device `.conf` files and QR codes are generated and persisted ([details][wiki-peers])
- **🔑 Bring your own keys** - a peer may give only its public key; no private key ever exists on the server ([details][wiki-peers])
- **🚪 Per-peer exits** - each peer leaves **direct**, via an **upstream VPN container** (NordVPN, any sidecar), via a **WireGuard provider** conf (Mullvad, your VPS), or via **another peer** acting as an exit node ([details][wiki-gateway])
- **🏠 Exit nodes** - a peer line with `exit=true` becomes an exit: the image creates the tunnel interface, the keys, the listen port and the config the exit device imports; dial-in (behind NAT) and dial-out both work ([details][wiki-exits])
- **🛡️ Fail-closed kill switch** - nftables guards on every path: an upstream that is down means no internet for its peers, never a leak ([details][wiki-killswitch])
- **🔄 Hot reload** - edit the peers file and `wg-reload` (or `PEERS_WATCH=1`) applies it in place with `wg syncconf`: unchanged peers keep their session ([details][wiki-reload])
- **🧭 DNS-named gateways** - name sidecars and endpoints by hostname; addresses are re-resolved live and re-routed without reconnects ([details][wiki-gateway])
- **📦 Sidecar mode** - `LOCAL_GATEWAY=<exit>` steers the container's own traffic and `network_mode: service:` containers into a tunnel with an output kill switch ([details][wiki-sidecar])
- **🩺 Opt-in health monitor** - Docker-native `HEALTHCHECK`: interface, routing tables, and real egress probes per gateway ([details][wiki-health])
- **📊 Built-in reporting** - `peer-report` (handshakes, traffic, exit per peer) and `network-diagnostic` (public IP seen through every gateway) ([details][wiki-diag])
- **🐧 Kernel WireGuard, userspace fallback** - uses the host module when present, `wireguard-go` otherwise
- **📦 Multi-arch** - amd64 / arm64 / riscv64, Alpine + s6-overlay, nftables only, no wg-quick

> **📖 [Full documentation on the Wiki][wiki-home]** - setup, peers, gateway mode, exit nodes, sidecar mode, configuration reference, troubleshooting, architecture.

---

## Quick Start

```yaml
# docker-compose.yml
services:
  wireguard:
    image: azinchen/wireguard:latest
    container_name: wireguard
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv4.ip_forward=1
    ports:
      - 51820:51820/udp
    environment:
      - SERVER_ENDPOINT=vpn.example.com     # what your devices dial
      - PEERS=alice,bob
    volumes:
      - ./volumes/config:/etc/wireguard
```

```bash
docker compose up -d
docker exec wireguard peer-conf alice --qr     # scan with the WireGuard app
docker exec wireguard peer-conf bob > bob.conf # or import the file
docker exec wireguard peer-report              # who is connected, through which exit
```

### Requirements

| Setting | Why |
|---|---|
| `--cap-add=NET_ADMIN` | configure interfaces, routes, nftables |
| `--sysctl net.ipv4.ip_forward=1` | forward peer traffic |
| host WireGuard module (Linux 5.6+, or `wireguard` dkms) | kernel WireGuard; without it add `--device /dev/net/tun` and the image falls back to `wireguard-go` |

## Common Setups

| I want to... | Guide |
|---|---|
| Run a plain WireGuard server for my devices | [Getting Started][wiki-start] · [Peers][wiki-peers] |
| Send some peers out through NordVPN / another VPN container | [Gateway Mode][wiki-gateway] |
| Use a WireGuard provider (Mullvad, Proton, my VPS) as an exit | [Exit Nodes and Upstreams][wiki-exits] |
| Route a peer's traffic out through my **home router** (behind NAT) | [Exit Nodes and Upstreams][wiki-exits] |
| Route other containers or LAN hosts through a WireGuard tunnel | [Sidecar Mode][wiki-sidecar] |
| Chain two of these containers (cascade) | [Exit Nodes and Upstreams#cascades][wiki-cascade] |

Per-peer exits are one file:

```
# volumes/config/peers.conf
alice   gw=nl                    # out through the nordvpn-wg container "nl"
bob                              # direct (default)
carol   gw=home                  # out through the home router
home    exit=true                # the home router: dial-in exit node, everything generated
site-a  allowed=192.168.50.0/24  # a site behind the peer, reachable from the VPN
```

with `VPN_GATEWAYS=nl=nordvpn-wg` in the environment (a DNS name on the Docker network). `docker exec wireguard peer-conf home` prints the config the router imports.

## Environment Variables

Grouped by feature; every variable is one line here - the **[Configuration Reference][wiki-config]** has the full descriptions.

### Core networking

| Variable | Default | Description |
|---|---|---|
| `VPN_SUBNET` | `10.10.10.0/24` | Peer subnet; the server takes the first host, peers are allocated from the second. |
| `LISTEN_PORT` | `51820` | UDP port `wg0` listens on. |
| `SERVER_ENDPOINT` | _(unset)_ | `host[:port]` your devices dial; written into generated configs (placeholder + warning if unset). |
| `WAN_IF` | _(auto)_ | Egress interface; auto-detected from the default route. |
| `MTU` | `1420` | `wg0` MTU. |
| `MSS` | _(unset)_ | Hard TCP MSS cap for forwarded traffic (default: clamp to interface MTU). |
| `TTL_SET` | _(unset)_ | Rewrite TTL/hop-limit of forwarded traffic on egress (e.g. `64`); hides hops behind this node from traceroutes. |
| `PEER_TO_PEER` | `true` | Allow peers to reach each other through `wg0`. |

### Peers - [details][wiki-peers]

| Variable | Default | Description |
|---|---|---|
| `PEERS` | _(unset)_ | Inline list: `alice,bob` (keys generated) or `bob=<pubkey>` (device-made key). |
| `PEERS_FILE` | `/etc/wireguard/peers.conf` | Peer definitions, one `name [option=value ...]` per line; file wins over `PEERS`. |
| `PEERS_WATCH` | `0` | `1` = `wg-reload` automatically whenever the peers file changes. |
| `PEER_DNS` | `1.1.1.1,1.0.0.1` | `DNS =` written into device configs (per-peer `dns=`). |
| `PEER_ROUTES` | `0.0.0.0/0,::/0` | Device-side `AllowedIPs` (full tunnel); per-peer `routes=` for split tunnels. |
| `PEER_KEEPALIVE` | `25` | `PersistentKeepalive` in device configs (`0` = off). |

### IPv6

| Variable | Default | Description |
|---|---|---|
| `IPV6_FORWARD` | `1` | Enable IPv6 forwarding inside the container. |
| `IPV6_NAT` | `0` | NAT66 for `IPV6_SUBNET`; peers only get an IPv6 address when IPv6 is actually routed. |
| `IPV6_SUBNET` | `fda9:…::/64` | ULA peer subnet (`<prefix>::/64`). |

### Gateway mode - [details][wiki-gateway]

| Variable | Default | Description |
|---|---|---|
| `VPN_GATEWAY` | _(unset)_ | Default exit for unmapped peers: IP/DNS name of an upstream container, `direct`, `block`, or `wg:<name>` (an exit node / upstream). |
| `VPN_GATEWAY6` | _(unset)_ | Same for IPv6 (`block` by default - no leak). |
| `VPN_GATEWAYS` | _(unset)_ | Named gateways, e.g. `nl=nordvpn-wg,us=172.28.0.4,mullvad=wg`. |
| `VPN_GATEWAYS6` | _(unset)_ | Optional IPv6 per gateway name. |
| `VPN_GATEWAYS_FILE` | _(unset)_ | Gateways in a file (`name ipv4 [ipv6]`). |
| `VPN_GATEWAYS_RESOLVE_INTERVAL` | `0` | Re-resolve DNS-named gateways and upstream endpoints every N seconds. |
| `VPN_PEER_GATEWAY` | _(unset)_ | Peer → gateway map, e.g. `alice=nl,bob=direct` (the `gw=` option in the peers file wins). |
| `VPN_PEER_GATEWAY_FILE` | _(unset)_ | The map in a file; hot-reload with `wg-reload`. |
| `VPN_PEER_GATEWAY_WATCH` | `0` | `1` = reload the map automatically on change. |
| `VPN_GATEWAY_TABLE` / `VPN_GATEWAY_RULE_PRIO` / `VPN_GATEWAY_PEER_RULE_PRIO` | `100` / `1000` / `900` | Routing table base and rule priorities (advanced). |

### Exit nodes and upstreams - [details][wiki-exits]

| Variable | Default | Description |
|---|---|---|
| `EXIT_SUBNET` / `EXIT_SUBNET6` | `10.10.11.0/24` / `fda9:…:03eb::/64` | Transfer addresses for exit nodes. |
| `EXIT_PORT_BASE` | `LISTEN_PORT+1` | First UDP port handed to dial-in exit nodes (publish them). |
| `UPSTREAMS_DIR` | `/etc/wireguard/upstreams` | Bring-your-own wg-quick-style confs (`<name>.conf`), each a gateway named `<name>`. |
| `UPSTREAM_HANDSHAKE_TIMEOUT` | `180` | Seconds without a handshake before a dial-out endpoint is re-resolved. |

### Sidecar mode - [details][wiki-sidecar]

| Variable | Default | Description |
|---|---|---|
| `LOCAL_GATEWAY` | `direct` | Exit for the container's own traffic and `network_mode: service:` containers; arms the output kill switch. |
| `FORWARD_FROM` / `FORWARD_FROM6` | _(unset)_ | Source CIDRs (or `auto`) routed through `LOCAL_GATEWAY`. |
| `GATEWAY_NAT6` | `true` | NAT66 for sidecar clients. |
| `NETWORK` / `NETWORK6` | _(unset)_ | LAN CIDRs the kill switch keeps reachable off-tunnel. |
| `DNS` | `1.1.1.1,1.0.0.1` | Resolvers written to `resolv.conf` in sidecar mode. |

### Health monitor - [details][wiki-health]

| Variable | Default | Description |
|---|---|---|
| `HEALTH_CHECK_ENABLED` | `false` | `true` = the `HEALTHCHECK` probe checks `wg0`, the listen port and the nft tables. |
| `HEALTH_CHECK_EGRESS` | _(unset)_ | Paths that also gate health: `direct`, gateway names, `default`, `upstreams`, `all` (join with `+`). |
| `HEALTH_CHECK_URL` | `https://1.1.1.1/…` | URL(s) for the direct probe, `;`-separated. |

## Operator commands

| Command | Purpose |
|---|---|
| `peer-conf <name> [--qr]` | print a peer's or exit node's device config (or QR) |
| `peer-conf --list` | every defined node with address, exit and state |
| `peer-report [--json]` | handshake, endpoint, traffic and gateway per peer |
| `wg-reload` | apply the peers file and maps in place |
| `network-diagnostic [--basic|--json|--explain <peer>]` | routing/kill-switch state, exit IP through every gateway |
| `vpngw-gw-resolve` | force a re-resolve of DNS-named gateways and endpoints |

## Build

```bash
docker build -t wireguard .
```

Base: Alpine Linux · Init: s6-overlay · VPN: WireGuard (`wg` + kernel module, `wireguard-go` fallback) · Firewall: nftables

## Issues

If you have any problems with or questions about this image, please contact me through a [GitHub issue][github-issues-link] or [email][email-link].

Check the **[Troubleshooting][wiki-troubleshoot]** wiki page first - and attach the output of the built-in diagnostic to any report:

```bash
docker exec wireguard network-diagnostic
```

## License

[MIT](LICENSE)

<!-- Links: GitHub -->
[github-release]: https://img.shields.io/github/v/release/azinchen/wireguard?logo=github&logoColor=white
[github-releasedate]: https://img.shields.io/github/release-date/azinchen/wireguard?logo=github&logoColor=white
[github-releases]: https://github.com/azinchen/wireguard/releases
[github-build]: https://img.shields.io/github/actions/workflow/status/azinchen/wireguard/ci-build-deploy.yml?branch=main&label=build&logo=github&logoColor=white
[github-actions]: https://github.com/azinchen/wireguard/actions/workflows/ci-build-deploy.yml
[github-stars]: https://img.shields.io/github/stars/azinchen/wireguard?style=flat-square&logo=github&logoColor=white
[github-forks]: https://img.shields.io/github/forks/azinchen/wireguard?style=flat-square&logo=github&logoColor=white
[github-issues]: https://img.shields.io/github/issues/azinchen/wireguard?logo=github&logoColor=white
[github-issues-link]: https://github.com/azinchen/wireguard/issues
[github-lastcommit]: https://img.shields.io/github/last-commit/azinchen/wireguard?logo=github&logoColor=white
[github-link]: https://github.com/azinchen/wireguard

<!-- Links: Docker Hub -->
[dockerhub-pulls]: https://img.shields.io/docker/pulls/azinchen/wireguard?logo=docker&logoColor=white
[dockerhub-stars]: https://img.shields.io/docker/stars/azinchen/wireguard?logo=docker&logoColor=white
[dockerhub-size]: https://img.shields.io/docker/image-size/azinchen/wireguard/latest?logo=docker&logoColor=white
[dockerhub-link]: https://hub.docker.com/r/azinchen/wireguard
[multiarch-badge]: https://img.shields.io/badge/multi--arch-amd64%20%7C%20arm64%20%7C%20riscv64-blue?logo=docker&logoColor=white

<!-- Links: Wiki -->
[wiki-home]: https://github.com/azinchen/wireguard/wiki
[wiki-start]: https://github.com/azinchen/wireguard/wiki/Getting-Started
[wiki-config]: https://github.com/azinchen/wireguard/wiki/Configuration-Reference
[wiki-peers]: https://github.com/azinchen/wireguard/wiki/Peers
[wiki-gateway]: https://github.com/azinchen/wireguard/wiki/Gateway-Mode
[wiki-killswitch]: https://github.com/azinchen/wireguard/wiki/Gateway-Mode#kill-switch-fail-closed
[wiki-reload]: https://github.com/azinchen/wireguard/wiki/Peers#hot-reload
[wiki-exits]: https://github.com/azinchen/wireguard/wiki/Exit-Nodes-and-Upstreams
[wiki-cascade]: https://github.com/azinchen/wireguard/wiki/Exit-Nodes-and-Upstreams#cascades
[wiki-sidecar]: https://github.com/azinchen/wireguard/wiki/Sidecar-Mode
[wiki-health]: https://github.com/azinchen/wireguard/wiki/Health-Monitor
[wiki-diag]: https://github.com/azinchen/wireguard/wiki/Troubleshooting#network-diagnostic
[wiki-troubleshoot]: https://github.com/azinchen/wireguard/wiki/Troubleshooting
[email-link]: mailto:alexander@zinchenko.com
