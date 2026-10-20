'use strict';
const crypto = require('crypto');
const endpoint = GetConvar('nerp_ac_url', '');
const secret = GetConvar('nerp_ac_secret', '');
const queue = [];
function playerKey(src) {
  return GetPlayerIdentifiers(String(src)).find(x => x.startsWith('license:')) || '';
}
function emit(type, player_key, extra = {}) {
  if (!endpoint.startsWith('https://') || secret.length < 32 || !player_key) return;
  queue.push({ type, player_key, ...extra });
}
function deliver(item, attempt = 0) {
  const body = JSON.stringify(item);
  const timestamp = String(Math.floor(Date.now()/1000));
  const signature = crypto.createHmac('sha256', secret).update(timestamp+'.'+body).digest('hex');
  const eventId = crypto.randomBytes(16).toString('hex');
  function send(retry) {
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
  if (key) emit('player_seen', key, {name: GetPlayerName(String(src)) || 'Unknown'});
});
on('playerBanned', (src, reason) => {
  const key = playerKey(src);
  if (key) emit('detection', key, {detection_type: String(reason || 'SecureServe ban').slice(0,128)});
});
setTimeout(() => {
  for (const src of GetPlayers()) {
    const key = playerKey(src);
    if (key) emit('player_seen', key, {name:GetPlayerName(src) || 'Unknown'});
  }
}, 5000);
console.log('[NERP-AC] telemetry bridge loaded; configured:', endpoint.startsWith('https://') && secret.length >= 32);
