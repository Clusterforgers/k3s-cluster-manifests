# Magic (Clusterforgers/magic)

A browser Magic: The Gathering for friends, deployed from `apps/magic/` into the namespace `magic`, pinned to `queen`, at **`magic.hivemindcloud.dk`**. The source, images and release flow are in the `magic` repo (`docs/deploy.md`).

## What runs

- `magic-db`: a Postgres 17 StatefulSet on a `longhorn-queen-bulk` volume (`Retain`, so pruning the app keeps the data).
- `magic-server`: the game server, one replica that restarts into its stored games. An init container runs `mtg-cli migrate` before every start. The picture cache is the volume `magic-images`.
- `magic-web`: nginx with the built client. One Ingress sends `/api`, `/ws` and `/healthz` to the server and everything else to the web.
- `magic-compile`: a post-sync hook Job that writes the card rules again after each release.
- `magic-ingest`: a suspended CronJob, the card data load, started by hand.

`values.yaml` holds everything to tune: `tag` (rewritten by the release script), the host, `server.registration` and the volume sizes.

## First install

1. **DNS.** An A record `magic.hivemindcloud.dk` pointing at the zone's public IP (`82.211.219.198`). Until it resolves, cert-manager's HTTP-01 challenge stays pending and the site answers with the ingress's default certificate.
2. **Secret** (once; it is not in git). The password is URL-safe hex:

   ```bash
   kubectl create namespace magic
   PW=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
   kubectl -n magic create secret generic magic-secrets \
     --from-literal=POSTGRES_PASSWORD="$PW" \
     --from-literal=DATABASE_URL="postgres://magic:$PW@magic-db:5432/magic"
   ```

   The database sets its password from the secret on its first start only, so keep the secret as long as the volume lives. Read it back with `kubectl -n magic get secret magic-secrets -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d`.
3. **Release** `scripts/release.sh` in the magic repo: it builds the images, pushes this chart's `tag` and waits for the rollout.
4. **CoreDNS.** `magic.hivemindcloud.dk` is in `apps/coredns-custom/values.yaml`; once that has synced, `kubectl rollout restart deployment -n kube-system coredns` (see the README).
5. **Card data.**

   ```bash
   kubectl -n magic create job --from=cronjob/magic-ingest ingest-first
   kubectl -n magic logs -f job/ingest-first
   ```

   The job downloads about 200 MiB from Scryfall and MTGJSON, loads it and compiles the rules. Run it again the same way to refresh the data.

## Operations

- Logs: `kubectl -n magic logs deploy/magic-server`.
- Database shell: `kubectl -n magic exec -it magic-db-0 -- psql -U magic magic`.
- Close sign-ups once everyone has an account: `server.registration: closed` in `values.yaml`.
- Roll back: `scripts/release.sh --rollback vX.Y.Z` in the magic repo.

## Backups

`magic-backup` dumps the whole database every night at 03:30 into the volume `magic-backups` (the newest 14 stay; `backup` in `values.yaml`). The volume is mounted read-only in `magic-db-0` at `/backups`:

```bash
kubectl -n magic exec magic-db-0 -- ls -lh /backups
kubectl -n magic cp magic-db-0:/backups/magic-<date>.dump ./magic.dump        # a copy off the cluster
kubectl -n magic create job --from=cronjob/magic-backup dump-now             # a dump right now
# restore (while nobody plays), then restart the server
kubectl -n magic exec magic-db-0 -- pg_restore -U magic -d magic --clean --if-exists --no-owner /backups/magic-<date>.dump
kubectl -n magic rollout restart deployment/magic-server
```

The dumps sit on queen like the database, so a copy off the machine (the `kubectl cp` above, or a Longhorn backup target) is what survives losing queen.
