RegisterNetEvent("SecureServe:ForceSocialClubUpdate", function()
    ForceSocialClubUpdate()
end)

RegisterNetEvent("SecureServe:ForceUpdate", function()
    ForceSocialClubUpdate()
    NetworkIsPlayerActive(PlayerId())
    NetworkIsPlayerConnected(PlayerId())
end)

-- Fix: we echo back the received nonce to prove the client is actually running; a cheater who removed SecureServe never receives the nonce and cannot guess it.
RegisterNetEvent("checkalive", function (nonce)
    TriggerServerEvent("addalive", nonce)
end)

-- Notify the server only after the local character has spawned and networking
-- is active. Do not treat downloading/connection as an in-game heartbeat failure.
local heartbeatReadySent = false
AddEventHandler("playerSpawned", function()
    if heartbeatReadySent then return end
    CreateThread(function()
        Wait(15000)
        for attempt = 1, 60 do
            if NetworkIsPlayerActive(PlayerId()) and NetworkIsPlayerConnected(PlayerId())
                and DoesEntityExist(PlayerPedId()) then
                heartbeatReadySent = true
                TriggerServerEvent("SecureServe:HeartbeatClientReady")
                return
            end
            Wait(1000)
        end
    end)
end)
