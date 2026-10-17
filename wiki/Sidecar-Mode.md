# Sidecar Mode - a tunnel for other containers

With `LOCAL_GATEWAY=<exit>` the container's **own** traffic - and therefore every container started with `network_mode: service:wireguard` - leaves through that exit, and an **output kill switch** (policy drop) makes sure nothing leaves any other way. This is the role nordvpn-wg and openconnect-client play, with a generic WireGuard upstream (a provider conf, your VPS, or a peer config from another instance of this image) as the tunnel. Inbound peers on `wg0` are optional in this mode.

```yaml
services:
  wireguard:
    image: azinchen/wireguard:latest
    cap_add: [NET_ADMIN]
    sysctls: [net.ipv4.ip_forward=1]
    environment:
      - LOCAL_GATEWAY=mullvad              # upstreams/mullvad.conf
      - NETWORK=192.168.1.0/24             # LAN stays reachable off-tunnel (optional)
    volumes:
      - ./volumes/config:/etc/wireguard
  torrent:
    image: ...
    network_mode: service:wireguard        # shares the tunnel and the kill switch
```

Containers with their own network namespace, or LAN hosts, can be routed too:

```yaml
      - LOCAL_GATEWAY=mullvad
      - FORWARD_FROM=auto                  # every subnet on the Docker network, or explicit CIDRs
```

`FORWARD_FROM` clients point their default route at this container's address and get the same guard as a peer mapped to that gateway.

## How it works

- Every WireGuard socket the image creates carries the fwmark `WG_FWMARK` (`0xca6c`). One policy rule, `iif lo not fwmark 0xca6c lookup <table>`, steers locally generated traffic into the exit's routing table while WireGuard's own encrypted UDP keeps leaving via `eth0` - wg-quick's mechanism, done explicitly.
- `table inet wg_gw` gains **output** and **input** chains with policy drop: accepted are `lo`, the tunnels, established flows, WireGuard's fwmarked UDP, DNS to the resolvers Docker configured (bootstrap, see below), neighbour discovery, the `LISTEN_PORT`/exit-node ports inbound, and `NETWORK`/`NETWORK6`.
- `/etc/resolv.conf` is rewritten to `DNS` (default `1.1.1.1,1.0.0.1`), reached through the tunnel. Docker's embedded resolver would forward queries via the host, outside the tunnel. Hostnames in upstream `Endpoint`s are resolved through the resolvers Docker gave the container (saved before the rewrite), because that has to work before any tunnel exists; this is the only DNS that leaves off-tunnel.
- Unmapped `wg0` peers are pinned to the main table explicitly, so the local rule does not swallow them.

| Variable | Default | |
|---|---|---|
| `LOCAL_GATEWAY` | `direct` | exit for local traffic: an exit node, an upstream, or a `VPN_GATEWAYS` name |
| `FORWARD_FROM` / `FORWARD_FROM6` | – | CIDRs (or `auto`) routed through `LOCAL_GATEWAY` |
| `GATEWAY_NAT6` | `true` | NAT66 for those clients |
| `NETWORK` / `NETWORK6` | – | LAN CIDRs kept reachable off-tunnel |
| `DNS` | `1.1.1.1,1.0.0.1` | resolvers for `resolv.conf` |
| `WG_FWMARK` | `0xca6c` | fwmark on WireGuard sockets (change only on a collision) |
| `LOCAL_GATEWAY_RULE_PRIO` | `1100` | priority of the local rule |

`GATEWAY_DNS` interception (as in the sibling images) is not implemented yet and is refused if set.

## Verify

```bash
docker exec wireguard curl -s https://1.1.1.1/cdn-cgi/trace | grep ^ip=   # the upstream's exit IP
docker exec -e HEALTH_CHECK_ENABLED=true -e HEALTH_CHECK_EGRESS=all wireguard healthcheck
docker exec wireguard nft list chain inet wg_gw output
```

Stop the upstream and the fetch fails instead of showing your real address.
