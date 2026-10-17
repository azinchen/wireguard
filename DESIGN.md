# Design: WireGuard VPN node in Docker (`azinchen/wireguard`)

Status: **phase 1 implemented (2026-10-17)**, verified by `test/cascade/run-test.sh`; phases 2-3 (§8) pending. Written after reviewing the four sibling
images - **ocserv-server** (the closest analogue: a VPN server with gateway mode,
per-user routing, destination bypass, kill switch), **openconnect-client**
(client-side gateway mode, nft kill switch), **nordvpn** and **nordvpn-wg**
(commercial-VPN sidecars that act as upstream gateways via `FORWARD_FROM`).

The sections are numbered like the shared `ttl-tuning-feature.md` contract. §4
(variables) is the contract that must stay aligned with the siblings; §9 lists
the decisions that still need a call.

---

## 1. Summary

A single Alpine + s6-overlay image that is a **WireGuard node** with two kinds of
tunnel interfaces and one routing policy between them:

```
                        ┌──────────────────────── container ─────────────────────────┐
  peer alice ──┐        │  wg0 (inbound, ListenPort 51820)                            │
  peer bob   ──┼─ UDP ─►│    alice 10.10.10.2 ── gw=direct ──► eth0 ──► ISP           │
  peer home  ──┘        │    bob   10.10.10.3 ── gw=nl ─────► 172.28.0.2 (nordvpn-wg) │
                        │    carol 10.10.10.4 ── gw=mullvad ► wg-mullvad ─► provider  │
                        │    dave  10.10.10.5 ── gw=home ───► wg-home ──► peer "home" │
                        │                                                             │
                        │  wg-mullvad (upstream, Endpoint = provider, we dial out)     │
                        │  wg-home    (upstream, ListenPort 51821, remote dials in)   │
                        └─────────────────────────────────────────────────────────────┘
```

- **wg0** is the server side: inbound peers, each with a static address inside
  `VPN_SUBNET`. Peers are defined declaratively (env and/or a peers file). **A node
  needs nothing but a name**: the image generates its keypair and pre-shared key,
  allocates the next free address from the subnet, writes the client config and QR
  code, and persists all of it on the volume. The one optional input is a
  **predefined public key** (`key=<pubkey>`) when the device made its own keypair;
  then no private key ever exists on the server. The same zero-config rule applies
  to exit nodes (`exit=true`, §4.5).
- **Routing per peer** is source-based policy routing keyed on the peer's static
  address(es), with a fail-closed nftables kill switch - the ocserv-server gateway
  machinery ported almost verbatim. Each peer exits **direct** (the container's own
  default route), via a **next-hop gateway** (an IP or DNS name on a Docker network,
  e.g. a nordvpn / nordvpn-wg sidecar) or via a **WireGuard upstream** (a second
  WireGuard interface whose single peer owns `0.0.0.0/0`: a commercial provider,
  your own VPS, or **another peer that dials in**, such as a home router behind NAT).
- Everything that is a *map* (peers, peer→gateway, peer→bypass pools, pool lists,
  DNS-named gateway addresses, upstream endpoint hostnames) is **hot-reloadable** in
  place: `wg syncconf` for the interface, rule/set reconciliation for routing. No
  session is dropped for a change that does not concern it.

The server has no notion of "username" or "session": a WireGuard peer *is* its
public key, and its address is fixed. That removes the connect/disconnect hook
layer ocserv-server needs (rules are installed at boot and reconciled on reload)
and gives free per-peer accounting (`wg show` transfer counters).

## 2. Background / motivation

- The cascade stack today is ocserv (server) + openconnect-client (client) + two
  NordVPN sidecars. There is no WireGuard server: WireGuard peers (phones, routers
  like Keenetic/OpenWrt/GL.iNet, Mikrotik, other containers) cannot terminate on
  this stack, and a WireGuard-only provider (Mullvad, Proton, AirVPN, an own VPS)
  cannot be used as an upstream exit without a provider-specific sidecar.
- Everything learned on ocserv-server - policy routing instead of a replaced
  default route, next-hop guards, blocked-family rejects, DNS-named gateways,
  per-user maps with live reload, destination bypass, the probe machinery, the
  opt-in health monitor - carries over. The port is mostly a *simplification*
  (static peers instead of dynamic sessions).
- Operators expect the WireGuard conveniences popularised by linuxserver/wireguard
  and wg-easy: `PEERS=alice,bob`, generated client `.conf` + QR code, stable
  addresses across restarts. Those are table stakes for a WireGuard image.

## 3. Goals / non-goals

**Goals**
- Same look and feel as the siblings: Alpine, pinned apk versions, s6-overlay 3.x,
  `backend-functions` with lowercase env copies, `init-*` oneshots and `svc-*`
  longruns, nftables only, fail-loud startup (`S6_BEHAVIOUR_IF_STAGE2_FAILS=2`),
  opt-in `HEALTHCHECK`, `network-diagnostic`, multi-arch CI, wiki in-repo, the same
  workflow set (`ci-build-deploy`, `maintenance-*`, `security-*`, `wiki-publish`).
