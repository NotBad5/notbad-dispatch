-- notbad-dispatch: serves the dispatch console through FiveM's built-in HTTP handler.
-- URL: http://<server ip>:<server port>/<resource name>/

local RESOURCE = GetCurrentResourceName()
local page = LoadResourceFile(RESOURCE, 'web/index.html')

local cache, cacheAt = nil, -1000000
local failed = {}   -- wrong password attempts per address

-- ---- password guessing protection ----
-- Per address: MAX_ATTEMPTS wrong passwords lock that address. The first lock lasts LOCK_SECONDS,
-- every further one twice as long, up to LOCK_MAX. Everything is forgotten after FORGET_SECONDS
-- without a wrong try, or after a correct login.
-- All addresses together: SIEGE_FAILS wrong passwords within SIEGE_WINDOW mean somebody is guessing
-- from many addresses; for SIEGE_SECONDS a single wrong password is then enough to lock an address.
-- A console that logged in gets a session token and uses that instead of the password, so
-- dispatchers who are already in keep working even when their address gets locked.
local MAX_ATTEMPTS = 5
local LOCK_SECONDS = 60
local LOCK_MAX = 3600
local FORGET_SECONDS = 3600
local SIEGE_FAILS = 30
local SIEGE_WINDOW = 300
local SIEGE_SECONDS = 600
local TOKEN_IDLE_SECONDS = 12 * 3600

local tokens = {}               -- [token] = { used = time, user = name, admin = bool }
local MAX_CHECKS_PER_SECOND = 2
local checkSecond, checksThisSecond = 0, 0
local failedCount = 0
local recentFails = {}          -- times of the latest wrong passwords, any address
local siegeUntil = 0

-- ---- language of the texts players see in game (locales.lua) ----
local LANG = (type(Locales) == 'table' and Locales[Config.Locale]) and Config.Locale or 'en'
GlobalState.dispatchLocale = LANG        -- client.lua reads this

local function L(key, ...)
    local text = Locales[LANG][key] or Locales.en[key] or key
    if select('#', ...) > 0 then return text:format(...) end
    return text
end

-- ---- history: who did what and when, shown on the console under History ----
local History = type(Config.History) == 'table' and Config.History or {}
local HISTORY_FILE = 'history.json'
local history, historyDirty = {}, false

if History.Enabled ~= false and History.Save ~= false then
    local raw = LoadResourceFile(RESOURCE, HISTORY_FILE)
    if raw then
        local ok, saved = pcall(json.decode, raw)
        if ok and type(saved) == 'table' then history = saved end
    end
end

local function logEvent(text)
    if History.Enabled == false then return end
    history[#history + 1] = { t = os.time(), text = text }
    local keep = tonumber(History.Keep) or 500
    while #history > keep do table.remove(history, 1) end
    historyDirty = true
end

-- written to history.json in the resource folder, at most twice a minute
CreateThread(function()
    while true do
        Wait(30000)
        if historyDirty and History.Save ~= false then
            historyDirty = false
            SaveResourceFile(RESOURCE, HISTORY_FILE, json.encode(history), -1)
        end
    end
end)

local function round(n)
    return math.floor(n * 10 + 0.5) / 10
end

-- ---------------------------------------------------------------------------
-- Dispatcher accounts. Nothing about them is in config.lua: the first account is made on the
-- console itself (first-time setup, with a code from the server console), and that admin adds
-- the others there. Passwords are generated here, shown once, and only kept as salted hashes
-- in accounts.json.
-- ---------------------------------------------------------------------------
local ACCOUNTS_FILE = 'accounts.json'
local HASH_ROUNDS = 500

local accounts, accountCount = {}, 0     -- [username in lower case] = { name, salt, hash, admin, created }

-- SHA-256, needed because FiveM's Lua has no hashing of its own
local SHA_K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function rotr(x, n)
    return ((x >> n) | (x << (32 - n))) & 0xffffffff
end

local function sha256(message)
    local h1, h2, h3, h4 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h5, h6, h7, h8 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    local length = #message
    message = message .. '\128' .. ('\0'):rep((55 - length) % 64) .. string.pack('>I8', length * 8)

    for at = 1, #message, 64 do
        local w = { string.unpack('>I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4', message, at) }
        for i = 17, 64 do
            local x, y = w[i - 15], w[i - 2]
            local s0 = rotr(x, 7) ~ rotr(x, 18) ~ (x >> 3)
            local s1 = rotr(y, 17) ~ rotr(y, 19) ~ (y >> 10)
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff
        end
        local a, b, c, d, e, f, g, h = h1, h2, h3, h4, h5, h6, h7, h8
        for i = 1, 64 do
            local t1 = (h + (rotr(e, 6) ~ rotr(e, 11) ~ rotr(e, 25)) + ((e & f) ~ (~e & g)) + SHA_K[i] + w[i]) & 0xffffffff
            local t2 = ((rotr(a, 2) ~ rotr(a, 13) ~ rotr(a, 22)) + ((a & b) ~ (a & c) ~ (b & c))) & 0xffffffff
            h, g, f, e, d, c, b, a = g, f, e, (d + t1) & 0xffffffff, c, b, a, (t1 + t2) & 0xffffffff
        end
        h1, h2, h3, h4 = (h1 + a) & 0xffffffff, (h2 + b) & 0xffffffff, (h3 + c) & 0xffffffff, (h4 + d) & 0xffffffff
        h5, h6, h7, h8 = (h5 + e) & 0xffffffff, (h6 + f) & 0xffffffff, (h7 + g) & 0xffffffff, (h8 + h) & 0xffffffff
    end
    return ('%08x%08x%08x%08x%08x%08x%08x%08x'):format(h1, h2, h3, h4, h5, h6, h7, h8)
end

-- Random hex that a logged-in user cannot predict: besides clocks and the Lua generator it is
-- mixed with things only the server knows.
local secretSeed = sha256(table.concat({
    GetConvar('sv_licenseKey', ''), GetConvar('rcon_password', ''), GetConvar('sv_hostname', ''),
    tostring(os.time()), tostring(os.clock()), tostring({}), tostring(math.random()),
}, '|'))
local randomCounter = 0

local function randomHex()                  -- 64 hex characters
    randomCounter = randomCounter + 1
    secretSeed = sha256(table.concat({ secretSeed, randomCounter, os.time(), os.clock(), GetGameTimer(), math.random() }, '|'))
    return sha256(secretSeed .. '|out')
end

-- a password that is easy to read out and type: no 0/O, 1/l/I
local PASSWORD_LETTERS = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'

local function randomPassword()
    local hex, out = randomHex(), {}
    for i = 1, 14 do
        local n = tonumber(hex:sub(i * 4 - 3, i * 4), 16) % #PASSWORD_LETTERS + 1
        out[i] = PASSWORD_LETTERS:sub(n, n)
    end
    return table.concat(out, '', 1, 5) .. '-' .. table.concat(out, '', 6, 10) .. '-' .. table.concat(out, '', 11, 14)
end

-- many rounds, so trying passwords against a stolen accounts.json is slow
local function hashPassword(password, salt)
    local hash = sha256(salt .. '|' .. password)
    for _ = 1, HASH_ROUNDS do
        hash = sha256(hash .. salt .. password)
    end
    return hash
end

local function accountName(value)
    if type(value) ~= 'string' then return nil end
    local name = value:gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' or #name > 24 or name:find('[^%w _%-%.]') then return nil end
    return name
end

local function saveAccounts()
    local list = {}
    for _, account in pairs(accounts) do list[#list + 1] = account end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    SaveResourceFile(RESOURCE, ACCOUNTS_FILE, json.encode(list), -1)
end

do
    local raw = LoadResourceFile(RESOURCE, ACCOUNTS_FILE)
    local ok, saved = pcall(json.decode, raw or '')
    if ok and type(saved) == 'table' then
        for _, account in ipairs(saved) do
            local name = type(account) == 'table' and accountName(account.name)
            if name and type(account.salt) == 'string' and type(account.hash) == 'string' and not accounts[name:lower()] then
                accounts[name:lower()] = {
                    name = name, salt = account.salt, hash = account.hash,
                    admin = account.admin == true, created = tonumber(account.created) or 0,
                }
                accountCount = accountCount + 1
            end
        end
    end
end

-- makes or replaces the password of an account; returns the new password (the only time it exists in clear)
local function setPassword(account)
    local password = randomPassword()
    account.salt = randomHex():sub(1, 32)
    account.hash = hashPassword(password, account.salt)
    return password
end

-- returns: password, or nil and why
local function createAccount(name, admin)
    name = accountName(name)
    if not name then return nil, 'name' end
    if accounts[name:lower()] then return nil, 'exists' end
    if accountCount >= 100 then return nil, 'full' end
    local account = { name = name, admin = admin == true, created = os.time() }
    local password = setPassword(account)
    accounts[name:lower()] = account
    accountCount = accountCount + 1
    saveAccounts()
    return password
end

local function adminCount()
    local count = 0
    for _, account in pairs(accounts) do
        if account.admin then count = count + 1 end
    end
    return count
end

-- First-time setup: while there is no account, this code (printed in the server console) lets
-- whoever has it create the first admin on the console. It changes on every start.
local setupCode = nil
if accountCount == 0 then
    setupCode = ('%06d'):format(tonumber(randomHex():sub(1, 8), 16) % 1000000)
end

local function needsSetup()
    return accountCount == 0
end

-- the console always needs a login now; kept as a function because much of the file asks it
local function passwordSet()
    return true
end

local function shouldShow(src)
    if type(Config.ShouldShow) ~= 'function' then return true end
    local ok, result = pcall(Config.ShouldShow, tonumber(src))
    return not ok or result ~= false
end

-- ---------------------------------------------------------------------------
-- Jobs: with Config.Jobs filled in, only players with one of those jobs are shown.
-- The job comes from Qbox, QBCore or ESX, or from Config.GetJob if you set it,
-- and is kept in the roster further down, so it is not looked up on every refresh.
-- ---------------------------------------------------------------------------
local jobs, jobFilter = {}, false
if type(Config.Jobs) == 'table' then
    for key, value in pairs(Config.Jobs) do
        local name, info = key, value
        if type(key) == 'number' then name, info = value, {} end      -- plain list: { 'police', 'ambulance' }
        if type(name) == 'string' then
            if type(info) ~= 'table' then info = {} end
            jobs[name:lower()] = {
                label = tostring(info.label or name),
                color = type(info.color) == 'string' and info.color:match('^#%x%x%x%x%x%x$') or nil,
            }
            jobFilter = true
        end
    end
end

local core, coreKind, coreCheckedAt = nil, nil, -100000

local function findCore()
    if coreKind then return end
    local now = GetGameTimer()
    if now - coreCheckedAt < 5000 then return end
    coreCheckedAt = now
    pcall(function()
        if GetResourceState('qbx_core') == 'started' then
            coreKind = 'qbx'
        elseif GetResourceState('qb-core') == 'started' then
            core = exports['qb-core']:GetCoreObject()
            coreKind = 'qb'
        elseif GetResourceState('es_extended') == 'started' then
            core = exports['es_extended']:getSharedObject()
            coreKind = 'esx'
        end
    end)
end

-- The framework's own object for a player. Asked for once per player read; the helpers
-- below (job, call sign, name) all take what they need from this one object.
local function frameworkPlayer(src)
    findCore()
    local id = tonumber(src)
    if coreKind == 'qbx' then return exports.qbx_core:GetPlayer(id) end
    if coreKind == 'qb' then return core.Functions.GetPlayer(id) end
    if coreKind == 'esx' then return core.GetPlayerFromId(id) end
end

-- returns: job name, on duty (nil when the framework does not know duty), name of the rank
local function frameworkJob(player)
    if not player then return nil end
    if coreKind == 'esx' then
        local job = player.job
        if job then return job.name, job.onDuty, job.grade_label or job.grade_name end
    else
        local job = player.PlayerData and player.PlayerData.job
        if job then return job.name, job.onduty, type(job.grade) == 'table' and job.grade.name or nil end
    end
end

-- ---------------------------------------------------------------------------
-- Call signs: set by the dispatcher on the map (for a player, or for everybody
-- in one car at once) or with the setCallsign export. Players without one fall
-- back to the call sign their QBCore / Qbox character has, if any.
-- ---------------------------------------------------------------------------
local callsigns = {}            -- [player id] = call sign

local function validCallsign(text)
    return type(text) == 'string' and #text >= 1 and #text <= 12 and not text:find('[^%w%-%. ]')
end

local onCallsignChanged         -- set further down: refreshes the call that unit is on

local function setCallsign(src, text)
    src = tonumber(src)
    if not src then return false end
    if text == nil or text == '' then
        callsigns[src] = nil
    elseif validCallsign(text) then
        callsigns[src] = text
    else
        return false
    end
    cache = nil
    if onCallsignChanged then onCallsignChanged(src) end
    return true
end

-- the character's name from the framework ("John Doe"), nil when there is none
local function frameworkName(player, src)
    if type(Config.GetName) == 'function' then
        return Config.GetName(tonumber(src))
    end
    if not player then return nil end
    if coreKind == 'esx' then
        if type(player.getName) == 'function' then return player.getName() end
        return player.name
    end
    local info = player.PlayerData and player.PlayerData.charinfo
    if info and info.firstname then
        return (tostring(info.firstname) .. ' ' .. tostring(info.lastname or '')):gsub('%s+$', '')
    end
end

-- the call sign a QBCore / Qbox character carries, if any
local function frameworkCallsign(player)
    if not player or coreKind == 'esx' then return nil end
    local sign = player.PlayerData and player.PlayerData.metadata and player.PlayerData.metadata.callsign
    if validCallsign(sign) and sign:upper() ~= 'NO CALLSIGN' then return sign end
end

-- ---------------------------------------------------------------------------
-- Roster: what the framework knows about each player (job, duty, call sign),
-- kept in memory so nothing has to ask the framework while the map refreshes
-- or a call goes out. It is updated when a player loads, changes job or duty,
-- or leaves; a slow background pass catches anything those events missed.
-- ---------------------------------------------------------------------------
local roster = {}               -- [player id] = { job = 'police', duty = true/false/nil, sign = 'A-12' or nil }
local units = {}                -- [player id] = true for players whose job is in Config.Jobs (and on duty if required)
local online = {}               -- [player id] = true for everybody connected

-- GetPlayers() is called exactly once, here, for players who were already connected when the
-- resource started. After that the list is kept up to date by the join and leave events.
for _, player in ipairs(GetPlayers()) do
    local src = tonumber(player)
    if src then online[src] = true end
end
AddEventHandler('playerJoining', function()
    local src = tonumber(source)
    if src then online[src] = true end
end)
local RESYNC_SECONDS = type(Config.GetJob) == 'function' and 15 or 60     -- Config.GetJob has no events to listen to

-- reads one player from the framework (the only place that does) and stores the result
local function readPlayer(src)
    src = tonumber(src)
    if not src or not GetPlayerName(tostring(src)) then return nil end

    -- one call into the framework per player, not one per piece of information
    local okPlayer, player = pcall(frameworkPlayer, src)
    if not okPlayer then player = nil end

    local ok, name, duty, grade
    if type(Config.GetJob) == 'function' then
        ok, name, duty, grade = pcall(Config.GetJob, src)
    else
        ok, name, duty, grade = pcall(frameworkJob, player)
    end
    if not ok or type(name) ~= 'string' then name, duty, grade = nil, nil, nil end
    if type(grade) == 'string' then
        grade = grade:gsub('%c', ' '):gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 32)
        if grade == '' then grade = nil end
    else
        grade = nil
    end
    local okSign, sign = pcall(frameworkCallsign, player)

    -- the character name, tidied: no control characters, not endless
    local okName, charName = pcall(frameworkName, player, src)
    if okName and type(charName) == 'string' then
        charName = charName:gsub('%c', ' '):gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 40)
        if charName == '' then charName = nil end
    else
        charName = nil
    end

    local entry = { job = name and name:lower() or nil, duty = duty, sign = okSign and sign or nil, name = charName, grade = grade }
    local old = roster[src]
    roster[src] = entry
    online[src] = true
    local wasUnit = units[src]
    units[src] = (entry.job ~= nil and jobs[entry.job] ~= nil
        and not (Config.OnDutyOnly == true and entry.duty == false)) or nil
    if jobFilter and (units[src] ~= wasUnit or not old) then
        -- the client uses this to know whether the call keys (arrows, G) mean anything for this player
        TriggerClientEvent('livemap:unit:flag', src, units[src] == true)
    end
    if not old or old.job ~= entry.job or old.duty ~= entry.duty or old.sign ~= entry.sign or old.name ~= entry.name or old.grade ~= entry.grade then
        cache = nil
        if old and old.sign ~= entry.sign and onCallsignChanged then onCallsignChanged(src) end
    end
    return entry
