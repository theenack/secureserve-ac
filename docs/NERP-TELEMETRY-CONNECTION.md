# NERP staff telemetry connection

The nerpweb development branch contains `api/anticheat-ingest.php` supporting `player_seen` and `detection` events. This is **not yet a live SecureServe integration**.

## Website configuration
Add a unique random 32+ character secret to the private `nerpweb/config.php` configuration under `anticheat.ingest_secret`. Never commit this secret.

## Request format
POST JSON to `https://newenergyrp.com/api/anticheat-ingest.php` with headers:
- `X-AC-Timestamp`: Unix epoch seconds
- `X-AC-Signature`: lowercase hex HMAC-SHA256 of `timestamp + '.' + exact JSON request body`, keyed by the configured secret
- `Content-Type: application/json`

Example JSON: `{"type":"player_seen","player_key":"license:example","name":"Example"}`.

A detection uses `{"type":"detection","player_key":"license:example","detection_type":"ExampleDetection"}`.

## Important limitations
- The endpoint is in a development branch and must be deployed before use.
- No SecureServe event hooks or ban manager synchronization have been implemented yet.
- The timestamp window alone does not prevent replay within that window. Add nonce/event-ID deduplication before production use.
- Only send server-verified detections. Never accept arbitrary client-submitted flags as confirmed cheats.
- Historical bans and unbans need explicit synchronization with SecureServe `bans.json` and its ban manager.
- The website must be HTTPS; never send secrets to browsers.
- Test on revamp-dev before production.
