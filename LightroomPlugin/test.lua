-- Self-check with a fake Lightroom. Run from the project folder with any Lua 5.1, e.g. Resolve's:
--   fuscript -l lua LightroomPlugin/test.lua
local vals = { Exposure = 0, Temperature = 5000, SplitToningShadowHue = 0, SplitToningShadowSaturation = 0, CropLeft = 0.25, CropRight = 0.75, CropTop = 0.25, CropBottom = 0.75 }
local calls, sent, socks, sleeps, body, prefs = {}, {}, {}, 0, nil, {}
local function rec(name) return function(...) calls[#calls + 1] = name .. '(' .. table.concat({ ... }, ',') .. ')' end end
local D = setmetatable({
  getValue = function(p) return assert(vals[p], 'no param ' .. p) end,
  setValue = function(p, v) vals[p] = v end,
  getRange = function(p) if p == 'Exposure' then return -5, 5 elseif p == 'Temperature' then return -100, 100 end error('no range') end,
  resetToDefault = function(p) vals[p] = 0 end,
  addAdjustmentChangeObserver = function() end,
}, { __index = function(_, k) return rec('D.' .. k) end })
local flag, rating, label = 0, 3, 'none'
local Sel = setmetatable({
  getFlag = function() return flag end, getRating = function() return rating end, getColorLabel = function() return label end,
  setRating = function(n) rating = n end, setColorLabel = function(c) label = c end,
  flagAsPick = function() flag = 1 end, flagAsReject = function() flag = -1 end, removeFlag = function() flag = 0 end,
}, { __index = function(_, k) return rec('Sel.' .. k) end })
local applied, photos = {}, {}
local function photo(id) return { localIdentifier = id, getDevelopSettings = function() return { from = id } end,
  applyDevelopSettings = function(_, st) applied[#applied + 1] = id .. '<-' .. st.from end, applyDevelopPreset = function(_, p) applied[#applied + 1] = id .. '<-' .. p.name end } end
photos = { photo(1), photo(2) }
local target = photos[1]
local mods = {
  LrApplication = {
    activeCatalog = function() return { getTargetPhoto = function() return target end, getTargetPhotos = function() return { target } end, withWriteAccessDo = function(_, _, f) f() end } end,
    developPresetFolders = function() return { { getName = function() return 'User' end, getDevelopPresets = function() return { { getUuid = function() return 'U1' end, getName = function() return 'Warm' end } } end } } end,
    developPresetByUuid = function(u) return u == 'U1' and { name = 'Warm' } or nil end,
  },
  LrDevelopController = D, LrSelection = Sel,
  LrApplicationView = setmetatable({}, { __index = function(_, k) return rec('View.' .. k) end }),
  LrUndo = setmetatable({}, { __index = function(_, k) return rec('Undo.' .. k) end }),
  LrFunctionContext = { callWithContext = function(_, f) f({}) end },
  LrLogger = function() return { enable = function() end, warn = function() end, info = function() end } end,
  LrSocket = { bind = function(t) socks[t.mode] = t; return { send = function(_, s) sent[#sent + 1] = s end, reconnect = function() end } end },
  LrTasks = { pcall = pcall, startAsyncTask = function(f) f() end,
    sleep = function() sleeps = sleeps + 1; if sleeps == 2 then body(); prefs.gen = -1 end end },
  LrPrefs = { prefsForPlugin = function() return prefs end },
}
_G._PLUGIN = {} -- on _G: some runners give the script its own environment
_G.import = function(n) return assert(mods[n], n) end

local function eq(a, b, what) if type(a) == 'number' then a = math.floor(a * 1000 + 0.5) / 1000 end; assert(a == b, what .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end
body = function()
  local function say(s) socks.receive.onMessage(nil, s) end
  socks.send.onConnected()
  say('Exposure = \t+\t0.5\t-5.0\t5.0'); eq(vals.Exposure, 0.5, 'nudge'); eq(sent[#sent], 'Exposure\t0.5\n', 'value back')
  say('Exposure = \t+\t9\t-2.0\t2.0'); eq(vals.Exposure, 2, 'nudge clamps to the app range')
  say('Exposure = \t=\t-1.5\t-5.0\t5.0'); eq(vals.Exposure, -1.5, 'set')
  say('Exposure = reset\t\t'); eq(vals.Exposure, 0, 'reset')
  say('Temperature = \t=\t9000\t1500.0\t50000.0'); eq(vals.Temperature, 100, 'JPEG range wins when the app range does not fit')
  say('ShadowsWheelX = \t+\t10\t0.0\t100.0'); eq(vals.SplitToningShadowSaturation, 10, 'wheel x'); eq(vals.SplitToningShadowHue, 0, 'wheel x hue')
  say('ShadowsWheelY = \t+\t10\t0.0\t360.0'); eq(vals.SplitToningShadowHue, 45, 'wheel y hue'); eq(vals.SplitToningShadowSaturation, 14.142, 'wheel y sat')
  say('ShadowsWheelY = \t+\t-20\t0.0\t360.0'); eq(vals.SplitToningShadowHue, 315, 'wheel below')
  say('CropPositionX = \t+\t10\t0.0\t100.0'); eq(vals.CropLeft, 0.35, 'crop x'); eq(vals.CropRight, 0.85, 'crop x right')
  say('CropPositionX = \t+\t90\t0.0\t100.0'); eq(vals.CropRight, 1, 'crop stops at the edge')
  say('CropScale = \t+\t50\t1.0\t0.0'); eq(vals.CropRight - vals.CropLeft, 0.25, 'crop tighter')
  say('flag = pick_next\t\t'); eq(flag, 1, 'pick'); eq(calls[#calls], 'Sel.nextPhoto()', 'then next')
  say('flag = \t+\t-1'); eq(flag, 0, 'flag dial')
  say('togglerating = 3\t\t'); eq(rating, 0, 'same rating takes it off')
  say('togglerating = 5\t\t'); eq(rating, 5, 'rating')
  say('labels = red\t\t'); eq(label, 'red', 'label'); say('labels = \t+\t1'); eq(label, 'yellow', 'label dial')
  say('WhiteBalance = As Shot\t\t'); eq(vals.WhiteBalance, 'As Shot', 'white balance')
  say('switchview = loupe\t\t'); eq(calls[#calls], 'View.showView(loupe)', 'view')
  say('reset = crop\t\t'); eq(calls[#calls], 'D.resetCrop()', 'reset crop')
  say('undo = 0\t\t'); eq(calls[#calls], 'Undo.undo()', 'undo')
  say('SetAspectRatio = 1:1\t\t'); assert(sent[#sent]:match('^!\tSetAspectRatio = 1:1.*not supported'), 'unsupported is reported: ' .. sent[#sent])
  say('presets = list\t\t'); eq(sent[#sent], '@function\tpreset = U1\tUser / Warm\n', 'preset list')
  -- plugin spec v1: bare names, a name alone, control lines
  say('Exposure\t=\t1.0\t-5.0\t5.0'); eq(vals.Exposure, 1, 'bare name sets')
  say('Exposure = reset'); eq(vals.Exposure, 0, 'a function without a value is its name alone')
  say('@hello\t1'); eq(sent[#sent], '@hello\t1\n', 'hello answered')
  say('@screen\tdevelop'); eq(calls[#calls], 'View.switchToModule(develop)', 'screen switch')
  say('@later\tx'); eq(calls[#calls], 'View.switchToModule(develop)', 'unknown control line skipped')
  say('preset = U1\t\t'); eq(applied[#applied], '1<-Warm', 'preset applied')
  say('preset = nope\t\t'); assert(sent[#sent]:match('preset not found'), 'missing preset is reported: ' .. sent[#sent])
  say('settings = copy\t\t'); target = photos[2]; say('settings = paste\t\t'); eq(applied[#applied], '2<-1', 'paste')
  print('plugin self-check ok')
end
dofile('LightroomPlugin/Knobtile.lrplugin/Init.lua')
assert(sleeps >= 2, 'the plugin never reached its loop')
