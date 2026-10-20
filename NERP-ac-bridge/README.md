# NERP SecureServe telemetry bridge

This server-only resource forwards player events and synchronizes SecureServe bans from `SecureServe/bans.json` to the NERP staff website. The website is read-only; remote unbans are not supported.

## Installation

1. Deploy the `nerpweb` `feature/anticheat-dashboard` branch to a staging website, with HTTPS enabled.
2. Set the private PHP config value `anticheat.ingest_secret` to a unique randomly generated string at least 32 characters long.
3. Place `NERP-ac-bridge` in the FiveM resources directory.
4. Add the following to your private `server.cfg` (never commit the secret):

```cfg
set nerp_ac_url "https://YOUR-STAGING-HOST/api/anticheat-ingest.php"
set nerp_ac_secret "YOUR_UNIQUE_32_PLUS_CHARACTER_SECRET"
set nerp_ac_server "dev" # use "production" on the production server
ensure SecureServe
ensure NERP-ac-bridge
```

5. In the nerpweb Access Roles page, assign `anticheat_view` to the appropriate Discord role.
6. Visit `/anticheat.php` as an authorized staff member and confirm that join records appear.
7. Test that invalid signatures and duplicate event IDs do not create records.

## Ban synchronization

- Pull the latest `main` of both `theenack/secureserve-ac` and `theenack/nerpweb`.
- Deploy the website changes, configure `anticheat.ingest_secret` on the website and the matching `nerp_ac_secret` convar on each FiveM server.
- Configure `nerp_ac_url` to `https://newenergyrp.com/api/anticheat-ingest.php`.
- Give each server a **unique** `nerp_ac_server` (e.g. `dev` or `production`). Do not use the default `dev` on production.
- Start `SecureServe` before `NERP-ac-bridge`. The bridge reads `bans.json` after 10 seconds and approximately every minute. The web API upserts bans by `(source_server, external_ban_id)` and reconciles removed bans by server.
- The first accepted sync imports existing bans with a valid license / FiveM ID; no unban or enforcement command is ever sent from the website.
- Check `https://newenergyrp.com/anticheat.php` with an authorized staff account. Both active and revoked/expired history should appear.
- If records do not appear, check `[NERP-AC] delivery failed` or `ban sync failed` console logs, the website PHP error log, matching secrets, and HTTPS connectivity.

## Limitations and required work

- This bridge is untested in a running FiveM server; validate JavaScript server runtime and event source semantics in staging.
- The `playerBanned` event contains limited metadata and does not establish a full historical ban record.
- SecureServe persists active bans in `SecureServe/bans.json`; importing historical bans, identifier matching, and unban acknowledgements still require implementation.
- The updated endpoint accepts ban upserts and authoritative ban inventories. The bridge reads on-disk ban state; synchronization is eventually consistent and needs server/Web deployment before it works.
- No replay-resistant command channel exists for website-to-server moderation yet; do not enable remote unban buttons.
- Do not send player IP addresses or hardware tokens to the website.
- SecureServe is AGPL-3.0; retain its license and comply with applicable source-sharing obligations.
