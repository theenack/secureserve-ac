# NERP SecureServe SQL bans and website unbans

## Deploy order
1. Back up `SecureServe/bans.json` and both databases before upgrading.
2. Deploy `theenack/nerpweb` main to the website, including `api/anticheat-unban.php`, `api/anticheat-ingest.php`, `lib/anticheat-data.php`, and `anticheat.php`.
3. Ensure `oxmysql` starts before `SecureServe`. SecureServe now loads `@oxmysql/lib/MySQL.lua` and requires `oxmysql`; the server MySQL connection string must point to the intended game database.
4. Deploy `SecureServe` and `NERP-ac-bridge` from this repository main. Configure both `nerp_ac_url` and a 32+ character `nerp_ac_secret` matching website `anticheat.ingest_secret`, with `nerp_ac_server` different on dev and production.
5. Restart FXServer (for client-side changes), test on development first, check `securebanlist`, `nerpacsync`, `nerpacstatus`, then `/anticheat.php`.

## Automatic tables
- On SecureServe startup, `nerp_ac_bans` and `nerp_ac_meta` are created automatically in the configured FiveM SQL database.
- `SecureServe/bans.json` is imported only once if `legacy_json_imported` is absent in `nerp_ac_meta`. **Do not delete this marker**: reimporting old JSON later can restore revoked bans.
- After migration, SQL is authoritative for ban enforcement and unbans. `bans.json` is preserved as a backup, not a live export.
- The website automatically creates `ac_unban_commands` as part of `acEnsureSchema`. It mirrors ban history in `ac_bans`; it is **not** the enforcement database.

## Remote unban flow
- Only staff with `site_admin` or `anticheat_unban` can queue a request using a CSRF-protected POST with a required reason.
- A signed `command_poll` from a named server leases a queued action. The FiveM JS bridge emits a server-only unban request to the Lua ban manager.
- The Lua ban manager changes the authoritative SQL record and replies. Only then does the bridge POST a signed `command_ack`. The website marks the command succeeded/failed and updates the displayed ban when acknowledged.
- Pending commands retry after a lease timeout. The Lua action is idempotent for previously revoked bans.
- Dev and production records are separate by `nerp_ac_server`. Use **different secrets per environment** in a future rollout if requiring credential isolation; the present shared `ingest_secret` authenticates the bridge but does not cryptographically distinguish servers using the same secret.
- Never expose the ingestion secret in browser code or repository commits.

## Limitations
- Runtime integration and SQL migration require testing on an actual FiveM FXServer with MariaDB/oxmysql before production.
- Existing JSON entries previously deleted/unbanned cannot be recovered automatically.
- Historical bans that are expired or already revoked remain in game SQL but are not all mirrored automatically to the web dashboard; the bridge currently exports active bans for synchronization.
- The web dashboard unban is asynchronous. A queued request is **not** a completed unban until server acknowledgement.
- `nerpacstatus` reports HTTP failures. Confirm a real `200 OK` before relying on remote management.
