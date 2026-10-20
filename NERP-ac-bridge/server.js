'use strict';
const crypto = require('crypto');
const endpoint = GetConvar('nerp_ac_url', '');
const secret = GetConvar('nerp_ac_secret', '');
const queue = [];
const sessions = new Map();
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
  queue.push({ type, player_key, ...extra });
}
function deliver(item, attempt = 0) {
  const body = JSON.stringify(item);
  const eventId = crypto.randomBytes(16).toString('hex');
  function send(retry) {
    const timestamp = String(Math.floor(Date.now()/1000));
    const signature = crypto.createHmac('sha256', secret).update(timestamp+'.'+body).digest('hex');
    PerformHttpRequest(endpoint, (_status, _body) => {
      if (_status >= 200 && _status < 300) return;
      if (retry < 4) setTimeout(() => send(retry + 1), Math.min(60000, 2000 * (2 ** retry)));
      else console.warn('[NERP-AC] telemetry delivery failed, event:', eventId);
    }, 'POST', body, {
      'Content-Type':'application/json',
      'X-AC-Timestamp':timestamp,
      'X-AC-Signature':signature,
      'X-AC-Event-ID':eventId
    });
  }
  send(attempt);
}
setInterval(() => {
  if (!queue.length) return;
  deliver(queue.shift());
}, 250);
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
