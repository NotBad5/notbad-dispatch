Config = {}

-- Shown in the browser tab and at the top of the unit list.
Config.Title = 'Dispatch'

-- Language of everything players see in game: 'en', 'cs', 'de', 'fr', 'es', 'pt' or 'pl'.
-- Add your own in locales.lua. The console in the browser is in English.
Config.Locale = 'en'

-- Logins are not kept in this file. The first admin account is created on the console itself
-- (first-time setup, with a code that the resource prints in the server console), and that
-- admin adds the other dispatchers there. See "Accounts" in the README.

-- How often player positions are refreshed, in milliseconds.
-- Positions are only collected while somebody has the map open.
Config.UpdateInterval = 2000

-- Show player names. With false the map only shows server IDs.
Config.ShowNames = true

-- Which name is shown for a player: 'character' = the character's name from your framework
-- (Qbox, QBCore, ESX), with the FiveM name as a fallback; 'fivem' = always the FiveM name.
Config.Names = 'character'

-- Only needed with another framework: return the character's name yourself.
-- Config.GetName = function(source)
--     return 'John Doe'
-- end

-- Show each unit's rank (the job grade from your framework, for example "Sergeant") in the unit list.
Config.ShowRanks = true

-- Show each player's ping in the player list.
Config.ShowPing = true

-- Return false to hide a player from the map (staff, undercover units...).
-- source is the player's server ID.
Config.ShouldShow = function(source)
    return true
end

-- The map picture. Any image URL works. Hosting it yourself is the safest choice:
-- if this link ever stops working the map shows players on an empty background.
Config.MapImage = 'https://imgur.com/kTRQ3mF.png'

-- How game coordinates land on the picture. Only change this if you use a different image.
-- You do not have to work these numbers out by hand: open the map with ?calibrate at the end
-- of the address, mark two or three places, and paste the block it gives you over this one.
-- size:  width of the image in pixels
-- zeroX, zeroY: pixel position of game coordinate 0, 0
-- scale: game units per pixel
Config.Calibration = {
    size  = 4096,
    zeroX = 1877.25,
    zeroY = 2765,
    scale = 3.037861303705727,
}

-- Jobs to show on the map. Empty = every player, like before.
-- With jobs filled in, ONLY players with one of these jobs are shown.
-- The job is read from Qbox, QBCore or ESX automatically.
-- label = name shown on the map, color = colour of the marker (#rrggbb).
Config.Jobs = {
    -- police    = { label = 'Police', color = '#4d8dff' },
    -- ambulance = { label = 'EMS',    color = '#ff5a4f' },
    -- mechanic  = { label = 'Mechanic', color = '#ffb020' },
}

-- true = only players who are on duty (frameworks that know duty; others count as on duty).
Config.OnDutyOnly = false

-- Only needed with another framework: return the player's job name, and optionally whether
-- they are on duty and the name of their rank.
-- Config.GetJob = function(source)
--     return 'police', true, 'Sergeant'
-- end

-- Dispatch calls. Other resources add a call to the map with:
--   exports['notbad-dispatch']:addCall({ title = 'Shots fired', text = 'Near the bank', coords = vector3(x, y, z) })
-- See README for all options.
Config.Calls = {
    -- How long a call stays on the map if nobody closes it, in seconds.
    Duration = 900,

    -- Who decides which unit goes to a call:
    --   'auto'   a dispatcher on duty sends the units. While nobody is on duty, every new call is
    --            offered to the available units in game and they take it themselves (F10).
    --   'always' units are always offered new calls and can take any call from /calls,
    --            the dispatcher coordinates on top of that.
    --   'never'  only a dispatcher sends units. With nobody on duty the calls wait.
    SelfDispatch = 'auto',

    -- true = units can open the list of open calls in game with /calls.
    UnitsSeeCalls = true,

    -- true = units flip through the open calls with the arrow keys and take the shown one with G.
    BrowseKeys = true,

    -- true = units have a panic button (/panic): a priority 1 call at their position, offered to everybody.
    Panic = true,

    -- true = client scripts may create calls with exports['notbad-dispatch']:addCall(...).
    -- A cheater can trigger that too (one call every two seconds at most), so turn it off if
    -- all your calls come from server scripts.
    ClientCalls = true,

    -- true = a unit can clear its own call in game (F9 or /callclear). false = only the dispatcher can.
    PlayersCanClear = true,

    -- Ready-made calls. On the console they fill in the New call form and appear in the
    -- right-click menu of the map; scripts use them with addCall({ template = 'shots', coords = ... }).
    -- id = short name for scripts, priority = 1 high, 2 normal, 3 low. text, code and job are optional.
    Templates = {
        { id = 'shots',    title = 'Shots fired',            text = 'Caller reports gunfire',        code = '10-71', priority = 1 },
        { id = 'robbery',  title = 'Robbery in progress',    text = 'Alarm triggered',               code = '10-90', priority = 1 },
        { id = 'backup',   title = 'Unit needs assistance',                                          code = '10-78', priority = 1 },
        { id = 'accident', title = 'Traffic accident',       text = 'Possible injuries',             code = '10-50', priority = 2 },
        { id = 'person',   title = 'Suspicious person',                                              code = '10-66', priority = 3 },
        { id = 'noise',    title = 'Disturbance',            text = 'Noise complaint',               code = '10-21', priority = 3 },
    },

    -- Chat command players can use to call dispatch, for example '911'. '' = no command.
    -- Check that no other resource already uses the same command.
    Command = '',
}

-- History: who created, sent, edited and closed what. Shown on the console under History.
Config.History = {
    Enabled = true,
    Keep = 500,        -- how many entries are kept
    Save = true,       -- keep it across restarts (written to history.json in this folder)
}

-- Radio: listen to and talk on a radio channel of your voice system straight from the console.
-- Works with pma-voice, SaltyChat and TokoVoip. Needs a password above (without one the radio stays off).
-- Talking from the browser only works when the map is opened over HTTPS, see README.
Config.Voice = {
    Enabled = true,

    -- Your voice system: 'auto' (finds pma-voice, saltychat or tokovoip_script), 'pma-voice',
    -- 'saltychat', 'tokovoip', or 'custom' for anything else (see README).
    System = 'auto',

    -- Channels the map may join. Empty = any channel.
    -- Example: { 1, 2, 3 }
    Channels = {},

    -- Name other map users see when somebody talks from the map.
    Name = 'Dispatch',

    -- How loud the map is for players in game, 0.0 to 1.0.
    Volume = 1.0,

    -- Radio sound: narrow band, static and squelch clicks. false = clean voice.
    Effect = true,
}
