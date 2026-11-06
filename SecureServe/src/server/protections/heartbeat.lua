local logger         = require("server/core/logger")
local ban_manager    = require("server/core/ban_manager")
local config_manager = require("server/core/config_manager")

local Heartbeat = {
    playerHeartbeats        = {},
    alive                   = {},
    allowedStop             = {},
    pendingReady            = {},
    failureCount            = {},
    silentStrikes           = {},
    playerJoinTime          = {},
    aliveNonce              = {},
    challengeSequence       = {},
    recentRecovery          = {},
    playerReadyAt           = {},
    challengeStartedAt      = {},
    loadingTimeout          = 600,
    postReadyGrace          = 120,
    checkInterval           = 10000,
    maxFailures             = 5,
    heartbeatCheckInterval  = 5000,
    responseGraceSeconds    = 8,
    timeoutThreshold        = 90,
    gracePeriod             = 90,
    silenceStrikes          = 3,
    initialized             = false,
}

local function seconds()
    return os.time()
end

local function cleanup_player(pid)
    Heartbeat.playerHeartbeats[pid] = nil
    Heartbeat.alive[pid]            = nil
    Heartbeat.allowedStop[pid]      = nil
    Heartbeat.pendingReady[pid]     = nil
    Heartbeat.failureCount[pid]     = nil
    Heartbeat.silentStrikes[pid]    = nil
    Heartbeat.playerJoinTime[pid]   = nil
    Heartbeat.aliveNonce[pid]       = nil
    Heartbeat.challengeSequence[pid] = nil
    Heartbeat.recentRecovery[pid]   = nil
    Heartbeat.playerReadyAt[pid]    = nil
    Heartbeat.challengeStartedAt[pid] = nil
end

-- Fix: unpredictable per-challenge nonce; a client must echo it back to prove it is alive (anti-spoof for "addalive").
local nonce_counter = 0
local function make_nonce()
    nonce_counter = nonce_counter + 1
    return string.format("%x-%x-%x", os.time(), nonce_counter, math.random(1, 0x7fffffff))
end

local function mark_joined(pid, at)
    if not pid then return end
    if not Heartbeat.playerJoinTime[pid] then
        Heartbeat.playerJoinTime[pid] = at or seconds()
    end
end

local function mark_ready(pid, at)
    if not pid then return end

    mark_joined(pid, at)
    Heartbeat.pendingReady[pid] = true

    if Heartbeat.playerHeartbeats[pid] then
        Heartbeat.allowedStop[pid] = true
        Heartbeat.pendingReady[pid] = nil
    end
end

local function mark_heartbeat(pid, at)
    if not pid then return end

    local now = at or seconds()
    mark_joined(pid, now)

    Heartbeat.playerHeartbeats[pid] = now
    Heartbeat.silentStrikes[pid] = 0
    Heartbeat.recentRecovery[pid] = now

    if Heartbeat.pendingReady[pid] then
        Heartbeat.allowedStop[pid] = true
        Heartbeat.pendingReady[pid] = nil
    end
end

local function is_connected(pid)
    return pid and GetPlayerName(pid) ~= nil
end

local function is_ready_for_alive_check(pid, now)
    if not is_connected(pid) then return false end

    local joined_at = Heartbeat.playerJoinTime[pid]
    if not joined_at then return false end

    -- Never enforce during ordinary connection loading. Client signals ready
    -- only after spawning and network initialization.
    local ready_at = Heartbeat.playerReadyAt[pid]
    if ready_at then
        return (now - ready_at) >= Heartbeat.postReadyGrace
            and (now - joined_at) >= Heartbeat.gracePeriod
    end

    -- Bound the exemption so disabling the SecureServe client cannot permanently
    -- bypass monitoring. Loading beyond this limit is abnormal and logged.
    return (now - joined_at) >= Heartbeat.loadingTimeout
end

local function can_punish_now(playerId, reason)
    local min_seconds = tonumber(SecureServe and SecureServe.MinimumOnlineSecondsBeforeBan) or 0
    if min_seconds <= 0 then return true end

    local joined_at = Heartbeat.playerJoinTime[playerId]
        or (_G.SecureServe_PlayerJoinedAt and _G.SecureServe_PlayerJoinedAt[playerId])

    if not joined_at then return true end

    local online_seconds = seconds() - joined_at
    if online_seconds >= min_seconds then return true end

    logger.warn(("Heartbeat punish ignored for %s; online %ds below %ds: %s")
        :format(tostring(playerId), online_seconds, min_seconds, tostring(reason)))
    return false
