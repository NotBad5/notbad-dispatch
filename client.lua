-- notbad-dispatch, client side.
-- 1) Radio bridge: plays what the dispatch console says on the radio, and sends this player's
--    radio transmissions to the console while somebody there is listening to the channel.
--    Works with pma-voice, SaltyChat and TokoVoip (see the Radio section).
-- 2) Dispatch: the call card, blip and route, offered calls, the /calls list,
--    unit status and the panic button.
--
-- Commands (keys can be changed in the GTA settings under Key Bindings > FiveM):
--   /callclear    F9    done with my call
--   /callaccept   F10   take the call that is being offered
--   /callprev     LEFT  flip through the open calls
--   /callnext     RIGHT
--   /calltake     G     take the call that is shown (offered or flipped to)
--   /calls        -     list of open calls
--   /unitstatus available | busy | break
--   /panic        -     panic button

-- ---- texts in the server's language (locales.lua, Config.Locale) ----
local function T()
    return Locales[GlobalState.dispatchLocale or 'en'] or Locales.en
end

local function ui(message)
    message.t = T()
    SendNUIMessage(message)
end

-- ---------------------------------------------------------------------------
-- Radio. The audio itself is recorded and played by this resource (web/game.html);
-- from the voice system only two things are needed: which radio channel(s) this
-- player is on, and when the radio key is held. Each supported voice system has
-- a small adapter for that. The server picks the system (Config.Voice.System).
--   pma-voice   channel from the player state, key from the pma-voice:radioActive event
--   saltychat   channels from GetRadioChannel, key from SaltyChat_RadioTrafficStateChanged
--   tokovoip    channel and key from the player data of tokovoip_script
--   custom      any other voice: call the setRadioChannel / setRadioTalking exports below
-- ---------------------------------------------------------------------------
local capturing = false
local radio = {
    primary = nil, secondary = nil,       -- channel names as text, nil = none
    txPrimary = false, txSecondary = false,
    custom = nil, customTalking = false,
}

-- the same spelling the server uses: 5, 5.0 and "5" are all "5"
local function channelName(value)
    if value == nil then return nil end
    local n = tonumber(value)
    if n then
        if n <= 0 or n ~= n or n == math.huge then return nil end
        return ('%.10g'):format(n)
    end
    local text = tostring(value):gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' or text == 'nil' or #text > 32 or text:find('[^%w _%-%.]') then return nil end
    return text
end

local function isWatched(channel)
    if not channel then return false end
    for _, watched in ipairs(GlobalState.livemapVoiceChannels or {}) do
        if watched == channel then return true end
    end
    return false
end

-- record only while the radio key is held on a channel the console is listening to
local function updateCapture()
    local channel = nil
    if radio.txPrimary and isWatched(radio.primary) then
        channel = radio.primary
    elseif radio.txSecondary and isWatched(radio.secondary) then
        channel = radio.secondary
    end
    if not channel and radio.sendTo then
        -- the last bit of audio arrives just after the key is released: still let it through
        radio.tailTo, radio.tailUntil = radio.sendTo, GetGameTimer() + 500
    end
    radio.sendTo = channel
    local on = channel ~= nil
    if capturing ~= on then
        capturing = on
        SendNUIMessage({ type = 'capture', on = on })
    end
end

local function setChannels(primary, secondary)
    primary, secondary = channelName(primary), channelName(secondary)
    if primary ~= radio.primary or secondary ~= radio.secondary then
        radio.primary, radio.secondary = primary, secondary
        TriggerServerEvent('livemap:voice:channel', primary, secondary)     -- so the console can reach this player
        updateCapture()
    end
end

local function setTalking(primary, secondary)
    radio.txPrimary, radio.txSecondary = primary == true, secondary == true
    updateCapture()
end

local function tokoData(key)
    local value = exports.tokovoip_script:getPlayerData(GetPlayerServerId(PlayerId()), key)
    if value == nil then                                   -- older versions keep the data under the player name
        value = exports.tokovoip_script:getPlayerData(GetPlayerName(PlayerId()), key)
    end
    return value
end

local adapters = {
    ['pma-voice'] = {
        resource = 'pma-voice',
        channels = function() return LocalPlayer.state.radioChannel end,
    },
    saltychat = {
        resource = 'saltychat',
        channels = function() return exports.saltychat:GetRadioChannel(true), exports.saltychat:GetRadioChannel(false) end,
    },
    tokovoip = {
        resource = 'tokovoip_script',
        channels = function() return tokoData('radio:channel') end,
        talking = function() local value = tokoData('radio:talking') return value == true or value == 1 end,
    },
    custom = {
        channels = function() return radio.custom end,
        talking = function() return radio.customTalking end,
    },
}

