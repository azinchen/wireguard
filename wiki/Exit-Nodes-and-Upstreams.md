# Exit Nodes and Upstreams

Both are a second WireGuard interface, `wg-<name>`, whose single peer owns `0.0.0.0/0` (and `::/0` when IPv6 is routed). Any peer can use it with `gw=<name>`, and `LOCAL_GATEWAY=<name>` sends the container's own traffic through it. They differ only in **who writes the config**.

| | Exit node | Upstream conf |
|---|---|---|
| defined by | a peer line with `exit=true` | a file `UPSTREAMS_DIR/<name>.conf` |
| config written by | this image (keys, addresses, port) - you import the result on the exit device | you (a provider download, a VPS you set up) |
| typical remote | your home router, a Raspberry Pi, a VPS, **another container of this image** | Mullvad, Proton, AirVPN, a VPS, another container of this image |
| direction | dial-in (remote behind NAT) or dial-out (`endpoint=`) | as the conf says (`Endpoint` present = dial-out) |

## Exit nodes (`exit=true`)

```
# peers.conf
home   exit=true                                      # dial-in: the router dials us; port auto-assigned
vps    exit=true endpoint=vps.example.com:51820 key=K9f...=   # dial-out; the VPS made its own key
carol  gw=home
dave   gw=vps
```

The image allocates a transfer address pair from `EXIT_SUBNET` (ours / the remote's), a local keypair for our side, and for a dial-in node a UDP listen port (first free from `EXIT_PORT_BASE`, default `LISTEN_PORT+1`, persisted - **publish it**). It brings up `wg-home`, registers gateway `home` with `default dev wg-home` in its own table, and writes the config the exit device imports:

```bash
docker exec wireguard peer-conf home          # or --qr
```

```
# Exit node 'home' - import this on the exit device. It must NAT traffic
# arriving from 10.10.11.3 out its own uplink, e.g. (Linux, replace eth0):
#   iptables -t nat -A POSTROUTING -s 10.10.11.3/32 -o eth0 -j MASQUERADE
#   sysctl -w net.ipv4.ip_forward=1
[Interface]
PrivateKey = <generated, or a placeholder when key= was given>
Address = 10.10.11.2/32

[Peer]
PublicKey = <our wg-home public key>
PresharedKey = ...
AllowedIPs = 10.10.11.3/32
Endpoint = vpn.example.com:51821
PersistentKeepalive = 25
```

What the exit device has to do: import the config, forward, and NAT packets from our transfer address out its uplink. Because this image masquerades peer traffic onto the `wg-home` address, the remote needs **no route to `VPN_SUBNET`** and sees exactly one source address. On OpenWrt / Keenetic / MikroTik this is "add the WireGuard interface to the WAN-NAT zone"; on a Linux box it is the two commented lines.

- **Dial-in** (no `endpoint=`): for a device behind NAT. We listen on the assigned port; the device keeps the tunnel up with `PersistentKeepalive`. Publish the port (`ports: ["51821:51821/udp"]`).
- **Dial-out** (`endpoint=host:port`): for a server with a public address. The device must listen on that port; the generated config has `ListenPort` and no `Endpoint`. Hostnames are re-resolved every `VPN_GATEWAYS_RESOLVE_INTERVAL` seconds and re-set when they move or after `UPSTREAM_HANDSHAKE_TIMEOUT` seconds without a handshake (DDNS).
- `key=<pubkey>` keeps the private key on the device, as for any peer.

Adding or removing an exit node needs a container restart (interface + routing table); changing its key, endpoint or pre-shared key is applied by `wg-reload`.

## Upstream confs (`UPSTREAMS_DIR`)

Drop a standard wg-quick-style file into `/etc/wireguard/upstreams/<name>.conf` - a provider download works untouched:

```
# /etc/wireguard/upstreams/mullvad.conf
[Interface]
PrivateKey = ...
Address = 10.66.123.45/32
DNS = 10.64.0.1

[Peer]
PublicKey = ...
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = se-sto-wg-001.relays.mullvad.net:51820
```

Honoured: `PrivateKey`, `Address`, `ListenPort`, `MTU`, `PublicKey`, `PresharedKey`, `Endpoint`, `AllowedIPs`, `PersistentKeepalive`. **Ignored with a log line:** `DNS`, `Table`, `PreUp/PostUp/PreDown/PostDown` - the image routes by policy (a provider's `0.0.0.0/0` must never become the container's default route) and never executes commands from a downloaded file. The families the peer's `AllowedIPs` cover (and `Address` has) are the families the gateway routes; the rest is blocked for its peers. Only the first `[Peer]` is used. Names: 1-12 characters, letters/digits/`_`/`-`.

The upstream is a gateway named after the file: `gw=mullvad`, `LOCAL_GATEWAY=mullvad`, `VPN_GATEWAY=wg:mullvad`.

## Cascades

To send this node's traffic through **another container of this image**, define this node as an ordinary **peer there** and use its generated config here as an upstream:

```bash
# on node B (the exit)
PEERS=gate-a            # B assigns gate-a an address and generates gate-a.conf
docker exec wireguard-b peer-conf gate-a > a/upstreams/b.conf
# on node A: peers.conf
alice  gw=b             # alice -> A -> B -> internet
```

The direction matters: the **exit side defines the peer** (so it forwards and NATs for it), the **entry side consumes the config as an upstream**. An `exit=true` node on A is the other shape - for a device that *terminates* A's exit traffic (a router with its own NAT), not for another instance of this image.

## Addresses and ports

| Variable | Default | |
|---|---|---|
| `EXIT_SUBNET` / `EXIT_SUBNET6` | `10.10.11.0/24` / `fda9:4efe:7e3b:03eb::/64` | transfer addresses (one pair per exit node, persisted in `peers/<name>/address` and `local.address`) |
| `EXIT_PORT_BASE` | `LISTEN_PORT+1` | first dial-in port; persisted in `peers/<name>/port` |
| `UPSTREAMS_DIR` | `/etc/wireguard/upstreams` | |
| `UPSTREAM_HANDSHAKE_TIMEOUT` | `180` | seconds without a handshake before a dial-out endpoint is re-resolved |

## MTU

`wg0` and every tunnel default to 1420. When a peer's traffic is carried by a WireGuard upstream it is encapsulated twice; TCP is clamped by the forward MSS rules, and `MTU=1340` on `wg0` (1420 − 80) avoids fragmentation for UDP-heavy peers. An upstream conf's own `MTU` is honoured.
