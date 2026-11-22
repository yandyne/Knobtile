# Knobtile plugin spec v1

Status: implemented (2026-11-22). The plugins in this repository (Lightroom, System) use nothing but this spec.
You should be able to write a plugin from this document alone. Where you get stuck, the document is at fault. ([한국어](plugin-spec-v1.ko.md))

## 1. What a plugin does

Knobtile handles the hardware (buttons, dials, sliders, the Orbiter) and the profiles.
A plugin offers **functions** to connect to those controls.

There are three levels. Build only as much as you need.

| Level | Files | Program | What you get |
|---|---|---|---|
| 1 Shortcuts | `plugin.json`, `keys.json` | none | buttons and dials press shortcuts |
| 2 The app opens a port | + `functions.json` | a plug-in inside the app listens on a TCP port | change values, show values, follow the app's screen |
| 3 Helper | + `functions.json`, a helper executable | Knobtile starts the helper | same as 2, for apps that cannot open a port (AppleScript and the like) |

## 2. Install

One folder is one plugin. Knobtile reads this place when it starts (restart Knobtile after adding one), or use Settings › Plugins › Add… in the app.
A plugin here replaces a built-in one with the same `id`.

```
~/Library/Application Support/Knobtile/Plugins/<any name>/
    plugin.json        required
    functions.json     when it has functions
    keys.json          when it has shortcuts
    starter.json       optional starter profiles: a profile file exported from Knobtile, as is. Settings › Plugins › Add Starter Profiles adds them. `starter.ko.json` (a language code) is used instead where Knobtile runs in that language
    (helper)           level 3
```

## 3. plugin.json

```json
{
  "spec": 1,
  "id": "com.example.editor",
  "name": "Example Editor",
  "version": "1.0",
  "apps": ["com.example.editor"],
  "connect": { "type": "tcp", "port": 50200 },
  "screens": [
    { "key": "edit",  "name": "Edit",  "recommended": ["Tone.Exposure", "Tone.Contrast"] },
    { "key": "color", "name": "Color" }
  ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `spec` | yes | version of this document, now `1` |
| `id` | yes | the plugin's unique name. It is saved in profiles, so never change it. Reverse-domain form is recommended |
| `name` | yes | the name shown to the user |
| `version` | no | the plugin's own version, for display |
| `apps` | yes | bundle ids of the apps this plugin controls. When one comes to the front, Knobtile switches to its profile. An empty list means functions for every app |
| `connect` | no | absent = level 1. See section 4 |
| `screens` | no | the app's own screens (modules, pages). A profile can be tied to one. `recommended` lists the `label`s to offer first on that screen |
| `recommended` | no | `label`s to offer first in a profile without a screen, or on a screen without its own list |

Unknown fields are ignored. A plugin must likewise ignore lines from Knobtile that it does not know.

One plugin is one "app" in Knobtile. A profile uses the functions of one plugin. Shortcuts (`keys.json`) of any plugin can be picked in any profile.
Several plugins may control the same app, as long as their `id`s differ.

## 4. connect

**TCP** (the app's side listens on a port of `127.0.0.1`; Knobtile connects.)

```json
{ "type": "tcp", "port": 50200 }
{ "type": "tcp", "port": 50200, "valuesPort": 50201 }
```

`valuesPort` is for apps that cannot send and receive on one socket (the Lightroom SDK).
With it, Knobtile only sends on `port` and only receives on `valuesPort`.

**Helper** (Knobtile starts a program, writes to its standard input and reads its standard output.)

```json
{ "type": "run", "command": ["./helper.py"] }
```

- The working directory is the plugin folder. Any language works. The first item of `command` is an absolute path or relative to the plugin folder, and must be executable.
- It is started when first needed: when a profile of that plugin becomes active, when one of its `apps` comes to the front, or when there is a line to send.
- When Knobtile quits, standard input closes. The helper must exit then.
- A helper that died is started again: after 5 seconds while a profile of that plugin is active, otherwise with the next line to send. Its standard error goes to Knobtile's log.
- Keep reading standard input. A helper that stays alive without reading can stall Knobtile.
- Flush every line you print.

## 5. functions.json

```json
{
  "inputs": [
    { "name": "exposure", "label": "Tone.Exposure", "step": 0.05, "range": [-5, 5], "reset": 0, "screens": ["edit"] },
    { "name": "profile",  "label": "Tone.Profile", "options": ["Neutral", "Vivid"] },
    { "name": "undo",     "label": "Edit.Undo" }
  ]
}
```

| Field | Meaning |
|---|---|
| `name` | the function's name as the plugin receives it. Saved in profiles, so never change it. No tabs or newlines |
| `label` | the name shown to the user. A dot makes a group: `"Group.Name"` |
| `step` | change per dial tick |
| `stepMin` | smaller changes are collected before they are sent |
| `range` | `[min, max]`. With it, the function has a value: it can go on a slider and its value is shown |
| `reset` | the default value. With it, "reset" can be connected |
| `options` | names of the values to choose from |
| `screens` | `key`s of the screens where the function works. Absent = everywhere |

**You do not need presets.** Knobtile builds the default connections from `inputs`:

- with `range`: dial = turn changes by `step`, press-and-turn by `step` × 10, press resets (when there is a `reset`). Slider = the whole range.
- without `range`: button = press runs it. With `options`, one button per value.
- per kind: when a dial preset in `presets` uses a function, no default dial connection is made for it (the same for sliders and buttons).

Write `presets` only where you want something else (optional):

```json
{ "presets": { "dial": [
  { "name": "exposure-fine", "label": "Tone.Exposure (fine)",
    "turn": { "input": "exposure", "step": 0.01 },
    "press": { "input": "exposure", "action": "reset" } } ] } }