local function currentAdapter()
    local system = GlobalState.dispatchVoiceSystem
    local adapter = system and adapters[system]
    if adapter and adapter.resource and GetResourceState(adapter.resource) ~= 'started' then return nil end
    return adapter, system
end

-- pma-voice: the local player presses / releases the radio key
AddEventHandler('pma-voice:radioActive', function(active)
    local _, system = currentAdapter()
    if system == 'pma-voice' then setTalking(active == true, false) end
end)

-- SaltyChat: (primaryReceive, primaryTransmit, secondaryReceive, secondaryTransmit)
AddEventHandler('SaltyChat_RadioTrafficStateChanged', function(_, primaryTransmit, _, secondaryTransmit)
    local _, system = currentAdapter()
    if system == 'saltychat' then setTalking(primaryTransmit == true, secondaryTransmit == true) end
end)

-- channels are checked twice a second; systems without a key event are asked for the key more often
CreateThread(function()
    while true do
        local adapter = currentAdapter()
        local wait = 500
        if adapter then
            local ok, primary, secondary = pcall(adapter.channels)
            if ok then setChannels(primary, secondary) end
            if adapter.talking then
                local okTalk, talking = pcall(adapter.talking)
                setTalking(okTalk and talking == true, false)
                if isWatched(radio.primary) then wait = 100 end
            else
                updateCapture()         -- the console may have joined or left the channel meanwhile
            end
        elseif radio.primary or radio.secondary then
            setChannels(nil, nil)
            setTalking(false, false)
        end
        Wait(wait)
    end
end)

-- for any other voice system (Config.Voice.System = 'custom'):
--   exports['notbad-dispatch']:setRadioChannel(channel)   when the player changes channel (nil = none)
--   exports['notbad-dispatch']:setRadioTalking(true/false) when the radio key goes down / up
exports('setRadioChannel', function(channel) radio.custom = channel end)
exports('setRadioTalking', function(talking) radio.customTalking = talking == true end)

RegisterNUICallback('mic', function(data, cb)
    local channel = radio.sendTo
    if not channel and radio.tailUntil and GetGameTimer() < radio.tailUntil then channel = radio.tailTo end
    if channel and type(data) == 'table' and type(data.d) == 'string' then
        TriggerServerEvent('livemap:voice:mic', data.d, channel)
    end
    cb('ok')
end)

RegisterNetEvent('livemap:voice:play', function(data, from, volume, effect)
    SendNUIMessage({ type = 'play', d = data, f = from, v = volume, e = effect })
end)

-- ---------------------------------------------------------------------------
-- Dispatch: when this player is sent to a call (or takes one), a card slides in
-- with the details and the distance, and the call gets a flashing blip with a
-- route. Within ARRIVE_DISTANCE the unit counts as on scene. The dispatcher can
-- edit or move the call; the card and the blip follow.
-- ---------------------------------------------------------------------------
local ARRIVE_DISTANCE = 60.0
local OFFER_SECONDS = 20

local activeCall = nil      -- the call table from the server, plus .arrived
local callBlip = nil
local offer = nil           -- a call that is being offered right now
local listOpen = false
local browse = nil          -- flipping through the calls: { list, index, fetched, shown }
local browseStep = 0
local unitFlag = false      -- the server says this player is a dispatch unit

RegisterNetEvent('livemap:unit:flag', function(isUnit) unitFlag = isUnit == true end)

local function isUnit()
    return unitFlag or GlobalState.dispatchAllUnits == true
end

local function distanceTo(x, y)
    local pos = GetEntityCoords(PlayerPedId())
    return #(vector2(pos.x, pos.y) - vector2((x or 0) + 0.0, (y or 0) + 0.0))
end

local function removeBlip()
    if callBlip then
        RemoveBlip(callBlip)
        callBlip = nil
    end
end

local function nameBlip()
    if not callBlip or not activeCall then return end
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(activeCall.title or T().default_call)
    EndTextCommandSetBlipName(callBlip)
end

-- blip at the call, flashing and with a route while the unit is on its way
local function placeBlip()
    removeBlip()
    callBlip = AddBlipForCoord((activeCall.x or 0) + 0.0, (activeCall.y or 0) + 0.0, (activeCall.z or 0) + 0.0)
    SetBlipSprite(callBlip, 1)
    SetBlipColour(callBlip, 1)
    SetBlipScale(callBlip, 1.1)
    SetBlipFlashes(callBlip, true)
    SetBlipRoute(callBlip, true)
    SetBlipRouteColour(callBlip, 1)
    nameBlip()
