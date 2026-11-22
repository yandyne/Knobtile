-- Knobtile <-> Lightroom Classic. Takes control lines from the Knobtile app and sends develop values back.
-- in  (port 50120): input \t op \t value \t min \t max      op: "+" nudge, "=" set, "?" ask, "" command
-- out (port 50121): name \t value [\t min \t max when the photo's own range replaces the app's]      ("!" \t text = a line that could not be done)
-- This is a Knobtile plugin (plugin spec v1, connect "tcp" with a values port); its function list is the "lightroom" plugin folder's functions.json.
-- input: a develop parameter ("Exposure") or "key = argument" ("WhiteBalance = Auto", "flag = pick_next", "Exposure = reset").
-- control lines: "@hello" (answered with "@hello \t 1"), "@screen \t module" (go there), "@screen \t ?"; out: "@screen \t module" when it changes,
-- "@function \t preset = <uuid> \t folder / name" for every develop preset. also in: "preset = <uuid>", "settings = copy | paste | previous"
local LrApplication = import 'LrApplication'
local LrApplicationView = import 'LrApplicationView'
local D = import 'LrDevelopController'
local LrFunctionContext = import 'LrFunctionContext'
local LrSelection = import 'LrSelection'
local LrSocket = import 'LrSocket'
local LrTasks = import 'LrTasks'
local LrUndo = import 'LrUndo'
local log = import 'LrLogger'('Knobtile')
log:enable('logfile') -- ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/Knobtile.log

local IN_PORT, OUT_PORT = 50120, 50121

local prefs = import 'LrPrefs'.prefsForPlugin() -- the one store all of the plugin's scripts share
local gen = (prefs.gen or 0) + 1 -- Stop.lua or a reload bumps it: this run then ends
prefs.gen = gen
local function alive() return prefs.gen == gen end
log:info('start ' .. gen)

local out, outOpen, renewOut = nil, false, false
local watched, last = {}, {} -- develop params the app has used; the value last sent for each

local function clamp(v, lo, hi)
  if lo and v < lo then return lo end
  if hi and v > hi then return hi end
  return v
end

