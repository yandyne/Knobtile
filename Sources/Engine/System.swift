import Foundation
import AppKit
import Carbon.HIToolbox
import CoreAudio
import AudioToolbox

/// Host-side effects: keystrokes, mouse, media keys, volume. Replaces robotjs/roadrunner.
/// All keystrokes are synthesized here, including ones the service used to run as USB HID on the Core.
enum System {
    // robotjs key names → macOS virtual key codes
    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "backspace": 51, "escape": 53,
        "numpad_decimal": 65, "numpad_multiply": 67, "numpad_plus": 69, "numpad_clear": 71, "numpad_divide": 75, "numpad_enter": 76,
        "numpad_minus": 78, "numpad_equals": 81, "numpad_0": 82, "numpad_1": 83, "numpad_2": 84, "numpad_3": 85, "numpad_4": 86,
        "numpad_5": 87, "numpad_6": 88, "numpad_7": 89, "numpad_8": 91, "numpad_9": 92,
        "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103, "f13": 105, "f14": 107, "f10": 109, "f12": 111,
        "f15": 113, "home": 115, "pageup": 116, "delete": 117, "f4": 118, "end": 119, "f2": 120, "pagedown": 121, "f1": 122,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "command": 55, "shift": 56, "capslock": 57, "alt": 58, "control": 59,
    ]
    static let modifierFlags: [String: CGEventFlags] = [
        "command": .maskCommand, "meta": .maskCommand, "win": .maskCommand, "windows": .maskCommand,
        "alt": .maskAlternate, "option": .maskAlternate, "control": .maskControl, "ctrl": .maskControl,
        "shift": .maskShift, "right_shift": .maskShift,
    ]

    static func flags(_ mods: [String]) -> CGEventFlags { mods.reduce([]) { $0.union(modifierFlags[$1] ?? []) } }

    /// Rehearsal (ScenarioTests): when set, nothing here touches the Mac or an app; each action is described to it instead.
    nonisolated(unsafe) static var dry: ((String) -> Void)?
    nonisolated(unsafe) static var dryFront: String? // the app the rehearsal pretends is in front
    /// 디자인 모드: every function runs inside Knobtile (lists, profiles, pointers) but nothing reaches the Mac or an app.
    nonisolated(unsafe) static var design = false
    /// Where an outgoing action goes instead of the Mac: the rehearsal's log, or nowhere in design mode.
    static var sink: ((String) -> Void)? { dry ?? (design ? { _ in } : nil) }
    static var frontBundle: String? { dry != nil ? dryFront : NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    static func keyTap(_ key: String, _ mods: [String]) {
        if let dry = sink { dry("key " + (mods + [key]).joined(separator: "+")); return }
        var f = flags(mods)
        guard let code = keyCodes[key.lowercased()] else { NSLog("unknown key %@", key); return }
        // a real arrow key carries fn + keypad; without them macOS ignores ⌃←/⌃→/⌃↑ (Spaces, Mission Control)
        if (123...126).contains(code) { f.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        let post = {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                e?.flags = f
                e?.post(tap: .cghidEventTap)
            }
        }
        // a Korean (or other composing) input source eats the key: "d" arrives as ㅇ. With ⌘ too: Resolve (Qt) matches
        // shortcuts by character, so ⌘D under 두벌식 is ⌘ㅇ and does nothing. Already ASCII = posted at once.
        DispatchQueue.main.async { inASCII(post) }
    }

    private static var composingSource: TISInputSource? // the user's input source while we hold the ASCII one
    private static var restoreSource: DispatchWorkItem?
    private static var waiting = 0
    private static var asciiReady = DispatchTime.now() // keys wait for the switch only until then; later ones go at once
    /// Main thread. Runs `post` under the ASCII keyboard layout and puts the user's input source back once the keys stop.
    private static func inASCII(_ post: @escaping () -> Void) {
        if composingSource == nil, let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue(), !CFEqual(cur, ascii) {
            composingSource = cur
            TISSelectInputSource(ascii)
            asciiReady = .now() + 0.05
        }
        guard let back = composingSource else { post(); return }
        restoreSource?.cancel()
        // shortcut: fixed 50 ms for the switch to land and 1 s before switching back, both untried on the device; tune if the first key still composes or the menu-bar flag flickers
        // while held (keys less than 1 s apart) the layout stays ASCII and each key goes at once; only the key that switched it waits
        if DispatchTime.now() >= asciiReady, waiting == 0 { post() }
        else { waiting += 1; DispatchQueue.main.asyncAfter(deadline: asciiReady) { waiting -= 1; post() } } // behind a waiting key, never before it
        let w = DispatchWorkItem { TISSelectInputSource(back); composingSource = nil }
        restoreSource = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    // MARK: 실행 (앱 열기, 단축어), 글자 입력

    /// Launches the app or brings it to the front; already frontmost = nothing. false = no such app on this Mac.
    @discardableResult static func open(_ bundle: String) -> Bool {
        guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return false }
        if let dry = sink { dry("open " + bundle); return true }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundle { NSWorkspace.shared.openApplication(at: u, configuration: .init()) }
        return true
    }
    private static var running: Set<String> = [] // main thread only
    /// Runs a Shortcuts shortcut by name in the background (the app in front stays). A press while it still runs is ignored.
    static func shortcut(_ name: String, failed: @escaping (String) -> Void) {
        if let dry = sink { dry("shortcut " + name); return }
        guard running.insert(name).inserted else { return }
        let p = Process(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = ["run", name]
        p.standardError = err; p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { p in
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { running.remove(name); if p.terminationStatus != 0 { failed(L("단축어 실패: \(name) \(msg)")) } }
        }
        do { try p.run() } catch { running.remove(name); failed(L("단축어 실패: \(name) \(error.localizedDescription)")) }
    }
    /// Names of the shortcuts in the Shortcuts app now (`shortcuts list`). Blocks for a moment: call off the main thread.
    static func shortcuts() -> [String] {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = ["list"]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return s.split(separator: "\n").map(String.init)
    }
    /// 글자 입력: the characters themselves, not key presses, so Korean goes in whatever the input source is.
    /// shortcut: a line break is sent as a character; apps that want the Return key for it need a 키 입력 step.
    static func type(_ text: String) {
        if let dry = sink { dry("type " + text); return }
        for chunk in chunks(text) {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                e?.flags = []
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e?.post(tap: .cghidEventTap)
            }
        }
    }
    /// One key event carries at most 20 UTF-16 units; a character is never split across two events.
    static func chunks(_ text: String) -> [[UniChar]] {
        var out: [[UniChar]] = [[]]
        for ch in text { let u = Array(String(ch).utf16); if out[out.count - 1].count + u.count > 20 { out.append([]) }; out[out.count - 1] += u }
        return out.filter { !$0.isEmpty }
    }

    // NX_KEYTYPE_* for IOKit system-defined events
    static let mediaKeys: [String: Int32] = [
        "audio_vol_up": 0, "audio_vol_down": 1, "brightness_up": 2, "brightness_down": 3, "audio_mute": 7,
        "audio_play": 16, "audio_next": 17, "audio_prev": 18, "audio_stop": 16, "audio_pause": 16,
    ]
    static func mediaTap(_ name: String) {
        if let dry = sink { dry("media " + name); return }
        guard let k = mediaKeys[name] else { NSLog("unknown media key %@", name); return }
        for down in [true, false] {
            let data1 = Int(k) << 16 | (down ? 0xA : 0xB) << 8
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: down ? [] : [], timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    static func click(_ button: String, double: Bool) {
        if let dry = sink { dry("click " + button); return }
        let p = NSEvent.mouseLocation
        let loc = CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
        let (down, up, b): (CGEventType, CGEventType, CGMouseButton) = button == "right" ? (.rightMouseDown, .rightMouseUp, .right)
            : button == "middle" ? (.otherMouseDown, .otherMouseUp, .center) : (.leftMouseDown, .leftMouseUp, .left)
        for n in 1...(double ? 2 : 1) {
            for t in [down, up] {
                let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: loc, mouseButton: b)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                e?.post(tap: .cghidEventTap)
            }
        }
    }

    static func scroll(x: Int, y: Int, mods: [String] = []) {
        if let dry = sink { dry("scroll \(x),\(y) " + mods.joined(separator: "+")); return }
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(y), wheel2: Int32(x), wheel3: 0)
        e?.flags = flags(mods)
        e?.post(tap: .cghidEventTap)
    }

    static func moveCursor(dx: Int, dy: Int) {
        if let dry = sink { dry("cursor \(dx),\(dy)"); return }
        let p = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: p.x + CGFloat(dx), y: h - p.y + CGFloat(dy)), mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    // MARK: Volume (default output device)

    static func volume() -> Float? {
        var dev = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr else { return nil }
        var v: Float = 0; size = UInt32(MemoryLayout<Float>.size)
        a = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
    }
    static func setVolume(percent: Double) {
        if let dry = sink { dry("volume \(Int(percent))"); return }
        var dev = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr else { return }
        var v = Float(min(100, max(0, percent)) / 100)
        a = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float>.size), &v)
    }
    static func adjustVolume(by percent: Double) { if let v = volume() { setVolume(percent: Double(v) * 100 + percent) } }
    /// shortcut: brightness has no public set API, so nudges use the brightness keys and absolute set is ignored
    static func adjustBrightness(by steps: Double) { for _ in 0..<Int(abs(steps).rounded()) { mediaTap(steps > 0 ? "brightness_up" : "brightness_down") } }
}