end

local function load_config()
    local config = (SecureServe and SecureServe.Module and SecureServe.Module.Heartbeat) or {}

    Heartbeat.checkInterval          = tonumber(config.CheckInterval)          or 10000
    Heartbeat.maxFailures            = tonumber(config.MaxFailures)            or 5
    Heartbeat.heartbeatCheckInterval = tonumber(config.HeartbeatCheckInterval) or 5000
    Heartbeat.timeoutThreshold       = tonumber(config.TimeoutThreshold)       or 90
    Heartbeat.gracePeriod            = tonumber(config.GracePeriod)            or 30
    Heartbeat.silenceStrikes         = tonumber(config.SilenceStrikes)         or 3
    Heartbeat.responseGraceSeconds   = math.max(2, tonumber(config.ResponseGraceSeconds) or 8)
    Heartbeat.loadingTimeout          = math.max(180, tonumber(config.LoadingTimeoutSeconds) or 600)
    Heartbeat.postReadyGrace          = math.max(30, tonumber(config.PostReadyGraceSeconds) or 120)
end

function Heartbeat.initialize()
    if Heartbeat.initialized then return end
    Heartbeat.initialized = true

    logger.info("Initializing Heartbeat protection module")

    load_config()
    Heartbeat.setupEventHandlers()
    Heartbeat.startMonitoringThreads()

    logger.info("Heartbeat protection module initialized")
end

function Heartbeat.setupEventHandlers()
    AddEventHandler("playerJoining", function()
        mark_joined(tonumber(source), seconds())
    end)

    AddEventHandler("playerDropped", function()
        local pid = tonumber(source)
        if pid then cleanup_player(pid) end
    end)

    RegisterNetEvent("mMkHcvct3uIg04STT16I:cbnF2cR9ZTt8NmNx2jQS", function(key)
        local pid = tonumber(source)
        if not pid then return end

        if type(key) ~= "string" or #key < 15 or #key > 35 then
            DropPlayer(tostring(pid), "Invalid heartbeat key")
            return
        end

        mark_heartbeat(pid, seconds())
    end)

    RegisterNetEvent("addalive", function(nonce)
        local pid = tonumber(source)
        if not pid then return end

        -- Fix: we only accept the alive proof if the nonce matches the current challenge; otherwise a client could spam "addalive" to declare itself alive without running.
        local expected = Heartbeat.aliveNonce[pid]
        if not expected or nonce ~= expected then return end

        Heartbeat.aliveNonce[pid] = nil
        Heartbeat.challengeStartedAt[pid] = nil
        Heartbeat.alive[pid] = true
        Heartbeat.recentRecovery[pid] = seconds()
        Heartbeat.failureCount[pid] = 0
    end)

    RegisterNetEvent("SecureServe:HeartbeatClientReady", function()
        local pid = tonumber(source)
        if not pid or not is_connected(pid) then return end
        mark_joined(pid, seconds())
        if not Heartbeat.playerReadyAt[pid] then
            Heartbeat.playerReadyAt[pid] = seconds()
            Heartbeat.failureCount[pid] = 0
            Heartbeat.silentStrikes[pid] = 0
            logger.info(("Heartbeat: player %s finished loading; enforcement begins after %ds"):format(pid, Heartbeat.postReadyGrace))
        end
    end)

    RegisterNetEvent("allowedStop", function()
        mark_ready(tonumber(source), seconds())
    end)

    RegisterNetEvent("playerLoaded", function()
        local pid = tonumber(source)
        if not pid then return end

        mark_heartbeat(pid, seconds())
        Heartbeat.allowedStop[pid] = true
        Heartbeat.pendingReady[pid] = nil
    end)

    RegisterNetEvent("playerSpawneda", function()
        mark_ready(tonumber(source), seconds())
    end)
end

