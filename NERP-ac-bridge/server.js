'use strict';
const crypto = require('crypto');
const endpoint = GetConvar('nerp_ac_url', '');
const secret = GetConvar('nerp_ac_secret', '');
const queue = [];
const sessions = new Map();
const serverId = GetConvar('nerp_ac_server', 'dev').trim().toLowerCase();
const knownBans = new Map();
let syncing = false;
let inFlight = false;
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
function emit(type, player_key, extra = {}) {
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
    PerformHttpRequest(endpoint, (status, response) => {
      if (status >= 200 && status < 300) {
        queue.shift();
        inFlight = false;
        pump();
      } else if (retry < 4) {
        setTimeout(() => send(retry + 1), Math.min(60000, 2000 * (2 ** retry)));
      } else {
        console.warn('[NERP-AC] delivery failed:', status, String(response || '').slice(0, 100));
        // Retain the unsent event and retry later. Do not lose ban revocations.
        inFlight = false;
        setTimeout(pump, 30000);
      }
    }, 'POST', body, {
      'Content-Type': 'application/json',
      'X-AC-Timestamp': timestamp,
      'X-AC-Signature': signature,
      'X-AC-Event-ID': item.eventId
    });
  }
  send(0);
}
function enqueue(type, key, extra = {}) {
  if (!endpoint.startsWith('https://') || secret.length < 32) return;
  if (queue.length >= MAX_QUEUE) return;
  queue.push({eventId: crypto.randomBytes(16).toString('hex'),
    data: {type, player_key: key, server_id: safeServerId, ...extra}});
  pump();
}
function stablePlayerKey(ids) {
  if (!ids || typeof ids !== 'object') return '';
  for (const key of ['license', 'license2', 'fivem']) {
    const value = ids[key];
    if (typeof value === 'string' && /^[a-zA-Z0-9:_-]{3,128}$/.test(value)) return value;
  }
  return '';
}
function syncBans() {
  if (syncing || !endpoint.startsWith('https://') || secret.length < 32) return;
  syncing = true;
  try {
    const raw = LoadResourceFile('SecureServe', 'bans.json');
    if (typeof raw !== 'string' || !raw.trim()) {
      console.warn('[NERP-AC] bans.json unavailable; not clearing remote bans');
      return;
    }
    const bans = JSON.parse(raw);
    if (!Array.isArray(bans)) throw new Error('bans.json is not an array');
    const currentIds = [];
    for (const ban of bans) {
      if (!ban || typeof ban !== 'object') continue;
      const banId = String(ban.id || '');
      const key = stablePlayerKey(ban.identifiers);
      if (!/^[a-zA-Z0-9_-]{1,64}$/.test(banId) || !key) continue;
      currentIds.push(banId);
      const data = {
        ban_id: banId, name: String(ban.player_name || 'Unknown').slice(0, 128),
        reason: String(ban.reason || 'SecureServe ban').slice(0, 2048),
        banned_at: Number(ban.timestamp) || 0,
        expires_at: Number(ban.expires) || 0
      };
      const hash = crypto.createHash('sha256').update(JSON.stringify([key, data])).digest('hex');
      if (knownBans.get(banId) !== hash) {
        enqueue('ban_upsert', key, data);
        knownBans.set(banId, hash);
      }
    }
    // Periodic authoritative inventory reconciles unbans even if the bridge
    // was offline when they happened. Empty list is valid only after JSON parse.
    // The API requires a player_key even for inventory; use a fixed system key.
    // A cap avoids oversized payloads; skip reconciliation rather than truncate.
    if (currentIds.length <= 1000) {
      enqueue('ban_inventory', 'system:inventory', {ban_ids: currentIds});
    } else {
      console.warn('[NERP-AC] ban inventory exceeds 1000 IDs; skipping reconciliation');
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
setInterval(syncBans, 60000);
setTimeout(syncBans, 10000);
on('playerJoining', () => {
  const src = global.source;
  const key = playerKey(src);
  if (key) {
    const session = crypto.randomBytes(16).toString('hex');
    sessions.set(String(src), {key, session});
    emit('player_seen', key, {name: GetPlayerName(String(src)) || 'Unknown'});
    emit('session_start', key, {session_key:session});
  }
});
on('playerDropped', () => {
  const src = String(global.source);
  const state = sessions.get(src);
  if (state) emit('session_end', state.key, {session_key:state.session});
  sessions.delete(src);
});
on('playerBanned', (src, reason) => {
  const key = playerKey(src);
  if (key) emit('detection', key, {detection_type: String(reason || 'SecureServe ban').slice(0,128)});
});
setTimeout(() => {
  for (const src of GetPlayers()) {
    const key = playerKey(src);
    if (key) {
      const session = crypto.randomBytes(16).toString('hex');
      sessions.set(String(src), {key, session});
      emit('player_seen', key, {name:GetPlayerName(src) || 'Unknown'});
      emit('session_start', key, {session_key:session});
    }
  }
}, 5000);
console.log('[NERP-AC] telemetry bridge loaded; configured:', endpoint.startsWith('https://') && secret.length >= 32);
