fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'notbad-dispatch'
author 'NotBad#9927'
description 'Dispatch console in your browser: live unit map, calls, call signs and radio (pma-voice, SaltyChat, TokoVoip). No extra port, no dependencies. https://discord.gg/JG49fzm2zF'
version '1.0.0-beta'

-- config.lua stays server-only on purpose: it holds the password.
server_scripts {
    'config.lua',
    'locales.lua',
    'server.lua'
}

-- In-game side: radio bridge and the call card.
client_scripts {
    'locales.lua',
    'client.lua'
}
ui_page 'web/game.html'
files {
    'web/game.html'
}
