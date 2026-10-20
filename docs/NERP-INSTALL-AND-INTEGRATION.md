# NERP Anti-Cheat — installation and integration guide

> NERP-specific guide based on the SecureServe project and its public documentation. This is an adaptation, not a reproduction of the upstream GitBook. Original documentation: https://peleg.gitbook.io/secureserve

## Status
This document describes a proposed NERP integration. The web API, staff panel and ban-history checker are **not installed by this guide** and must be implemented and tested before enabling enforcement.

## Prerequisites
- FiveM server with access to server.cfg and resources directory
- NERP Qbox server; database backup; staging environment
- Existing nerpweb staff authentication/roles
- HTTPS for all staff and API endpoints

## Install the upstream resources
1. Back up server.cfg and existing anticheat configuration.
2. Under resources create `[AC]`.
3. Copy `SecureServe/` and `keep-alive/` from this repository into `resources/[AC]/`.
4. In server.cfg put `ensure SecureServe` before gameplay resources (subject to dependency requirements). Verify whether keep-alive needs an explicit ensure from its manifest.
5. Run `refresh`, then start SecureServe in staging. Verify console startup and resource health.
6. Configure logging webhooks and review all detector settings, entity/explosion thresholds, and event allowlists.
7. Run in observation/log-only mode **if supported by the installed version**, or disable automatic punishment while tuning. Never assume that all default detections are safe for a heavily customized Qbox server.
8. Test legitimate events from qbx_core, ox_inventory, ox_target, lb-phone, NERP properties, garages, drugs, gangs, business and mechanic resources before enforcing bans.

## Existing integration point
The upstream README documents `exports['SecureServe']:banPlayer(source, 'Detected Cheat Activity')`. Validate the export and argument types in the checked-out version before calling it.

## Proposed NERP-AC architecture
- FiveM SecureServe adapter (server-side): normalize detections, connect/disconnects, bans and unbans; send signed events to the API. Never expose server-side credentials to clients.
- nerpweb backend: authenticated staff endpoints with separate read, investigate, ban, unban and configuration permissions.
- Database: `ac_players`, `ac_identifiers`, `ac_sessions`, `ac_detections`, `ac_bans`, `ac_ban_identifiers`, `ac_cases`, `ac_audit_log`, `ac_outbox`.
- UI: dashboard, online players, player profiles, previous bans, identifier matches, detections, appeals, staff notes and audit logs.
- Ban-history checker: exact identifier match first; weak/shared IP matches informational only, never automatic punishment.
- Ban sync: website unban creates a durable, authenticated action request consumed by the FiveM server; server confirms completion and writes an audit entry. Do not mark a ban removed until confirmation.

## Security requirements
- Signed authenticated API requests (HMAC with timestamp, nonce and replay protection), HTTPS, rate limiting and least-privilege staff roles.
- Store identifier fingerprints using keyed hashes for matching; protect raw identifiers, limit access and define retention.
- Parameterized SQL, CSRF protection on staff actions, session verification and immutable audit records.
- Require reason and confirmation for unbans; preserve ban history instead of deleting records.
- Reconcile website ban state with SecureServe's actual persistent ban storage to avoid contradictory enforcement.
- Do not expose API tokens or webhooks in the repository.

## Testing checklist
- [ ] Staging starts without Lua errors
- [ ] Legitimate Qbox gameplay does not trigger punishment
- [ ] Detection logs appear once and have stable IDs
- [ ] Reconnect correlates to the same player where identifiers match
- [ ] Previous ban matches distinguish exact and weak matches
- [ ] Unauthorized staff cannot access ban or unban endpoints
- [ ] Unban is acknowledged by the game server and survives restart
- [ ] Failed API calls retry safely without duplicate bans
- [ ] Audit logs include actor, timestamp, reason, before/after and outcome
- [ ] NERP-AC documentation and AGPL-3.0 notices remain available

## Attribution
Based on SecureServe-AC by peleg-development, licensed under GNU AGPL-3.0. Preserve license and copyright notices and comply with AGPL source-availability requirements when deploying modified network-facing software.
