'use strict';
const crypto = require('crypto');
const https = require('https');
const endpoint = GetConvar('nerp_ac_url', '');
const secret = GetConvar('nerp_ac_secret', '');
const queue = [];
const sessions = new Map();
const serverId = GetConvar('nerp_ac_server', 'dev').trim().toLowerCase();
const knownBans = new Map();
let syncing = false;
let inFlight = false;
let lastHttp = 'not sent';
let lastScan = 'never';
let lastScanCounts = {total: 0, eligible: 0, skipped: 0};
let acceptedBans = 0;
let lastWarnAt = 0;
let pollBlockedUntil = 0;
let lastPollError = '';
let lastInventoryHash = '';
let lastInventorySuccessAt = 0;
const INVENTORY_REFRESH_MS = 5 * 60 * 1000;
const activeCommands = new Set();
// Never transmit player IPs, hardware tokens, or the full SecureServe ban file.
const MAX_QUEUE = 10000;
const safeServerId = /^[a-z0-9_-]{1,32}$/.test(serverId) ? serverId : 'dev';
function playerKey(src) {
  // FiveM's JavaScript runtime does not expose Lua's GetPlayerIdentifiers helper.
  const player = String(src);
  if (!player || player === 'undefined' || player === 'null') return '';
  if (typeof GetPlayerIdentifierByType === 'function') {
    const license = GetPlayerIdentifierByType(player, 'license');
    if (typeof license === 'string' && license.startsWith('license:')) return license;
  }
  if (typeof GetNumPlayerIdentifiers === 'function' && typeof GetPlayerIdentifier === 'function') {
    const count = GetNumPlayerIdentifiers(player);
    for (let i = 0; i < count; i++) {
      const identifier = GetPlayerIdentifier(player, i);
      if (typeof identifier === 'string' && identifier.startsWith('license:')) return identifier;
    }
  }
  return '';
}
function queueTelemetry(type, player_key, extra = {}) {
  if (!endpoint.startsWith('https://') || secret.length < 32 || !player_key) return;
  enqueue(type, player_key, extra);
}
// Preserve FIFO ordering (including ban inventory after upserts), and retry
// the exact same event ID so an accepted response cannot duplicate records.
function pump() {
  if (inFlight || !queue.length) return;
  inFlight = true;
  const item = queue[0];
  const body = JSON.stringify(item.data);
  function send(retry) {
    const timestamp = String(Math.floor(Date.now() / 1000));
    const signature = crypto.createHmac('sha256', secret).update(timestamp + '.' + body).digest('hex');
    let settled = false;
    const watchdog = setTimeout(() => finish(0, 'HTTP timeout (20 seconds)'), 20000);
    function finish(status, response) {
      if (settled) return;
      settled = true;
      clearTimeout(watchdog);
      if (status >= 200 && status < 300) {
        if (item.data.type === 'command_poll') {
          try {
            const decoded = JSON.parse(response || '{}');
            const cmd = decoded.command;
            if (cmd && cmd.action === 'unban' && Number.isSafeInteger(cmd.id) &&
                typeof cmd.ban_id === 'string' && /^[a-zA-Z0-9_-]{1,64}$/.test(cmd.ban_id) &&
                !activeCommands.has(cmd.id)) {
              activeCommands.add(cmd.id);
              console.log('[NERP-AC] processing website unban command', cmd.id, 'server:', safeServerId);
              emit('NERP-AC:RemoteUnban', cmd.id, cmd.ban_id);
              setTimeout(() => activeCommands.delete(cmd.id), 45000);
            }
          } catch (error) {
            console.warn('[NERP-AC] invalid command poll response:', error.message);
          }
        }
        lastHttp = String(status) + ' OK (' + item.data.type + ')';
        if (item.data.type === 'ban_upsert') acceptedBans++;
        if (item.data.type === 'ban_inventory') {
          lastInventoryHash = crypto.createHash('sha256').update(JSON.stringify(item.data.ban_ids)).digest('hex');
          lastInventorySuccessAt = Date.now();
        }
        queue.shift();
        inFlight = false;
        // Yield to the event loop rather than recurse through queued messages.
        setTimeout(pump, 0);
      } else if (item.data.type === 'command_poll' && status >= 400 && status < 500) {
        // A 4xx poll cannot succeed by replaying the exact same request.
        // Drop this optional poll so bans and session telemetry can continue.
        lastPollError = String(status) + ': ' + String(response || '').slice(0, 200);
        pollBlockedUntil = Date.now() + 5 * 60 * 1000;
        lastHttp = String(status) + ' DISABLED POLL (command_poll)';
        console.warn('[NERP-AC] command polling rejected by website:', lastPollError,
          '- pausing polls for 5 minutes; verify current anticheat-ingest.php is deployed');
        queue.shift();
        inFlight = false;
        setTimeout(pump, 0);
      } else if (retry < 4) {
        lastHttp = String(status) + ' RETRY (' + item.data.type + ')';
        if (retry === 0) {
          console.warn('[NERP-AC] HTTP retry:', status, 'event:', item.data.type,
            'response:', String(response || '').slice(0, 200));
        }
        setTimeout(() => send(retry + 1), Math.min(60000, 2000 * (2 ** retry)));
      } else {
        lastHttp = String(status) + ' FAILED (' + item.data.type + ')';
        console.warn('[NERP-AC] delivery failed:', status, 'event:', item.data.type,
          'response:', String(response || '').slice(0, 180));
        // Keep unsent event, including its idempotency ID, at the queue head.
        inFlight = false;
        setTimeout(pump, 30000);
      }
    }
    try {
      // FiveM's JS runtime does not expose the Lua PerformHttpRequest API.
      // Use the built-in Node.js HTTPS client instead.
      const req = https.request(endpoint, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(body),
          'X-AC-Timestamp': timestamp,
          'X-AC-Signature': signature,
          'X-AC-Event-ID': item.eventId
        },
        timeout: 20000
      }, (res) => {
        let response = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => { if (response.length < 1024) response += chunk.slice(0, 1024); });
        res.on('end', () => finish(res.statusCode || 0, response));
        res.on('error', (error) => finish(0, error.message));
      });
      req.on('timeout', () => req.destroy(new Error('HTTPS request timed out')));
      req.on('error', (error) => finish(0, error.message));
      req.end(body);
    } catch (error) {
      finish(0, String(error && error.message || error));
    }
  }
  send(0);
}
function enqueue(type, key, extra = {}) {
  if (!endpoint.startsWith('https://') || secret.length < 32) return false;
  if (queue.length >= MAX_QUEUE) return false;
  queue.push({eventId: crypto.randomBytes(16).toString('hex'),
    data: {type, player_key: key, server_id: safeServerId, ...extra}});
  pump();
  return true;
}
function stablePlayerKey(ids) {
  if (!ids || typeof ids !== 'object') return '';
  for (const key of ['license', 'license2', 'fivem', 'discord', 'steam']) {
    const value = ids[key];
    if (typeof value === 'string' && /^[a-zA-Z0-9:_-]{3,128}$/.test(value)) return value;
  }
  return '';
}
function syncBans() {
  if (syncing) return;
  if (!endpoint.startsWith('https://') || secret.length < 32) {
    if (Date.now() - lastWarnAt > 60000) {
      console.warn('[NERP-AC] ban sync not configured: HTTPS URL set:', endpoint.startsWith('https://'), 'secret length valid:', secret.length >= 32);
      lastWarnAt = Date.now();
    }
    return;
  }
  syncing = true;
  try {
    if (GetResourceState('SecureServe') !== 'started') throw new Error('SecureServe not started');
    const snapshot = exports['SecureServe'].GetSyncBans();
    const bans = JSON.parse(snapshot);
    if (!Array.isArray(bans)) throw new Error('SecureServe SQL snapshot unavailable');
    const currentIds = [];
    let skipped = 0;
    for (const ban of bans) {
      if (!ban || typeof ban !== 'object') { skipped++; continue; }
      const banId = String(ban.id || '');
      const key = stablePlayerKey(ban.identifiers);
      if (!/^[a-zA-Z0-9_-]{1,64}$/.test(banId) || !key) { skipped++; console.warn('[NERP-AC] skipping ban with missing eligible identifier or invalid ID:', banId); continue; }
      currentIds.push(banId);
      const data = {
        ban_id: banId, name: String(ban.player_name || 'Unknown').slice(0, 128),
        reason: String(ban.reason || 'SecureServe ban').slice(0, 2048),
        banned_at: Number(ban.timestamp) || 0,
        expires_at: Number(ban.expires) || 0
      };
      const hash = crypto.createHash('sha256').update(JSON.stringify([key, data])).digest('hex');
      if (knownBans.get(banId) !== hash) {
        if (enqueue('ban_upsert', key, data)) knownBans.set(banId, hash);
      }
    }
    lastScan = new Date().toISOString();
    lastScanCounts = {total: bans.length, eligible: currentIds.length, skipped};
    console.log('[NERP-AC] ban scan:', JSON.stringify(lastScanCounts), 'server:', safeServerId, 'pending:', queue.length, 'last HTTP:', lastHttp);
    // Periodic authoritative inventory reconciles unbans even if the bridge
    // was offline when they happened. Empty list is valid only after JSON parse.
    // The API requires a player_key even for inventory; use a fixed system key.
    // A cap avoids oversized payloads; skip reconciliation rather than truncate.
    const inventoryHash = crypto.createHash('sha256').update(JSON.stringify(currentIds)).digest('hex');
    const inventoryChanged = inventoryHash !== lastInventoryHash;
    const inventoryDue = Date.now() - lastInventorySuccessAt >= INVENTORY_REFRESH_MS;
    if (currentIds.length > 1000) {
      console.warn('[NERP-AC] ban inventory exceeds 1000 IDs; skipping reconciliation');
    } else if (queue.length >= MAX_QUEUE) {
      console.warn('[NERP-AC] telemetry queue full; ban inventory deferred');
    } else if ((inventoryChanged || inventoryDue) &&
               !queue.some(item => item.data.type === 'ban_inventory')) {
      enqueue('ban_inventory', 'system:inventory', {ban_ids: currentIds});
    }
    for (const id of Array.from(knownBans.keys())) {
      if (!currentIds.includes(id)) knownBans.delete(id);
    }
  } catch (err) {
    console.warn('[NERP-AC] ban sync failed; no remote changes:', err.message);
  } finally {
    syncing = false;
  }
}
// Acknowledgement comes from the authoritative Lua ban manager after the SQL
// revoke has completed. No website status is marked successful before then.
on('NERP-AC:RemoteUnbanResult', (commandId, success, message) => {
  if (!Number.isSafeInteger(commandId) || !activeCommands.has(commandId)) return;
  activeCommands.delete(commandId);
  enqueue('command_ack', 'system:commands', {
    command_id: commandId, success: success === true,
    message: String(message || '').slice(0, 255)
  });
  syncBans();
});
setInterval(() => {
  if (endpoint.startsWith('https://') && secret.length >= 32 &&
      Date.now() >= pollBlockedUntil &&
      !queue.some(item => item.data.type === 'command_poll')) {
    enqueue('command_poll', 'system:commands');
  }
}, 10000);
setInterval(syncBans, 60000);
setTimeout(syncBans, 10000);
on('playerJoining', () => {
  const src = global.source;
  const key = playerKey(src);
  if (key) {
    const session = crypto.randomBytes(16).toString('hex');
    sessions.set(String(src), {key, session});
    queueTelemetry('player_seen', key, {name: GetPlayerName(String(src)) || 'Unknown'});
    queueTelemetry('session_start', key, {session_key:session});
  }
});
on('playerDropped', () => {
  const src = String(global.source);
  const state = sessions.get(src);
  if (state) queueTelemetry('session_end', state.key, {session_key:state.session});
  sessions.delete(src);
});
on('playerBanned', (src, reason) => {
  const key = playerKey(src);
  if (key) queueTelemetry('detection', key, {detection_type: String(reason || 'SecureServe ban').slice(0,128)});
});
setTimeout(() => {
  for (const src of GetPlayers()) {
    const key = playerKey(src);
    if (key) {
      const session = crypto.randomBytes(16).toString('hex');
      sessions.set(String(src), {key, session});
      queueTelemetry('player_seen', key, {name:GetPlayerName(src) || 'Unknown'});
      queueTelemetry('session_start', key, {session_key:session});
    }
  }
}, 5000);
RegisterCommand('nerpacstatus', (src) => {
  if (Number(src) !== 0) return;
  console.log('[NERP-AC] status', JSON.stringify({
    configured: endpoint.startsWith('https://') && secret.length >= 32,
    endpointHost: (() => { try { return new URL(endpoint).host; } catch (_) { return 'invalid'; } })(),
    server: safeServerId, lastScan, lastScanCounts, pending: queue.length,
    inFlight, acceptedBans, lastHttp, lastPollError,
    lastInventorySuccess: lastInventorySuccessAt ? new Date(lastInventorySuccessAt).toISOString() : 'never',
    pollPausedSeconds: Math.max(0, Math.ceil((pollBlockedUntil - Date.now()) / 1000))
  }));
}, true);
RegisterCommand('nerpacsync', (src) => {
  if (Number(src) !== 0) return;
  console.log('[NERP-AC] manual ban sync requested');
  syncBans();
}, true);
console.log('[NERP-AC] telemetry bridge loaded; configured:', endpoint.startsWith('https://') && secret.length >= 32, 'server:', safeServerId);
