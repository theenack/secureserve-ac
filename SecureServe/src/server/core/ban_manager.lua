local BanManager = {
    bans               = {},
    bans_index         = {},
    pending_bans       = {},
    ban_file           = "bans.json",
    load_attempts      = 0,
    max_load_attempts  = 5,
    next_ban_id        = 1,
    active_connections = {},
    dirty              = false,
}

local config_manager = require("server/core/config_manager")
local logger         = require("server/core/logger")

local function rebuild_index()
    BanManager.bans_index = {}
    for _, ban in ipairs(BanManager.bans) do
        if ban.identifiers then
            for _, id_value in pairs(ban.identifiers) do
                if type(id_value) == "string" then
                    BanManager.bans_index[id_value] = ban
                end
            end
        end
    end
end

function BanManager.initialize()
    BanManager.load_bans()
    -- The bridge can request a narrowly-scoped unban by SecureServe ban ID.
    -- Server-only event: never RegisterNetEvent (clients cannot invoke it).
    AddEventHandler("NERP-AC:RemoteUnban", function(commandId, banId)
        if GetInvokingResource() ~= "NERP-ac-bridge" then return end
        if type(commandId) ~= "number" or type(banId) ~= "string" or
           not banId:match("^[%w_-]+$") or #banId > 64 then return end
        local ok, result, message = pcall(function()
            local rows = MySQL.query.await("SELECT id,revoked_at FROM nerp_ac_bans WHERE id=? LIMIT 1", {banId})
            if not rows or not rows[1] then return false, "ban not found" end
            if rows[1].revoked_at then return true, "already revoked" end
            local success = BanManager.unban_player(banId)
            return success == true, success and "revoked" or "could not revoke"
        end)
        TriggerEvent("NERP-AC:RemoteUnbanResult", commandId,
            ok and result == true, ok and message or tostring(result))
    end)

    local maxId = MySQL.scalar.await("SELECT MAX(CAST(id AS UNSIGNED)) FROM nerp_ac_bans") or 0
    BanManager.next_ban_id = math.max(BanManager.next_ban_id, tonumber(maxId) + 1)
    for _, ban in ipairs(BanManager.bans) do
        local n = tonumber(ban.id)
        if n and n >= BanManager.next_ban_id then
            BanManager.next_ban_id = n + 1
        end
    end

    RegisterCommand("reloadbans", function(source)
        if source > 0 then return end
        logger.info("Manually reloading ban list")
        BanManager.load_bans()
        logger.info("Ban list reloaded. " .. #BanManager.bans .. " bans loaded.")
    end, true)

    RegisterCommand("clearbans", function(source)
        if source > 0 then return end
        local count = #BanManager.bans
        logger.warn("CLEARING ALL BANS")
        local backupName = BanManager.ban_file .. ".backup.clear." .. os.time()
        SaveResourceFile(GetCurrentResourceName(), backupName,
            json.encode(BanManager.bans, { indent = true }), -1)
        MySQL.update.await("UPDATE nerp_ac_bans SET revoked_at=? WHERE revoked_at IS NULL", {os.time()})
        BanManager.bans = {}
        BanManager.bans_index = {}
        BanManager.pending_bans = {}
        BanManager.dirty = false
        logger.info("Revoked " .. count .. " bans in SQL")
    end, true)

    BanManager.clean_expired_bans()

    AddEventHandler("playerConnecting", function(name, _, deferrals)
        local src = source
        deferrals.defer()

        Citizen.Wait(0)

        local identifiers = GetPlayerIdentifiers(src)
        local has_steam = false

        for _, id in ipairs(identifiers) do
            if string.match(id, "^steam:") then
                has_steam = true
                break
            end
        end

        if SecureServe.RequireSteam and not has_steam then
            deferrals.done("Steam is required. Please open Steam and try again.")
            return
        end

        local ids_table = {}
        for _, id in ipairs(identifiers) do
            local t = string.match(id, "^([^:]+):")
            if t then ids_table[t] = id end
        end

        local tokens = {}
        if GetPlayerToken then
            local count = GetNumPlayerTokens and GetNumPlayerTokens(src) or 5
            for i = 0, count - 1 do
                local tok = GetPlayerToken(src, i)
                if tok then tokens[#tokens + 1] = tok end
            end
        end
        ids_table.tokens = tokens

        if src and tonumber(src) > 0 then
            BanManager.active_connections[tostring(src)] = ids_table
        end

        local is_banned, ban_data = BanManager.check_ban(ids_table)
        if is_banned then
            logger.info(("Blocked banned player: %s (id %s, banId %s)"):format(
                name, src, ban_data.id or "?"))
            local id = ban_data.id or "Unknown"
            local discord_link = SecureServe.AppealURL or "Contact server administration"
            if not discord_link:find("http") then
                discord_link = "https://discord.gg/" .. discord_link:gsub("discord.gg/", "")
            end
            deferrals.done(("You have been banned from this server.\nBan ID: %s\nAppeal: %s"):format(id, discord_link))
            return
        end

        deferrals.done()
    end)

    AddEventHandler("playerDropped", function()
        local src = source
        if src and tonumber(src) > 0 then
            BanManager.active_connections[tostring(src)] = nil
        end
    end)

    CreateThread(function()
        while true do
            Wait(60000)
            BanManager.clean_expired_bans()
            if BanManager.dirty then
                BanManager.save_bans()
            end
        end
    end)

    logger.info("^5[SUCCESS] ^3Ban Manager^7 initialized")
end

-- Authoritative SQL ban storage. bans.json is read only during the first migration.
-- The metadata marker prevents a subsequently cleared SQL table from reimporting
-- historical bans from an old JSON file.
local function mysql_ready()
    return MySQL and MySQL.query and MySQL.query.await and MySQL.update and MySQL.update.await
end

local function create_tables()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS nerp_ac_bans (
        id VARCHAR(64) NOT NULL PRIMARY KEY,
        player_name VARCHAR(128) NOT NULL DEFAULT 'Unknown',
        reason TEXT NOT NULL,
        identifiers_json LONGTEXT NOT NULL,
        banned_at BIGINT NOT NULL DEFAULT 0,
        expires_at BIGINT NOT NULL DEFAULT 0,
        admin VARCHAR(128) NOT NULL DEFAULT 'System',
        detection TEXT NULL,
        screenshot TEXT NULL,
        revoked_at BIGINT NULL,
        INDEX idx_nerp_ac_active (revoked_at, expires_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS nerp_ac_meta (
        meta_key VARCHAR(64) PRIMARY KEY,
        meta_value VARCHAR(255) NOT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
end

local function decode_json_bans()
    local raw = LoadResourceFile(GetCurrentResourceName(), BanManager.ban_file)
    if not raw or raw == "" then return {} end
    local ok, records = pcall(json.decode, raw)
    if not ok or type(records) ~= "table" then
        error("Invalid legacy bans.json; refusing migration to avoid data loss")
    end
    return records
end

local function sql_upsert(ban)
    return MySQL.update.await([[INSERT INTO nerp_ac_bans
        (id,player_name,reason,identifiers_json,banned_at,expires_at,admin,detection,screenshot,revoked_at)
        VALUES (?,?,?,?,?,?,?,?,?,NULL)
        ON DUPLICATE KEY UPDATE player_name=VALUES(player_name),reason=VALUES(reason),
        identifiers_json=VALUES(identifiers_json),banned_at=VALUES(banned_at),
        expires_at=VALUES(expires_at),admin=VALUES(admin),detection=VALUES(detection),
        screenshot=VALUES(screenshot),revoked_at=NULL]], {
        tostring(ban.id), tostring(ban.player_name or "Unknown"), tostring(ban.reason or ""),
        json.encode(ban.identifiers or {}), tonumber(ban.timestamp) or 0,
        tonumber(ban.expires) or 0, tostring(ban.admin or "System"),
        tostring(ban.detection or ""), tostring(ban.screenshot or ""),
    })
end

function BanManager.load_bans()
    if not mysql_ready() then
        error("[SecureServe] oxmysql is required for SQL ban enforcement; will not start with an empty ban list")
    end
    create_tables()
    local migrated = MySQL.scalar.await("SELECT meta_value FROM nerp_ac_meta WHERE meta_key='legacy_json_imported'")
    if not migrated then
        local old = decode_json_bans()
        for _, ban in ipairs(old) do
            if ban.id and type(ban.identifiers) == "table" then
                sql_upsert(ban)
            end
        end
        MySQL.update.await("INSERT INTO nerp_ac_meta (meta_key,meta_value) VALUES ('legacy_json_imported',?)", {
            tostring(os.time())
        })
        logger.info(("Imported %d historical bans from bans.json into SQL"):format(#old))
    end

    local rows = MySQL.query.await([[SELECT * FROM nerp_ac_bans
        WHERE revoked_at IS NULL AND (expires_at=0 OR expires_at>?) ORDER BY banned_at,id]], {os.time()})
    BanManager.bans = {}
    BanManager.pending_bans = {}
    for _, row in ipairs(rows or {}) do
        local ok, identifiers = pcall(json.decode, row.identifiers_json or "{}")
        if ok and type(identifiers) == "table" then
            BanManager.bans[#BanManager.bans + 1] = {
                id=tostring(row.id), player_name=row.player_name, reason=row.reason,
                identifiers=identifiers, timestamp=tonumber(row.banned_at) or 0,
                expires=tonumber(row.expires_at) or 0, admin=row.admin,
                detection=row.detection, screenshot=row.screenshot
            }
        else
            logger.error("Invalid identifiers JSON for SQL ban " .. tostring(row.id))
        end
    end
    rebuild_index()
    logger.info(("Loaded %d active bans from SQL"):format(#BanManager.bans))
end

function BanManager.save_bans()
    -- Preserve the existing in-memory interface for admin panels while writing
    -- authoritative changes through SQL before reporting success.
    if #BanManager.pending_bans > 0 then
        for _, ban in ipairs(BanManager.pending_bans) do
            sql_upsert(ban)
            BanManager.bans[#BanManager.bans + 1] = ban
        end
        BanManager.pending_bans = {}
    end
    BanManager.dirty = false
    rebuild_index()
    return true
end

function BanManager.get_sync_bans()
    return BanManager.bans
end

function BanManager.clean_expired_bans()
    if not BanManager.bans or #BanManager.bans == 0 then return end
    local now = os.time()
    local kept = {}
    local removed = false
    for _, ban in ipairs(BanManager.bans) do
        if ban.expires and ban.expires > 0 and now > ban.expires then
            removed = true
        else
            kept[#kept + 1] = ban
        end
    end
    if removed then
        BanManager.bans = kept
        rebuild_index()
    end
end

function BanManager.format_time_remaining(seconds)
    if seconds < 60 then return seconds .. " seconds"
    elseif seconds < 3600 then return math.floor(seconds / 60) .. " minutes"
    elseif seconds < 86400 then return math.floor(seconds / 3600) .. " hours"
    else return math.floor(seconds / 86400) .. " days" end
end

function BanManager.get_player_identifiers(source)
    local identifiers = {}
    local src = tonumber(source)
    if not src or src <= 0 then return identifiers end

    for _, t in ipairs({"steam", "license", "xbl", "live", "discord", "fivem", "ip"}) do
        local id = GetPlayerIdentifierByType(src, t)
        if id then identifiers[t] = id end
    end

    if GetNumPlayerTokens then
        identifiers.tokens = {}
        for i = 0, GetNumPlayerTokens(src) - 1 do
            identifiers.tokens[#identifiers.tokens + 1] = GetPlayerToken(src, i)
        end
    end
    if GetPlayerEndpoint then identifiers.endpoint = GetPlayerEndpoint(src) end
    if GetPlayerGuid     then identifiers.guid     = GetPlayerGuid(src)     end

    return identifiers
end

function BanManager.check_ban(identifiers)
    if not identifiers then return false, nil end

    for id_type, id_value in pairs(identifiers) do
        if id_type ~= "tokens" and type(id_value) == "string" then
            local ban = BanManager.bans_index[id_value]
            if ban then
                if not (ban.expires and ban.expires > 0 and os.time() > ban.expires) then
                    return true, ban
                end
            end
        end
    end

    if identifiers.license then
        local clean_a = identifiers.license:gsub("license2?:", "")
        for _, ban in ipairs(BanManager.bans) do
            if ban.identifiers and ban.identifiers.license then
                local clean_b = ban.identifiers.license:gsub("license2?:", "")
                if clean_a == clean_b then
                    if not (ban.expires and ban.expires > 0 and os.time() > ban.expires) then
                        return true, ban
                    end
                end
            end
        end
    end

    if identifiers.tokens then
        for _, ban in ipairs(BanManager.bans) do
            if ban.identifiers and ban.identifiers.tokens then
                for _, t in ipairs(identifiers.tokens) do
                    for _, bt in ipairs(ban.identifiers.tokens) do
                        if t == bt then
                            if not (ban.expires and ban.expires > 0 and os.time() > ban.expires) then
                                return true, ban
                            end
                        end
                    end
                end
            end
        end
    end

    return false, nil
end

function BanManager.is_banned(identifier)
    if not identifier then return false end
    local ban = BanManager.bans_index[identifier]
    if ban and not (ban.expires and ban.expires > 0 and os.time() > ban.expires) then
        return true, ban
    end
    return false, nil
end

function BanManager.ban_player(player_id, reason, details)
    if not player_id or not reason then return false end

    local pid = tonumber(player_id)
    if not pid or pid <= 0 then
        logger.error("Invalid player ID: " .. tostring(player_id))
        return false
    end

    local identifiers = BanManager.get_player_identifiers(pid)
    if not next(identifiers) then
        logger.error("No identifiers for player " .. pid)
        return false
    end

    local already_banned, existing = BanManager.check_ban(identifiers)
    if already_banned then
        logger.info("Player " .. pid .. " already banned (banId " .. (existing.id or "?") .. ")")
        return false
    end

    if type(details) ~= "table" then
        details = { detection = tostring(details or reason) }
    end
    details.detection = details.detection or reason

    local expires = 0
    if details.time and tonumber(details.time) then
        local mins = tonumber(details.time)
        if mins == -1 then
            DropPlayer(tostring(pid), "Kicked: " .. reason)
            return false
        end
        if mins > 0 and mins < 2147483647 then
            expires = os.time() + (mins * 60)
        end
    end

    local admin = details.admin or "System"
    local player_name = GetPlayerName(pid) or "Unknown"

    local ban_data = {
        id          = tostring(BanManager.next_ban_id),
        player_name = player_name,
        reason      = reason,
        identifiers = identifiers,
        timestamp   = os.time(),
        expires     = expires,
        admin       = admin,
        detection   = details.detection,
        screenshot  = details.screenshot,
    }

    BanManager.next_ban_id = BanManager.next_ban_id + 1
    -- Write the ban to SQL before dropping the player.
    local persisted, persistErr = pcall(sql_upsert, ban_data)
    if not persisted then
        logger.error("SQL ban write failed: " .. tostring(persistErr))
        return false
    end
    BanManager.bans[#BanManager.bans + 1] = ban_data
    rebuild_index()

    logger.warn(("Banned %s (id %s, banId %s) reason: %s"):format(player_name, pid, ban_data.id, reason))

    Citizen.CreateThread(function()
        Citizen.Wait(3000)
        if GetPlayerName(pid) then
            local expire_text = expires > 0 and ("\nExpires: " .. os.date("%Y-%m-%d %H:%M:%S", expires)) or ""
            DropPlayer(pid, "You have been banned.\nReason: " .. reason .. expire_text)
        end
    end)

    if DiscordLogger and type(DiscordLogger.log_ban) == "function" then
        local screenshot = ban_data.screenshot
        if type(screenshot) ~= "string" or not screenshot:find("^https?://") then
            screenshot = nil
        end

        if screenshot then
            DiscordLogger.log_ban(pid, reason, ban_data, screenshot)
        elseif type(DiscordLogger.request_screenshot) == "function" then
            DiscordLogger.request_screenshot(pid, "Ban: " .. reason, function(url)
                if url and url ~= "" then
                    ban_data.screenshot = url
                    BanManager.dirty = true
                end
                DiscordLogger.log_ban(pid, reason, ban_data, ban_data.screenshot)
            end, 10)
        else
            DiscordLogger.log_ban(pid, reason, ban_data, nil)
        end
    end

    TriggerEvent("playerBanned", pid, reason, admin)

    Citizen.CreateThread(function()
        TriggerClientEvent("SecureServe:ShowWindowsBluescreen", pid)
        Wait(3000)
        TriggerClientEvent("SecureServe:ForceSocialClubUpdate", pid)
        Wait(500)
        TriggerClientEvent("SecureServe:ForceUpdate", pid)
        BanManager.active_connections[tostring(pid)] = nil
    end)

    return true
end

function BanManager.unban_player(identifier)
    if not identifier then return false end

    local found = false
    local kept  = {}

    for _, ban in ipairs(BanManager.bans) do
        local is_match = false

        if ban.id and tostring(ban.id) == tostring(identifier) then
            is_match = true
        end

        if not is_match and ban.identifiers then
            for id_type, id_value in pairs(ban.identifiers) do
                if type(id_value) == "string" and id_value == identifier then
                    is_match = true
                    break
                end
                if id_type == "license" or (type(identifier) == "string" and identifier:find("license:") == 1) then
                    if type(id_value) == "string" then
                        local a = id_value:gsub("license2?:", "")
                        local b = (type(identifier) == "string" and identifier or ""):gsub("license2?:", "")
                        if a == b and a ~= "" then
                            is_match = true
                            break
                        end
                    end
                end
            end
        end

        if is_match then
            found = true
        else
            kept[#kept + 1] = ban
        end
    end

    if found then
        local ids = {}
        for _, ban in ipairs(BanManager.bans) do
            local retained = false
            for _, entry in ipairs(kept) do
                if entry == ban then retained = true; break end
            end
            if not retained then ids[#ids+1] = tostring(ban.id) end
        end
        for _, id in ipairs(ids) do
            MySQL.update.await("UPDATE nerp_ac_bans SET revoked_at=? WHERE id=? AND revoked_at IS NULL", {os.time(), id})
        end
        BanManager.bans = kept
        rebuild_index()
        return true
    end
    return false
end

-- Admin lookup must query the authoritative SQL table, not the active
-- enforcement cache. Include expired and revoked records for audit/history.
function BanManager.get_all_bans()
    local rows = MySQL.query.await([[SELECT id,player_name,reason,identifiers_json,
        banned_at,expires_at,admin,detection,screenshot,revoked_at
        FROM nerp_ac_bans ORDER BY banned_at DESC, id DESC LIMIT 2000]]) or {}
    local bans = {}
    for _, row in ipairs(rows) do
        local ok, identifiers = pcall(json.decode, row.identifiers_json or "{}")
        if not ok or type(identifiers) ~= "table" then identifiers = {} end
        bans[#bans + 1] = {
            id=tostring(row.id), player_name=row.player_name, reason=row.reason,
            identifiers=identifiers, timestamp=tonumber(row.banned_at) or 0,
            expires=tonumber(row.expires_at) or 0, admin=row.admin,
            detection=row.detection, screenshot=row.screenshot,
            revoked_at=row.revoked_at and tonumber(row.revoked_at) or nil
        }
    end
    return bans
end

function BanManager.get_recent_bans(count)
    count = tonumber(count) or 10
    local result = {}
    local total = #BanManager.bans
    for i = math.max(1, total - count + 1), total do
        result[#result + 1] = BanManager.bans[i]
    end
    return result
end

-- Read-only export for the server-only telemetry bridge. Do not expose tokens/IPs.
exports("GetSyncBans", function()
    local result = {}
    for _, b in ipairs(BanManager.bans) do
        local ids = b.identifiers or {}
        result[#result+1] = {
            id=b.id, player_name=b.player_name, reason=b.reason,
            timestamp=b.timestamp, expires=b.expires,
            identifiers={license=ids.license, license2=ids.license2, fivem=ids.fivem}
        }
    end
    if #result == 0 then return "[]" end
    return json.encode(result)
end)

return BanManager