end

-- the stored entry; a player seen for the first time is read once
local function rosterEntry(src)
    src = tonumber(src)
    return src and (roster[src] or readPlayer(src)) or nil
end

-- The name shown for a player everywhere (map, calls, history, radio): the character's name
-- from the framework, or the FiveM name when there is none or Config.Names = 'fivem'.
local function displayName(src)
    if Config.Names ~= 'fivem' then
        local entry = rosterEntry(src)
        if entry and entry.name then return entry.name end
    end
    return GetPlayerName(tostring(src))
end

local function forgetPlayer(src)
    src = tonumber(src)
    if not src then return end
    online[src] = nil
    units[src] = nil
    if roster[src] then
        roster[src] = nil
        cache = nil
    end
end

AddEventHandler('playerDropped', function() forgetPlayer(source) end)

-- QBCore / Qbox
AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    local src = type(player) == 'table' and player.PlayerData and player.PlayerData.source
    if not src then return end
    readPlayer(src)
    SetTimeout(1500, function() readPlayer(src) end)       -- in case the framework was not finished yet
end)
AddEventHandler('QBCore:Server:OnJobUpdate', function(src) readPlayer(src) end)
-- fires for every change of player data (money too), so only look closer when job, duty or call sign differ
AddEventHandler('QBCore:Player:SetPlayerData', function(data)
    local src = type(data) == 'table' and tonumber(data.source)
    if not src then return end
    local entry = roster[src]
    local job = type(data.job) == 'table' and data.job or {}
    local sign = type(data.metadata) == 'table' and data.metadata.callsign or nil
    if not (validCallsign(sign) and sign:upper() ~= 'NO CALLSIGN') then sign = nil end
    local name = type(job.name) == 'string' and job.name:lower() or nil
    if not entry or entry.job ~= name or entry.duty ~= job.onduty or entry.sign ~= sign then
        readPlayer(src)
    end
end)

-- ESX
AddEventHandler('esx:playerLoaded', function(src) readPlayer(src) end)
AddEventHandler('esx:setJob', function(src) readPlayer(src) end)

-- another framework can push a change itself: exports['notbad-dispatch']:refreshPlayer(playerId)
exports('refreshPlayer', readPlayer)

