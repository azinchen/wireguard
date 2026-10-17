# Getting Started

## 1. Requirements

- Docker with `--cap-add=NET_ADMIN` and `--sysctl net.ipv4.ip_forward=1` for the container.
- A host kernel with WireGuard (Linux 5.6+, or the `wireguard` dkms module; load it once with `modprobe wireguard` if it is not auto-loaded). Without it, add `--device /dev/net/tun` and the image falls back to `wireguard-go` automatically.
- UDP port `51820` reachable from your devices (port-forward it on your router / cloud firewall).

## 2. Compose file

```yaml
services:
  wireguard:
    image: azinchen/wireguard:latest
    container_name: wireguard
    restart: unless-stopped
    cap_add: [NET_ADMIN]
    sysctls: [net.ipv4.ip_forward=1]
    ports: ["51820:51820/udp"]
    environment:
      - SERVER_ENDPOINT=vpn.example.com     # DNS name or IP your devices dial (port 51820 implied)
      - PEERS=alice,bob
    volumes:
      - ./volumes/config:/etc/wireguard
```

```bash
docker compose up -d
docker compose logs wireguard
```

The first start generates the server keypair, one keypair + pre-shared key per peer, assigns `10.10.10.2` and `10.10.10.3`, and writes `alice.conf` / `bob.conf` (plus QR PNGs) under `volumes/config/peers/<name>/`. Everything is persisted: restarts, upgrades and added peers never change an existing peer's key or address.

## 3. Connect a device

```bash
docker exec wireguard peer-conf alice --qr      # scan in the WireGuard app
docker exec wireguard peer-conf bob > bob.conf  # import on a laptop / router
```

`SERVER_ENDPOINT` is what ends up in `Endpoint =`. If you leave it unset the configs carry `<SERVER_ENDPOINT>:51820` and the log warns once; fill it in by hand or set the variable.

## 4. Check

```bash
docker exec wireguard peer-report          # state, last handshake, traffic per peer
docker exec wireguard network-diagnostic   # routing, kill switch, exit IP per gateway
```

## 5. Next

- Prefer a file over the `PEERS` variable, with per-peer options (exit, networks behind the peer, DNS, split tunnel): **[[Peers]]**.
- Send peers out through other VPNs or other peers: **[[Gateway Mode]]** and **[[Exit Nodes and Upstreams]]**.
- Use the container as a tunnel for other containers: **[[Sidecar Mode]]**.
