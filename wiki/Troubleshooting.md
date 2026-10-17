# Troubleshooting

## network-diagnostic

Attach its output to any report:

```bash
docker exec wireguard network-diagnostic            # full: config, interfaces, gateways + exit IP per table, peers, routing, nft
docker exec wireguard network-diagnostic --basic    # one line + one per gateway
docker exec wireguard network-diagnostic --json
docker exec wireguard network-diagnostic --explain alice   # which exit alice's traffic takes, and the rules behind it
```

Non-zero exit when a `[warn]` was raised (an unreachable gateway, a stale DNS pin, a missing rule, a down interface).

## The container does not start

Startup is fail-loud: a configuration error stops the container with one `ERROR:` line in `docker logs`. Common ones:

| Log line | Fix |
|---|---|
| `IPv4 forwarding is disabled and /proc/sys is read-only` | add `sysctls: [net.ipv4.ip_forward=1]` |
| `cannot create interface wg0 (load the wireguard module ...)` | `modprobe wireguard` on the host, or add `devices: [/dev/net/tun]` for the `wireguard-go` fallback |
| `invalid peer definitions` | the lines above it name the peer and the option |
| `peer 'x': unknown gateway 'y'` | define `y` in `VPN_GATEWAYS`, as an exit node (`y exit=true`) or as `upstreams/y.conf` |
| `exit node 'x': name must be at most 12 characters` | interface names are limited to 15 characters (`wg-` + name) |
| `GATEWAY_DNS is not supported by this image yet` / `TTL_INC is not supported` | unset them (reserved for a later phase) |

## A device cannot connect

- `docker exec wireguard peer-report`: a peer that never handshakes has the wrong endpoint, a blocked UDP port, or a key mismatch.
- `SERVER_ENDPOINT` unset? The device config then carries `<SERVER_ENDPOINT>:51820`; the log warns at startup.
- Device-made key (`key=`): the config has a placeholder private key; the device must use its own.
- UDP `LISTEN_PORT` (and every dial-in exit port) must be published and port-forwarded.

## A peer connects but has no internet

- `network-diagnostic --explain <peer>` shows the exit and the rules. An exit whose probe says `UNREACHABLE` is down: with the kill switch that is the **expected** result (no leak), fix the upstream.
- Exit node (`exit=true`): the exit device must forward and **NAT** packets from our transfer address (the comment block in its config says how). A handshake alone (`peer-report` says online) is not enough.
- IPv6 "blocked by config": normal when the exit has no IPv6; devices fall back to IPv4. `VPN_GATEWAY6=direct` keeps IPv6 on the ISP for unmapped peers (exposes their real IPv6).
- A `block` reject or a missing `forward` accept: `nft list table inet wg_gw` and `nft list table inet wg`.

## DNS-named gateways and endpoints

A sidecar restarted with a new address, or a DDNS endpoint moved: `network-diagnostic` flags `now resolves to X but routing pins Y`. Set `VPN_GATEWAYS_RESOLVE_INTERVAL=30` or run `docker exec wireguard vpngw-gw-resolve`.

## Reload says nothing changed / rejects the file

`wg-reload` validates everything first and aborts without touching live state on any error - the log says which line. New exit nodes and upstream confs need a restart. With `PEERS_WATCH=1` the watcher only reacts to the watched file's basename; writing a different file in the same directory does nothing.

## Inspecting by hand

```bash
docker exec wireguard wg show                       # all interfaces, handshakes, transfer
docker exec wireguard ip rule; docker exec wireguard ip route show table 101
docker exec wireguard nft list ruleset
docker exec wireguard cat /run/wireguard/peers.def  # the normalized peer records
docker exec wireguard cat /run/wireguard/vpngw/gateways /run/wireguard/vpngw/subnet
```
