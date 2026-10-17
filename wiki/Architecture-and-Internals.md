# Architecture and Internals

## Stack

| Layer | What |
|---|---|
| Base | Alpine Linux, pinned apk versions |
| Init / supervisor | s6-overlay |
| VPN | WireGuard: the kernel module through `wg` (`wireguard-tools-wg`), `wireguard-go` as fallback |
| Firewall / routing | nftables, iproute2 policy routing. No wg-quick. |

## Multi-stage build

1. **`s6-fetch`** - downloads the architecture-appropriate s6-overlay tarballs.
2. **`rootfs`** - assembles `root/` (services, scripts) + s6; normalizes permissions; stamps the image version into `backend-functions`.
3. **Final** - Alpine + runtime packages, one `COPY` of the rootfs, `ENTRYPOINT ["/init"]`, `S6_BEHAVIOUR_IF_STAGE2_FAILS=2` so a failed init oneshot aborts the container (fail-closed).

## Startup: the s6 service graph

```
init-env ─► init-nat ─► init-upstreams ─► init-vpngw ─► svc-wireguard (longrun)
                                                         svc-peer-watch · svc-vpngw-watch · svc-vpngw-gw-resolve (idle unless enabled)
```

| Service | Does |
|---|---|
| **init-env** | validates every variable; IPv6 availability; generates the server keypair; parses `PEERS` + `peers.conf` into normalized records (`/run/wireguard/peers.def`), generating keys and allocating/persisting addresses and exit-node ports; writes device configs + QR; in sidecar mode saves Docker's `resolv.conf` and rewrites it to `DNS`. |
| **init-nat** | forwarding sysctls; `table inet wg`: forward chain (policy drop; `wg0 → WAN`, `wg0 → wg-*`, `wg0 → gateway egress interfaces`, return traffic, `wg0 → wg0`, sidecar clients) and masquerade (`VPN_SUBNET` on the WAN and gateway interfaces, everything entering a `wg-*` tunnel); `inet wg_mss` (MSS clamp); `inet wg_ttl` (`TTL_SET`). |
| **init-upstreams** | brings up `wg-<name>` for every exit node (config generated from the record) and every `UPSTREAMS_DIR/*.conf` (sanitised); resolves `Endpoint` hostnames; records each interface's families in `/run/wireguard/ifaces/`. |
| **init-vpngw** | named gateways → routing tables (`default via <ip>` or `default dev wg-<name>`); peer map; subnet default; `LOCAL_GATEWAY` rule; kill switch `inet wg_gw`; per-peer policy rules and set membership. State in `/run/wireguard/vpngw/`. |
| **svc-wireguard** | creates `wg0` (`ip link add` + `wg setconf`), adds the server address and `allowed=` routes, then blocks; `SIGHUP` → `wg-reload`; `finish` removes `wg0`. |
| **watchers** | `inotifyd` on the peers file / map file (`PEERS_WATCH`, `VPN_PEER_GATEWAY_WATCH`); the resolver loop (`VPN_GATEWAYS_RESOLVE_INTERVAL`). |

## Why no wg-quick

wg-quick owns the default route (its fwmark + `suppress_prefixlength` trick), edits `resolv.conf`, runs hooks from the conf and needs bash. A node with several tunnels and policy routing needs none of that and must not have a provider conf take over its default route. The image uses `ip` + `wg setconf` to create interfaces and `wg syncconf` to reload peers without touching unchanged ones; the single piece of wg-quick behaviour it keeps - fwmarking WireGuard's own sockets so they are never routed into a tunnel - is explicit (`WG_FWMARK`).

## Routing model

Source policy routing keyed on peer addresses (static, so installed at boot and reconciled on reload - no connect hook as in ocserv-server):

- rule prio `900`: one `from <cidr> lookup <table>` per address of a mapped peer (its `/32` and every `allowed=` network); `direct` → `main`
- rule prio `1000`: `from VPN_SUBNET lookup 100` for the subnet default (or `lookup main` in sidecar mode)
- rule prio `1100`: `iif lo not fwmark 0xca6c lookup <table>` for `LOCAL_GATEWAY`
- tables `101, 102, …`: one per named gateway, `default via <next-hop>` or `default dev wg-<name>`

Kill switch `inet wg_gw` (forward hook, priority −10): per-gateway guards (next-hop guard or interface guard), `direct`/`block` sets, the subnet default guard; in sidecar mode also `output`/`input` chains with policy drop.

## Filesystem map

| Path | Role |
|---|---|
| `/etc/wireguard/` (volume) | `server/` keys, `peers.conf`, `peers/<name>/` (keys, address, device config, QR), `upstreams/`, optional map files |
| `/run/wireguard/` | generated interface configs (`wg0.conf`, `wg-<name>.conf`), `peers.def` / `peers.applied` (normalized records), `ifaces/` (tunnel capabilities, endpoints), `vpngw/` (gateways, subnet, local, applied rules) |
| `/usr/local/bin/` | `backend-functions` (shared env + helpers), `wg-reload`, `peer-conf`, `peer-report`, `network-diagnostic`, `healthcheck`, `vpngw-gw-resolve` |

## Shared contract with the sibling images

`VPN_GATEWAY*`, `VPN_GATEWAYS*`, `MSS`, `TTL_SET`, `IPV6_*`, `HEALTH_CHECK_*`, `FORWARD_FROM*`, `NETWORK*`, `DNS` keep the semantics they have in ocserv-server, openconnect-client and nordvpn-wg; `VPN_USER_*` becomes `VPN_PEER_*`. `TTL_INC` and `GATEWAY_DNS` are reserved and refused.
