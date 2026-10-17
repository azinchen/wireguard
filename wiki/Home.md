# wireguard - a WireGuard node in Docker

A WireGuard server for your devices with **zero-config peers**, **per-peer exits** (direct, upstream VPN container, WireGuard provider, or another peer acting as exit node), a **fail-closed kill switch**, **hot reload**, and a **sidecar mode** for other containers - all in one Alpine + s6-overlay image.

```
 phone (alice) ──┐                 ┌─ gw=direct ──► eth0 ──► internet (your IP)
 laptop (bob)  ──┼─► wg0 (server) ─┼─ gw=nl ──────► nordvpn-wg container ──► NL exit
 tv (carol)    ──┘                 ├─ gw=mullvad ─► wg-mullvad ──► provider
                                   └─ gw=home ────► wg-home ──► your home router ──► home ISP
```

| Start here | |
|---|---|
| [[Getting Started]] | first container, first device, in five minutes |
| [[Peers]] | the peers file: options, keys, addresses, device configs, hot reload |
| [[Gateway Mode]] | per-peer exits, named gateways, the kill switch |
| [[Exit Nodes and Upstreams]] | exits through another peer, provider confs, cascades |
| [[Sidecar Mode]] | route other containers / LAN hosts through a tunnel |
| [[Configuration Reference]] | every variable, volume, port and capability |
| [[Health Monitor]] · [[Troubleshooting]] · [[Architecture and Internals]] | operating the container |

**Family:** [ocserv-server](https://github.com/azinchen/ocserv-server) shares the gateway contract (`VPN_GATEWAY*`); [nordvpn](https://github.com/azinchen/nordvpn) / [nordvpn-wg](https://github.com/azinchen/nordvpn-wg) are drop-in upstream gateways; [openconnect-client](https://github.com/azinchen/openconnect-client) is the OpenConnect sidecar.
