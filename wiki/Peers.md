# Peers

A **node** (peer) is one line. Nothing is required but a name: the image generates the keypair and pre-shared key, allocates the next free address from `VPN_SUBNET`, writes the device config and QR code, and persists all of it on the volume. The only optional input most people ever add is a **predefined public key** when the device made its own keypair.

## Where peers are defined

| Source | Form | Notes |
|---|---|---|
| `PEERS` (env) | `alice,bob` or `bob=<pubkey>` | quick, compose-only setups |
| `PEERS_FILE` (default `/etc/wireguard/peers.conf`) | one `name [option=value ...]` per line, `#` comments | the full per-peer description; used when the file exists |

Both are merged; on the same name the **file wins**. Names: letters, digits, `_`, `-` (not starting with `-`); `direct`, `block`, `drop`, `none`, `all`, `default`, `main` are reserved. Exit-node names are at most 12 characters (interface `wg-<name>`).

## Options

```
# volumes/config/peers.conf
alice                                      # key generated, next free address
bob     key=2xZ...=                        # device-made key: only the public key is stored
site-a  ip=10.10.10.30 allowed=192.168.50.0/24    # LAN behind the peer (site-to-site)
carol   gw=mullvad dns=10.10.10.1          # exit + DNS pushed to the device
tv      gw=us routes=0.0.0.0/0 keepalive=0 enabled=false
home    exit=true                          # exit node (see Exit Nodes and Upstreams)
```

| Option | Default | Meaning |
|---|---|---|
| `key=auto\|<pubkey>` | `auto` | Generate a keypair on the volume, or use the device's public key (44 chars). With a predefined key no private key exists on the server; the generated config carries a placeholder for it. |
| `psk=auto\|off\|<key>` | `auto` | Pre-shared key: generated and stored, off, or given. |
| `ip=` / `ip6=` | next free | Pin the tunnel address. A pin colliding with another peer's persisted address fails startup. |
| `allowed=<cidr>[+cidr]` | – | Networks behind the peer: added to its `AllowedIPs`, routed to `wg0`, and included in its policy rules and kill-switch sets. |
| `gw=direct\|block\|<gateway>` | – (unmapped) | Exit path: see [[Gateway Mode]]. Wins over the `VPN_PEER_GATEWAY` map. |
| `dns=<ip>[+ip]` | `PEER_DNS` | `DNS =` in the device config. Resolvers are reached through the peer's exit like any other traffic. |
| `routes=<cidr>[+cidr]` | `PEER_ROUTES` (`0.0.0.0/0,::/0`) | Device-side `AllowedIPs`: what the device sends into the tunnel. Narrow it for a split tunnel, e.g. `routes=10.10.10.0/24+192.168.50.0/24`. |
| `keepalive=<n>` | `PEER_KEEPALIVE` (`25`) | `PersistentKeepalive` in the device config; `0` = off. |
| `enabled=true\|false` | `true` | A disabled peer is removed from `wg0`; its keys and address are kept. |
| `exit=true` | `false` | The node is an exit node ([[Exit Nodes and Upstreams]]). |
| `endpoint=host[:port]`, `port=` | – | Exit nodes only: dial-out endpoint, or dial-in listen port (auto-assigned from `EXIT_PORT_BASE`). |

Lists use `+` as separator because `,` separates variables in compose and `;` is a shell character.

## What is stored

```
/etc/wireguard/
├── server/privatekey, publickey     generated once
├── peers.conf                       your definitions (optional)
└── peers/<name>/
    ├── publickey                    always
    ├── privatekey, presharedkey     only when generated (mode 0600)
    ├── address                      the persisted IPv4 (and a pinned IPv6)
    ├── <name>.conf, <name>.png      the device config + QR (derived; rewritten on change)
    └── local.*, port                exit nodes: our side of the link and the listen port
```

A peer removed from the definitions leaves `wg0` but keeps its directory, so re-adding it restores the same key and address. Address allocation is "lowest free host", skipping the server, every persisted address and every pin - nobody is ever renumbered.

## Device configs

```bash
docker exec wireguard peer-conf alice           # print
docker exec wireguard peer-conf alice --qr      # QR in the terminal
docker exec wireguard peer-conf --list          # all nodes
```

The generated config is a standard WireGuard file:

```
[Interface]
PrivateKey = <generated, or a placeholder when key= was given>
Address = 10.10.10.2/32
DNS = 1.1.1.1, 1.0.0.1

[Peer]
PublicKey = <server public key>
PresharedKey = <generated>
Endpoint = vpn.example.com:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

IPv6: a peer gets an IPv6 address (`IPV6_SUBNET`, derived from its IPv4 host number) only when IPv6 is actually routed (`IPV6_NAT=1`, or a gateway that carries IPv6). Handing out an address without a route would only blackhole the device's IPv6.

## Hot reload

Edit the peers file (or the `VPN_PEER_GATEWAY_FILE` map) and apply it without restarting:

```bash
docker exec wireguard wg-reload
```

or set `PEERS_WATCH=1` to apply on every save. The reload is all-or-nothing: the new definitions are validated in full first, then the peer list is synced into `wg0` with `wg syncconf` (peers that did not change keep their handshake), routes for `allowed=` networks are added/removed, policy rules and kill-switch membership are reconciled, and device configs regenerated.

Not reloadable: **adding** an exit node or an upstream conf (their interfaces and routing tables are created at boot - restart the container). Changing an existing exit node's key or endpoint is applied live.

Edit the file atomically (write a temp file, then `mv` over it) when a watcher is on, so a reload never reads a half-written file; editors do this by default.