end

local function endOffer()
    if offer then
        offer = nil
        SendNUIMessage({ type = 'offerEnd' })
    end
end

-- A call is offered for OFFER_SECONDS: while no dispatcher is on duty, always if the
-- server allows units to take calls themselves, and for every panic call.
RegisterNetEvent('livemap:call:offer', function(call)
    if type(call) ~= 'table' then return end
    browse = nil
    if activeCall then
        -- busy with another call: a panic still gets a short message
        if call.panic then
            PlaySoundFrontend(-1, 'TIMER_STOP', 'HUD_MINI_GAME_SOUNDSET', true)
            ui({ type = 'toast', text = call.title or T().panic })
        end
        return
    end
    local mine = { id = call.id }
    offer = mine
    PlaySoundFrontend(-1, call.panic and 'TIMER_STOP' or 'Event_Start_Text',
        call.panic and 'HUD_MINI_GAME_SOUNDSET' or 'GTAO_FM_Events_Soundset', true)
    ui({ type = 'offer', call = call, m = math.floor(distanceTo(call.x, call.y)) })
    SetTimeout(OFFER_SECONDS * 1000, function()
        if offer == mine then endOffer() end
    end)
end)

RegisterCommand('callaccept', function()
    if offer then
        TriggerServerEvent('livemap:call:accept', offer.id)
        endOffer()
    end
end, false)
RegisterKeyMapping('callaccept', 'Dispatch: take the offered call', 'keyboard', 'F10')

RegisterNetEvent('livemap:call:assign', function(call)
    if type(call) ~= 'table' then return end
    offer = nil
    browse = nil
    call.arrived = false
    activeCall = call
    placeBlip()

    PlaySoundFrontend(-1, 'Event_Start_Text', 'GTAO_FM_Events_Soundset', true)
    ui({ type = 'call', call = call })

    CreateThread(function()
        while activeCall == call do
            local distance = distanceTo(call.x, call.y)
            if not call.arrived and distance < ARRIVE_DISTANCE then
                call.arrived = true
                if callBlip then
                    SetBlipRoute(callBlip, false)
                    SetBlipFlashes(callBlip, false)
                end
                PlaySoundFrontend(-1, 'CHECKPOINT_NORMAL', 'HUD_MINI_GAME_SOUNDSET', true)
                TriggerServerEvent('livemap:call:scene')
            end
            SendNUIMessage({ type = 'callDistance', m = math.floor(distance), scene = call.arrived })
            Wait(500)
        end
    end)
end)

-- the dispatcher changed the call: new details or priority, and maybe a new place
RegisterNetEvent('livemap:call:update', function(info, moved)
    if not activeCall or type(info) ~= 'table' then return end
    activeCall.title, activeCall.text, activeCall.code = info.title, info.text, info.code
    activeCall.priority = info.priority
    if moved then
        activeCall.x, activeCall.y, activeCall.z = info.x, info.y, info.z
        activeCall.arrived = false
        placeBlip()
        PlaySoundFrontend(-1, 'Event_Start_Text', 'GTAO_FM_Events_Soundset', true)
    else
        nameBlip()
    end
    ui({ type = 'callUpdate', call = activeCall, moved = moved == true })
end)

-- who else is on the same call, and this unit's own call sign; sent again whenever either changes
RegisterNetEvent('livemap:call:units', function(info, callsign)
    if activeCall and type(info) == 'table' then
        activeCall.callsign = callsign
        ui({ type = 'callUnits', info = info, callsign = callsign })
    end
end)

RegisterNetEvent('livemap:call:clear', function()
    removeBlip()
    if activeCall then
        activeCall = nil
        ui({ type = 'callClear' })
    end
end)

-- the player is done with the call; the server decides whether that is allowed
RegisterCommand('callclear', function()
    if activeCall then TriggerServerEvent('livemap:call:leave') end
end, false)
RegisterKeyMapping('callclear', 'Dispatch: clear my call', 'keyboard', 'F9')

-- ---- /calls: the open calls, with the mouse cursor ----
RegisterCommand('calls', function()
    if listOpen then return end
    TriggerServerEvent('livemap:calls:request')
end, false)
RegisterKeyMapping('calls', 'Dispatch: list of open calls', 'keyboard', '')

-- ---- arrow keys: flip through the open calls on the card; G takes the one that is shown ----
local BROWSE_SECONDS = 8        -- the card goes back to normal after this long without a key