-- the app's range, unless this photo's own range does not overlap it (a JPEG's temperature is -100..100): then that range and true
local function bounds(p, lo, hi)
  local ok, a, b = pcall(D.getRange, p)
  if not ok or type(a) ~= 'number' or type(b) ~= 'number' then return lo, hi end
  if lo and hi and math.max(a, lo) < math.min(b, hi) then return math.max(a, lo), math.min(b, hi) end
  return a, b, lo ~= nil and hi ~= nil
end

local appRange = {} -- param: { lo, hi } the app sent with it
local function tell(name, v)
  -- not gated on outOpen: Lightroom's connect/close/error callbacks came out of step after the app restarted and the values stopped for good
  if not out or v == nil or last[name] == v then return end
  local line = name .. '\t' .. tostring(v)
  local r = appRange[name]
  if r then -- this photo has a scale of its own: send it along, the app's dial pointer follows it
    local a, b, own = bounds(name, r[1], r[2])
    if own then line = line .. '\t' .. tostring(a) .. '\t' .. tostring(b) end
  end
  if pcall(out.send, out, line .. '\n') then last[name] = v end
end

local function report()
  for p in pairs(watched) do
    local ok, v = pcall(D.getValue, p)
    if ok then tell(p, v) end
  end
end

local function param(p, op, v, lo, hi)
  watched[p] = true
  last[p] = nil -- always answer, also when the value did not move (at the end of its range): the app's dial follows the answer
  if lo and hi then appRange[p] = { lo, hi } end
  if op == '?' then return end
  local alo, ahi, own = lo, hi, nil
  lo, hi, own = bounds(p, lo, hi)
  if op == '+' then
    if own and ahi > alo then -- the app's step is meant for its own range: same share of this photo's range, at least one whole unit
      v = v * (hi - lo) / (ahi - alo)
      if math.abs(v) < 1 then v = v < 0 and -1 or 1 end
    end
    v = D.getValue(p) + v
  end
  D.setValue(p, clamp(v, lo, hi))
end

-- colour grading wheels: { hue param, saturation param }
local wheels = {
  Shadows = { 'SplitToningShadowHue', 'SplitToningShadowSaturation' },
  Midtones = { 'ColorGradeMidtoneHue', 'ColorGradeMidtoneSat' },
  Highlights = { 'SplitToningHighlightHue', 'SplitToningHighlightSaturation' },
  Global = { 'ColorGradeGlobalHue', 'ColorGradeGlobalSat' },
}

local function wheel(w, axis, op, v)
  local hp, sp = w[1], w[2]
  watched[hp], watched[sp] = true, true
  if op == '?' then return end
  if op == '=' then -- slider or reset: X is saturation, Y is hue
    D.setValue(axis == 'X' and sp or hp, v)
    return
  end
  -- nudge: move the point on the wheel sideways (X) or up (Y), hue 0 at the right, counter-clockwise
  local h, s = math.rad(D.getValue(hp)), D.getValue(sp)
  local x, y = s * math.cos(h), s * math.sin(h)
  if axis == 'X' then x = x + v else y = y + v end
  D.setValue(sp, math.min(100, math.sqrt(x * x + y * y)))
  if x ~= 0 or y ~= 0 then D.setValue(hp, (math.deg(math.atan2(y, x)) + 360) % 360) end
end

-- shortcut: crop edges are moved as a plain rectangle, a rotated crop may hit the image edge early; use the crop tool's own maths if that matters
local function crop(what, op, v)
  local l, r, t, b = D.getValue('CropLeft'), D.getValue('CropRight'), D.getValue('CropTop'), D.getValue('CropBottom')
  local w, h = r - l, b - t
  if what == 'Scale' then -- "=": 1 fills the frame; "+": tighter by v percent
    local k = op == '=' and v / math.max(w, h) or 1 - v / 100
    k = clamp(k, 0.05, 1 / math.max(w, h))
    local cx, cy = (l + r) / 2, (t + b) / 2
    w, h = w * k, h * k
    l, t = clamp(cx - w / 2, 0, 1 - w), clamp(cy - h / 2, 0, 1 - h)
  elseif what == 'PositionX' then -- "=": 0..100 across the free travel
    l = clamp(op == '=' and v / 100 * (1 - w) or l + v / 100, 0, 1 - w)
  else -- PositionY: a positive nudge moves the crop up
    t = clamp(op == '=' and v / 100 * (1 - h) or t - v / 100, 0, 1 - h)
  end
  D.setValue('CropLeft', l)
  D.setValue('CropRight', l + w)
  D.setValue('CropTop', t)
  D.setValue('CropBottom', t + h)
end

local labels = { 'none', 'red', 'yellow', 'green', 'blue', 'purple' }
local resets = { crop = 'resetCrop', spotremoval = 'resetSpotRemoval', redeye = 'resetRedeye', gradient = 'resetGradient',
  circularGradient = 'resetCircularGradient', brushing = 'resetBrushing', alldevelop = 'resetAllDevelopAdjustments' }
local selects = { all = 'selectAll', none = 'selectNone', inverse = 'selectInverse', deselectothers = 'deselectOthers',
  deselectactive = 'deselectActive', previousphoto = 'previousPhoto', nextphoto = 'nextPhoto' }

-- "pick_next" = do "pick", then go to the next photo
local function andNext(a)
  local base, n = a:gsub('_next$', '')
  return base, n > 0
end

-- commands: cmd[key](text after "=", op, value)
local cmd = {}
function cmd.WhiteBalance(a) D.setValue('WhiteBalance', a) end
function cmd.PerspectiveUpright(a) D.setValue('PerspectiveUpright', tonumber(a)) end
function cmd.selecttool(a) D.selectTool(a) end
function cmd.toggle_masking_tool() D.selectTool(D.getSelectedTool() == 'masking' and 'loupe' or 'masking') end
function cmd.select_sky() D.createNewMask('aiSelection', 'sky') end
function cmd.select_subject() D.createNewMask('aiSelection', 'subject') end
function cmd.toggle_color_range() D.createNewMask('rangeMask', 'color') end
function cmd.toggle_luminance_range() D.createNewMask('rangeMask', 'luminance') end
function cmd.toggle_depth_range() D.createNewMask('rangeMask', 'depth') end
function cmd.reset(a) D[resets[a]]() end
function cmd.select(a) LrSelection[selects[a]]() end
function cmd.selectphoto(_, _, v) if v < 0 then LrSelection.previousPhoto() else LrSelection.nextPhoto() end end
function cmd.undo() LrUndo.undo() end
function cmd.redo() LrUndo.redo() end
function cmd.togglezoom() LrApplicationView.toggleZoom() end
function cmd.develop_before_after_horiz() LrApplicationView.showView('develop_before_after_horiz') end
function cmd.switchview(a)
  if a == 'toggle_secondary' then LrApplicationView.toggleSecondaryDisplay()
  elseif a == 'toggle_secondary_fullscreen' then LrApplicationView.toggleSecondaryDisplayFullscreen()
  else LrApplicationView.showView(a) end
end
function cmd.flag(a, _, v)
  local go
  a, go = andNext(a)
  local f = LrSelection.getFlag() or 0
  if a == '' then f = clamp(f + (v < 0 and -1 or 1), -1, 1) -- dial: reject, none, pick
  elseif a == 'toggle' then f = f == 1 and 0 or 1
  else f = assert(({ pick = 1, reject = -1, unflag = 0 })[a], 'unknown flag') end
  if f == 1 then LrSelection.flagAsPick() elseif f == -1 then LrSelection.flagAsReject() else LrSelection.removeFlag() end
  if go then LrSelection.nextPhoto() end
end
function cmd.togglerating(a, _, v)
  local go
  a, go = andNext(a)
  if a == 'increase' or (a == '' and v >= 0) then LrSelection.increaseRating()
  elseif a == 'decrease' or a == '' then LrSelection.decreaseRating()
  elseif a == 'remove' then LrSelection.setRating(0)
  else
    local n = assert(tonumber(a), 'unknown rating')
    LrSelection.setRating(LrSelection.getRating() == n and 0 or n) -- the same rating again takes it off
  end
  if go then LrSelection.nextPhoto() end
end
function cmd.labels(a, _, v)
  local go
  a, go = andNext(a)
  local now = LrSelection.getColorLabel()
  if a == '' then -- dial: step through the colours
    local i = 1
    for k, name in ipairs(labels) do if name == now then i = k end end
    a = labels[clamp(i + (v < 0 and -1 or 1), 1, #labels)]
  elseif a == 'clear' then a = 'none'
  elseif a == now then a = 'none' -- the same colour again takes it off
  end
  local known = false
  for _, name in ipairs(labels) do known = known or name == a end
  assert(known, 'unknown label')
  LrSelection.setColorLabel(a)
  if go then LrSelection.nextPhoto() end
end

-- develop presets and settings copy / paste. Catalog reads and writes need a task of their own; what fails is logged.
-- shortcut: written from the SDK reference, not yet run inside Lightroom (계획.md 검증 190~192)
local copied, prevPhoto, nowPhoto, nowId = nil, nil, nil, nil
local function task(name, f)
  LrTasks.startAsyncTask(function()
    local ok, err = LrTasks.pcall(f)
    if not ok then
      log:warn(name .. ' : ' .. tostring(err))
      if out then pcall(out.send, out, '!\t' .. name .. ' : ' .. tostring(err):gsub('[\r\n\t]', ' ') .. '\n') end
    end
  end)
end
local function write(name, f) -- f(catalog, target photo) inside one undo step
  task(name, function()
    local cat = LrApplication.activeCatalog()
    local photo = assert(cat:getTargetPhoto(), 'no photo')
    cat:withWriteAccessDo(name, function() f(cat, photo) end, { timeout = 2 })
  end)
end
function cmd.presets()
  task('presets', function()
    for _, folder in ipairs(LrApplication.developPresetFolders()) do
      for _, p in ipairs(folder:getDevelopPresets()) do
        if out then pcall(out.send, out, '@function\tpreset = ' .. p:getUuid() .. '\t' .. folder:getName() .. ' / ' .. p:getName() .. '\n') end
      end
    end
  end)
end
function cmd.preset(a)
  write('Knobtile preset', function(_, photo) photo:applyDevelopPreset(assert(LrApplication.developPresetByUuid(a), 'preset not found'), _PLUGIN) end)
end
function cmd.settings(a)
  if a == 'copy' then task('Knobtile copy', function() copied = assert(LrApplication.activeCatalog():getTargetPhoto(), 'no photo'):getDevelopSettings() end)
  elseif a == 'paste' then write('Knobtile paste', function(cat) for _, p in ipairs(cat:getTargetPhotos()) do p:applyDevelopSettings(assert(copied, 'nothing copied')) end end)
  elseif a == 'previous' then write('Knobtile previous', function(_, photo) photo:applyDevelopSettings(assert(prevPhoto, 'no previous photo'):getDevelopSettings()) end)
  else error('unknown settings command') end
end
-- the photo that was the target before this one ("previous" copies from it)
local function track()
  local p = LrApplication.activeCatalog():getTargetPhoto()
  local id = p and p.localIdentifier
  if id ~= nowId then prevPhoto, nowPhoto, nowId = nowPhoto, p, id end
end

-- control lines of the plugin spec; ones we do not know are skipped
-- shortcut: written from the SDK reference, not yet run inside Lightroom
local lastModule = nil -- the module last told to the app
local function control(line)
  local key, arg = line:match('^(@%a+)\t?([^\t]*)')
  if key == '@hello' then
    if out then pcall(out.send, out, '@hello\t1\n') end
  elseif key == '@screen' then
    if arg == '?' then lastModule = nil else LrApplicationView.switchToModule(arg) end
  end
end

local function handle(line)
  local f = {}
  for s in (line .. '\t'):gmatch('([^\t]*)\t') do f[#f + 1] = s end
  local key, arg = (f[1] or ''):match('^%s*(.-)%s*=%s*(.-)%s*$')
  if not key then key, arg = f[1] or '', '' end
  local op, v, lo, hi = f[2] or '', tonumber(f[3]), tonumber(f[4]), tonumber(f[5])
  local wname, axis = key:match('^(%a+)Wheel([XY])$')
  local cropPart = key:match('^Crop(Scale)$') or key:match('^Crop(Position[XY])$')
  if op == '' and arg == 'reset' then -- "Temperature = reset"
    watched[key] = true
    D.resetToDefault(key)
  elseif cmd[key] then if op ~= '?' then cmd[key](arg, op, v or 0) end -- a question never runs a command
  elseif op ~= '+' and op ~= '=' and op ~= '?' then error('not supported')
  elseif op ~= '?' and not v then error('no value')
  elseif wname and wheels[wname] then wheel(wheels[wname], axis, op, v)
  elseif cropPart then if op ~= '?' then crop(cropPart, op, v) end
  else param(key, op, v, lo, hi) end
end

LrTasks.startAsyncTask(function()
  LrTasks.sleep(0.6) -- on a reload: let the previous run notice the new generation and close its sockets first
  -- Lightroom runs this file twice at start (init, then enable). The first run must not open the ports at all:
  -- it opened and closed them within 0.1 s and the app stayed attached to that dead socket.
  if not alive() then log:info('skip ' .. gen); return end
  while alive() do -- one pass per app connection: when the app goes away the context ends, which closes both sockets, and the next pass binds new ones
  renewOut = false
  local ok, err = LrTasks.pcall(LrFunctionContext.callWithContext, 'Knobtile', function(context)
    -- not while the context is ending: its cleanup closes the sockets and calls onClosed, and a reconnect() from there hung Lightroom (2026-11-15 13:10)
    local function again(socket) if alive() and not renewOut then socket:reconnect() end end
    out = LrSocket.bind {
      functionContext = context, plugin = _PLUGIN, port = OUT_PORT, mode = 'send',
      onConnected = function() log:info('values connected'); outOpen = true; last = {}; lastModule = nil; report(); cmd.presets() end, -- the app asks on the command socket, which may be up before this one
      onClosed = function(socket) log:info('values closed'); outOpen = false; again(socket) end,
      onError = function(socket, err) log:info('values error ' .. tostring(err)); outOpen = false; again(socket) end,
    }
    LrSocket.bind {
      functionContext = context, plugin = _PLUGIN, port = IN_PORT, mode = 'receive',
      onMessage = function(_, line)
        if type(line) ~= 'string' then return end
        if line:sub(1, 1) == '@' then LrTasks.pcall(control, line) return end
        local ok, err = LrTasks.pcall(handle, line)
        if ok then report() else
          log:warn(line .. ' : ' .. tostring(err))
          if out then pcall(out.send, out, '!\t' .. (line:gsub('\t', ' ')) .. ' : ' .. tostring(err):gsub('[\r\n\t]', ' ') .. '\n') end
        end
      end,
      -- a send socket never notices that the app went away (seen 2026-11-15: app restarted, Lightroom kept the old values
      -- connection and never accepted the new one), so when the command connection ends, start the values socket over too
      -- Never out:reconnect() for that: it blocks Lightroom's main thread for good, from this callback (4 of 4) and from the loop (1 of 1, 2026-11-15).
      -- Leaving the context closes both sockets without a hang (7 of 7 in the log, 10:55-11:09 the same day).
      onClosed = function() log:info('commands closed'); renewOut = true end,
      onError = function(socket, err) log:info('commands error ' .. tostring(err)); again(socket) end,
    }
    D.addAdjustmentChangeObserver(context, {}, function() if alive() then report() end end) -- mouse edits and photo changes
    log:info('listening on ' .. IN_PORT .. ', values on ' .. OUT_PORT)
    while alive() and not renewOut do
      LrTasks.sleep(0.25)
      pcall(report); LrTasks.pcall(track)
      local ok, m = pcall(LrApplicationView.getCurrentModuleName)
      if ok and m ~= lastModule and out and pcall(out.send, out, '@screen\t' .. m .. '\n') then lastModule = m end
    end -- also catches what no observer tells: entering Develop, a question asked too early
  end)
  out, outOpen = nil, false
  log:info('stop ' .. gen .. (ok and '' or ' : ' .. tostring(err)))
  LrTasks.sleep(0.5) -- the closed ports are free again
  end
end)