- Variable contract identical to ocserv-server wherever the semantics are
  identical (`VPN_GATEWAY*`, `VPN_GATEWAYS*`, `VPN_BYPASS_*`, `MSS`, `TTL_SET`,
  `IPV6_*`, `HEALTH_CHECK_*`), with `USER` → `PEER` where ocserv says "user".
- Per-peer control: exit path, extra networks behind the peer, bypass pools, DNS and
  routes pushed in the generated client config, keepalive, enable/disable.
- Three exit kinds for inbound peer traffic: direct, next-hop gateway, WireGuard
  upstream (incl. a peer that dials in). Each fail-closed.
- Hot reload of every map without dropping unrelated tunnels.
- Kernel WireGuard by default, automatic `wireguard-go` fallback when the host has
  no module (same packages nordvpn-wg ships).

**Non-goals (for the first release)**
- No web UI / REST API (wg-easy territory); files and env are the interface.
- No in-container DNS resolver: generated client configs point at `PEER_DNS`
  (default public resolvers), which simply travels the peer's exit path. DNS
  interception à la `GATEWAY_DNS` is phase 3 (§8).
- No dynamic address pools: a peer's address is stable and persisted; that is a
  WireGuard property, not a limitation.
- No `TTL_INC` (reserved, refused if set - same as ocserv-server/openconnect-client).
- Not a replacement for nordvpn-wg: that image's value is the NordVPN API
  (server selection, key fetch, reconnect by load). A static WireGuard provider
  config *is* supported here as an upstream.

## 4. Configuration (environment variables)

Defaults live in `backend-functions` as in every sibling. Grouping follows the
ocserv-server Configuration Reference.

### 4.1 Core networking

| Variable | Default | Meaning |
|---|---|---|
| `VPN_SUBNET` | `10.10.10.0/24` | Peer subnet. The server takes the first host (`.1`); peers are allocated from `.2` upward unless pinned. Masqueraded out `WAN_IF` and every gateway egress interface (as ocserv-server). |
| `LISTEN_PORT` | `51820` | `wg0` UDP listen port (`EXPOSE 51820/udp`). |
| `SERVER_ENDPOINT` | _(unset)_ | `host[:port]` written as `Endpoint` into the generated configs of nodes that dial **us** (inbound peers, dial-in exit nodes). The server itself never uses it. Unset: those configs carry `Endpoint = <SERVER_ENDPOINT>:51820` and one warning is logged; exit nodes we dial (`endpoint=`) never need it. Port defaults to `LISTEN_PORT`. |
| `WAN_IF` | _(auto)_ | Egress interface, auto-detected from the IPv4 default route (ocserv-server logic). |
| `MTU` | `1420` | `wg0` MTU. Lower it when `wg0` traffic is itself carried by a WireGuard upstream (1420 − 80 = 1340); see §5.6. |
| `MSS` | _(unset)_ | TCP MSS clamp, same contract as the siblings (unset = clamp forwarded SYN to `rt mtu`; `536`–`65535` = hard cap). |
| `TTL_SET` | _(unset)_ | TTL / hop-limit rewrite on egress of forwarded peer traffic; same contract. `TTL_INC` reserved/refused. |
| `PEER_TO_PEER` | `true` | Allow forwarding between peers on `wg0` (`false` adds a `wg0 → wg0` drop). |

### 4.2 IPv6

Identical to ocserv-server: `IPV6_FORWARD` (`1`), `IPV6_NAT` (`0`), `IPV6_SUBNET`
(`fda9:4efe:7e3b:03ea::/64`; server `::1`, peers `::2`…). A peer gets an IPv6
address only when `IPV6_SUBNET` is routed (`IPV6_NAT=1` or `VPN_GATEWAY6` set) -
the same "don't hand out a blackhole" rule the ocserv wiki warns about.

### 4.3 Peers (`wg0`)

| Variable | Default | Meaning |
|---|---|---|
| `PEERS` | _(unset)_ | Quick inline list: `alice,bob` (keys generated) or `alice=<pubkey>` (client-side key, nothing private stored). |
| `PEERS_FILE` | `/etc/wireguard/peers.conf` | Peer definitions, one per line (format below). Used when the file exists; merged with `PEERS`, **file wins** on a name. |
| `PEERS_WATCH` | `0` | `1` = run `wg-reload` whenever `PEERS_FILE` changes. |
| `PEER_DNS` | `1.1.1.1,1.0.0.1` | `DNS =` written into generated peer configs (overridable per peer). |
| `PEER_ROUTES` | `0.0.0.0/0,::/0` | Client-side `AllowedIPs` in generated configs (full tunnel). Per-peer `routes=` gives a split tunnel. |
| `PEER_KEEPALIVE` | `25` | `PersistentKeepalive` in generated configs (`0` = off). |

