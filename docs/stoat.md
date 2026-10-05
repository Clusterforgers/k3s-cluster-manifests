# Stoat chat

[Stoat](https://stoat.chat) (formerly Revolt), served at
<https://stoat.hivemindcloud.dk>, deployed from `apps/stoat/`. Upstream only
ships a docker-compose setup ([stoatchat/self-hosted](https://github.com/stoatchat/self-hosted));
the chart is a hand translation of its `compose.yml`, `Caddyfile` and
`generate_config.sh`. All of it runs on `queen`, in namespace `stoat`.

## How it's wired

```
internet ─▶ nginx ingress (queen:443, TLS) ─▶ caddy:80 ─┬─ /api      ─▶ api:14702
                                                        ├─ /ws       ─▶ events:14703
                                                        ├─ /autumn   ─▶ autumn:14704 ─▶ minio
                                                        ├─ /january  ─▶ january:14705
                                                        ├─ /gifbox   ─▶ gifbox:14706
                                                        ├─ /livekit  ─▶ livekit:7880
                                                        ├─ /ingress  ─▶ voice-ingress:8500
                                                        └─ /         ─▶ web:5000
internet ─▶ queen TCP 7881 + UDP 50000-50100 ─▶ livekit (hostNetwork, WebRTC media)
```

- Upstream's Caddy is kept as an internal path router behind nginx, with the
  Caddyfile copied verbatim (in `templates/config.yaml`). When upstream changes
  its routing, copy the new Caddyfile across.
- Service names match the compose service names (`database`, `redis`,
  `rabbit`, `minio`, ...), so the defaults built into the images resolve
  unchanged.
- MinIO (actually [Silo](https://github.com/pgsty/silo), the fork upstream
  switched to) uses **path-style** buckets. Compose relies on network aliases
  like `revolt-uploads.minio`, and Kubernetes has nothing equivalent. An
  initContainer on `autumn` creates the `revolt-uploads` bucket if it is
  missing.
- Mongo, MinIO and RabbitMQ data live on `longhorn-queen-bulk` PVCs (Retain).
  Valkey is ephemeral, as it is upstream.

## Secrets

Everything secret is in two Secrets that are **not** in git:

| Secret | Contents |
|---|---|
| `stoat-secrets` | `REVOLT__*` env overrides: VAPID keypair, `FILES__ENCRYPTION_KEY`, LiveKit key/secret, `RABBIT__PASSWORD`, `FILES__S3__SECRET_ACCESS_KEY` (also used as the rabbit/minio server passwords) |
| `stoat-livekit` | `livekit.yml`, which embeds the LiveKit key/secret |

They were generated with the same `openssl` commands as upstream's
`generate_config.sh`, and the original files are kept off-cluster. **If
`REVOLT__FILES__ENCRYPTION_KEY` is lost, every uploaded file becomes
unreadable.** To back them up from the cluster:

```bash
kubectl -n stoat get secret stoat-secrets -o json | jq -r '.data | map_values(@base64d) | to_entries[] | "\(.key)=\(.value)"'
kubectl -n stoat get secret stoat-livekit -o jsonpath='{.data.livekit\.yml}' | base64 -d
```

Non-secret settings go in `Revolt.toml`, rendered from `values.yaml` into the
`revolt-toml` ConfigMap. Defaults and all available options are in the
[upstream Revolt.toml](https://github.com/stoatchat/stoatchat/blob/main/crates/core/config/Revolt.toml).
Any key can also be overridden by env as `REVOLT__SECTION__KEY`. For example,
adding `REVOLT__API__SECURITY__TENOR_KEY` to `stoat-secrets` and restarting
`gifbox` enables the GIF picker (key from [gifbox.me](https://gifbox.me)).

## Invites

Registration is invite-only (`registration.inviteOnly`). To create an invite
code:

```bash
kubectl -n stoat exec deploy/database -- mongosh revolt --quiet \
  --eval 'db.account_invites.insertOne({ _id: "some-invite-code" })'
```

## Voice and video

LiveKit needs TCP 7881 and UDP 50000-50100 reachable on the public IP,
unproxied. It runs with `hostNetwork` on queen, and those ports are:

1. opened in the `servers` repo's `modules/queen/configuration.nix`, which
   also opens 7880 on `cni0` only, so pods (api, caddy) can reach LiveKit's
   signalling port on the host network
2. port-forwarded on the router to queen (`192.168.50.187`), just like ARK's

`rtc.use_external_ip: true` makes LiveKit advertise the public IP it finds
via STUN. Clients on the home LAN therefore depend on the router supporting
hairpin NAT, the same caveat as ARK (see [ark.md](ark.md)).

## Upgrading

1. Read the "Notices" section of the
   [self-hosted README](https://github.com/stoatchat/self-hosted#notices).
   Some releases need manual migrations.
2. Compare upstream `compose.yml`, `Caddyfile` and `generate_config.sh` with
   this chart (new services, new config keys, new secrets).
3. Bump all `ghcr.io/stoatchat/*` tags in `values.yaml` together, plus
   `for-web` and `livekit-server` to the versions upstream's compose pins.
4. Do not bump MongoDB by more than one major version at a time.