function Heartbeat.startMonitoringThreads()
    Citizen.CreateThread(function()
        while true do
            Citizen.Wait(Heartbeat.heartbeatCheckInterval)
            local now = seconds()

            for _, playerId in ipairs(GetPlayers()) do
                local pid = tonumber(playerId)
                if pid then
                    mark_joined(pid, now)

                    local last = Heartbeat.playerHeartbeats[pid]

                    if last and is_ready_for_alive_check(pid, now)
                        and (now - last) > Heartbeat.timeoutThreshold
                    then
                        Heartbeat.silentStrikes[pid] = (Heartbeat.silentStrikes[pid] or 0) + 1
                        if Heartbeat.silentStrikes[pid] >= Heartbeat.silenceStrikes then
                            -- A recent successful challenge is evidence that the anti-cheat is active.
                            if not Heartbeat.recentRecovery[pid] or (now - Heartbeat.recentRecovery[pid]) > Heartbeat.timeoutThreshold then
                                Heartbeat.banPlayer(pid, "No heartbeat received")
                            end
                            Heartbeat.playerHeartbeats[pid] = nil
                            Heartbeat.silentStrikes[pid] = 0
                        end
                    else
                        Heartbeat.silentStrikes[pid] = 0
         Citizen.CreateThread(function()
        while true do
            -- Only one outstanding challenge per player.  The previous loop
            -- replaced nonces before its response window had elapsed under
            -- certain scheduling conditions, which could reject valid replies.
            local now = seconds()
            local challenged = {}

            for _, playerId in ipairs(GetPlayers()) do
                local pid = tonumber(playerId)
                if pid and is_ready_for_alive_check(pid, now) then
                    -- Do not overwrite a challenge still awaiting its response.
                    if not Heartbeat.aliveNonce[pid] then
                        local nonce = make_nonce()
                        Heartbeat.alive[pid] = false
                        Heartbeat.aliveNonce[pid] = nonce
                        Heartbeat.challengeStartedAt[pid] = now
                        challenged[#challenged + 1] = { pid = pid, nonce = nonce, sentAt = now }
                        TriggerClientEvent("checkalive", pid, nonce)
                    end
                end
            end

            -- CheckInterval is the cadence between challenge batches, not
            -- additional response time. Wait for the response window only.
            Citizen.Wait(Heartbeat.responseGraceSeconds * 1000)

            local checked_at = seconds()
            for _, entry in ipairs(challenged) do
                local pid = entry.pid
                -- Ignore dropped/reconnected players and challenges that
                -- have already been answered or superseded.
                if is_connected(pid) and Heartbeat.aliveNonce[pid] == entry.nonce then
                    Heartbeat.aliveNonce[pid] = nil
                    Heartbeat.challengeStartedAt[pid] = nil

                    if is_ready_for_alive_check(pid, checked_at) then
                        Heartbeat.failureCount[pid] = (Heartbeat.failureCount[pid] or 0) + 1

                        -- Missing challenges alone are inconclusive during lag;
                        -- require a simultaneous absence of regular heartbeats.
                        local last = Heartbeat.playerHeartbeats[pid]
                        local lastValid = math.max(last or 0, Heartbeat.recentRecovery[pid] or 0)
                        if Heartbeat.failureCount[pid] >= Heartbeat.maxFailures
                            and (checked_at - lastValid) > Heartbeat.timeoutThreshold then
                            Heartbeat.banPlayer(pid, "Failed alive checks")
                            Heartbeat.failureCount[pid] = 0
                        end
                    end
                end
            end
            -- Preserve the intended configurable challenge cadence.
            Citizen.Wait(math.max(1000, Heartbeat.checkInterval - Heartbeat.responseGraceSeconds * 1000))
        end
    end)                 end
                end
            end
        end
    end)
end

function Heartbeat.banPlayer(playerId, reason)
    if not is_ready_for_alive_check(playerId, seconds()) then return end
    if not can_punish_now(playerId, reason) then return end

    logger.warn("Heartbeat violation for player " .. tostring(playerId) .. ": " .. reason)

    local cfg = config_manager.get_config()
    local shouldBan = false
    if cfg and cfg.Module and cfg.Module.Heartbeat then
        shouldBan = cfg.Module.Heartbeat.BanOnViolation == true
    end

    -- Missed keep-alive checks can result from hitching, loading, or network loss.
    -- Never permanently ban on heartbeat evidence alone.
    logger.warn("Heartbeat enforcement uses a kick (not a ban); configured BanOnViolation=" .. tostring(shouldBan))
    DropPlayer(tostring(playerId), "SecureServe keep-alive timed out; please reconnect")
end

return Heartbeat