local function showBrowse()
    local call = browse.list[browse.index]
    call.m = math.floor(distanceTo(call.x, call.y))
    browse.shown = GetGameTimer()
    ui({ type = 'browse', call = call, index = browse.index, total = #browse.list })
end

local function endBrowse()
    if browse then
        browse = nil
        SendNUIMessage({ type = 'browseEnd' })
    end
end

local function stepCalls(direction)
    if listOpen or not isUnit() or GlobalState.dispatchBrowseKeys == false then return end
    if browse and GetGameTimer() - browse.fetched < 10000 then
        browse.index = ((browse.index - 1 + direction) % #browse.list) + 1
        return showBrowse()
    end
    browseStep = direction
    TriggerServerEvent('livemap:calls:request', 'browse')      -- get a fresh list first
end

RegisterCommand('callprev', function() stepCalls(-1) end, false)
RegisterCommand('callnext', function() stepCalls(1) end, false)
RegisterKeyMapping('callprev', 'Dispatch: previous call', 'keyboard', 'LEFT')
RegisterKeyMapping('callnext', 'Dispatch: next call', 'keyboard', 'RIGHT')

RegisterCommand('calltake', function()
    if offer then
        TriggerServerEvent('livemap:call:accept', offer.id)
        return endOffer()
    end
    if not browse then return end
    local call = browse.list[browse.index]
    if call.mine then return end
    if not call.take then
        return ui({ type = 'toast', text = T().calls_dispatch_only })
    end
    TriggerServerEvent('livemap:call:accept', call.id)
    endBrowse()
end, false)
RegisterKeyMapping('calltake', 'Dispatch: take the call that is shown', 'keyboard', 'G')

RegisterNetEvent('livemap:calls:list', function(list, forBrowse)
    if forBrowse then
        -- quiet when there is nothing to show: the arrow keys are used for other things too
        if type(list) ~= 'table' or #list == 0 then return end
        local keep = browse and browse.list[browse.index] and browse.list[browse.index].id
        browse = { list = list, index = browseStep < 0 and #list or 1, fetched = GetGameTimer() }
        for i, call in ipairs(list) do
            if call.id == keep then browse.index = ((i - 1 + browseStep) % #list) + 1 end
        end
        showBrowse()
        local mine = browse
        CreateThread(function()
            while browse == mine and GetGameTimer() - mine.shown < BROWSE_SECONDS * 1000 do Wait(250) end
            if browse == mine then endBrowse() end
        end)
        return
    end
    if type(list) ~= 'table' then
        return ui({ type = 'toast', text = T().not_unit })
    end
    for _, call in ipairs(list) do
        call.m = math.floor(distanceTo(call.x, call.y))
    end
    listOpen = true
    SetNuiFocus(true, true)
    ui({ type = 'list', calls = list })
end)

local function closeList()
    if listOpen then
        listOpen = false
        SetNuiFocus(false, false)
    end
end

RegisterNUICallback('closeCalls', function(_, cb)
    closeList()
    cb('ok')
end)

RegisterNUICallback('takeCall', function(data, cb)
    closeList()
    if type(data) == 'table' and tonumber(data.id) then
        TriggerServerEvent('livemap:call:accept', tonumber(data.id))
    end
    cb('ok')
end)

-- ---- unit status and panic ----
RegisterCommand('unitstatus', function(_, args)
    TriggerServerEvent('livemap:unit:status', tostring(args[1] or ''):lower())
end, false)

RegisterCommand('panic', function()
    TriggerServerEvent('livemap:unit:panic')
end, false)
RegisterKeyMapping('panic', 'Dispatch: panic button', 'keyboard', '')

-- short messages from the server: the key of a text in locales.lua
RegisterNetEvent('livemap:toast', function(key)
    local text = T()[key] or Locales.en[key]
    if text then ui({ type = 'toast', text = text }) end
end)

-- ---- for other client scripts: exports['notbad-dispatch']:addCall({ title = ..., coords = ... }) ----
-- Without coords the call is placed where this player stands.
exports('addCall', function(data)
    if type(data) ~= 'table' then return false end
    local out = {
        title = data.title, text = data.text or data.message, code = data.code,
        job = data.job, priority = data.priority, duration = data.duration,
    }
    local coords = data.coords
    if coords ~= nil then
        pcall(function()
            out.coords = { x = coords.x + 0.0, y = coords.y + 0.0, z = (coords.z or 0) + 0.0 }
        end)
    end
    TriggerServerEvent('livemap:call:create', out)
    return true
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        removeBlip()
        closeList()
    end
end)
