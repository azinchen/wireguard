#!/bin/sh
# Integration test: two nodes of this image chained (A exits through B via a
# generated peer config used as an upstream), a dial-in exit node, a direct
# peer, three sidecar containers consuming A's generated configs, kill switch
# with the upstream down, and a live reload. Needs docker, NET_ADMIN and a
# host with the WireGuard module. Usage: ./run-test.sh [image]  (default wireguard:dev)
set -eu
IMG="${1:-wireguard:dev}"
W="$(mktemp -d)"
trap 'docker rm -f wgt-a wgt-b wgt-c wgt-d wgt-e >/dev/null 2>&1; docker network rm wgtest >/dev/null 2>&1; docker run --rm -v "$W:/x" alpine sh -c "rm -rf /x/*" >/dev/null 2>&1; rmdir "$W" 2>/dev/null' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
run() { docker run -d --network wgtest --cap-add NET_ADMIN --sysctl net.ipv4.ip_forward=1 "$@" "$IMG" >/dev/null; }
fetch() { docker exec "$1" curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://1.1.1.1/cdn-cgi/trace || true; }

docker network create --subnet 172.29.0.0/24 wgtest >/dev/null
mkdir -p "$W/a/upstreams" "$W/b"
run --name wgt-b -e VPN_SUBNET=10.20.20.0/24 -e PEERS=gatea -e SERVER_ENDPOINT=wgt-b -v "$W/b:/etc/wireguard"
sleep 3
docker exec wgt-b peer-conf gatea | grep -v '^#' > "$W/a/upstreams/b.conf"
cat > "$W/a/peers.conf" <<EOP
alice   gw=b
bob
carol   gw=home
home    exit=true
EOP
run --name wgt-a -e VPN_SUBNET=10.10.10.0/24 -e SERVER_ENDPOINT=wgt-a -v "$W/a:/etc/wireguard"
sleep 4
for n in c:alice d:bob e:home; do
    c="${n%%:*}"; p="${n##*:}"; mkdir -p "$W/$c/upstreams"
    docker exec wgt-a peer-conf "$p" | grep -v '^#' > "$W/$c/upstreams/a.conf"
done
i=1; for c in c d e; do run --name wgt-$c -e LOCAL_GATEWAY=a -e VPN_SUBNET=10.99.$i.0/24 -v "$W/$c:/etc/wireguard"; i=$((i + 1)); done
sleep 6

echo "# traffic paths"
b0="$(docker exec wgt-b wg show wg0 transfer | awk '{ print $2 + $3 }')"
[ "$(fetch wgt-c)" = 200 ] || fail "alice (via B) cannot fetch"
b1="$(docker exec wgt-b wg show wg0 transfer | awk '{ print $2 + $3 }')"
[ "$b1" -gt "$((b0 + 1000))" ] || fail "alice's traffic did not cross B"
[ "$(fetch wgt-d)" = 200 ] || fail "bob (direct) cannot fetch"
b2="$(docker exec wgt-b wg show wg0 transfer | awk '{ print $2 + $3 }')"
[ "$b2" -lt "$((b1 + 1000))" ] || fail "bob's traffic crossed B"
[ "$(docker exec wgt-a wg show wg-home latest-handshakes | awk '{ print $2 }')" != 0 ] || fail "dial-in exit node did not handshake"
echo "ok: alice via B, bob direct, exit node handshake"

echo "# kill switch"
docker stop wgt-b >/dev/null
[ "$(fetch wgt-c)" != 200 ] || fail "alice leaked with B down"
[ "$(fetch wgt-d)" = 200 ] || fail "bob broken with B down"
echo "ok: fail-closed"

echo "# reload"
cat > "$W/a/peers.conf" <<EOP
alice   gw=direct
bob     enabled=false
carol   gw=home
dave    gw=b
home    exit=true
EOP
docker exec wgt-a wg-reload >/dev/null
[ "$(fetch wgt-c)" = 200 ] || fail "alice (now direct) cannot fetch"
[ "$(fetch wgt-d)" != 200 ] || fail "disabled bob still passes"
docker exec wgt-a ip rule | grep -q 'from 10.10.10.2 lookup main' || fail "alice rule not direct"
docker exec wgt-a wg show wg0 allowed-ips | grep -q 10.10.10.5 || fail "dave not on wg0"
echo "ok: live reload"

docker start wgt-b >/dev/null; sleep 3
echo "# health"
docker exec -e HEALTH_CHECK_ENABLED=true -e HEALTH_CHECK_EGRESS=direct+b wgt-a healthcheck || fail "healthcheck A"
docker exec -e HEALTH_CHECK_ENABLED=true -e HEALTH_CHECK_EGRESS=all wgt-c healthcheck || fail "healthcheck C"
echo "ALL TESTS PASSED"