**`peers.conf` format** - whitespace-separated, `#` comments, first token is the
name, the rest are optional `key=value` options:

```
# name    options...
alice                                       # key generated, next free address
bob       key=2xZ...=                       # client-made key: only the pubkey is stored
site-a    ip=10.10.10.30 allowed=192.168.50.0/24   # LAN behind the peer (site-to-site)
carol     gw=mullvad bypass=ru dns=10.10.10.1      # exit + bypass + pushed DNS
tv        gw=us routes=0.0.0.0/0 keepalive=0 enabled=false
```

| Option | Default | Meaning |
|---|---|---|
| `key=auto\|<pubkey>` | `auto` | Generate a keypair on the volume, or use the client's own public key. |
| `psk=auto\|off\|<key>` | `auto` | Pre-shared key (generated and stored, off, or given). |
| `ip=` / `ip6=` | next free | Pin the peer's tunnel address; conflicts fail loudly. |
| `allowed=<cidr>[+cidr]` | – | Extra networks behind the peer: added to the peer's `AllowedIPs`, routed to `wg0`, and included in the peer's policy rules and kill-switch sets. |
| `gw=direct\|block\|<gateway>` | – (unmapped) | Exit path; same values as the `VPN_PEER_GATEWAY` map. File option wins over the map. |
| `bypass=<pool>[+pool]\|none` | – | Destination-bypass pools (phase 2); same values as `VPN_PEER_BYPASS`. |
| `dns=`, `routes=`, `keepalive=` | the `PEER_*` defaults | Per-peer overrides for the generated client config. |
| `enabled=true\|false` | `true` | A disabled peer is removed from `wg0` (keys and address kept). |
| `exit=true\|false` | `false` | The node is an **exit node** (§4.5): it gets its own `wg-<name>` interface and becomes a gateway other peers can name in `gw=`. |
| `endpoint=host[:port]` | – | Exit nodes only: we dial the node (a VPS). Without it the node dials us (home router behind NAT) on an auto-assigned `port=`. |
| `port=` | next free from `LISTEN_PORT+1` | Exit nodes only: UDP port the node dials in on; persisted. |

**Zero-config rule:** every option is optional. `PEERS=alice,home` with
`home exit=true` in the file is a complete, working definition of a client and an
exit node; the image creates everything else and keeps it stable across restarts.
`key=<pubkey>` is the only thing a device-made keypair requires.

Names: letters, digits, `_`, `-`, not starting with `-` (they become nft set names,
interface suffixes and directory names; exit-node names ≤ 12 chars for `wg-<name>`);
`direct`, `block`, `drop`, `none` reserved. The gateway map variables below are
kept for parity and for compose-only setups; the peers file is the single place
where one node is *fully* described.

### 4.4 Gateway mode (per-peer exits)

Identical contract to ocserv-server with `USER` → `PEER`:

| Variable | Default | Meaning |
|---|---|---|
| `VPN_GATEWAY` / `VPN_GATEWAY6` | _(unset)_ | Default exit for **unmapped** peers: IP or DNS name, `direct`, `block` - exactly as ocserv-server (`VPN_GATEWAY6` unset = blocked). **New value:** `wg:<name>` = the WireGuard upstream `<name>` (§4.5). |
| `VPN_GATEWAYS` / `VPN_GATEWAYS6` / `VPN_GATEWAYS_FILE` | _(unset)_ | Named gateways `name=addr`; addr is an IP, a DNS name, `block`, or **`wg`** (shorthand for `wg:<name>`, the upstream config of the same name) / `wg:<other>`. File format `name addr [addr6]` unchanged. |
| `VPN_GATEWAYS_RESOLVE_INTERVAL` | `0` | Re-resolve DNS-named next-hops **and** upstream `Endpoint` hostnames every N seconds; re-route / `wg set endpoint` in place when an address moved. |
| `VPN_PEER_GATEWAY` / `VPN_PEER_GATEWAY_FILE` / `VPN_PEER_GATEWAY_WATCH` | _(unset)_ / `0` | peer → gateway map (`alice=nl,bob=direct`), file `peer gateway` lines; hot-reload via `wg-reload`. Equivalent of `VPN_USER_GATEWAY*`. |
| `VPN_GATEWAY_TABLE` / `VPN_GATEWAY_RULE_PRIO` / `VPN_GATEWAY_PEER_RULE_PRIO` | `100` / `1000` / `900` | Routing table base and rule priorities, as ocserv-server. |

### 4.5 Exit nodes and WireGuard upstreams

Both are a second WireGuard interface `wg-<name>` whose single peer owns
`0.0.0.0/0` / `::/0`, usable as a gateway by name. They differ only in who writes
the config.

