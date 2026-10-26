# NERP SecureServe telemetry bridge

Server-only bridge for SecureServe SQL ban history, player activity and authenticated website unban commands. Source of truth for enforcement remains the `nerp_ac_bans` SQL table. It never forwards player IPs or hardware tokens.

## Deployment

1. Deploy matching latest `main` versions of `theenack/secureserve-ac` and `theenack/nerpweb`.
2. Configure `anticheat.ingest_secret` in the website's private configuration as a random secret of at least 32 characters.
3. Ensure `oxmysql`, `SecureServe`, then `NERP-ac-bridge` in the game server.
4. In private `server.cfg` set the same secret and HTTPS endpoint:

```cfg
set nerp_ac_url "https://newenergyrp.com/api/anticheat-ingest.php"
set nerp_ac_secret "REPLACE_WITH_THE_SAME_32_PLUS_CHARACTER_SECRET"
set nerp_ac_server "production"
ensure SecureServe
ensure NERP-ac-bridge
```

Use `nerp_ac_server "dev"` **only on development**. The web page defaults to `production` and filters each environment separately.

## Verify synchronization

Run `nerpacstatus` in server console: `configured` must be true, `lastScanCounts` gives SQL history total, eligible, active and skipped, `acceptedBans` should increase on first upload, and `lastHttp` must report successful `ban_upsert` and `ban_inventory`. Run `nerpacsync` to request an immediate sync. A `total:0` scan means there are no SQL records returned, or SecureServe is connected to a different database; inspect `nerp_ac_bans`. A `skipped` count indicates records without supported identifiers or invalid IDs. Check PHP server error log and environment filter if uploads appear successful but are not displayed.

The bridge scans SQL-based history every minute, sends idempotent ban upserts, and sends an inventory containing active (non-revoked, non-expired) ban IDs only. The website retains historic and revoked bans. An approved website unban is leased to the server and acknowledged after the SQL revoke; there is no direct website-side bypass of game enforcement.

### Important

The bridge's queue is memory-based and not durable across resource restarts; the next full SQL scan repairs gaps in ban history. A 1000-item inventory cap prevents oversize requests, so systems with more than 1000 *active* bans need pagination before automatic reconciliation. Test in staging before production rollout. The OCR engine is disabled because the embedded FiveM browser does not support its WebAssembly dependency.
