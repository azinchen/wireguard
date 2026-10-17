# Gateway Mode - per-peer exits

Each peer leaves the server through one of:

| Exit | How it is named | Example |
|---|---|---|
| **direct** | `direct` (also the default for unmapped peers) | the container's own default route (your ISP) |
| **next-hop gateway** | an IP or DNS name on a Docker network | a [nordvpn-wg](https://github.com/azinchen/nordvpn-wg) / [nordvpn](https://github.com/azinchen/nordvpn) sidecar with `FORWARD_FROM`, an ocserv-server, any router |
| **WireGuard upstream** | `wg:<name>` / an exit node or upstream name | a provider conf (Mullvad, Proton, your VPS) or **another peer** acting as exit node - see [[Exit Nodes and Upstreams]] |
| **block** | `block` | the peer's forwarded traffic is rejected |

```
 alice (gw=nl)   ─► wg0 ─► policy rule ─► table 101: default via 172.28.0.2 (nordvpn-wg) ─► eth0
 bob   (gw=home) ─► wg0 ─► policy rule ─► table 102: default dev wg-home ─────────────────► home router
 carol (unmapped)─► wg0 ─► VPN_GATEWAY (or direct) ───────────────────────────────────────► eth0
```

The server keeps its own default route: only **peer-sourced** packets are policy-routed, so inbound handshakes and the container's own traffic are unaffected (the same reason ocserv-server never replaces the default route).

## Configuration

Named gateways and the default come from the environment, exactly as in ocserv-server:

```yaml
environment:
  - VPN_GATEWAYS=nl=nordvpn-wg,us=172.28.0.4,mullvad=wg    # DNS name, IP, WireGuard upstream
  - VPN_GATEWAY=direct                                     # unmapped peers (default)
  - VPN_GATEWAYS_RESOLVE_INTERVAL=30                       # follow sidecar restarts
```

| Variable | Meaning |
|---|---|
| `VPN_GATEWAY` / `VPN_GATEWAY6` | Default exit for **unmapped** peers: IP / DNS name, `direct`, `block`, or `wg:<name>`. IPv6 defaults to `block` whenever any gateway is configured (no leak); set `VPN_GATEWAY6=direct` to keep IPv6 on the ISP. |
| `VPN_GATEWAYS` / `VPN_GATEWAYS6` | `name=addr` pairs. `addr` is an IP, a DNS name, `block`, `wg` (the exit node / upstream of the same name) or `wg:<other>`. |
| `VPN_GATEWAYS_FILE` | `name ipv4 [ipv6]` lines; merged per field, file wins. |
| `VPN_GATEWAYS_RESOLVE_INTERVAL` | Re-resolve DNS names and upstream endpoints every N seconds; moved addresses are re-routed in place. |
| `VPN_GATEWAY_TABLE`, `VPN_GATEWAY_RULE_PRIO`, `VPN_GATEWAY_PEER_RULE_PRIO` | Table base (`100`; gateways use 101, 102, …) and rule priorities (`1000` subnet default, `900` per peer). |

Exit nodes (`exit=true` peers) and upstream confs are registered as gateways **under their own name** automatically - `VPN_GATEWAYS` is only needed for next-hop gateways or to alias.

## Mapping peers

Either in the peers file (`gw=` option) or with the map variables, which exist for parity with ocserv-server and compose-only setups:

```yaml
  - VPN_PEER_GATEWAY=alice=nl,bob=home,carol=direct
  - VPN_PEER_GATEWAY_FILE=/etc/wireguard/peer-gateway.conf   # "peer gateway" lines; hot-reload
  - VPN_PEER_GATEWAY_WATCH=1
```

Precedence: the `gw=` option in the peers file, then the map file, then `VPN_PEER_GATEWAY`, then the subnet default (`VPN_GATEWAY`). A peer's `allowed=` networks follow the peer.

Because peer addresses are static there is no connect hook: the rules are installed at boot and reconciled by `wg-reload`.

```
$ docker exec wireguard ip rule
900:   from 10.10.10.2 lookup 101      # alice -> nl
900:   from 10.10.10.3 lookup 102      # bob   -> home
900:   from 10.10.10.5 lookup main     # a 'direct' peer when VPN_GATEWAY steers the rest
1000:  from 10.10.10.0/24 lookup 100   # unmapped peers -> VPN_GATEWAY
```

## Kill switch (fail-closed)

The policy routes already force peer traffic to its exit; `table inet wg_gw` makes a leak impossible if a route is ever missing:

| Gateway kind | Guard |
|---|---|
| next-hop IP | `ip saddr @gw_nl_v4 oifname "eth0" rt ip nexthop != 172.28.0.2 drop` - may leave the WAN only toward that next-hop |
| WireGuard upstream / exit node | `ip saddr @gw_home_v4 oifname != { "wg-home", "wg0" } drop` - may leave only through its own tunnel (or to other peers) |
| blocked family | `reject with icmp admin-prohibited` - fails fast, the device falls back to the other family |
| subnet default | the same guard for the whole `VPN_SUBNET` |

| Situation | Result |
|---|---|
| upstream tunnel down | packets have no exit; dropped. **No leak.** |
| sidecar container stopped | its IP does not answer; dropped at this node. **No leak.** |
| policy rule somehow missing | the guard drops instead of falling through to the ISP. **No leak.** |

The forward chain of `table inet wg` is policy **drop** as well; only `wg0 → WAN`, `wg0 → tunnels`, `wg0 → gateway interfaces`, return traffic and (optionally) `wg0 → wg0` are accepted.

## Upstream requirements

A next-hop gateway must forward this container's Docker-network address out its tunnel: peers are **masqueraded** onto this container's address before they reach the gateway, so it needs no route back to `VPN_SUBNET`. With nordvpn / nordvpn-wg that is `FORWARD_FROM=<docker network subnet>`; with ocserv-server, nothing - it masquerades too.

## Verify

```bash
docker exec wireguard network-diagnostic           # exit IP as seen through every gateway table
docker exec wireguard network-diagnostic --explain alice
docker exec wireguard ip rule; docker exec wireguard ip route show table 101
docker exec wireguard nft list table inet wg_gw
```