**Exit nodes (managed, zero-config)** - a peer line with `exit=true`. The image
generates the keypair (or takes `key=<pubkey>`), allocates a transfer address pair
from `EXIT_SUBNET`, a listen port (dial-in) or uses `endpoint=` (dial-out), creates
`wg-<name>`, and writes the **remote side's config** to
`peers/<name>/<name>.conf` (+ QR): our public key, our endpoint or its listen
port, `AllowedIPs = <our transfer address>/32`, and a commented masquerade hint -
the remote only has to NAT that one address out its own uplink. Other peers use
it with `gw=<name>`; no `VPN_GATEWAYS` entry is needed.

| Variable | Default | Meaning |
|---|---|---|
| `EXIT_SUBNET` | `10.10.11.0/24` | Transfer addresses for exit nodes: each gets a persisted pair (ours / remote). `EXIT_SUBNET6` likewise when IPv6 is routed. |
| `EXIT_PORT_BASE` | `LISTEN_PORT+1` | First UDP port handed to dial-in exit nodes (publish them). |
| `UPSTREAMS_DIR` | `/etc/wireguard/upstreams` | **Bring-your-own** upstreams: one standard wg-quick-style `<name>.conf` (a provider download such as Mullvad/Proton, or a VPS conf you already have). Brought up as `wg-<name>`; referenced as `wg`/`wg:<name>` in `VPN_GATEWAYS` or as `gw=<name>`. |
| `UPSTREAM_HANDSHAKE_TIMEOUT` | `180` | Seconds without a handshake on a dial-out exit/upstream before its endpoint is re-resolved and re-set (DDNS / provider rotation). |

