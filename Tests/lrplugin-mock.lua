-- mock Lightroom SDK, run the plugin, drive its socket callbacks
local sent, socks, range, value, tasks = {}, {}, {}, {}, {}
local prefs = {}
local function sock(t) local s = { t = t, n = 0 }
  function s:send(x) sent[#sent+1] = x end
  function s:reconnect() self.n = self.n + 1 end
  socks[t.mode] = s; return s end
local mods = {
  LrApplication = { activeCatalog = function() return { getTargetPhoto = function() return nil end } end, developPresetFolders = function() return {} end },
  LrApplicationView = {}, LrSelection = {}, LrUndo = {},
  LrDevelopController = { getValue = function(p) return value[p] end, setValue = function(p, v) value[p] = v end,
    getRange = function(p) local r = range[p]; if not r then error('no range') end; return r[1], r[2] end,
    addAdjustmentChangeObserver = function() end },
  LrFunctionContext = { callWithContext = function(_, f) f({}); for _, k in pairs(socks) do k.t.onClosed(k) end end }, -- like Lightroom: leaving the context closes its sockets
  LrSocket = { bind = sock },
  LrTasks = { startAsyncTask = function(f) tasks[#tasks+1] = coroutine.create(f) end, sleep = function() coroutine.yield() end,
    pcall = pcall },
  LrLogger = function() return { enable = function() end, info = function(_, m) print('log ' .. m .. '\n') end, warn = function(_, m) print('WARN ' .. m .. '\n') end } end,
  LrPrefs = { prefsForPlugin = function() return prefs end },
}
_G.import = function(n) return assert(mods[n], n) end
_G._PLUGIN = {}
local function step() for _, t in ipairs(tasks) do if coroutine.status(t) == 'suspended' then local ok, e = coroutine.resume(t); if not ok then error(e) end end end end
dofile(PLUGIN)
step(); step() -- past sleep(0.6): sockets bound, in the loop
assert(socks.send and socks.receive, 'sockets not bound')
local function line(l) sent = {}; socks.receive.t.onMessage(socks.receive, l); return table.concat(sent) end
-- DNG: app range is the photo's range
range.Temperature, value.Temperature = { 2000, 50000 }, 5000
assert(line('Temperature = \t+\t100.0\t1500.0\t50000.0') == 'Temperature\t5100\n', 'dng nudge: ' .. table.concat(sent))
-- JPG: -100..100, value 0. step 100 of 48500 -> 0.41 -> one unit; range rides along
range.Temperature, value.Temperature = { -100, 100 }, 0
assert(line('Temperature = \t?\t\t1500.0\t50000.0') == 'Temperature\t0\t-100\t100\n', 'jpg ask: ' .. table.concat(sent))
assert(line('Temperature = \t+\t100.0\t1500.0\t50000.0') == 'Temperature\t1\t-100\t100\n', 'jpg up: ' .. table.concat(sent))
assert(line('Temperature = \t+\t-500.0\t1500.0\t50000.0') == 'Temperature\t-1.0618556701031\t-100\t100\n' or value.Temperature < 0, 'jpg down: ' .. table.concat(sent))
-- tint on a JPG overlaps the app's range: no scaling, no range sent
range.Tint, value.Tint = { -100, 100 }, 0
assert(line('Tint = \t+\t5.0\t-150.0\t150.0') == 'Tint\t5\n', 'tint: ' .. table.concat(sent))
-- exposure untouched
range.Exposure, value.Exposure = { -5, 5 }, 0
assert(line('Exposure = \t+\t0.1\t-5.0\t5.0') == 'Exposure\t0.1\n', 'exposure: ' .. table.concat(sent))
-- the app goes away: no reconnect() on either socket (it hangs Lightroom); the context ends and both are bound anew
local a, b = socks.send, socks.receive
b.t.onClosed(b)
step(); step(); step()
assert(a.n == 0 and b.n == 0, 'reconnect called')
assert(socks.send ~= a and socks.receive ~= b, 'sockets not bound anew')
range.Exposure, value.Exposure = { -5, 5 }, 0
assert(line('Exposure = \t+\t0.1\t-5.0\t5.0') == 'Exposure\t0.1\n', 'after renew: ' .. table.concat(sent))
print('PLUGIN OK\n') -- run: one file of "local PLUGIN = [[...Init.lua]]" + this file, with Resolve's fuscript -l lua
