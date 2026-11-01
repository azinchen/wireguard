# wireguard — a WireGuard node in Docker

A WireGuard server for your devices with **zero-config peers**, **per-peer exits** (direct, upstream VPN container, WireGuard provider, or another peer acting as exit node), a **fail-closed kill switch**, **hot reload**, and a **sidecar mode** for other containers — all in one Alpine + s6-overlay image.

```
 phone (alice) ──┐                 ┌─ gw=direct ──► eth0 ──► internet (your IP)
 laptop (bob)  ──┼─► wg0 (server) ─┼─ gw=nl ──────► nordvpn-wg container ──► NL exit
 tv (carol)    ──┘                 ├─ gw=mullvad ─► wg-mullvad ──► provider
                                   └─ gw=home ────► wg-home ──► your home router ──► home ISP
```

---

## What you get

- **Zero-config peers** — `PEERS=alice,bob` is a complete setup: keys, addresses, device configs and QR codes generated ([[Peers]])
- **Bring your own keys** — a peer may give only its public key; no private key ever exists on the server ([Peers](Peers#options))
- **Per-peer exits** — direct, an upstream VPN container, a WireGuard provider conf, or another peer ([[Gateway Mode]])
- **Exit nodes** — `exit=true` turns a peer such as a home router into an exit; its config is generated for you ([[Exit Nodes and Upstreams]])
- **Fail-closed kill switch** — if an upstream is down, its peers lose internet rather than leak ([Gateway Mode](Gateway-Mode#kill-switch-fail-closed))
- **Hot reload** — edit the peers file and `wg-reload` applies it in place; unchanged peers keep their session ([Peers](Peers#hot-reload))
- **DNS-named gateways** — name sidecars and endpoints by hostname; re-resolved and re-routed live ([Gateway Mode](Gateway-Mode#configuration))
- **Sidecar mode** — `LOCAL_GATEWAY=<exit>` tunnels the container and its `network_mode: service:` clients ([[Sidecar Mode]])
- **Opt-in health monitor** — `HEALTHCHECK` for the interface, routing tables and egress probes per gateway ([[Health Monitor]])
- **Built-in reporting** — `peer-report` (handshakes, traffic, exit per peer) and `network-diagnostic` ([Troubleshooting](Troubleshooting#network-diagnostic))
- **Kernel WireGuard, userspace fallback** — the host module when present, `wireguard-go` otherwise ([[Architecture and Internals]])
- **Small multi-arch Alpine image** — 386, amd64, arm/v6, arm/v7, arm64, riscv64; s6-overlay, nftables only, no wg-quick ([[Building and CI]])

---

## Start here

| If you want to… | Go to |
|---|---|
| Get your first device connected in five minutes | **[[Getting Started]]** |
| Understand the peers file: options, keys, addresses, device configs, hot reload | **[[Peers]]** |
| Send peers out through different exits, name gateways, understand the kill switch | **[[Gateway Mode]]** |
| Use another peer, a provider conf or a cascade as an exit | **[[Exit Nodes and Upstreams]]** |
| Route other containers / LAN hosts through a tunnel | **[[Sidecar Mode]]** |
| Understand every variable, volume, port and capability | **[[Configuration Reference]]** |
| Report container health to Docker / monitoring | **[[Health Monitor]]** |
| Fix a problem | **[[Troubleshooting]]** |
| See how the image works internally | **[[Architecture and Internals]]** |
| Build it yourself / understand image tags and releases | **[[Building and CI]]** |

---

## At a glance

```yaml
services:
  wireguard:
    image: azinchen/wireguard:latest
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv4.ip_forward=1
    ports:
      - 51820:51820/udp
    environment:
      - SERVER_ENDPOINT=vpn.example.com
      - PEERS=alice,bob
    volumes:
      - ./volumes/config:/etc/wireguard
```

Then `docker exec wireguard peer-conf alice --qr` and scan — see **[[Getting Started]]**.

**Family:** [ocserv-server](https://github.com/azinchen/ocserv-server) shares the gateway contract (`VPN_GATEWAY*`); [nordvpn](https://github.com/azinchen/nordvpn) / [nordvpn-wg](https://github.com/azinchen/nordvpn-wg) are drop-in upstream gateways; [openconnect-client](https://github.com/azinchen/openconnect-client) is the OpenConnect sidecar.

> **Project:** https://github.com/azinchen/wireguard
> **License:** MIT