```

Kinds are `button`, `dial`, `slider`, `orbiter`. The gesture names:

- button: `press`, `doublePress`, `pressAndHold`, `pressDown`, `pressUp`
- dial: `turn`, `pressAndTurn`, `press`, `doublePress`, `leftTurn`, `rightTurn`, `pose`
- slider: `pose`
- orbiter: `turn`, `leftTurn`, `rightTurn`, `tiltX`, `tiltY`

A gesture's value is `{ "input": name, "step": number, "action": "reset" | "increment" | "decrement" | "apply", "invert": boolean }`.

## 6. keys.json

```json
[
  { "id": "ex.undo", "label": "Edit.Undo", "key": "z", "modifiers": ["command"], "opposite": "ex.redo" },
  { "id": "ex.redo", "label": "Edit.Redo", "key": "z", "modifiers": ["command", "shift"], "opposite": "ex.undo" }
]
```

- `id` must be unique across all plugins. Use a prefix of your own (`ex.`).
- `modifiers`: `command`, `shift`, `alt`, `control`.
- With `opposite`, the two become the left/right pair when connected to a dial.
- The user can change a key inside Knobtile. The change is saved on the user's side; this file is not touched.

## 7. Line format (the same for TCP and helpers)

UTF-8, one message per line, lines end with `\n`, fields are separated by tabs (⇥). Lines starting with `@` are control lines, the rest are functions.

### Knobtile → plugin

| Line | Meaning |
|---|---|
| `@hello` ⇥ `1` | once, right after connecting. The number is the highest spec version Knobtile knows |
| `name` ⇥ `+` ⇥ `amount` [⇥ `min` ⇥ `max`] | change the value by `amount` (negative = down) |
| `name` ⇥ `=` ⇥ `value` [⇥ `min` ⇥ `max`] | set the value. With `options`, the option's name |
| `name` ⇥ `?` ⇥ (empty) [⇥ `min` ⇥ `max`] | report the current value. A plugin without values ignores it |
| `name` | run it (a function without a value) |
| `@screen` ⇥ `key` | switch the app to this screen |
| `@screen` ⇥ `?` | report the current screen. Sent every second while the plugin has `screens` and its app is frontmost. A plugin that reports changes by itself may ignore it |

`min` and `max` are the range of this connection: the user's own if they set one, otherwise `range` from `functions.json`. They are not sent for functions without `range`. Clamp the value to them.

### Plugin → Knobtile

| Line | Meaning |
|---|---|
| `@hello` ⇥ `1` | the answer to `@hello`: the spec version the plugin uses (not above the number Knobtile sent) |
| `name` ⇥ `value` [⇥ `min` ⇥ `max`] | the current value. The answer to `?`, and also sent unasked when the value changes in the app. `min` and `max` only when the range differs this once |
| `@screen` ⇥ `key` | the app is on this screen now. Send on every change |
| `@function` ⇥ `line` ⇥ `label` | a function that exists only at run time (a preset the user made, say). When the user connects it to a button, Knobtile sends `line` back as is. No tabs in `line` |
| `@key` ⇥ `key` ⇥ `modifier,modifier` | press this key for me. Pressed only while one of `apps` is frontmost |
| `!` ⇥ `text` | the last line could not be done. Goes to the log |

- Values are real values, never the hardware's 0–255. Numbers use `.` as the decimal point.
- Answers are optional. Knobtile never waits for one. Without values, the map simply shows none.
- If no line at all arrives within 3 seconds after `@hello`, Knobtile drops the connection (ends the helper) and tries again 5 seconds later. So always answer `@hello`.
- With `valuesPort`, Knobtile sends `@hello` only once both ports are connected.

## 8. Versions and compatibility

- `spec` is an integer. Knobtile accepts every `spec` up to its own.
- Within one `spec`, fields and lines are only added. Changing or removing a meaning raises `spec`.
- Both sides ignore fields and `@` lines they do not know.

## 9. The smallest example (level 3, helper)

`plugin.json`

```json
{ "spec": 1, "id": "com.example.counter", "name": "Counter", "apps": [],
  "connect": { "type": "run", "command": ["./helper.py"] } }
```

`functions.json`

```json
{ "inputs": [ { "name": "count", "label": "Demo.Count", "step": 1, "range": [0, 100], "reset": 50 } ] }
```

`helper.py`

```python
#!/usr/bin/env python3
import sys
v = 50.0
for line in sys.stdin:
    f = line.rstrip("\n").split("\t")
    if f[0] == "@hello": print("@hello\t1", flush=True)
    elif f[0] == "count":
        if len(f) > 2 and f[1] == "+": v += float(f[2])
        elif len(f) > 2 and f[1] == "=": v = float(f[2])
        v = max(0, min(100, v))
        print(f"count\t{v}", flush=True)
```

This example is in `Docs/examples/counter/`, and an automatic test (`PluginTests.testExamplePluginEndToEnd`) installs that very folder and runs it.
One dial tick out and its value back took about 3 ms (an M-series Mac, 2026-11-22).

A larger example is `lightroom` in the repository's `Plugins/` folder (TCP, with `LightroomPlugin/`). Only `system` is inside the app (`Sources/Engine/Resources/Plugins/system`); any other is installed by copying its folder into `~/Library/Application Support/Knobtile/Plugins/`.

## 10. Decided (2026-11-22)

1. Several plugins for one app: allowed. Each is registered on its own as long as the `id`s differ.
2. `@key`: included. Pressed only while an app in the plugin's `apps` is frontmost. A plugin with empty `apps` cannot use it.
3. Translated names: not in v1. There is only the one `label`.
