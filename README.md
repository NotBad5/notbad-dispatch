# notbad-dispatch

A dispatch console for your FiveM server that runs in the browser: a live map of your units, calls you can create and hand out, call signs, and a radio link to your voice system (pma-voice, SaltyChat, TokoVoip). (Formerly notbad-livemap.)

> **Beta.** Tested in game on **ESX** with **pma-voice**. Qbox, QBCore, SaltyChat and TokoVoip are supported in the code but have not been tested on a live server yet. Please report what you find: https://discord.gg/JG49fzm2zF

What the dispatcher sees:
- **Units**, not a player list: everybody in one car is one unit, grouped under **Free**, **En route** and **On scene**, with call sign, crew and job
- **Calls** on the map and in a list; create one by clicking the map, send units to it, close it when it is done
- Units in game get a call card with the distance, a blip and a route

## Features
- Runs on your normal server port: **no extra port, no yarn, no npm, no dependencies**
- Optional **password**, with a lockout after repeated wrong guesses
- Optional **radio**: listen to and talk on a radio channel from the console (pma-voice, SaltyChat, TokoVoip)
- Player list with search. Click a player to follow them on the map
- Markers show the direction a player is facing and whether they are on foot or in a vehicle
- Drag and zoom with mouse or touch, works on phones; **W A S D** move the map (hold Shift to go faster)
- Game coordinates under the cursor, click the map to copy them
- Player count in the browser tab, ping in the player list
- Hide players with a simple config function (staff, undercover units...)
- Positions are only collected while somebody has the map open

## Install
1. Put the `notbad-dispatch` folder in your `resources` directory.
2. Add `ensure notbad-dispatch` to `server.cfg`.
3. Start the resource. It prints the address of the console (with your server IP, and the secure `https://...users.cfx.re` address) and a **setup code** in the server console.
4. Open `http://YOUR_SERVER_IP:30120/notbad-dispatch/` (use your own server port if it is not 30120), create the admin account with the setup code and save the password it shows you (see Accounts).

Requires OneSync, which is on by default on current servers.

## Config
| Option | What it does |
|---|---|
| `Config.Title` | Name shown on the page |
| `Config.UpdateInterval` | Refresh rate in milliseconds |
| `Config.ShowNames` | Show player names, or only server IDs |
| `Config.ShowPing` | Show each player's ping in the list |
| `Config.ShouldShow` | Function that returns `false` to hide a player |
| `Config.MapImage` | URL of the map picture |
| `Config.Calibration` | How game coordinates map to the picture, only needed for a different image |
| `Config.Voice` | Radio: on/off, allowed channels, name shown for map users, volume in game, radio sound effect |
| `Config.Jobs`, `Config.OnDutyOnly`, `Config.GetJob` | Show only players with certain jobs, with a colour per job |
| `Config.Names`, `Config.GetName` | Character name from the framework (default) or the FiveM name |
| `Config.ShowRanks` | Show the rank (job grade) of each unit in the unit list |
| `Config.Calls` | Dispatch calls: how long they stay, who may take them, panic, call list, optional chat command |
| `Config.Locale` | Language of the in-game texts |
| `Config.History` | The history shown on the console |

## Showing only some jobs
Fill in `Config.Jobs` and the map shows only players with those jobs, each in its own colour:

```lua
Config.Jobs = {
    police    = { label = 'Police', color = '#4d8dff' },
    ambulance = { label = 'EMS',    color = '#ff5a4f' },
}
```

- The job is read from Qbox, QBCore or ESX. With another framework, set `Config.GetJob`.
- **Performance:** jobs, duty and call signs are cached. The framework is only asked when a player loads, changes job or duty, or leaves (plus a slow background check once a minute), never while the map refreshes or a call goes out. With `Config.Jobs` set, a refresh only touches the players who have those jobs, however many players are on the server.
- With `Config.GetJob` there are no events to listen to, so changes are picked up within 15 seconds; call `exports['notbad-dispatch']:refreshPlayer(playerId)` from your own job script to make it instant.
- `Config.OnDutyOnly = true` hides players who are off duty.
- The job name is the internal one from your framework (`police`, not `Police Department`).
- Leave `Config.Jobs` empty to show everybody.

