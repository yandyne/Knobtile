-- a new generation number ends the running loop in Init.lua, which closes its sockets
local prefs = import 'LrPrefs'.prefsForPlugin()
prefs.gen = (prefs.gen or 0) + 1
