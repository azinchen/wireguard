# Health Monitor

The image bakes in a Docker `HEALTHCHECK` (every 60 s, 15 s timeout, 60 s start period, 3 retries) that runs `/usr/local/bin/healthcheck`. It is **opt-in**: unless `HEALTH_CHECK_ENABLED=true` the probe reports healthy without checking anything.

| Tier | Always / opt-in | Checks |
|---|---|---|
| interface | always | `wg0` exists, `wg show` answers, listening on `LISTEN_PORT` |
| tables | always | `inet wg` (forward/NAT) and `inet wg_gw` (kill switch) present |
| egress | `HEALTH_CHECK_EGRESS` | real HTTPS fetches through routing tables, joined with `+`: `direct`, `default` (the subnet default gateway), gateway names, `upstreams` (handshake no older than `UPSTREAM_HANDSHAKE_TIMEOUT` on every dial-out tunnel), `all` |

```yaml
environment:
  - HEALTH_CHECK_ENABLED=true
  - HEALTH_CHECK_EGRESS=direct+mullvad
```

Egress checks are opt-in on purpose: an upstream being down makes the **container** unhealthy only if you say so. Restart automation reacting to that would restart this container, which cannot fix the upstream and would drop every peer. Gate on the paths whose failure you would act on.

The probe's one-line verdict lands in `docker inspect --format '{{json .State.Health}}'`, so you can see **why** it failed:

```
unhealthy: egress via gateway 'home' (table 101) failed for IPv4
healthy: wg0 up, 5 peer(s), 2 online; egress ok: direct,mullvad
```

Gateway probes use a dedicated fwmark/table/priority (`wg_health` / `0xd1a7` / 791) so a manual `network-diagnostic` run never collides with a probe. `HEALTH_CHECK_URL` (`;`-separated) is used for the direct probe only; gateway probes use `1.1.1.1` by address.