## Cars and call signs
- A unit in a vehicle is drawn as a small **vehicle icon** seen from above (car, motorbike, helicopter, plane or boat) that points the way it is heading and takes the colour of its job.
- Players sitting in the same car are drawn as **one marker** (on the driver). Hover the marker to see who is inside.
- Click a player or a car and a **Call sign** box appears under the search field. Type a call sign (for example `A-12`) and press **Save**: everybody in that car gets it. The marker then shows the call sign and the crew size, and the player list is sorted by call sign.
- The call sign stays with those players when they get out or change cars. Save an empty box to remove it.
- A new call sign shows up everywhere at once: on the map, in the unit list, on the calls the unit is on, and on the call cards in game (the unit's own card and the cards of the other units on the same call).
- On QBCore and Qbox the call sign of the character is used until you set another one.
- **Cars only** (top right) hides everybody who is on foot, so the map shows vehicles only.
- **Auto focus** (top right) decides whether the map moves by itself: on, a click on a unit or call centers the map on it and a chosen unit is followed; off, the map stays where you put it. "Center on this call" in the right-click menu always works.
- **Send** on a call sends the whole crew of the selected car.
- From a server script: `exports['notbad-dispatch']:setCallsign(playerId, 'A-12')` and `getCallsign(playerId)`.

## Dispatch calls
Calls appear on the map as a red pulsing pin and in a **Calls** list above the units. The pin, its label and the list show **how many units are on the call** and how many have arrived; units in game see the same on their call card, with the names of the other units. Players who share a call sign or a car count as one unit. Click a call to jump to it, press **Done** to close it. A new call plays a short beep.

**Creating a call on the map.** Press **New call** (top right), click the place on the map, type what it is and press **Create call**. If a player or car is selected, the form offers to send that unit right away.

**Dispatchers on duty.** Type your name at the top of the panel and press **Go on duty**. Several dispatchers can work at the same time: everybody opens the same address with the same password, sees the same units and calls (changes show up within a couple of seconds) and sees who else is on duty. On the radio they hear each other too. Closing the console ends the shift.

**Nobody on duty.** While no dispatcher is on duty, a new call is offered to every available unit in game: a card slides in for 20 seconds and **F10** or `/callaccept` takes the call. With a job set on the call only that job gets the offer. See `Config.Calls.SelfDispatch` under "Units in game" for the other modes.

**Selecting several units.** **Ctrl + click** units on the map or in the list to add or remove them, or hold **Shift and drag** a box over the map. **Send**, **New call** and the right-click menu then work for all of them at once. **Clear selection** or Esc starts over.

**Editing a call.** **Edit** under a call changes its title, details and code; **Move** lets you click its new place on the map. Units on the call see the change on their card at once, and after a move their route goes to the new place.

**Templates.** Ready-made calls (title, details, code, priority). There are two kinds: the ones in `Config.Calls.Templates`, and the ones dispatchers save on the console. To save one, fill in the New call (or Edit) form and tick **Save this as a new template**; it is stored on the server in `templates.json`, so every dispatcher gets it and it survives restarts. The **Templates** button (top right) opens a window with all of them: add a new one at the bottom, or use **Edit** and **Delete** on a saved one. The same works from inside the call form: choose a saved template in the Template box, edit the fields and press **Update** (no call is created); **Delete** removes it. Templates from the config can only be changed in the config, but you can choose one, change the fields and save the result as a new template. In the form the **Template** box fills everything in, and you can still change it before saving. In the right-click menu of the map each template creates the call on that spot in one click, and sends the selected units along if any are selected. Scripts use them with `addCall({ template = 'shots', coords = ... })`; anything else you pass overrides the template.

**Finding a call on the map.** Point at a call in the list and it lights up on the map: the pin grows with a white ring, its routes turn white and the other calls fade. It works the other way round too (pointing at a pin marks its row), and pointing at a unit in the list lights up its marker.

**Right-click menu.** Right-click the map for **New call here**, **Send (selected unit) here** and **Copy coordinates**. Right-click a unit, on the map or in the unit list, to send it to one of the open calls, take it off its call, set its call sign or set its status (available, busy, unavailable). Any logged-in dispatcher can do this, not only admins. Right-click a call to send the selected unit, center on it or close it.

**Sending units.** The quickest way: **click the call** (in the list or its pin on the map), then **click the units** that should go, on the map or in the list. Each click sends that unit with its whole crew; clicking a unit that is already on the call takes it off again. A red bar at the top shows which call you are sending to; **Done**, Esc or a second click on the call ends it. The other way round also works: click a player or car (on the map or in the list), then press **Send** on a call. On the map a dashed line runs from the unit to the call, the call lists its units, and the player list shows who is **En route**, **On scene** or **Free**.

**In game.** A unit that is sent gets a card on the right side of the screen with the call sign, code, title, details and the live distance, plus a flashing blip with a route. Within 60 m the card turns green and says **On scene**. The unit clears the call itself with **F9** or `/callclear` (the key can be changed in the GTA key bindings under FiveM; switch this off with `Config.Calls.PlayersCanClear = false`). Click a unit's name under the call to take it off again. Closing the call frees all its units. A unit is on one call at a time.

Add a call from any **server** script:

```lua
local id = exports['notbad-dispatch']:addCall({
    title    = 'Shots fired',            -- shown on the map
    text     = 'Caller heard 3 shots',   -- optional details
    code     = '10-71',                  -- optional short code
    priority = 1,                        -- optional: 1 high, 2 normal (default), 3 low
    coords   = vector3(215.0, -810.0, 30.0),  -- where; or use source = playerId to take a player's position
    job      = 'police',                 -- optional; hidden if the map does not show this job
    duration = 600,                      -- optional, seconds; default is Config.Calls.Duration
})

exports['notbad-dispatch']:updateCall(id, { title = 'Armed robbery', text = '', coords = vector3(x, y, z) })  -- change or move it
exports['notbad-dispatch']:removeCall(id)     -- close it from a script
exports['notbad-dispatch']:assignCall(id, playerId)   -- send a unit, same as the Send button
exports['notbad-dispatch']:unassignUnit(playerId)     -- take a unit off its call
local open = exports['notbad-dispatch']:getCalls()
```

From a **client** script the same export exists (most alert scripts run on the client). Without `coords` the call is placed where that player stands:

```lua
-- client, for example inside a robbery or shots-fired script
exports['notbad-dispatch']:addCall({
    title = 'Store robbery', text = 'Silent alarm', code = '10-90', priority = 1, job = 'police',
})
```

Client calls can also be triggered by cheaters, so they are limited to one every two seconds per player. If all your calls come from server scripts, set `Config.Calls.ClientCalls = false`.

All server exports:

| Export | What it does |
|---|---|
| `addCall(data)` | New call, returns its id |
| `updateCall(id, data)` | Change title, text, code, priority or coords |
| `removeCall(id)` | Close a call |
| `getCalls()` | Open calls |
| `assignCall(id, playerId)` / `unassignUnit(playerId)` | Send a unit / take it off its call |
| `setUnitStatus(playerId, 'available' \| 'busy' \| 'break')` / `getUnitStatus(playerId)` | Unit status |
| `setCallsign(playerId, 'A-12')` / `getCallsign(playerId)` | Call signs |
| `getDispatchers()` | Names of the dispatchers on duty |
| `refreshPlayer(playerId)` | Re-read a player's job after your own job script changed it |

## Priorities
Every call has a priority: **P1** high (red, pulsing, a longer alert sound on the console), **P2** normal (orange) or **P3** low (grey). Calls are sorted by priority, then newest first, on the console and in the in-game list. Choose it in the New call form, change it with **Edit**, or pass `priority` to `addCall`.

## Units in game
| Command | Default key | What it does |
|---|---|---|
| `/callaccept` | F10 | Take the call that is being offered |
| `/callclear` | F9 | Done with my call |
| `/callprev`, `/callnext` | Left / Right arrow | Flip through the open calls on the card |
| `/calltake` | G | Take the call that is shown (flipped to, or offered) |
| `/calls` | none | List of open calls; a unit can take one from it when `SelfDispatch` allows |
| `/unitstatus available`, `busy`, `break` | none | Set my status |
| `/panic` | none | Panic button: a P1 call at my position, offered to every unit |

Keys can be changed (or added) in the GTA settings under Key Bindings > FiveM.

**Unit status.** A unit is **Free**, **En route** or **On scene** automatically. With `/unitstatus` it can also be **Busy** or **Unavailable**; the dispatcher can set the same from the right-click menu on a unit. Busy and unavailable units are not offered new calls (a panic call goes to everybody).

**Who decides (`Config.Calls.SelfDispatch`).**
- `'auto'` (default): a dispatcher on duty sends the units. While nobody is on duty, new calls are offered to the available units and they take them themselves.
- `'always'`: units are always offered new calls and can take any call from `/calls`; the dispatcher coordinates on top.
- `'never'`: only a dispatcher sends units.

The dispatcher can switch between these three on the console at any time (**Units take calls themselves**, under the duty button); the change applies at once for everybody and lasts until the resource restarts, when the value from the config is used again. From a script: `exports['notbad-dispatch']:setSelfDispatch('never')`.

**Arrow keys.** A unit flips through the open calls with the left and right arrow keys; the card shows the call, its priority, how many units are on it and the distance. **G** takes the call that is shown, if the current mode lets units take calls. After 8 seconds without a key the card goes back to the unit's own call. Players who are not units are not affected by these keys. Turn it off with `Config.Calls.BrowseKeys = false`.

## History
**History** (top right on the console) lists who did what and when: calls created, edited, moved and closed, units sent, arrived and cleared, status changes, panic, dispatchers going on and off duty. It is kept across restarts in `history.json` (`Config.History`). Dispatchers are told apart by their address, so two dispatchers behind the same address appear under one name.

## Languages
`Config.Locale` sets the language of everything players see in game (call card, offers, call list, status messages, the reply of the call command): `en`, `cs`, `de`, `fr`, `es`, `pt`, `pl`. To add one, copy the `en` block in `locales.lua` and translate it. The console in the browser is in English.

Set `Config.Calls.Command = '911'` to give players a ready-made `/911 what happened` command.

## Radio
The console can join a radio channel of your voice system: you hear the players on it and can talk to them.

Supported voice systems (`Config.Voice.System`, `'auto'` finds the one that is running):

| System | Resource | Notes |
|---|---|---|
| pma-voice | `pma-voice` | |
| SaltyChat | `saltychat` | Primary and secondary channel; channel names can be text |
| TokoVoip | `tokovoip_script` | |
| anything else | | Set `System = 'custom'` and call `exports['notbad-dispatch']:setRadioChannel(channel)` and `:setRadioTalking(true/false)` from a client script |

The audio is recorded and played by this resource itself; from the voice system it only reads which channel a player is on and when the radio key is held. So it also works with TeamSpeak-based systems, but the console's voice comes out of the game, not out of TeamSpeak.

1. Log in to the console (see Accounts).
2. Keep `Config.Voice.Enabled = true` and make sure your voice resource is running.
3. Open the map, type a channel number in the **Radio channel** box and press **Join**.
4. Hold **Hold to talk** (or the space bar) to transmit.

**Talking needs HTTPS, except on the server's own computer.** Browsers only give a page the microphone on an HTTPS address or on `localhost` / `127.0.0.1`. So if the browser runs on the same computer as the server and you open `http://localhost:30120/...`, talking works over plain HTTP. From any other computer, listening works on the normal `http://IP:30120/...` address but talking does not. Two ways around it:
- Open the map through your server's `https://xxxx.users.cfx.re/notbad-dispatch/` address (the same address txAdmin shows for your server).
- Or, in Chrome, open `chrome://flags/#unsafely-treat-insecure-origin-as-secure`, add `http://YOUR_SERVER_IP:30120` and restart the browser.

How it works, so there are no surprises:
- It is a relay next to your voice system, not part of it. There is a delay of roughly a quarter of a second.
- With `Config.Voice.Effect = true` voices get a radio sound: narrow band, a loud compressed voice, very light static and a soft click at the start and end of each transmission. Set it to `false` for a clean voice.
- Players are heard on the map only while they hold their radio key, and only while somebody on the map has joined their channel.
- For that, the game asks each player once for permission to use the microphone for this resource. A player who says no still hears the map but is not heard on it. The game always uses the default Windows microphone here.
- Players do not see the map user in their radio list, they just hear the voice.
- The **Volume** slider in the radio box sets how loud players are in your browser. `Config.Voice.Volume` sets how loud the dispatcher is for players in game.
- Restrict the channels the map may join with `Config.Voice.Channels`.

## Using your own map picture
1. Put the URL of your picture in `Config.MapImage` and restart the resource. Any size or shape works.
2. Open the map with `?calibrate` at the end of the address: `http://YOUR_SERVER_IP:30120/notbad-dispatch/?calibrate`
3. For each place, choose a player in the list (their current position is used, so ask them to stand still) or type game coordinates yourself. Then click that exact spot on the picture.
4. After two places the players on the map jump to the new alignment so you can check it. A third place tells you how well it fits.
5. Press **Copy for config.lua**, paste the block over `Config.Calibration` in `config.lua`, and restart the resource.

Pick places that are far apart, for example one in the city and one up north. The picture must be a straight top-down map with north at the top.

## Upgrading from notbad-livemap
- Delete the old `notbad-livemap` folder and change the line in `server.cfg` to `ensure notbad-dispatch`.
- The address is now `http://IP:30120/notbad-dispatch/`.
- Exports are now called on `exports['notbad-dispatch']`.
- Copy your password and other settings into the new `config.lua`.

## Upgrading from 1.0
- Delete the old folder first. `config.json`, `server.js`, `package.json` and `node_modules` are gone.
- The address changed from `http://IP:3000/` to `http://IP:30120/notbad-dispatch/`. You can close port 3000.
- The `yarn` resource is no longer needed for this script.

## Accounts
Everybody logs in to the console with a **username and a password**. Nothing about logins is written in `config.lua`.

**First-time setup.** The first time you open the console there is no account yet, so it shows a setup screen:
1. Start the resource and look at the server console (for example the txAdmin live console). It prints a 6-digit **setup code**. The code changes on every restart and only exists while there is no account.
2. On the setup screen choose a username and type the code.
3. The console shows the **generated password of the admin account, once**. Save it (a password manager is best) and log in.

The code is there so that not just anybody who finds the address first becomes the admin: only somebody who can read your server console can.

**More dispatchers.** An admin opens **Accounts** (top right) and adds a username. The console generates the password and shows it once, to pass on to that dispatcher. In the same window an admin can give an account a **new password** (the old one stops working and that dispatcher is logged out), make it an admin or not, and delete it. The last admin cannot be removed.

- The username is the dispatcher's name on duty and in the History, so you can see who did what.
- Admins may manage accounts and call templates and change who sends units (**Units take calls themselves**). Everything else is the same for all accounts.
- Passwords are always generated (three groups, like `k7Qnd-R2mfa-9pXe`); nobody chooses or types one into a file. They are stored only as salted hashes in `accounts.json` in the resource folder.
- **Lost the only admin password?** Stop the resource, delete `accounts.json`, start it again and do the first-time setup again. The other accounts are gone then too.
- **Log out** is at the top of the panel.

## Password protection
- **Guessing is slowed down.** Five wrong passwords lock that address: 1 minute the first time, then 2, 4, 8 and so on up to an hour. A correct login or an hour without wrong tries clears it.
- **Guessing from many addresses** is noticed too: after 30 wrong passwords in 5 minutes overall, a single wrong password locks an address for the next 10 minutes.
- **Dispatchers who are logged in are not thrown out** by somebody else's guessing: after login the console uses a session token instead of the password. Tokens are forgotten when the resource restarts (everybody logs in again) or after 12 hours without use.
- Locks and attacks are printed in the server console and written to the History.
- All of this limits guessing, it does not make a short password safe. Use at least 8 characters, and remember the connection is plain HTTP unless you open the console through an HTTPS address.

## Good to know
- The connection is plain HTTP, so the password is not encrypted on the way. Do not reuse an important password.
- The map picture is loaded from the URL in `Config.MapImage`. Host the image yourself if you want to be sure it never disappears.
- If you rename the resource folder, the address changes with it.
- When the resource starts it makes one request to `api.ipify.org` to learn the server's public IP, only to print the right address in the server console. Nothing else is sent anywhere.
- `accounts.json`, `history.json` and `templates.json` are created in the resource folder while it runs. Keep them when you update; never share `accounts.json`.

## License
Free to use and change, not to sell. See `LICENSE`.
