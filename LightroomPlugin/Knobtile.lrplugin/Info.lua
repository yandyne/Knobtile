return {
  LrSdkVersion = 10.0,
  LrSdkMinimumVersion = 6.0,
  LrToolkitIdentifier = 'io.github.yandyne.knobtile.lightroom',
  LrPluginName = 'Knobtile',
  LrInitPlugin = 'Init.lua',
  LrForceInitPlugin = true, -- start with Lightroom, not on first menu use
  -- Lightroom 16 only honours LrForceInitPlugin while it builds a plug-in's menu items (AgSdkMenus): without one, Init.lua
  -- never ran at launch and the app stayed unconnected until disable/enable in the Plug-in Manager (tested 2026-11-22, 5 of 5 launches).
  LrExportMenuItems = { { title = LOC '$$$/Knobtile/Reconnect=Reconnect Knobtile', file = 'Init.lua' } }, -- File > Plug-in Extras; running Init.lua again starts a new generation
  LrEnablePlugin = 'Init.lua',
  LrDisablePlugin = 'Stop.lua',
  LrShutdownPlugin = 'Stop.lua',
  LrShutdownApp = 'Quit.lua',
  VERSION = { major = 0, minor = 2, revision = 0 }, -- the app's version (make-app.sh)
}