-- everybody once at start, then slowly again and again as a safety net
CreateThread(function()
    Wait(2000)
    while true do
        local list = {}
        for src in pairs(online) do list[#list + 1] = src end
        for i, src in ipairs(list) do
            if not readPlayer(src) then forgetPlayer(src) end      -- nil = no longer connected
            if i % 50 == 0 then Wait(0) end
        end
        Wait(RESYNC_SECONDS * 1000)
    end
end)

local function getCallsign(src)
    local own = callsigns[tonumber(src)]
    if own then return own end
    local entry = rosterEntry(src)
    return entry and entry.sign or nil
end

exports('setCallsign', setCallsign)      -- (playerId, 'A-12'), '' clears it
exports('getCallsign', getCallsign)      -- (playerId)

-- ---------------------------------------------------------------------------
-- Dispatchers on duty. Everybody who has the console open sees the same units and
-- calls, so several dispatchers can work together. A console reports "on duty"
-- with every refresh; one that stops reporting is dropped after DUTY_TIMEOUT.
-- While nobody is on duty, new calls are offered straight to the units in game.
-- ---------------------------------------------------------------------------
local DUTY_TIMEOUT = 90         -- seconds; long because browsers slow down background tabs
local dispatchers = {}          -- [console id] = { name = ..., seen = os.time(), addr = address }

local function dispatchersOnDuty()
    local now = os.time()
    local names = {}
    for id, entry in pairs(dispatchers) do
        if now - entry.seen > DUTY_TIMEOUT then
            logEvent(('Dispatcher %s went off duty (console closed)'):format(entry.name))
            dispatchers[id] = nil
            cache = nil
        else
            names[#names + 1] = entry.name
        end
    end
    table.sort(names)
    return names
end

-- called with the query of every /players request: ?d=<console id>&duty=1&name=<name>
local function reportDuty(q, addr, user)
    local id = q.d
    if type(id) ~= 'string' or #id > 16 or not id:match('^%w+$') then return end
    if q.duty == '1' then
        -- logged in: the name is the account. Without login the console sends a name of its own.
        local name = user or (q.name or ''):gsub('+', ' '):gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
        name = name:gsub('%c', ' '):gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 24)
        if name == '' then name = 'Dispatcher' end
        local entry = dispatchers[id]
        if not entry or entry.name ~= name then cache = nil end
        if not entry then logEvent(('Dispatcher %s went on duty'):format(name)) end
        dispatchers[id] = { name = name, seen = os.time(), addr = addr }
    elseif dispatchers[id] then
        logEvent(('Dispatcher %s went off duty'):format(dispatchers[id].name))
        dispatchers[id] = nil
        cache = nil
    end
end

exports('getDispatchers', dispatchersOnDuty)     -- names of the dispatchers on duty

-- nil = no job filter, false = hide this player, table = the job to show
local function visibleJob(src)
    if not jobFilter then return nil end
    local entry = rosterEntry(src)
    local job = entry and entry.job and jobs[entry.job]
    if not job then return false end
    if Config.OnDutyOnly == true and entry.duty == false then return false end
    return job
end

-- the players the map shows. With Config.Jobs set this is the cached list of units,
-- so a server with 300 players and 10 units only ever touches those 10.
local function shownPlayers()
    local out = {}
    for src in pairs(jobFilter and units or online) do out[#out + 1] = src end
    table.sort(out)
    for i, src in ipairs(out) do out[i] = tostring(src) end
    return out
end

-- ---------------------------------------------------------------------------
-- Dispatch calls. They come from the console, from other resources
--   exports['notbad-dispatch']:addCall({ title = ..., text = ..., coords = ... })
-- from the /911-style command, or from a unit's panic button, and stay open until
-- somebody closes them or they run out.
-- A unit that is sent gets a card, a blip and a route in game.
-- ---------------------------------------------------------------------------
local Calls = type(Config.Calls) == 'table' and Config.Calls or {}
local MAX_CALLS = 50

GlobalState.dispatchAllUnits = not jobFilter                 -- without Config.Jobs everybody is a unit
GlobalState.dispatchBrowseKeys = Calls.BrowseKeys ~= false   -- arrow keys and G in game
local calls, lastCallId = {}, 0
local callCooldown = {}

local function clean(value, max)
    if value == nil then return nil end
    local text = tostring(value):gsub('%c', ' ')
    if text == '' then return nil end
    return text:sub(1, max)
end

local unitCall = {}             -- [player id] = id of the call that unit is on
local unitScene = {}            -- [player id] = true once that unit has arrived
local unitStatus = {}           -- [player id] = 'busy' or 'break'; nothing = available

local function isOnline(src)
    return GetPlayerName(tostring(src)) ~= nil
end

-- how a unit and a call are written in the history
local function unitLabel(src)
    local name = displayName(src) or ('player ' .. tostring(src))
    local sign = getCallsign(src)
    return sign and (sign .. ' (' .. name .. ')') or name
end

local function callLabel(call)
    return ('#%d "%s"'):format(call.id, call.title)
end

-- Players that share a call sign or a car count as one unit.
-- returns: key that is the same for the whole unit, name to show for it
local function unitKey(src)
    local sign = getCallsign(src)
    if sign then return 'c' .. sign, sign end
    local name = displayName(src) or ('Unit ' .. src)
    local ped = GetPlayerPed(tostring(src))
    if ped and ped ~= 0 and DoesEntityExist(ped) then
        local vehicle = GetVehiclePedIsIn(ped, false)
        if vehicle ~= 0 then return 'v' .. NetworkGetNetworkIdFromEntity(vehicle), name end
    end
    return 'p' .. src, name
end

-- how many units are on a call, how many have arrived, and what they are called
local function callUnits(call)
    local list = {}
    for src in pairs(call.units) do list[#list + 1] = src end
    table.sort(list)

    local found, order = {}, {}
    for _, src in ipairs(list) do
        local key, name = unitKey(src)
        if not found[key] then
            found[key] = { name = name, scene = true }
            order[#order + 1] = key
        end
        if not unitScene[src] then found[key].scene = false end     -- arrived only when the whole crew has
    end

    local info = { total = #order, scene = 0, units = {} }
    for _, key in ipairs(order) do
        info.units[#info.units + 1] = found[key].name
        if found[key].scene then info.scene = info.scene + 1 end
    end
    return info
end

-- tells every unit on the call who else is coming (shown on their call card in game)
local function notifyCall(call)
    local info = callUnits(call)
    for src in pairs(call.units) do
        -- the second value is that unit's own call sign, for the top of its card
        if isOnline(src) then TriggerClientEvent('livemap:call:units', src, info, getCallsign(src)) end
    end
end

-- a call sign changed: the cards of everybody on the same call show the new one
onCallsignChanged = function(src)
    local id = unitCall[src]
    if not id then return end
    for _, call in ipairs(calls) do
        if call.id == id then notifyCall(call) end
    end
end

-- Who may take calls without being sent (Config.Calls.SelfDispatch):
--   'never'  only a dispatcher sends units
--   'auto'   units take calls themselves while no dispatcher is on duty
--   'always' units can always take calls; the dispatcher coordinates on top
local runtimeMode = nil          -- set from the console; wins over the config until the resource restarts

local function selfDispatch()
    if runtimeMode then return runtimeMode end
    local mode = Calls.SelfDispatch
    if mode ~= 'never' and mode ~= 'auto' and mode ~= 'always' then
        mode = Calls.AutoDispatch == false and 'never' or 'auto'       -- the older on/off setting
    end
    return mode
end

-- the dispatcher switches the mode on the console (or a script through the export)
local function setSelfDispatch(mode, actor)
    if mode ~= 'never' and mode ~= 'auto' and mode ~= 'always' then return false end
    if selfDispatch() ~= mode then
        runtimeMode = mode
        cache = nil
        logEvent(('Units taking calls themselves set to "%s" (%s)'):format(mode, actor or 'script'))
    end
    return true
end

exports('setSelfDispatch', setSelfDispatch)      -- ('never' | 'auto' | 'always')
exports('getSelfDispatch', selfDispatch)

local function canSelfTake(call)
    if call.panic then return true end
    local mode = selfDispatch()
    return mode == 'always' or (mode == 'auto' and #dispatchersOnDuty() == 0)
end

-- what a unit in game is told about a call
local function callInfo(call, src)
    return {
        id = call.id, title = call.title, text = call.text, code = call.code,
        x = call.x, y = call.y, z = call.z,
        priority = call.priority, panic = call.panic,
        callsign = src and getCallsign(src) or nil,
        canClear = Calls.PlayersCanClear ~= false,
    }
end

-- actor: who did it, for the history. false = do not log (part of a bigger action).
local function unassignUnit(src, actor)
    src = tonumber(src)
    local id = src and unitCall[src]
    if not id then return false end
    unitCall[src] = nil
    unitScene[src] = nil
    for _, call in ipairs(calls) do
        if call.id == id then
            if actor ~= false then
                logEvent(('%s left call %s (%s)'):format(unitLabel(src), callLabel(call), actor or 'script'))
            end
            call.units[src] = nil
            notifyCall(call)
        end
    end
    if isOnline(src) then TriggerClientEvent('livemap:call:clear', src) end
    cache = nil
    return true
end

-- a unit is on one call at a time: sending it somewhere else moves it
local function assignUnit(id, src, actor)
    id, src = tonumber(id), tonumber(src)
    if not id or not src or not isOnline(src) then return false end
    for _, call in ipairs(calls) do
        if call.id == id then
            if unitCall[src] == id then return true end
            unassignUnit(src, false)
            call.units[src] = true
            unitCall[src] = id
            logEvent(('%s sent to call %s (%s)'):format(unitLabel(src), callLabel(call), actor or 'script'))
            TriggerClientEvent('livemap:call:assign', src, callInfo(call, src))
            notifyCall(call)
            cache = nil
            return true
        end
    end
    return false
end

-- the call is over: every unit on it is free again
local function releaseCall(call)
    for src in pairs(call.units) do
        unitCall[src] = nil
        unitScene[src] = nil
        if isOnline(src) then TriggerClientEvent('livemap:call:clear', src) end
    end
    call.units = {}
end

local function removeCall(id, actor)
    id = tonumber(id)
    for i, call in ipairs(calls) do
        if call.id == id then
            logEvent(('Call %s closed (%s)'):format(callLabel(call), actor or 'script'))
            releaseCall(call)
            table.remove(calls, i)
            cache = nil
            return true
        end
    end
    return false
end

-- may this player take this call? (shown job, and the call's own job if it has one)
local function eligible(src, call)
    if visibleJob(src) == false then return false end
    if call.job then
        local entry = rosterEntry(src)
        return entry ~= nil and entry.job == call.job
    end
    return true
end

-- every available unit gets the call offered and can take it with one key.
-- A panic call goes to everybody, whatever their status.
local function offerCall(call)
    for _, player in ipairs(shownPlayers()) do
        local src = tonumber(player)
        if src and src ~= call.panicSrc and not unitCall[src] and (call.panic or not unitStatus[src]) and eligible(src, call) then
            TriggerClientEvent('livemap:call:offer', src, callInfo(call))
        end
    end
end

-- a unit takes a call itself (F10 on an offer, or from the /calls list)
RegisterNetEvent('livemap:call:accept', function(id)
    local src = tonumber(source)
    id = tonumber(id)
    if not src or not id then return end
    for _, call in ipairs(calls) do
        if call.id == id and canSelfTake(call) and eligible(src, call) then
            assignUnit(id, src, 'took it in game')
            return
        end
    end
end)

-- Config.Calls.Templates, cleaned up once: by id for scripts, as a list for the console
local templates, templateList = {}, {}
if type(Calls.Templates) == 'table' then
    for _, tpl in ipairs(Calls.Templates) do
        if type(tpl) == 'table' and clean(tpl.title, 60) then
            local priority = math.floor(tonumber(tpl.priority) or 2)
            local entry = {
                id = clean(tpl.id, 32), title = clean(tpl.title, 60), text = clean(tpl.text, 300), code = clean(tpl.code, 12),
                priority = (priority >= 1 and priority <= 3) and priority or 2,
                job = type(tpl.job) == 'string' and tpl.job:lower() or nil,
            }
            entry.fixed = true                       -- from the config: cannot be removed on the console
            templateList[#templateList + 1] = entry
            if entry.id then templates[entry.id:lower()] = entry end
        end
    end
end

-- Templates the dispatchers save on the console. Kept in templates.json so they survive restarts.
local TEMPLATES_FILE = 'templates.json'
local MAX_SAVED_TEMPLATES = 40
local savedTemplates, lastTemplateId = {}, 0

do
    local raw = LoadResourceFile(RESOURCE, TEMPLATES_FILE)
    if raw then
        local ok, saved = pcall(json.decode, raw)
        if ok and type(saved) == 'table' then
            for _, tpl in ipairs(saved) do
                local number = type(tpl) == 'table' and tonumber(tostring(tpl.id or ''):match('^w(%d+)$'))
                if number and clean(tpl.title, 60) then
                    local priority = math.floor(tonumber(tpl.priority) or 2)
                    local entry = {
                        id = 'w' .. number, title = clean(tpl.title, 60), text = clean(tpl.text, 300), code = clean(tpl.code, 12),
                        priority = (priority >= 1 and priority <= 3) and priority or 2,
                    }
                    savedTemplates[#savedTemplates + 1] = entry
                    templates[entry.id] = entry
                    if number > lastTemplateId then lastTemplateId = number end
                end
            end
        end
    end
end

local function allTemplates()
    local out = {}
    for _, tpl in ipairs(templateList) do out[#out + 1] = tpl end
    for _, tpl in ipairs(savedTemplates) do out[#out + 1] = tpl end
    return out
end

local function storeTemplates()
    SaveResourceFile(RESOURCE, TEMPLATES_FILE, json.encode(savedTemplates), -1)
    cache = nil
end

local function saveTemplate(data, actor)
    local title = type(data) == 'table' and clean(data.title, 60)
    if not title or #savedTemplates >= MAX_SAVED_TEMPLATES then return nil end
    local priority = math.floor(tonumber(data.priority) or 2)
    lastTemplateId = lastTemplateId + 1
    local entry = {
        id = 'w' .. lastTemplateId, title = title, text = clean(data.text, 300), code = clean(data.code, 12),
        priority = (priority >= 1 and priority <= 3) and priority or 2,
    }
    savedTemplates[#savedTemplates + 1] = entry
    templates[entry.id] = entry
    storeTemplates()
    logEvent(('Template "%s" saved (%s)'):format(title, actor or 'script'))
    return entry.id
end

-- overwrites a template saved on the console with new values
local function updateTemplate(id, data, actor)
    local title = type(data) == 'table' and clean(data.title, 60)
    if not title then return false end
    for _, tpl in ipairs(savedTemplates) do
        if tpl.id == id then
            local priority = math.floor(tonumber(data.priority) or 2)
            tpl.title, tpl.text, tpl.code = title, clean(data.text, 300), clean(data.code, 12)
            tpl.priority = (priority >= 1 and priority <= 3) and priority or 2
            storeTemplates()
            logEvent(('Template "%s" changed (%s)'):format(title, actor or 'script'))
            return true
        end
    end
    return false
end

local function removeTemplate(id, actor)
    for i, tpl in ipairs(savedTemplates) do
        if tpl.id == id then
            table.remove(savedTemplates, i)
            templates[id] = nil
            storeTemplates()
            logEvent(('Template "%s" removed (%s)'):format(tpl.title, actor or 'script'))
            return true
        end
    end
    return false
end

local function addCall(data)
    if type(data) ~= 'table' then return nil end

    -- addCall({ template = 'shots', ... }): the template fills in whatever was not given
    local tpl = type(data.template) == 'string' and templates[data.template:lower()] or nil
    if tpl then
        local filled = {}
        for key, value in pairs(tpl) do filled[key] = value end
        for key, value in pairs(data) do filled[key] = value end
        data = filled
    end

    local x, y, z
    local coords = data.coords
    if coords ~= nil then
        pcall(function() x, y = tonumber(coords.x), tonumber(coords.y) end)       -- vector3 or { x =, y = }
        pcall(function() z = tonumber(coords.z) end)
        if (not x or not y) and type(coords) == 'table' then
            x, y, z = tonumber(coords[1]), tonumber(coords[2]), tonumber(coords[3])   -- { 123.4, 567.8 }
        end
    end
    if (not x or not y) and data.source then                                       -- a player: use where they stand
        local ped = GetPlayerPed(tostring(data.source))
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            local pos = GetEntityCoords(ped)
            x, y, z = pos.x, pos.y, pos.z
        end
    end
    if not x or not y then return nil end

    local priority = math.floor(tonumber(data.priority) or 2)
    if priority < 1 or priority > 3 then priority = 2 end
    if data.panic then priority = 1 end

    lastCallId = lastCallId + 1
    local now = os.time()
    local call = {
        id = lastCallId,
        title = clean(data.title, 60) or 'Call',
        text = clean(data.text or data.message, 300),
        code = clean(data.code, 12),
        job = type(data.job) == 'string' and data.job:lower() or nil,
        priority = priority,                       -- 1 high, 2 normal, 3 low
        panic = data.panic == true or nil,
        panicSrc = data.panic and tonumber(data.source) or nil,
        x = round(x),
        y = round(y),
        z = round(z or 0),
        units = {},
        at = now,
        expires = now + (tonumber(data.duration) or tonumber(Calls.Duration) or 900),
    }
    calls[#calls + 1] = call
    while #calls > MAX_CALLS do
        releaseCall(calls[1])
        table.remove(calls, 1)
    end
    cache = nil
    logEvent(('Call %s created, P%d (%s)'):format(callLabel(call), priority, clean(data.by, 60) or 'script'))
    if canSelfTake(call) then offerCall(call) end
    return call.id
end

-- Changes an open call. data may hold title, text, code ('' removes text or code), priority and coords.
-- Units on the call see the change at once; after a move they are en route again.
local function updateCall(id, data, actor)
    id = tonumber(id)
    if not id or type(data) ~= 'table' then return false end
    for _, call in ipairs(calls) do
        if call.id == id then
            if data.title ~= nil then call.title = clean(data.title, 60) or call.title end
            if data.text ~= nil then call.text = clean(data.text, 300) end
            if data.code ~= nil then call.code = clean(data.code, 12) end
            local priority = math.floor(tonumber(data.priority) or 0)
            if priority >= 1 and priority <= 3 then call.priority = priority end

            local moved = false
            local coords = data.coords
            if coords ~= nil then
                local x, y, z
                pcall(function() x, y = tonumber(coords.x), tonumber(coords.y) end)
                pcall(function() z = tonumber(coords.z) end)
                if x and y then
                    call.x, call.y, call.z = round(x), round(y), round(z or 0)
                    moved = true
                end
            end

            for src in pairs(call.units) do
                if moved then unitScene[src] = nil end
                if isOnline(src) then
                    TriggerClientEvent('livemap:call:update', src, callInfo(call, src), moved)
                end
            end
            if moved then notifyCall(call) end
            logEvent(('Call %s %s (%s)'):format(callLabel(call), moved and 'moved' or 'edited', actor or 'script'))
            cache = nil
            return true
        end
    end
    return false
end

-- calls that are still open, in the shape the map wants
local function activeCalls()
    local now = os.time()
    local out = {}
    for i = #calls, 1, -1 do
        if calls[i].expires <= now then
            logEvent(('Call %s ran out and was closed'):format(callLabel(calls[i])))
            releaseCall(calls[i])
            table.remove(calls, i)
        end
    end
    for _, call in ipairs(calls) do
        -- a call meant for one job is hidden when the map does not show that job
        if not (jobFilter and call.job and not jobs[call.job]) then
            local ids = {}
            for src in pairs(call.units) do ids[#ids + 1] = src end
            table.sort(ids)
            local info = callUnits(call)
            out[#out + 1] = {
                id = call.id, title = call.title, text = call.text, code = call.code,
                x = call.x, y = call.y, age = now - call.at, units = ids,
                count = info.total, onScene = info.scene,
                p = call.priority, panic = call.panic,
            }
        end
    end
    return out
end

exports('addCall', addCall)
exports('removeCall', removeCall)
exports('updateCall', updateCall)        -- (callId, { title =, text =, code =, priority =, coords = })
exports('getCalls', activeCalls)
exports('assignCall', assignUnit)        -- (callId, playerId)
exports('unassignUnit', unassignUnit)    -- (playerId)

-- the unit reports that it has arrived (sent by client.lua near the call)
RegisterNetEvent('livemap:call:scene', function()
    local src = tonumber(source)
    if src and unitCall[src] and not unitScene[src] then
        unitScene[src] = true
        cache = nil
        for _, call in ipairs(calls) do
            if call.id == unitCall[src] then
                logEvent(('%s arrived at call %s'):format(unitLabel(src), callLabel(call)))
                notifyCall(call)
            end
        end
    end
end)

-- the unit clears its own call (F9 or /callclear in game)
RegisterNetEvent('livemap:call:leave', function()
    if Calls.PlayersCanClear ~= false then unassignUnit(source, 'cleared it in game') end
end)

-- ---- unit status: available / busy / break (unavailable) ----
local STATUSES = { available = true, busy = true, ['break'] = true }

local function setUnitStatus(src, status, actor)
    src = tonumber(src)
    if not src or not STATUSES[status] or not isOnline(src) then return false end
    local value = status ~= 'available' and status or nil
    if unitStatus[src] ~= value then
        unitStatus[src] = value
        cache = nil
        logEvent(('%s is now %s (%s)'):format(unitLabel(src), status == 'break' and 'unavailable' or status, actor or 'script'))
    end
    TriggerClientEvent('livemap:toast', src, 'status_' .. status)
    return true
end

exports('setUnitStatus', setUnitStatus)                 -- (playerId, 'available' | 'busy' | 'break')
exports('getUnitStatus', function(src) return unitStatus[tonumber(src)] or 'available' end)

-- /unitstatus in game
RegisterNetEvent('livemap:unit:status', function(status)
    local src = source
    if visibleJob(src) == false then
        return TriggerClientEvent('livemap:toast', src, 'not_unit')
    end
    if not setUnitStatus(src, status, 'set in game') then
        TriggerClientEvent('livemap:toast', src, 'status_usage')
    end
end)

-- ---- panic button: a priority 1 call at the unit's position that every other unit is offered ----
local panicAt = {}

RegisterNetEvent('livemap:unit:panic', function()
    local src = tonumber(source)
    if Calls.Panic == false or not src then return end
    if visibleJob(src) == false then
        return TriggerClientEvent('livemap:toast', src, 'not_unit')
    end
    local now = os.time()
    if panicAt[src] and now - panicAt[src] < 30 then
        return TriggerClientEvent('livemap:toast', src, 'panic_wait')
    end
    panicAt[src] = now
    local name = displayName(src) or ('Unit ' .. src)
    local sign = getCallsign(src)
    addCall({
        source = src, panic = true, priority = 1,
        title = ('PANIC %s'):format(sign or name), text = sign and name or nil,
        by = 'panic button, ' .. unitLabel(src),
    })
    TriggerClientEvent('livemap:toast', src, 'panic_sent')
end)

-- ---- calls from client scripts: exports['notbad-dispatch']:addCall({...}) on the client ----
local createAt = {}

RegisterNetEvent('livemap:call:create', function(data)
    local src = tonumber(source)
    if Calls.ClientCalls == false or not src or type(data) ~= 'table' then return end
    local now = os.time()
    if createAt[src] and now - createAt[src] < 2 then return end     -- one call every two seconds per player
    createAt[src] = now
    local duration = tonumber(data.duration)
    addCall({
        source = src,
        coords = type(data.coords) == 'table' and data.coords or nil,
        title = data.title, text = data.text or data.message, code = data.code,
        job = data.job, priority = data.priority,
        duration = duration and math.max(30, math.min(duration, 3600)) or nil,
        by = 'client script, player ' .. (displayName(src) or src),
    })
end)

-- ---- /calls in game: the open calls a unit may see, and whether it may take them ----
-- how = 'browse' when the unit flips through the calls with the arrow keys instead of opening the list
RegisterNetEvent('livemap:calls:request', function(how)
    local src = tonumber(source)
    if not src then return end
    local browse = how == 'browse'
    if Calls.UnitsSeeCalls == false or visibleJob(src) == false then
        return TriggerClientEvent('livemap:calls:list', src, false, browse)
    end
    activeCalls()       -- drops calls that have run out
    local list = {}
    for _, call in ipairs(calls) do
        if eligible(src, call) then
            list[#list + 1] = {
                id = call.id, title = call.title, text = call.text, code = call.code,
                priority = call.priority, panic = call.panic, x = call.x, y = call.y,
                units = callUnits(call).total,
                mine = unitCall[src] == call.id,
                take = canSelfTake(call),
            }
        end
    end
    table.sort(list, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.id > b.id
    end)
    TriggerClientEvent('livemap:calls:list', src, list, browse)
end)

if type(Calls.Command) == 'string' and Calls.Command ~= '' then
    RegisterCommand(Calls.Command, function(src, args)
        if src == 0 then return end
        local text = table.concat(args, ' ')
        local function tell(message)
            TriggerClientEvent('chat:addMessage', src, { args = { L('dispatch'), message } })
        end
        if text == '' then
            return tell(L('call_usage', Calls.Command))
        end
        local now = os.time()
        if callCooldown[src] and now - callCooldown[src] < 15 then
            return tell(L('call_wait'))
        end
        callCooldown[src] = now
        local name = displayName(src) or tostring(src)
        addCall({ source = src, title = L('call_from', name), text = text, by = '/' .. Calls.Command .. ', ' .. name })
        tell(L('call_sent'))
    end, false)
end

-- car / bike / heli / plane / boat, for the icon on the map
local KINDS = { automobile = 'car', trailer = 'car', train = 'car', bike = 'bike', heli = 'heli', plane = 'plane', boat = 'boat', submarine = 'boat' }

local function vehicleKind(vehicle)
    local ok, kind = pcall(GetVehicleType, vehicle)
    return ok and KINDS[kind] or 'car'
end

local function snapshot()
    local now = GetGameTimer()
    if cache and now - cacheAt < Config.UpdateInterval then
        return cache
    end

    local players = {}
    for _, src in ipairs(shownPlayers()) do
        local ped = GetPlayerPed(src)
        local job = visibleJob(src)
        if job ~= false and ped and ped ~= 0 and DoesEntityExist(ped) and shouldShow(src) then
            local coords = GetEntityCoords(ped)
            local vehicle = GetVehiclePedIsIn(ped, false)
            local inVehicle = vehicle ~= 0
            players[#players + 1] = {
                -- players with the same veh sit in the same car and are drawn as one marker
                veh = inVehicle and NetworkGetNetworkIdFromEntity(vehicle) or nil,
                drv = inVehicle and GetPedInVehicleSeat(vehicle, -1) == ped or nil,
                vt = inVehicle and vehicleKind(vehicle) or nil,     -- which icon the map draws
                cs = getCallsign(src),
                id = tonumber(src),
                name = Config.ShowNames and displayName(src) or nil,
                x = round(coords.x),
                y = round(coords.y),
                h = math.floor(GetEntityHeading(ped) + 0.5),
                v = inVehicle,
                ping = Config.ShowPing and GetPlayerPing(src) or nil,
                job = job and job.label or nil,
                gr = Config.ShowRanks ~= false and (roster[tonumber(src)] or {}).grade or nil,     -- rank
                call = unitCall[tonumber(src)],
                st = unitStatus[tonumber(src)],
                sc = unitScene[tonumber(src)],
                c = job and job.color or nil,
            }
        end
    end

    cache = json.encode({
        players = players,
        count = #players,
        max = GetConvarInt('sv_maxclients', 48),
        calls = activeCalls(),
        dispatchers = dispatchersOnDuty(),
        mode = selfDispatch(),
        templates = allTemplates(),
    })
    cacheAt = now
    return cache
end

local function header(request, name)
    for key, value in pairs(request.headers or {}) do
        if key:lower() == name then return value end
    end
end

local function address(request)
    local addr = tostring(request.address or '?')
    return addr:match('^%[(.+)%]:%d+$') or addr:match('^([^:]+):%d+$') or addr
end

-- compares in the same time whether the texts differ early or late, so timing gives nothing away
local function sameText(a, b)
    if type(a) ~= 'string' or type(b) ~= 'string' or #b == 0 then return false end
    local diff = #a ~ #b
    for i = 1, #a do
        diff = diff | (a:byte(i) ~ b:byte((i - 1) % #b + 1))
    end
    return diff == 0
end

local function newToken(session)
    local now = os.time()
    local count, oldest, oldestUsed = 0, nil, now + 1
    for token, entry in pairs(tokens) do
        if now - entry.used > TOKEN_IDLE_SECONDS then
            tokens[token] = nil
        else
            count = count + 1
            if entry.used < oldestUsed then oldest, oldestUsed = token, entry.used end
        end
    end
    if count >= 200 and oldest then tokens[oldest] = nil end     -- far more than any server needs
    local token = 't' .. randomHex():sub(1, 32)
    tokens[token] = { used = now, user = session.user, admin = session.admin }
    return token
end

-- the logged-in dispatcher behind a request, if any
local function sessionOf(request)
    if request.dispatchSession then return request.dispatchSession end
    local given = header(request, 'x-livemap-key')
    return given and tokens[given] or nil
end

-- may this request change settings and templates? Without any login everybody may.
local function isAdmin(request)
    if not passwordSet() then return true end
    local session = sessionOf(request)
    return session ~= nil and session.admin == true
end

-- the dispatcher behind a request, for the history: the logged-in user. Without any login,
-- consoles are told apart by address.
local function actorOf(request)
    local session = sessionOf(request)
    if session then return 'dispatcher ' .. session.user end
    local addr = address(request)
    local names = {}
    for _, entry in pairs(dispatchers) do
        if entry.addr == addr then names[#names + 1] = entry.name end
    end
    table.sort(names)
    return names[1] and ('dispatcher ' .. names[1]) or 'console'
end

local function wrongPassword(addr, entry, now)
    if not entry then
        failedCount = failedCount + 1
        if failedCount > 5000 then failed, failedCount = {}, 1 end     -- keep memory bounded under attack
        entry = { count = 0, locks = 0, lockedUntil = 0 }
    end
    entry.count = entry.count + 1
    entry.last = now

    -- many wrong passwords from everywhere: tighten up for a while
    recentFails[#recentFails + 1] = now
    while recentFails[1] and now - recentFails[1] > SIEGE_WINDOW do table.remove(recentFails, 1) end
    if #recentFails >= SIEGE_FAILS and now >= siegeUntil then
        siegeUntil = now + SIEGE_SECONDS
        local text = ('%d wrong passwords in %d minutes: for the next %d minutes one wrong password locks an address'):format(
            #recentFails, SIEGE_WINDOW // 60, SIEGE_SECONDS // 60)
        print(('^1[%s]^7 %s.'):format(RESOURCE, text))
        logEvent('Security: ' .. text)
    end

    if entry.count >= (now < siegeUntil and 1 or MAX_ATTEMPTS) then
        entry.locks = entry.locks + 1
        entry.count = 0
        local seconds = math.floor(math.min(LOCK_MAX, LOCK_SECONDS * 2 ^ (entry.locks - 1)))
        entry.lockedUntil = now + seconds
        if now >= siegeUntil then            -- during an attack from many addresses one line above says it all
            local text = ('address %s locked for %d min after wrong passwords'):format(addr, math.ceil(seconds / 60))
            print(('^3[%s]^7 Console: %s.'):format(RESOURCE, text))
            logEvent('Security: ' .. text)
        end
    end
    failed[addr] = entry
end

-- returns: allowed (bool), status code when not allowed, a fresh session token after a login
local function authorize(request)
    if not passwordSet() then return true end

    local given = header(request, 'x-livemap-key')
    local now = os.time()
    if given and tokens[given] then                  -- already logged in
        tokens[given].used = now
        return true
    end

    local addr = address(request)
    local entry = failed[addr]
    if entry and now - (entry.last or 0) > FORGET_SECONDS and now >= entry.lockedUntil then
        failed[addr] = nil
        entry = nil
    end
    if entry and now < entry.lockedUntil then return false, 429 end

    -- nothing sent is just the login screen asking; an old session token (from before a restart)
    -- only means "log in again"; neither counts as a wrong try
    if not given or needsSetup() or given:match('^t%x+$') then return false, 401 end

    -- username + password against the stored hash; an unknown name is hashed too, so it takes as long
    -- checking a password costs real work (the hash), so only a few are checked per second;
    -- a flood of login tries gets "try again" instead of slowing the server down
    if now ~= checkSecond then checkSecond, checksThisSecond = now, 0 end
    checksThisSecond = checksThisSecond + 1
    if checksThisSecond > MAX_CHECKS_PER_SECOND then return false, 429 end

    local name = accountName(header(request, 'x-livemap-user'))
    local account = name and accounts[name:lower()] or nil
    local session = nil
    if #given <= 128 then
        local hash = hashPassword(given, account and account.salt or 'no-such-account')
        if account and sameText(hash, account.hash) then
            session = { user = account.name, admin = account.admin }
        end
    end

    if session then
        failed[addr] = nil
        request.dispatchSession = session
        return true, nil, newToken(session)
    end

    wrongPassword(addr, entry, now)
    return false, 401
end

local function send(response, code, contentType, body, token)
    response.writeHead(code, {
        ['Content-Type'] = contentType,
        ['Cache-Control'] = 'no-store',
        ['X-Content-Type-Options'] = 'nosniff',
        ['X-Livemap-Token'] = token,         -- only set right after a password login
    })
    response.send(body)
end

-- ---------------------------------------------------------------------------
-- Radio: the console can listen to and talk on a radio channel of the voice system
-- (pma-voice, SaltyChat, TokoVoip, or a custom one).
--
-- A voice system cannot be reached from a browser, so this is a small relay
-- next to it: audio travels as short mu-law packets (12 kHz, 100 ms each).
--   web  -> game: POST /voice/talk, relayed to every player on that channel
--   game -> web : players transmitting on a watched channel send their
--                 microphone here, the web map collects it with /voice/poll.
--                 /voice/poll is a long poll: the answer is held back until
--                 there is audio, so nothing waits for the next poll.
-- ---------------------------------------------------------------------------
local Voice = type(Config.Voice) == 'table' and Config.Voice or {}

local MAX_PACKET = 8192        -- base64 characters, one packet is about 1600
local KEEP_MS = 5000           -- how long packets wait for the web map to collect them
local WATCH_TIMEOUT = 3000     -- a web listener that stops polling is gone after this
local MAX_WEB_LISTENERS = 32
local MAX_PACKETS_PER_SECOND = 25
local HOLD_MS = 8000           -- longest time a /voice/poll request is held open

local seq = 1
local packets = {}             -- { s = seq, ch = channel, f = sender, n = name, d = data, t = time }
local watchers = {}            -- web listeners: [id] = { ch = channel, seen = time }
local waiters = {}             -- held /voice/poll requests: [id] = { response, ch = channel, at = time }
local watched, watchedKey = {}, ''
local rate = {}                -- per player: { t = second, n = packets in that second }

local function voiceConfigured()
    return Voice.Enabled == true and passwordSet()
end

-- nil when the radio can be used, otherwise the HTTP status to answer with
-- Which voice system the players use. The server only needs its name: the clients report their
-- radio channel themselves (client.lua has an adapter per system), so nothing here calls into it.
local VOICE_SYSTEMS = { { 'pma-voice', 'pma-voice' }, { 'saltychat', 'saltychat' }, { 'tokovoip', 'tokovoip_script' } }

local function voiceSystem()
    local want = Voice.System
    if want == 'custom' then return 'custom' end
    for _, system in ipairs(VOICE_SYSTEMS) do
        if (want == nil or want == 'auto' or want == '' or want == system[1]) and GetResourceState(system[2]) == 'started' then
            return system[1]
        end
    end
end

local function voiceUnavailable()
    if not voiceConfigured() then return 404 end
    if not voiceSystem() then return 503 end
end

-- channel names are text ("5", "1.5", "police"); 5, 5.0 and "5" are the same channel
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

-- who is on which radio channel, as reported by the clients
local playerChannels = {}       -- [player id] = { primary, secondary }
local channelMembers = {}       -- [channel] = { [player id] = true }

local function leaveChannels(src)
    local old = playerChannels[src]
    if not old then return end
    for _, channel in ipairs(old) do
        local members = channelMembers[channel]
        if members then
            members[src] = nil
            if not next(members) then channelMembers[channel] = nil end
        end
    end
    playerChannels[src] = nil
end

RegisterNetEvent('livemap:voice:channel', function(primary, secondary)
    local src = tonumber(source)
    if not src then return end
    leaveChannels(src)
    local list = {}
    for _, channel in ipairs({ channelName(primary) or false, channelName(secondary) or false }) do
        if channel and channel ~= list[1] then
            list[#list + 1] = channel
            channelMembers[channel] = channelMembers[channel] or {}
            channelMembers[channel][src] = true
        end
    end
    if #list > 0 then playerChannels[src] = list end
end)

local function channelAllowed(channel)
    if type(Voice.Channels) ~= 'table' or #Voice.Channels == 0 then return true end
    for _, allowed in ipairs(Voice.Channels) do
        if channelName(allowed) == channel then return true end
    end
    return false
end

local function validPacket(data)
    return type(data) == 'string' and #data > 0 and #data <= MAX_PACKET and not data:find('[^%w%+/=]')
end

local function answerPoll(response, list)
    -- the browser may be gone by now, that must not break anything
    pcall(send, response, 200, 'application/json', json.encode({ seq = seq, chunks = list }))
end

local function pushPacket(channel, from, name, data)
    local now = GetGameTimer()
    while packets[1] and now - packets[1].t > KEEP_MS do
        table.remove(packets, 1)
    end
    seq = seq + 1
    packets[#packets + 1] = { s = seq, ch = channel, f = from, n = name, d = data, t = now }

    -- hand it straight to every web listener waiting on this channel
    for id, waiter in pairs(waiters) do
        if waiter.ch == channel and id ~= from then
            waiters[id] = nil
            answerPoll(waiter.response, { { f = from, n = name, d = data } })
        end
    end
end

-- works out which channels the web map is listening to and tells the clients
local function refreshWatched()
    local now = GetGameTimer()

    -- a listener with a held request is still there; requests held too long get an empty answer
    for id, waiter in pairs(waiters) do
        if watchers[id] then watchers[id].seen = now end
        if now - waiter.at > HOLD_MS then
            waiters[id] = nil
            answerPoll(waiter.response, {})
        end
    end

    local set, list = {}, {}
    for id, watcher in pairs(watchers) do
        if now - watcher.seen > WATCH_TIMEOUT then
            watchers[id] = nil
        elseif not set[watcher.ch] then
            set[watcher.ch] = true
            list[#list + 1] = watcher.ch
        end
    end
    table.sort(list)
    watched = set

    local key = table.concat(list, ',')
    if key ~= watchedKey then
        watchedKey = key
        GlobalState.livemapVoiceChannels = list
    end
end

local function playersInChannel(channel)
    local out = {}
    for src in pairs(channelMembers[channel] or {}) do out[#out + 1] = src end
    return out
end

local function query(request)
    local out = {}
    local text = (request.path or ''):match('%?(.*)$') or ''
    for key, value in text:gmatch('([^&=]+)=([^&]*)') do out[key] = value end
    return out
end

-- reads and checks ?ch= and ?id=, answers the request itself when they are wrong
local function voiceRequest(request, response)
    local unavailable = voiceUnavailable()
    if unavailable then
        send(response, unavailable, 'application/json', '{"error":"voice"}')
        return
    end

    local allowed, code = authorize(request)
    if not allowed then
        send(response, code, 'application/json', '{"error":"' .. (code == 429 and 'locked' or 'password') .. '"}')
        return
    end

    local q = query(request)
    local raw = (q.ch or ''):gsub('+', ' '):gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
    local channel, id = channelName(raw), q.id
    if not channel or type(id) ~= 'string' or #id > 16 or not id:match('^%w+$') then
        send(response, 400, 'application/json', '{"error":"request"}')
        return
    end
    if not channelAllowed(channel) then
        send(response, 403, 'application/json', '{"error":"channel"}')
        return
    end
    return channel, id, q
end

local function handlePoll(request, response)
    local channel, id, q = voiceRequest(request, response)
    if not channel then return end

    if not watchers[id] then
        local count = 0
        for _ in pairs(watchers) do count = count + 1 end
        if count >= MAX_WEB_LISTENERS then
            return send(response, 429, 'application/json', '{"error":"full"}')
        end
    end
    local old = waiters[id]
    if old then
        waiters[id] = nil
        answerPoll(old.response, {})
    end
    watchers[id] = { ch = channel, seen = GetGameTimer() }
    refreshWatched()

    -- since = 0 (just joined) or a number from before a restart: start from now
    local since = tonumber(q.since) or 0
    if since <= 0 or since > seq then
        return answerPoll(response, {})
    end

    local out = {}
    for _, packet in ipairs(packets) do
        if packet.s > since and packet.ch == channel and packet.f ~= id then
            out[#out + 1] = { f = packet.f, n = packet.n, d = packet.d }
        end
    end
    if #out > 0 then
        return answerPoll(response, out)
    end

    -- nothing yet: keep the request open until somebody talks (or HOLD_MS passes)
    waiters[id] = { response = response, ch = channel, at = GetGameTimer() }
end

-- the web listener pressed Leave: stop capturing players for it right away
local function handleLeave(request, response)
    local allowed, code = authorize(request)
    if not allowed then
        return send(response, code, 'application/json', '{"error":"password"}')
    end
    local id = query(request).id
    if type(id) == 'string' and watchers[id] then
        local waiter = waiters[id]
        waiters[id] = nil
        watchers[id] = nil
        if waiter then answerPoll(waiter.response, {}) end
        refreshWatched()
    end
    send(response, 200, 'application/json', '{"ok":true}')
end

local function handleTalk(request, response)
    local channel, id = voiceRequest(request, response)
    if not channel then return end

    -- talking is only possible after joining the channel with /voice/poll
    local watcher = watchers[id]
    if not watcher or watcher.ch ~= channel then
        return send(response, 409, 'application/json', '{"error":"join"}')
    end

    request.setDataHandler(function(body)
        if not validPacket(body) then
            return send(response, 400, 'application/json', '{"error":"packet"}')
        end
        local volume = tonumber(Voice.Volume) or 0.6
        for _, src in ipairs(playersInChannel(channel)) do
            TriggerClientEvent('livemap:voice:play', src, body, id, volume, Voice.Effect ~= false)
        end
        pushPacket(channel, id, Voice.Name or 'Dispatch', body)   -- so other web listeners hear it too
        send(response, 200, 'application/json', '{"ok":true}')
    end)
end

-- a player transmitting on a channel the web map is listening to
RegisterNetEvent('livemap:voice:mic', function(data, channel)
    local src = tonumber(source)
    if not src or voiceUnavailable() or not validPacket(data) then return end

    -- the channel must be one this player reported being on, and one the console listens to
    channel = channelName(channel)
    local mine = playerChannels[src]
    if not channel or not mine or (mine[1] ~= channel and mine[2] ~= channel) or not watched[channel] then return end

    local now = os.time()
    local entry = rate[src]
    if not entry or entry.t ~= now then
        entry = { t = now, n = 0 }
        rate[src] = entry
    end
    entry.n = entry.n + 1
    if entry.n > MAX_PACKETS_PER_SECOND then return end

    pushPacket(channel, 'p' .. src, displayName(src) or ('Player ' .. src), data)
end)

AddEventHandler('playerDropped', function()
    leaveChannels(tonumber(source) or 0)
    callCooldown[source] = nil
    callsigns[tonumber(source) or 0] = nil
    unassignUnit(source, 'left the server')
    local gone = tonumber(source) or 0
    unitStatus[gone], panicAt[gone], createAt[gone] = nil, nil, nil
    rate[source] = nil
end)

CreateThread(function()
    GlobalState.livemapVoiceChannels = {}
    local told = false
    while true do
        -- client.lua picks its adapter from this; a voice resource may start after this one
        local system = voiceConfigured() and voiceSystem() or nil
        if system ~= told then
            told = system
            GlobalState.dispatchVoiceSystem = system
        end
        Wait(1000)
        if next(watchers) or next(waiters) or watchedKey ~= '' then refreshWatched() end
    end
end)

-- ---------------------------------------------------------------------------

local function renderPage()
    local legend = {}
    for _, job in pairs(jobs) do
        if job.color then legend[#legend + 1] = { label = job.label, color = job.color } end
    end
    table.sort(legend, function(a, b) return a.label < b.label end)

    local settings = json.encode({
        jobs = legend,
        title = Config.Title,
        mapImage = Config.MapImage,
        calibration = Config.Calibration,
        interval = Config.UpdateInterval,
        password = passwordSet(),
        voice = voiceConfigured(),
        selfDispatch = selfDispatch(),
        templates = allTemplates(),
        voiceEffect = Voice.Effect ~= false,
    }):gsub('<', '\\u003c')

    return (page:gsub('__LIVEMAP_CONFIG__', function() return settings end))
end

SetHttpHandler(function(request, response)
    local path = (request.path or '/'):gsub('%?.*$', '')

    if path == '/voice/talk' then
        if request.method ~= 'POST' then
            return send(response, 405, 'text/plain', 'Method not allowed')
        end
        return handleTalk(request, response)
    end

    if path == '/calls/close' or path == '/calls/assign' or path == '/calls/unassign' then
        if request.method ~= 'POST' then
            return send(response, 405, 'text/plain', 'Method not allowed')
        end
        local allowed, code = authorize(request)
        if not allowed then
            return send(response, code, 'application/json', '{"error":"password"}')
        end
        local full = request.path or ''
        local id, unit = full:match('[?&]id=(%d+)'), full:match('[?&]unit=(%d+)')
        local ok
        local actor = actorOf(request)
        if path == '/calls/close' then
            ok = removeCall(id, actor)
        elseif path == '/calls/assign' then
            ok = assignUnit(id, unit, actor)
        else
            ok = unassignUnit(unit, actor)
        end
        return send(response, 200, 'application/json', ok and '{"ok":true}' or '{"ok":false}')
    end

    -- the dispatcher clicked a place on the map and filled in the New call form
    if path == '/calls/add' then
        if request.method ~= 'POST' then
            return send(response, 405, 'text/plain', 'Method not allowed')
        end
        local allowed, code = authorize(request)
        if not allowed then
            return send(response, code, 'application/json', '{"error":"password"}')
        end
        local q = query(request)
        local function field(name)
            local text = (q[name] or ''):gsub('+', ' '):gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
            text = text:gsub('^%s+', ''):gsub('%s+$', '')
            return text ~= '' and text or nil
        end
        local id = addCall({
            title = field('title'), text = field('text'), code = field('code'),
            coords = { x = tonumber(q.x), y = tonumber(q.y) },
            priority = tonumber(q.p), by = actorOf(request), job = field('job'),
        })
        if not id then
            return send(response, 400, 'application/json', '{"error":"call"}')
        end
        return send(response, 200, 'application/json', ('{"ok":true,"id":%d}'):format(id))
    end

    -- the dispatcher changed the details of a call, or moved it
    if path == '/calls/edit' then
        if request.method ~= 'POST' then
            return send(response, 405, 'text/plain', 'Method not allowed')
        end
        local allowed, code = authorize(request)
        if not allowed then
            return send(response, code, 'application/json', '{"error":"password"}')
        end
        local q = query(request)
        local function field(name)          -- nil = not sent, '' = sent empty
            if q[name] == nil then return nil end
            local text = q[name]:gsub('+', ' '):gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
            return (text:gsub('^%s+', ''):gsub('%s+$', ''))
        end
        local data = { title = field('title'), text = field('text'), code = field('code'), priority = tonumber(q.p) }
        if data.title == '' then data.title = nil end
        if tonumber(q.x) and tonumber(q.y) then data.coords = { x = tonumber(q.x), y = tonumber(q.y) } end
        local ok = updateCall(q.id, data, actorOf(request))
        return send(response, 200, 'application/json', ok and '{"ok":true}' or '{"ok":false}')
    end

    -- the dispatcher saved the New call form as a template, changed a saved one, or removed it
    if path == '/templates/add' or path == '/templates/edit' or path == '/templates/remove' then
        if request.method ~= 'POST' then
            return send(response, 405, 'text/plain', 'Method not allowed')
        end
        local allowed, code = authorize(request)
        if not allowed then
            return send(response, code, 'application/json', '{"error":"password"}')
        end
        local q = query(request)
        local function field(name)
            local text = (q[name] or ''):gsub('+', ' '):gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
            text = text:gsub('^%s+', ''):gsub('%s+$', '')
            return text ~= '' and text or nil
        end
        local ok
        if not isAdmin(request) then
            return send(response, 403, 'application/json', '{"error":"admin"}')
        end
        local values = { title = field('title'), text = field('text'), code = field('code'), priority = tonumber(q.p) }
        if path == '/templates/add' then
            ok = saveTemplate(values, actorOf(request)) ~= nil
        elseif path == '/templates/edit' then
            ok = updateTemplate(q.id, values, actorOf(request))
        else
            ok = removeTemplate(q.id, actorOf(request))
        end
        return send(response, ok and 200 or 400, 'application/json', ok and '{"ok":true}' or '{"ok":false}')
    end

    -- the dispatcher switched who sends units: never / auto / always
    if path == '/settings/mode' then
        if request.method ~= 'POST' then
            return send(response, 405, 'text/plain', 'Method not allowed')
        end
        local allowed, code = authorize(request)
        if not allowed then
            return send(response, code, 'application/json', '{"error":"password"}')
        end
        if not isAdmin(request) then
            return send(response, 403, 'application/json', '{"error":"admin"}')
        end
        local ok = setSelfDispatch(query(request).m, actorOf(request))
        return send(response, ok and 200 or 400, 'application/json', ok and '{"ok":true}' or '{"error":"mode"}')
    end

    -- the dispatcher set a unit's status from the console
    if path == '/units/status' then
        if request.method ~= 'POST' then
            return send(response, 405, 'text/plain', 'Method not allowed')
        end
        local allowed, code = authorize(request)
        if not allowed then
            return send(response, code, 'application/json', '{"error":"password"}')
        end
        local q = query(request)
        local actor = actorOf(request)
        for unit in (q.units or ''):gmatch('%d+') do
            setUnitStatus(unit, q.st, actor)
        end
        return send(response, 200, 'application/json', '{"ok":true}')
    end

    if path == '/units/callsign' then
        if request.method ~= 'POST' then
            return send(response, 405, 'text/plain', 'Method not allowed')
        end
        local allowed, code = authorize(request)
        if not allowed then
            return send(response, code, 'application/json', '{"error":"password"}')
        end
        local q = query(request)
        local sign = (q.cs or ''):gsub('+', ' '):gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
        sign = sign:gsub('^%s+', ''):gsub('%s+$', '')
        if sign ~= '' and not validCallsign(sign) then
            return send(response, 400, 'application/json', '{"error":"callsign"}')
        end
        for unit in (q.units or ''):gmatch('%d+') do
            if GetPlayerName(unit) and setCallsign(unit, sign) then
                logEvent(('Call sign of %s set to %s (%s)'):format(displayName(unit) or unit, sign ~= '' and sign or 'none', actorOf(request)))
            end
        end
        return send(response, 200, 'application/json', '{"ok":true}')
    end

    -- First-time setup: no account exists yet. The right code from the server console creates
    -- the first admin; the generated password goes back to the page once.
    if path == '/setup' then
        if request.method ~= 'POST' then
            return send(response, 405, 'text/plain', 'Method not allowed')
        end
        if not needsSetup() then
            return send(response, 409, 'application/json', '{"error":"done"}')
        end
        local addr = address(request)
        local entry = failed[addr]
        local now = os.time()
        if entry and now < entry.lockedUntil then
            return send(response, 429, 'application/json', '{"error":"locked"}')
        end
        local q = query(request)
        if not sameText(tostring(q.code or ''), setupCode) then
            wrongPassword(addr, entry, now)                 -- guessing the code is limited like guessing passwords
            return send(response, 401, 'application/json', '{"error":"code"}')
        end
        local raw = (q.user or ''):gsub('+', ' '):gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
        local password, why = createAccount(raw, true)
        if not password then
            return send(response, 400, 'application/json', '{"error":"' .. why .. '"}')
        end
        setupCode = nil
        failed[addr] = nil
        local name = accountName(raw)
        logEvent(('First-time setup: admin account %s created'):format(name))
        print(('^2[%s]^7 First-time setup done: admin account "%s" created.'):format(RESOURCE, name))
        return send(response, 200, 'application/json', json.encode({ ok = true, user = name, password = password }))
    end

    -- Accounts window (admins only): list, add, new password, admin on/off, delete
    if path == '/accounts' or path:sub(1, 10) == '/accounts/' then
        local allowed, code = authorize(request)
        if not allowed then
            return send(response, code, 'application/json', '{"error":"password"}')
        end
        if not isAdmin(request) then
            return send(response, 403, 'application/json', '{"error":"admin"}')
        end
        local actor = actorOf(request)
        local me = sessionOf(request)

        if path == '/accounts' then
            local list = {}
            for _, account in pairs(accounts) do
                list[#list + 1] = { user = account.name, admin = account.admin, created = account.created }
            end
            table.sort(list, function(a, b) return a.user:lower() < b.user:lower() end)
            return send(response, 200, 'application/json', json.encode({ accounts = list }))
        end
        if request.method ~= 'POST' then
            return send(response, 405, 'text/plain', 'Method not allowed')
        end

        local q = query(request)
        local raw = (q.user or ''):gsub('+', ' '):gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
        local name = accountName(raw)
        local account = name and accounts[name:lower()] or nil
        local function fail(why)
            return send(response, 400, 'application/json', '{"error":"' .. why .. '"}')
        end
        -- whoever is logged in as this account must log in again
        local function dropSessions()
            for token, session in pairs(tokens) do
                if session.user == account.name then tokens[token] = nil end
            end
        end

        if path == '/accounts/add' then
            local password, why = createAccount(raw, q.admin == '1')
            if not password then return fail(why) end
            logEvent(('Account %s created%s (%s)'):format(name, q.admin == '1' and ' as admin' or '', actor))
            return send(response, 200, 'application/json', json.encode({ ok = true, user = name, password = password }))
        end

        if not account then return fail('unknown') end

        if path == '/accounts/reset' then
            local password = setPassword(account)
            saveAccounts()
            if not (me and me.user == account.name) then dropSessions() end
            logEvent(('New password for account %s (%s)'):format(account.name, actor))
            return send(response, 200, 'application/json', json.encode({ ok = true, user = account.name, password = password }))
        end

        if path == '/accounts/admin' then
            local admin = q.admin == '1'
            if account.admin and not admin and adminCount() <= 1 then return fail('last-admin') end
            account.admin = admin
            saveAccounts()
            for _, session in pairs(tokens) do
                if session.user == account.name then session.admin = admin end
            end
            logEvent(('Account %s is %s (%s)'):format(account.name, admin and 'now an admin' or 'no longer an admin', actor))
            return send(response, 200, 'application/json', '{"ok":true}')
        end

        if path == '/accounts/remove' then
            if me and me.user == account.name then return fail('self') end
            if account.admin and adminCount() <= 1 then return fail('last-admin') end
            dropSessions()
            accounts[account.name:lower()] = nil
            accountCount = accountCount - 1
            saveAccounts()
            logEvent(('Account %s deleted (%s)'):format(account.name, actor))
            return send(response, 200, 'application/json', '{"ok":true}')
        end

        return send(response, 404, 'text/plain', 'Not found')
    end

    if request.method ~= 'GET' then
        return send(response, 405, 'text/plain', 'Method not allowed')
    end

    if path == '/' or path == '' or path == '/index.html' then
        if not page then
            return send(response, 500, 'text/plain', 'web/index.html is missing from the resource')
        end
        return send(response, 200, 'text/html; charset=utf-8', renderPage())
    end

    if path == '/players' then
        local allowed, code, token = authorize(request)
        if not allowed then
            -- "setup" tells the console to show the first-time setup instead of the login
            local why = code == 429 and 'locked' or (needsSetup() and 'setup' or 'password')
            return send(response, code, 'application/json', '{"error":"' .. why .. '"}')
        end
        local session = sessionOf(request)
        reportDuty(query(request), address(request), session and session.user)
        local body = snapshot()
        if session then
            -- who you are (and after a login the session token) goes in front of the shared data
            body = ('{"me":{"user":"%s","admin":%s%s},'):format(session.user, tostring(session.admin == true),
                token and (',"token":"' .. token .. '"') or '') .. body:sub(2)
        end
        return send(response, 200, 'application/json', body, token)
    end

    -- Log out: the session token stops working
    if path == '/logout' then
        local given = header(request, 'x-livemap-key')
        if given then tokens[given] = nil end
        return send(response, 200, 'application/json', '{"ok":true}')
    end

    if path == '/history' then
        local allowed, code = authorize(request)
        if not allowed then
            return send(response, code, 'application/json', '{"error":"password"}')
        end
        local entries = {}
        for i = #history, math.max(1, #history - 299), -1 do        -- newest first, 300 at most
            entries[#entries + 1] = history[i]
        end
        return send(response, 200, 'application/json', json.encode({ entries = entries }))
    end

    if path == '/voice/poll' then
        return handlePoll(request, response)
    end

    if path == '/voice/leave' then
        return handleLeave(request, response)
    end

    send(response, 404, 'text/plain', 'Not found')
end)

CreateThread(function()
    Wait(1000)
    local port = GetConvar('netPort', '30120')

    -- Work out the real addresses to print. The public IP comes from one request to api.ipify.org
    -- (a server cannot see its own public address); the https address is the one FiveM gives
    -- every server (web_baseUrl), which shows up a few seconds after the start.
    local ip, asked = nil, false
    PerformHttpRequest('https://api.ipify.org', function(status, body)
        if status == 200 and type(body) == 'string' and body:match('^%d+%.%d+%.%d+%.%d+$') then ip = body end
        asked = true
    end, 'GET')
    local secure = GetConvar('web_baseUrl', '')
    local waited = 0
    while (not asked or secure == '') and waited < 8000 do
        Wait(500)
        waited = waited + 500
        secure = GetConvar('web_baseUrl', '')
    end

    print(('^2[%s]^7 Dispatch console: ^5http://%s:%s/%s/^7'):format(RESOURCE, ip or '<your server ip>', port, RESOURCE))
    if secure ~= '' then
        print(('^2[%s]^7 Secure address (for talking on the radio from another computer): ^5https://%s/%s/^7'):format(RESOURCE, secure, RESOURCE))
    end
    if needsSetup() then
        print(('^3[%s]^7 No dispatcher account yet. Open the console in your browser and use this setup code: ^2%s^7 (it changes on every restart).'):format(RESOURCE, setupCode))
    end
    if jobFilter and type(Config.GetJob) ~= 'function' then
        findCore()
        if not coreKind then
            print(('^3[%s]^7 Config.Jobs is set, but no Qbox, QBCore or ESX was found, so the map stays empty. Set Config.GetJob in config.lua.'):format(RESOURCE))
        end
    end
    if Voice.Enabled == true then
        if not voiceSystem() then
            print(('^3[%s]^7 Radio is off: no supported voice resource is running (pma-voice, saltychat, tokovoip_script). See Config.Voice.System.'):format(RESOURCE))
        else
            print(('^2[%s]^7 Radio is on, using %s. Talking from a browser on another computer needs the HTTPS address, see README.'):format(RESOURCE, voiceSystem()))
        end
    end
end)
