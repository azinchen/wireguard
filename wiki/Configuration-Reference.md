# Configuration Reference

Everything you configure at the container level. Defaults are the in-image defaults (`/usr/local/bin/backend-functions`). Lists accept `,` or `;` as separators unless noted.

| Group | Guide |
|---|---|
| [Core networking](#core-networking) | [[Getting Started]] |
| [Peers](#peers) | [[Peers]] |
| [IPv6](#ipv6) | |
| [Gateway mode](#gateway-mode) | [[Gateway Mode]] |
| [Exit nodes and upstreams](#exit-nodes-and-upstreams) | [[Exit Nodes and Upstreams]] |
| [Sidecar mode](#sidecar-mode) | [[Sidecar Mode]] |
| [Health monitor](#health-monitor) | [[Health Monitor]] |

## Core networking

| Variable | Default | Description |
|---|---|---|
| `VPN_SUBNET` | `10.10.10.0/24` | IPv4 peer subnet (at least a /30). The server takes the first host; peers are allocated from the second upward unless pinned with `ip=`. Masqueraded out `WAN_IF`, gateway egress interfaces and tunnels. |
| `LISTEN_PORT` | `51820` | UDP port `wg0` listens on. Publish it. |
| `SERVER_ENDPOINT` | _(unset)_ | `host[:port]` (IPv6 in brackets) written as `Endpoint` into the configs of nodes that dial this server: inbound peers and dial-in exit nodes. The server itself never uses it. Unset: those configs carry `<SERVER_ENDPOINT>:<port>` and one warning is logged. Port defaults to `LISTEN_PORT` (or the exit node's port). |
| `WAN_IF` | _(auto)_ | Egress interface, auto-detected from the IPv4 default route (handles macvlan uplinks). |
| `MTU` | `1420` | MTU of `wg0` and of exit-node interfaces (an upstream conf's own `MTU` wins for that tunnel). Lower to `1340` when peer traffic is carried by a WireGuard upstream and UDP matters. |
| `MSS` | _(unset)_ | Hard TCP MSS cap (`536`–`65535`) on forwarded SYNs. Unset clamps to each interface's MTU (tunnels: MTU − 40/60). |
| `TTL_SET` | _(unset)_ | Rewrite the IPv4 TTL / IPv6 hop-limit of forwarded traffic on egress to this value (`1`–`255`), hiding every hop behind this node from client traceroutes. Fatal on an invalid value. `TTL_INC` is reserved and refused. |
| `PEER_TO_PEER` | `true` | `false` drops forwarding between peers on `wg0`. |

## Peers

| Variable | Default | Description |
|---|---|---|
| `PEERS` | _(unset)_ | Inline peer list: `alice,bob` (keys generated) or `alice=<pubkey>` (device-made key). |
| `PEERS_FILE` | `/etc/wireguard/peers.conf` | Peer definitions, one `name [option=value …]` per line, `#` comments; used when the file exists, wins over `PEERS` on a name. Options: `key psk ip ip6 allowed gw bypass dns routes keepalive enabled exit endpoint port` - see [[Peers]]. |
| `PEERS_WATCH` | `0` | `1` = run `wg-reload` whenever the peers file changes. |
| `PEER_DNS` | `1.1.1.1,1.0.0.1` | `DNS =` in generated device configs; per-peer `dns=`. |
| `PEER_ROUTES` | `0.0.0.0/0,::/0` | Device-side `AllowedIPs` in generated configs; per-peer `routes=`. |
| `PEER_KEEPALIVE` | `25` | `PersistentKeepalive` in generated configs; `0` = none; per-peer `keepalive=`. |

## IPv6

| Variable | Default | Description |
|---|---|---|
| `IPV6_FORWARD` | `1` | Enable the IPv6 forwarding sysctl. |
| `IPV6_NAT` | `0` | NAT66 for `IPV6_SUBNET` out `WAN_IF`. |
| `IPV6_SUBNET` | `fda9:4efe:7e3b:03ea::/64` | ULA peer subnet, written as `<prefix>::/N` (N ≤ 64); the server is `::1`, peers get `::<IPv4 host number>`. Peers receive an IPv6 address only when IPv6 is routed (`IPV6_NAT=1` or a gateway with IPv6). |

## Gateway mode

| Variable | Default | Description |
|---|---|---|
| `VPN_GATEWAY` | _(unset)_ | Default IPv4 exit for **unmapped** peers: an IP or DNS name (next-hop on a Docker network, kill switch added), `direct`/unset (ISP), `block`, or `wg:<name>` (an exit node / upstream). |
| `VPN_GATEWAY6` | _(unset)_ | Default IPv6 exit for unmapped peers: IP / DNS name, `direct`, `block`, `wg:<name>`. Unset = `block` as soon as any gateway is configured (no leak), otherwise plain IPv6. |
| `VPN_GATEWAYS` | _(unset)_ | Named gateways `name=addr,…`; `addr` is an IP, a DNS name, `block`, `wg` (= `wg:<name>`) or `wg:<other>`. Names: letters, digits, `_`, `-`. Exit nodes and upstreams are gateways of their own name automatically. |
| `VPN_GATEWAYS6` | _(unset)_ | Optional IPv6 per gateway name. A gateway without IPv6 blocks its peers' IPv6. |
| `VPN_GATEWAYS_FILE` | _(unset)_ | `name ipv4 [ipv6]` lines, `#` comments; merged per field with the variables, file wins. |
| `VPN_GATEWAYS_RESOLVE_INTERVAL` | `0` | Seconds between re-resolving DNS-named gateways **and** dial-out tunnel endpoints (`0` = off). A moved address is re-routed in place; a name that fails to resolve keeps its last address. `vpngw-gw-resolve` forces one pass. |
| `VPN_PEER_GATEWAY` | _(unset)_ | Peer → gateway map `alice=nl,bob=direct`. The `gw=` option in the peers file wins; unmapped peers follow `VPN_GATEWAY`. |
| `VPN_PEER_GATEWAY_FILE` | _(unset)_ | The map in a file (`peer gateway` or `peer=gateway` lines); merged, file wins; hot-reload with `wg-reload`. |
| `VPN_PEER_GATEWAY_WATCH` | `0` | `1` = reload automatically when that file changes. |
| `VPN_GATEWAY_TABLE` | `100` | Routing table of the subnet default; named gateways use 101, 102, … |
| `VPN_GATEWAY_RULE_PRIO` | `1000` | Priority of the `from VPN_SUBNET` rule. |
| `VPN_GATEWAY_PEER_RULE_PRIO` | `900` | Priority of the per-peer rules (must be lower = stronger). |

## Exit nodes and upstreams

| Variable | Default | Description |
|---|---|---|
| `EXIT_SUBNET` | `10.10.11.0/24` | Transfer addresses for exit nodes: each gets a persisted pair (the exit device's, ours). |
| `EXIT_SUBNET6` | `fda9:4efe:7e3b:03eb::/64` | Same for IPv6 (used when IPv6 is routed). |
| `EXIT_PORT_BASE` | `LISTEN_PORT+1` | First UDP port handed to dial-in exit nodes (next free, persisted). Publish them. |
| `UPSTREAMS_DIR` | `/etc/wireguard/upstreams` | Bring-your-own wg-quick-style confs, `<name>.conf` → interface `wg-<name>`, gateway `<name>`. `DNS`, `Table` and hooks are ignored. |
| `UPSTREAM_HANDSHAKE_TIMEOUT` | `180` | Seconds without a handshake on a dial-out tunnel before its endpoint is re-resolved and re-set (also the `upstreams` health criterion). |
| `WG_FWMARK` | `0xca6c` | fwmark on every WireGuard socket (keeps encrypted UDP out of the tunnels). |

## Sidecar mode

| Variable | Default | Description |
|---|---|---|
| `LOCAL_GATEWAY` | `direct` | Exit for locally generated traffic (the container and `network_mode: service:` containers): `direct`, or a gateway / exit node / upstream name. Anything but `direct` arms the output/input kill switch and rewrites `resolv.conf`. |
| `FORWARD_FROM` / `FORWARD_FROM6` | _(unset)_ | Source CIDRs routed through `LOCAL_GATEWAY`; `auto` = the subnets connected to `WAN_IF`. Requires `LOCAL_GATEWAY`. |
| `GATEWAY_NAT6` | `true` | NAT66 for traffic entering tunnels; `false` masquerades IPv4 only. |
| `NETWORK` / `NETWORK6` | _(unset)_ | LAN CIDRs the kill switch keeps reachable off-tunnel (in and out). |
| `DNS` | `1.1.1.1,1.0.0.1` | Resolvers written to `/etc/resolv.conf` in sidecar mode. |
| `LOCAL_GATEWAY_RULE_PRIO` | `1100` | Priority of the local-traffic rule (must be above `VPN_GATEWAY_RULE_PRIO`). |
| `GATEWAY_DNS` / `GATEWAY_DNS_SERVER` | `off` | Reserved (phase 3); any other value is refused. |

## Health monitor

| Variable | Default | Description |
|---|---|---|
| `HEALTH_CHECK_ENABLED` | `false` | Master switch for the baked-in `HEALTHCHECK`. |
| `HEALTH_CHECK_EGRESS` | _(unset)_ | Paths that gate health, joined with `+`: `direct`, `default`, gateway names, `upstreams`, `all`. |
| `HEALTH_CHECK_URL` | `https://1.1.1.1/cdn-cgi/trace` | URL(s) for the direct probe, `;`-separated. |

## Volumes

| Mount | Purpose |
|---|---|
| `/etc/wireguard` | **Required.** Server keys, peer directories (keys, addresses, device configs), `peers.conf`, `upstreams/`, map files. Persist it. |
| `/etc/localtime` (read-only) | Optional, for log timestamps. |

## Ports

| Port | Purpose |
|---|---|
| `51820/udp` (`LISTEN_PORT`) | inbound peers |
| `51821/udp`, … (`EXIT_PORT_BASE` upward) | one per dial-in exit node; `docker logs` prints the assigned port |

## Capabilities, devices, sysctls

| Requirement | Why |
|---|---|
| `--cap-add=NET_ADMIN` | interfaces, routes, nftables |
| `--sysctl net.ipv4.ip_forward=1` | forward peer traffic |
| `--sysctl net.ipv6.conf.all.forwarding=1` | only when routing IPv6 |
| `--device /dev/net/tun` | only for the `wireguard-go` fallback on hosts without the kernel module |

`--privileged` works but is not needed.