The set of exit nodes and upstreams is fixed at startup like gateway names;
their endpoints re-resolve live. Accepted keys in a bring-your-own conf: `[Interface] PrivateKey, Address, ListenPort, MTU, FwMark`;
`[Peer] PublicKey, PresharedKey, Endpoint, AllowedIPs, PersistentKeepalive`.
`DNS`, `Table`, `PreUp/PostUp/PreDown/PostDown` are **ignored with a log line**:
`Table` is forced off (we route by policy; a provider conf's `0.0.0.0/0` must never
become the container's default route - the same argument as ocserv-server's "why
not just set a default gateway"), and hooks from a downloaded file are never
executed. The peer must own `0.0.0.0/0` and/or `::/0`; the families it owns are
the families the gateway routes (the rest `block`). A managed exit node routes the
families the container itself routes (`IPV6_SUBNET` routed → `::/0` too).

### 4.6 Destination bypass (phase 2)

`VPN_BYPASS_POOLS_DIR` (`/etc/wireguard/pools`), `VPN_GATEWAY_BYPASS`,
`VPN_GATEWAYS_BYPASS`, `VPN_PEER_BYPASS[_FILE|_WATCH]`, `VPN_BYPASS_TARGETS[_FILE]`,
`VPN_BYPASS_WATCH`, `VPN_BYPASS_SOURCES_FILE`, `VPN_BYPASS_UPDATE_INTERVAL`,
`VPN_BYPASS_RULE_PRIO`, `VPN_BYPASS_MARK` - unchanged semantics. A pool target may
also be a `wg` gateway.

### 4.7 Sidecar role (the container's own traffic and other containers)

The same image serves as a generic WireGuard client sidecar, the role nordvpn-wg
and openconnect-client play today: containers started with
`network_mode: service:wireguard` and subnets listed in `FORWARD_FROM` exit through
one exit node / upstream with a fail-closed kill switch. It works with or without
inbound peers on `wg0`.

| Variable | Default | Meaning |
|---|---|---|
| `LOCAL_GATEWAY` | `direct` | Exit for **locally generated** traffic (the container itself and every container sharing its network namespace): `direct`, or the name of an exit node / upstream / `VPN_GATEWAYS` gateway. Anything but `direct` also installs the output-chain kill switch (§5.9). |
| `FORWARD_FROM` / `FORWARD_FROM6` | _(unset)_ | Source CIDRs on the Docker network (other containers with their own netns, LAN hosts) routed through `LOCAL_GATEWAY`; `auto` = the subnets connected to `WAN_IF` (openconnect-client semantics). Requires `LOCAL_GATEWAY` ≠ `direct`. |
| `GATEWAY_NAT6` | `true` | NAT66 for `FORWARD_FROM6` clients (as openconnect-client). |
| `NETWORK` / `NETWORK6` | _(unset)_ | LAN CIDRs the kill switch keeps reachable off-tunnel (as the siblings). |
| `DNS` | `1.1.1.1,1.0.0.1` | Resolvers written to `/etc/resolv.conf` when `LOCAL_GATEWAY` ≠ `direct` (Docker's embedded resolver would leak queries via the host, as nordvpn-wg documents). |
| `GATEWAY_DNS` / `GATEWAY_DNS_SERVER` | `off` | Port-53 interception for `FORWARD_FROM` clients (`redirect`/`local`/`forward`/`off`) - phase 3, same contract as the siblings. |

### 4.8 Health monitor

`HEALTH_CHECK_ENABLED` (`false`), `HEALTH_CHECK_EGRESS` (`direct`, `default`,
gateway names, `all`), `HEALTH_CHECK_URL` - unchanged. Tier 1 becomes "wg0 exists,
listening on `LISTEN_PORT`, `wg show wg0` answers"; tier 2 "nft tables present";
tier 3 the egress probes through each path's routing table (shared probe
machinery, dedicated table/mark/prio). Optional `upstreams` keyword: an
`Endpoint`-type upstream with a handshake older than `UPSTREAM_HANDSHAKE_TIMEOUT`
is unhealthy.

## 5. Behaviour / implementation

### 5.1 Image

- Base `alpine:3.24.x`, pinned apk: `wireguard-tools`, `wireguard-go` (fallback),
  `iproute2-minimal`, `nftables`, `libqrencode-tools` (QR), `bind-tools`
  (`getent`/`dig` for DNS-named gateways), `ca-certificates`, `curl`/`wget` for
  probes and pool fetches. s6-overlay fetched per arch as in the siblings
  (`s6-fetch` stage), `root/` overlay, perms normalised in the `rootfs` stage,
  `IMAGE_VERSION`/`BUILD_DATE` stamped via `safe_sed`.
- `ENTRYPOINT ["/init"]`, `S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0`,
  `S6_BEHAVIOUR_IF_STAGE2_FAILS=2`. `VOLUME /etc/wireguard`. `EXPOSE 51820/udp`.
- Requirements: `cap_add: NET_ADMIN`, `sysctl net.ipv4.ip_forward=1`
  (+ `net.ipv6.conf.all.forwarding=1` if routing IPv6). Kernel WireGuard needs the
  host module loaded (`modprobe wireguard`, built-in on 5.6+; the dev host has it);
  the image cannot load modules and does not ask for `SYS_MODULE`. If
  `ip link add type wireguard` fails, `wireguard-go` is used on `/dev/net/tun`
  (then `devices: /dev/net/tun` is required) and the choice is logged once.
- No `wg-quick`. Interfaces are built with `ip link add` + `wg setconf` +
  `ip addr add` + `ip link set up`; reloads use `wg syncconf` (only changed peers
  are touched). wg-quick's implicit default-route takeover, `resolvconf` and
  `sysctl` side effects are exactly what a multi-interface router must not have.

### 5.2 Volume layout

```
/etc/wireguard/
├── server/privatekey, publickey        generated once (0600)
├── peers.conf                          PEERS_FILE (optional)
├── peers/<name>/
│   ├── publickey                       always
│   ├── privatekey, presharedkey        only when generated (0600)
│   ├── address                         "10.10.10.2 fda9:...::2" - persisted so peers never renumber
│   ├── port                            exit nodes (dial-in): persisted listen port
│   └── <name>.conf, <name>.png         generated config + QR for the device (client or exit remote; rewritten on reload)
├── upstreams/<name>.conf               bring-your-own WireGuard upstreams (provider confs)
├── vpngw/                              suggested home for gateways / peer-gateway map files
└── pools/                              destination-bypass lists (phase 2)
/run/wireguard/
├── wg0.conf, wg-<name>.conf            generated interface configs (never on the volume)
└── vpngw/                              routing state: gateways, gateways.src, peers, subnet, bypass_* (ocserv layout)
```

A peer removed from `PEERS`/`peers.conf` leaves `wg0` but keeps its directory, so
re-adding it restores the same key and address. Address allocation is "lowest free
host in `VPN_SUBNET`", skipping the server, pinned and persisted addresses; a pin
colliding with a persisted address fails startup.

### 5.3 Service graph

```
init-env ─► init-nat ─► init-upstreams ─► init-vpngw ─► svc-wireguard (longrun)
                                                        svc-peer-watch, svc-vpngw-watch,
                                                        svc-vpngw-gw-resolve, svc-bypass-* (idle unless enabled)
```

- **init-env** - validate every variable (enums, numbers, name charsets), parse
  `PEERS` + `peers.conf`, resolve the peer set (keys, addresses), generate missing
  server/peer keys, write `/run/wireguard/wg0.conf` and the peer client configs.
  Any error aborts the start with one clear line.
- **init-nat** - forwarding sysctls; `table inet wg` (forward accepts `wg0 → WAN`,
  `wg0 → <gw egress if>`, `wg0 → wg-<up>`, return paths `established,related`,
  optional `wg0 → wg0`; masquerade `VPN_SUBNET` on `WAN_IF`, on every next-hop
  gateway's egress interface and on every `wg-<up>`), `inet wg_mss`, `inet wg_ttl`
  - the ocserv-server `init-nat` with the tunnel match `wg0` and upstreams added
  to the egress list.
- **init-upstreams** - for each exit node (`exit=true`, config generated by
  `init-env`) and each `UPSTREAMS_DIR/<name>.conf` (sanitised, §4.5): create
  `wg-<name>`, `wg setconf`, address, MTU, up; resolve `Endpoint` hostnames
  (recorded in `gateways.src` for the resolver). No routes in `main`. Exit nodes
  and upstreams are registered as named gateways with an interface next-hop.
- **init-vpngw** - ocserv-server's `init-vpngw` with two changes: (1) a gateway
  may be an *interface* (`wg:<name>` → `ip route replace default dev wg-<name>
  table N`) as well as a next-hop IP; (2) there is no connect hook: the per-peer
  policy rules and kill-switch set entries are installed **here**, at boot, for
  every mapped peer (from the peer's address and `allowed=` networks). The
  destination-bypass source sets are filled the same way (phase 2).
- **svc-wireguard** - creates `wg0` from `/run/wireguard/wg0.conf`, adds the
  server address and the `allowed=` routes, brings it up, then blocks. `SIGHUP`
  (`s6-svc -h`) runs `wg-reload`; `finish` tears the interfaces down. The kill
  switch and NAT exist before `wg0` does (fail-closed by construction).
- **Watchers** - `svc-peer-watch` (`PEERS_WATCH`), `svc-vpngw-watch`
  (`VPN_PEER_GATEWAY_WATCH`, `VPN_PEER_BYPASS_WATCH`), `svc-vpngw-gw-resolve`
  (`VPN_GATEWAYS_RESOLVE_INTERVAL`, now also upstream endpoints + handshake
  watchdog), `svc-bypass-watch`, `svc-bypass-fetch`. All `inotifyd`/sleep loops
  that idle when disabled, as today.

### 5.4 Routing model (per peer)

Unchanged from ocserv-server, with a session replaced by a peer's address set:

```
ip rule  900: from 10.10.10.3        lookup 101      # bob    -> nl      (next-hop table)
ip rule  900: from 10.10.10.4        lookup 102      # carol  -> mullvad (default dev wg-mullvad)
ip rule  900: from 10.10.10.30       lookup 103      # site-a -> home
ip rule  900: from 192.168.50.0/24   lookup 103      #   ...and the LAN behind it
ip rule  900: from 10.10.10.2        lookup main     # alice  -> direct
ip rule 1000: from 10.10.10.0/24     lookup 100      # unmapped -> VPN_GATEWAY
```

Kill switch `table inet wg_gw` (forward hook, priority −10), rules in this order:
bypass fwmarks (phase 2) → per-gateway guards → direct/block sets → subnet default.
Per gateway kind:

| Gateway kind | Route in its table | Guard |
|---|---|---|
| next-hop IP (sidecar) | `default via <ip>` | `ip saddr @gw_<n>_v4 oifname "<egress if>" rt ip nexthop != <ip> drop` (as ocserv) |
| `wg:<name>` upstream | `default dev wg-<name>` | `iifname "wg0" ip saddr @gw_<n>_v4 oifname != { "wg-<name>", "wg0" } drop` - the interface *is* the guard: anything leaving that interface is encrypted to that one peer |
| `direct` | `main` | accept set, no guard (as ocserv) |
| `block` (per family) | none | `reject with icmp(x) admin-prohibited` |

Sets use `flags interval` so a peer's `allowed=` networks are members too.

**Why one interface per WireGuard upstream.** Cryptokey routing is by destination:
on a given interface only one peer can own `0.0.0.0/0`. A second exit peer on
`wg0` is impossible, and a single exit peer on `wg0` would silently receive every
destination `wg0` is handed. A dedicated `wg-<name>` per exit makes every upstream
uniform (a routing table with `default dev`), keeps `wg0` purely for inbound
peers, and lets the kill switch key on the interface instead of a next-hop.

**"Route to another peer".** The exit node is a peer line with `exit=true`. Its
remote side may be (a) a device that dials us (home router behind NAT; the image
picks a listen port, the generated remote config carries our endpoint), or (b) a
server we dial (`endpoint=vps.example.com:51820`). Either way the remote config
has `AllowedIPs = <our transfer address>/32` and NATs that address out its own
uplink; because we masquerade onto the `wg-<name>` address, the remote needs no
route to `VPN_SUBNET`. With `key=<pubkey>` the remote keeps its own private key
and the generated config carries a placeholder for it. Another container of this
image can be the remote: it consumes the generated config as a bring-your-own
upstream, which is how cascades are built.

### 5.5 Reload

`wg-reload` (manual via `docker exec`, or from the watchers), serialised by a
flock, all-or-nothing:

1. Re-parse `PEERS` + `peers.conf` + the maps; validate fully (names, keys,
   address conflicts, unknown gateways/pools). Any error → abort, nothing touched.
2. Allocate/persist addresses and generate keys for new peers.
3. Write a new `/run/wireguard/wg0.conf`; `wg syncconf wg0` - unchanged peers keep
   their handshake and traffic; added/removed/changed peers are the only diff.
4. Reconcile `allowed=` routes, per-peer policy rules and kill-switch/bypass set
   membership against the recorded state (`/run/wireguard/vpngw/peers`), the same
   diff logic as `vpngw-reload` today, minus the session records.
5. Regenerate client configs/QR for peers whose derived config changed.

The set of named gateways and upstreams is startup-only (tables and interfaces are
created at boot), their addresses/endpoints are live - exactly the ocserv rule.

### 5.6 MTU and MSS

`wg0` defaults to 1420. When a peer's traffic is carried by a WireGuard upstream
the inner packet is encapsulated twice; the forward MSS clamp (`rt mtu`, as in
the siblings) handles TCP, and `MTU` lets the operator lower `wg0` for UDP-heavy
peers. Upstream interfaces honour their conf's `MTU` (default 1420). Document the
cascade recommendation in the wiki, don't auto-tune.

### 5.7 Operator commands

| Command | Role (sibling equivalent) |
|---|---|
| `wg-reload` | reload peers + maps in place (`vpngw-reload`) |
| `peer-conf <name> [--qr]` | print a peer's client config / QR in the terminal |
| `peer-report [--json]` | per peer: address, gateway, endpoint, last handshake, rx/tx (from `wg show dump`), online/offline (`session-report`) |
| `network-diagnostic` | routing/kill-switch state, exit IP per gateway table (same probe machinery) |
| `vpngw-gw-resolve` | force one re-resolve pass |
| `bypass-reload`, `bypass-fetch` | phase 2, unchanged |
| `healthcheck` | the `HEALTHCHECK` probe |

### 5.8 Sidecar role: local traffic and the output kill switch

`LOCAL_GATEWAY=<name>` reuses the gateway table built for `<name>` and adds one
policy rule for locally generated traffic:

```
ip rule 1100: from all iif lo not fwmark 0xca6c lookup <table of name>
```

Every WireGuard interface the image creates carries `FwMark = 0xca6c`
(`WG_FWMARK`, overridable), so WireGuard's own encrypted UDP - inbound peers'
handshakes and replies on `wg0`, the upstream's packets to its endpoint - is
excluded from the rule and keeps leaving via `eth0`. This is wg-quick's own
mechanism, done explicitly. Unmapped peer traffic is not affected: with
`VPN_GATEWAY` direct/unset an explicit `from VPN_SUBNET lookup main` rule at
priority 1000 keeps it on the ISP; `FORWARD_FROM` CIDRs get `from <cidr> lookup
<table>` rules at 900, i.e. they behave like peers mapped to `LOCAL_GATEWAY`.

The kill switch grows an **output** chain (`table inet wg_gw`, policy drop) only
in this mode: accept `lo`, `oifname "wg-*"`/`wg0`, `ct established,related`,
`meta mark 0xca6c udp` toward the configured endpoints (`@endpoint4/6` sets,
refreshed on re-resolve), ICMPv6 neighbour discovery, `@lan4/@lan6`
(`NETWORK*`), and DNS to Docker's embedded resolver on `lo` during bootstrap.
Forward rules for `FORWARD_FROM` mirror openconnect-client's `gateway setup`
(sets `gw_clients4/6`, masquerade on the exit interface, MSS clamp). Resolving an
upstream's `Endpoint` hostname before its tunnel is up goes through the embedded
resolver on `lo`, so no eth0 DNS pinhole is needed.

### 5.9 Security notes

- Private keys only exist on the volume for peers the image generated; the
  documented best practice is `key=<pubkey>` with keys made on the device.
- Upstream confs are untrusted input: hooks never run, `Table`/`DNS` ignored,
  unknown keys rejected with a line number.
- Kill switch, NAT and policy rules are installed before any interface comes up;
  a startup error leaves no half-routed state (`S6_BEHAVIOUR_IF_STAGE2_FAILS=2`).
- No input-chain policy on `wg0`/`eth0` beyond Docker's port publishing, matching
  ocserv-server (a server image); `PEER_TO_PEER=false` is the only isolation knob.

## 6. Mapping from ocserv-server

| ocserv-server | here | note |
|---|---|---|
| `ocserv.conf` (user-owned) | generated `/run/wireguard/wg0.conf` | peers are data, not a hand-edited daemon config |
| `ocpasswd` user | peer (`PEERS`/`peers.conf`) | identity = public key |
| session (dynamic IP, connect hook) | peer address (static) | rules at boot + reload, no hook |
| `VPN_USER_GATEWAY*`, `VPN_USER_BYPASS*` | `VPN_PEER_GATEWAY*`, `VPN_PEER_BYPASS*` | plus `gw=`/`bypass=` in `peers.conf` |
| `vpns+` tunnel pattern (`VPN_IF`) | `wg0` fixed | |
| `VPN_GATEWAYS` value: IP/DNS/`block` | + `wg`/`wg:<name>` | WireGuard upstream as a gateway |
| `vpngw-reload` | `wg-reload` | also syncs peers into the interface |
| `session-report` | `peer-report` | counters come from WireGuard itself |
| `cert-reload` / SWAG | – | no TLS |
| camouflage | – | WireGuard has no cover protocol |
| nft tables `ocserv*` | `wg`, `wg_mss`, `wg_ttl`, `wg_gw`, `wg_bypass` | |

## 7. Example deployments

**Plain server, two peers, one behind NAT as a site:**
```yaml
services:
  wireguard:
    image: azinchen/wireguard:latest
    cap_add: [NET_ADMIN]
    sysctls: [net.ipv4.ip_forward=1]
    ports: ["51820:51820/udp"]
    environment:
      - SERVER_ENDPOINT=vpn.example.com
      - PEERS=alice,bob
    volumes: [./volumes/config:/etc/wireguard]
```
`docker exec wireguard peer-conf alice --qr` → scan on the phone.

**Per-peer exits: NordVPN sidecar, a Mullvad upstream, a home router that dials in:**
```yaml
    environment:
      - SERVER_ENDPOINT=vpn.example.com
      - PEERS_FILE=/etc/wireguard/peers.conf
      - PEERS_WATCH=1
      - VPN_GATEWAYS=nl=nordvpn-wg,mullvad=wg             # DNS name + provider conf
      - VPN_GATEWAYS_RESOLVE_INTERVAL=30
      - VPN_GATEWAY=direct                                # unmapped peers -> ISP
    ports: ["51820:51820/udp", "51821:51821/udp"]         # 51821 = home dials in
```
```
# /etc/wireguard/peers.conf
alice   gw=nl
bob     gw=mullvad
carol   gw=home
site-a  gw=direct allowed=192.168.50.0/24
home    exit=true                       # everything generated; port 51821 assigned
vps     exit=true endpoint=vps.example.com:51820 key=K9f...=   # we dial; VPS made its own key
```
`upstreams/mullvad.conf` is the provider's download untouched. `peer-conf home --qr`
prints the config the home router imports; `peer-conf vps` prints the one for the
VPS (with a private-key placeholder, since the VPS keeps its own).

## 8. Phases

1. **Core** - image + CI skeleton copied from openconnect-client/ocserv-server;
   zero-config nodes (env + file, keys, addresses, client conf + QR, predefined
   public keys); `init-nat` (NAT, MSS, TTL_SET); gateway mode with next-hop
   gateways, **managed exit nodes** (dial-in and dial-out, remote config
   generated) and bring-your-own upstream confs; per-peer map, kill switch,
   `wg-reload` + watchers, DNS/endpoint re-resolve; `peer-report`,
   `network-diagnostic`, `healthcheck`; **sidecar role** (`LOCAL_GATEWAY`,
   `FORWARD_FROM*`, output kill switch, `DNS`, `NETWORK*`); README + wiki (Getting
   Started, Peers, Gateway Mode, Exit Nodes and Upstreams, Sidecar Mode,
   Configuration Reference, Architecture, Troubleshooting).
2. **Destination bypass** (port as-is, exit nodes/upstreams as targets).
3. **DNS interception** - `GATEWAY_DNS` for `FORWARD_FROM` clients and for peers
   on `wg0` (per-peer resolver DNAT), same contract as the siblings.

## 9. Decisions (resolved 2026-10-16)

1. **Repo/image name:** `azinchen/wireguard`.
2. **Peer definition:** `peers.conf` with `name [key=value…]`, every option
   optional: a bare name is a complete node, `key=<pubkey>` for device-made keys,
   `exit=true` for exit nodes; the ocserv-style maps stay for parity (file wins).
3. **No wg-quick:** interfaces are built with `ip` + `wg setconf/syncconf`;
   wg-quick's fwmark/policy trick is reproduced explicitly (§5.8).
4. **One interface per exit node / upstream** (the single-exit-peer-on-`wg0`
   shortcut is rejected: at most one exit, and it silently absorbs every unknown
   destination).
5. **Sidecar role is in phase 1** (`LOCAL_GATEWAY`, `FORWARD_FROM*`, output kill
   switch).
6. **`SERVER_ENDPOINT` is optional:** the server never uses it; unset, the
   generated configs of nodes that dial us carry a placeholder and a warning is
   logged.
7. **License:** MIT.
