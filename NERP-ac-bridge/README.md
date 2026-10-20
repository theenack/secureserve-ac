# NERP SecureServe telemetry bridge

This optional server-only resource forwards player join records and SecureServe `playerBanned` notifications to the NERP staff website. It does **not** perform ban synchronization or remote unbans.

## Installation

1. Deploy the `nerpweb` `feature/anticheat-dashboard` branch to a staging website, with HTTPS enabled.
2. Set the private PHP config value `anticheat.ingest_secret` to a unique randomly generated string at least 32 characters long.
3. Place `NERP-ac-bridge` in the FiveM resources directory.
4. Add the following to your private `server.cfg` (never commit the secret):

```cfg
set nerp_ac_url "https://YOUR-STAGING-HOST/api/anticheat-ingest.php"
set nerp_ac_secret "YOUR_UNIQUE_32_PLUS_CHARACTER_SECRET"
ensure SecureServe
ensure NERP-ac-bridge
```

5. In the nerpweb Access Roles page, assign `anticheat_view` to the appropriate Discord role.
6. Visit `/anticheat.php` as an authorized staff member and confirm that join records appear.
7. Test that invalid signatures and duplicate event IDs do not create records.

## Limitations and required work

- This bridge is untested in a running FiveM server; validate JavaScript server runtime and event source semantics in staging.
- The `playerBanned` event contains limited metadata and does not establish a full historical ban record.
- SecureServe persists active bans in `SecureServe/bans.json`; importing historical bans, identifier matching, and unban acknowledgements still require implementation.
- The current telemetry endpoint accepts player and detection records only. Do not assume that bans or unbans synchronize.
- No replay-resistant command channel exists for website-to-server moderation yet; do not enable remote unban buttons.
- Do not send player IP addresses or hardware tokens to the website.
- SecureServe is AGPL-3.0; retain its license and comply with applicable source-sharing obligations.
