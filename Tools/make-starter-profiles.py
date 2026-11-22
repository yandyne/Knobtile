#!/usr/bin/env python3
"""Writes each plugin's starter.json (환경설정 › 플러그인 › 시작 프로필 추가). Usage: make-starter-profiles.py
Board: Core, 3 buttons (B), Orbiter (O), two 3-dial modules (A above, C below).
Every function is checked against the plugins' own lists and the key table before a file is written."""
import glob, json, re, os

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGINS = [os.path.join(HERE, '../Sources/Engine/Resources/Plugins/system')] + sorted(d for d in glob.glob(os.path.join(HERE, '../Plugins/*')) if os.path.isdir(d))
CORE, B, O, A, C = '?-L6z', 'v:B0770001', 'v:0B170001', 'v:D1A10001', 'v:D1A10002'
A2, A3 = 'v:D1A10011', 'v:D1A10012'  # 현상: the upper dials' 2nd and 3rd layer
LAYOUT = {'v': 2, 'modules': [
    {'r': 0, 't': 25, 'u': CORE, 'x': 0, 'y': 0}, {'r': 1, 't': 8, 'u': B, 'x': 2, 'y': 0}, {'r': 2, 't': 24, 'u': O, 'x': 2, 'y': 1},
    {'r': 3, 't': 9, 'u': A, 'x': 0, 'y': 1}, {'r': 3, 't': 9, 'u': C, 'x': 0, 'y': 2}]}
LR, PS, RESOLVE, C1 = 'com.adobe.lightroom', 'com.adobe.Photoshop', 'com.blackmagic-design.DaVinciResolve', 'com.phaseone.captureone'

def key(k, *mods): return {'key': k, 'modifiers': list(mods)}
def inp(name, **kw): return dict({'input': name}, **kw)
def reset(name): return {'input': name, 'action': 'reset'}
def dispatch(t): return {'dispatch': {'type': t}}
def slot(name, **settings): return {'app': '', 'preset': '', 'settings': dict({'name': name}, **settings)}
def keys(name, left, right, sens=4, **more): return slot(name, leftTurn=left, rightTurn=right, sensitivity=sens, **more)
def lr(name, input, step, deco=None, also=None, **more):  # a develop slider: 두 번 누르면 초기화, 누른 채 돌리면 `also`
    s = dict(turn=inp(input, step=step), doublePress=inp(input.replace('= ', '= reset')) if input.split(' ')[0] in ('Temperature', 'Tint', 'Exposure') else reset(input), **more)
    if deco: s['deco'] = deco
    if also: s['pressAndTurn'] = inp(also, step=step)
    return slot(name, **s)
def dial(name, input, step, sens=None, deco=None):  # other apps' sliders: 누르면 초기화
    s = dict(turn=inp(input, step=step), press=reset(input))
    if sens: s['sensitivity'] = sens
    if deco: s['deco'] = deco
    return slot(name, **s)
def d3(mod, a, b, c): return {mod + '::dial1': a, mod + '::dial2': b, mod + '::dial3': c}
def b3(a, b, c): return {B + '::button1': a, B + '::button2': b, B + '::button3': c}

n = [0]
def profile(title, app, assignments, screen=None, **more):
    n[0] += 1
    p = {'id': '5a17e7000000000000%03d' % n[0], 'title': title, 'app': app, 'tags': [], 'layout': LAYOUT, 'lastActivated': 1000 - n[0], 'assignments': assignments}
    if screen: p['screen'] = screen
    p.update(more)
    return p

UNDO = keys('실행 취소 ↔ 다시 실행', key('z', 'command'), key('z', 'command', 'shift'))
SCROLL = dict(tiltMode=1, tiltSensitivity=3, tiltX={'scroll': 'horizontal', 'step': 20}, tiltY={'scroll': 'vertical', 'step': -20}, turnSensitivity=9)

basic = profile('기본', '', {
    **d3(A, slot('음량 · 누르면 음소거', turn=inp('system.volume', step=2), press=inp('audio_mute'), deco='volume'),
         slot('화면 밝기', turn=inp('system.brightness', step=1), sensitivity=5),
         keys('확대 ↔ 축소 · 누르면 실제 크기', key('-', 'command'), key('=', 'command'), 5, press=key('0', 'command'))),
    **d3(C, UNDO,
         keys('탭 넘기기', key('tab', 'control', 'shift'), key('tab', 'control')),
         keys('데스크탑 넘기기 · 누르면 Mission Control', key('left', 'control'), key('right', 'control'), 3, press=key('up', 'control'))),
    O: slot('스크롤', turn={'scroll': 'vertical', 'step': 20}, **SCROLL),
    **b3(slot('재생 ↔ 정지 · 두 번 누르면 다음 곡', press=inp('audio_play'), doublePress=inp('audio_next')),
         slot('화면 캡처 · 길게 누르면 캡처 도구', press=key('4', 'command', 'shift'), pressAndHold=key('5', 'command', 'shift')),
         slot('Spotlight · 길게 누르면 앱 실행 목록', press=key('space', 'command'), pressAndHold={'panel': 'list:앱 실행'})),
})

RATING = slot('별점 · 누르면 지우기', turn=inp('togglerating = ', step=1), press=inp('togglerating = 0'), sensitivity=4)
LABEL = slot('색 라벨 · 누르면 지우기', turn=inp('labels = ', step=1), press=inp('labels = clear'), sensitivity=4)
VIEW = slot('격자 ↔ 확대경 · 누르면 줌', leftTurn=inp('switchview = grid'), rightTurn=inp('switchview = loupe'), press=inp('togglezoom = 0'), doublePress=inp('switchview = compare'), sensitivity=3)
LRUNDO = slot('실행 취소 ↔ 다시 실행', leftTurn=inp('undo = 0'), rightTurn=inp('redo = 0'), sensitivity=4)
STACKS = {A: {'index': 0, 'members': [A, A2, A3], 'names': {A: '톤', A2: '질감', A3: '색'}}}
NAMES = {A: '현상 다이얼 (층 3개)'}
library = profile('라이브러리', LR, {
    # the 묶음 shares the 현상 layers: the same three dials under every layer, so the library never changes with them
    **{k: v for m in (A, A2, A3) for k, v in d3(m, RATING, LABEL, VIEW).items()},
    **d3(C, LRUNDO,
         slot('채택하고 다음 · 두 번 누르면 제외하고 다음', press=inp('flag = pick_next'), doublePress=inp('flag = reject_next'), color='#34c759'),
         slot('현상 모듈로', press=key('d'))),
    O: slot('사진 넘기기', turn=inp('selectphoto = ', step=1), turnSensitivity=5),
    **b3(slot('채택', press=inp('flag = pick'), color='#ffffff'), slot('제외', press=inp('flag = reject'), color='#ff3b30'), slot('플래그 해제', press=inp('flag = unflag'), color='#555555')),
}, screen='library', stacks=STACKS, moduleNames=NAMES)

develop = profile('현상', LR, {
    **d3(A, lr('대비', 'Contrast = ', 1, 'contrast'), lr('밝은 영역 · 누른 채 흰색 계열', 'Highlights = ', 1, 'highlight', also='Whites = '), lr('어두운 영역 · 누른 채 검정 계열', 'Shadows = ', 1, 'shadow', also='Blacks = ')),
    **d3(A2, lr('텍스처', 'Texture = ', 1), lr('부분 대비', 'Clarity = ', 1, 'clarity'), lr('디헤이즈', 'Dehaze = ', 1)),
    **d3(A3, lr('생동감', 'Vibrance = ', 1), lr('채도', 'Saturation = ', 1, 'saturation'), lr('비네팅', 'PostCropVignetteAmount = ', 1)),
    **d3(C, lr('색온도', 'Temperature = ', 100, 'temp'), lr('색조', 'Tint = ', 1, 'tint'), lr('노출', 'Exposure = ', 0.05, 'exposure')),
    O: slot('전체 색 (기울이기) · 사진 넘기기 (돌리기)', nudgeSpeedMs=15, tiltMode=2, tiltSensitivity=5, tiltX=inp('GlobalWheelX = '), tiltY=inp('GlobalWheelY = '),
            turn=inp('selectphoto = ', step=1), turnSensitivity=5),
    **b3(slot('다음 층 (톤 › 질감 › 색)', press=dispatch('STACK_NEXT:' + A)),
         slot('전/후 비교 · 두 번 누르면 자동 WB · 길게 누르면 설정 복사', press=key('\\'), doublePress=inp('WhiteBalance = Auto'), pressAndHold={'send': 'settings = copy'}),
         slot('실행 취소 · 두 번 누르면 다시 실행 · 길게 누르면 설정 붙여넣기', press=inp('undo = 0'), doublePress=inp('redo = 0'), pressAndHold={'send': 'settings = paste'})),
}, screen='develop', stacks=STACKS, moduleNames=NAMES)

photoshop = profile('Photoshop', PS, {
    **d3(A, keys('브러시 크기', key('['), key(']'), 6),
         keys('브러시 경도', key('[', 'shift'), key(']', 'shift'), 5),
         keys('확대 ↔ 축소 · 누르면 화면 맞춤', key('-', 'command'), key('=', 'command'), 5, press=key('0', 'command'), doublePress=key('1', 'command'))),
    **d3(C, UNDO,
         keys('레이어 선택 · 누르면 복제', key('[', 'alt'), key(']', 'alt'), 4, press=key('j', 'command')),
         keys('혼합 모드', key('-', 'shift'), key('=', 'shift'), 3)),
    O: slot('화면 이동 (기울이기) · 확대 (돌리기)', turn={'scroll': 'vertical', 'step': 20, 'modifiers': ['alt']}, **SCROLL),
    **b3(slot('브러시 · 두 번 누르면 지우개', press=key('b'), doublePress=key('e')),
         slot('전경색 ↔ 배경색 · 두 번 누르면 기본색', press=key('x'), doublePress=key('d')),
         slot('이동 도구 · 길게 누르면 도구 목록', press=key('v'), pressAndHold={'panel': 'list:Photoshop 도구'})),
})

JOG = dict(leftTurn=key('left'), rightTurn=key('right'), turnSensitivity=6)
CLIPS = keys('클립 넘기기', key('up'), key('down'), 3)
edit = profile('편집', RESOLVE, {
    **d3(A, CLIPS, keys('타임라인 확대 ↔ 축소', key('-', 'command'), key('=', 'command'), 5), UNDO),
    **d3(C, keys('뒤로 ↔ 앞으로 재생 · 누르면 정지', key('j'), key('l'), 3, press=key('k')),
         slot('컬러 페이지로', press=inp('pageColor')),
         slot('프로젝트 저장', press=key('s', 'command'))),
    O: slot('프레임 조그', **JOG),
    **b3(slot('재생 ↔ 정지', press=key('space')), slot('시작점 · 두 번 누르면 끝점', press=key('i'), doublePress=key('o')), slot('마커', press=key('m'))),
})
color = profile('컬러', RESOLVE, {
    **d3(A, dial('게인 (Slope)', 'slopeMaster', 0.01, 4), dial('오프셋', 'offsetMaster', 0.005, deco='exposure'), dial('감마 (Power)', 'powerMaster', 0.01)),
    **d3(C, dial('채도', 'saturation', 0.01, deco='saturation'), slot('노드 선택', turn=inp('cdlNode', step=1), sensitivity=4), CLIPS),
    O: slot('프레임 조그', **JOG),
    **b3(slot('노드 켜기 ↔ 끄기', press=inp('toggleNode')),
         slot('스틸 저장 · 길게 누르면 CDL 초기화', press=inp('grabStill'), pressAndHold=inp('resetCDL')),
         slot('재생 ↔ 정지', press=key('space'))),
}, screen='color')

captureone = profile('Capture One', C1, {
    **d3(A, dial('대비', 'contrast', 1, 5, 'contrast'), dial('하이라이트', 'highlightRecovery', 1, 5, 'highlight'), dial('섀도', 'shadowRecovery', 1, 5, 'shadow')),
    **d3(C, slot('색온도', turn=inp('temperature', step=25), press=inp('resetWhiteBalance'), sensitivity=5, deco='temp'), dial('색조', 'tint', 0.1, 5, 'tint'), dial('노출', 'exposure', 0.03, 5, 'exposure')),
    O: slot('사진 넘기기', leftTurn=key('left', 'command'), rightTurn=key('right', 'command'), turnSensitivity=5),
    **b3(slot('별점 올리기', press=inp('increaseRating')), slot('별점 내리기', press=inp('decreaseRating')), slot('보정 복사 · 길게 누르면 붙여넣기', press=inp('copyAdjustments'), pressAndHold=inp('applyAdjustments'))),
})

def item(label, **d): return dict(d, label=label, fn=label)
PANELS = [
    {'name': '앱 실행', 'items': [item('Lightroom Classic', open='com.adobe.LightroomClassicCC7'), item('Photoshop', open='com.adobe.Photoshop'),
                               item('DaVinci Resolve', open=RESOLVE), item('Capture One', open='com.captureone.captureone16')]},
    {'name': 'Photoshop 도구', 'items': [item(l, **key(k)) for l, k in [('이동', 'v'), ('브러시', 'b'), ('지우개', 'e'), ('복제 도장', 's'), ('스팟 복구', 'j'),
                                                                     ('올가미', 'l'), ('자르기', 'c'), ('그레이디언트', 'g'), ('닷지 · 번', 'o'), ('문자', 't')]]},
]
def core(page, prof): return {'app': '', 'preset': '', 'settings': {'holdDelay': 800, 'press': dispatch(page + '_SCREEN'), 'doublePress': dispatch(prof + '_PROFILE'), 'pressAndHold': dispatch('PROFILE_SWITCHER')}}
out = {'profiles': [basic, library, develop, photoshop, edit, color, captureone],
       'root': {'assignments': {'::button1': core('PREVIOUS', 'PREVIOUS'), '::button2': core('NEXT', 'NEXT')}, 'panels': PANELS}}

# ---- self-check: every function must be one the engine can run (mirrors ActionDecoder.decode and Engine.settingKinds) ----
def load(d, f): return json.load(open(os.path.join(d, f))) if os.path.exists(os.path.join(d, f)) else {}
dirs = {load(d, 'plugin.json')['id']: d for d in PLUGINS}
apps = {i: load(d, 'functions.json') for i, d in dirs.items()}
out['profiles'] = [p for p in out['profiles'] if p['app'] in dirs]  # the public repository carries fewer plugins than the author's
# The profiles below were written with the old Lightroom names ("Exposure = ", "undo = 0"); the plugin's list names them plainly.
def rename(v, app):
    if isinstance(v, dict):
        i = v.get('input')
        if app == LR and isinstance(i, str) and i not in inputs(LR):
            v['input'] = next((i[:-len(e)] for e in (' = ', ' = 0') if i.endswith(e) and i[:-len(e)] in inputs(LR)), i)
        for x in v.values(): rename(x, app)
def inputs(app):
    i = apps[app].get('inputs', [])
    return {(x['name'] if isinstance(x, dict) else x): (x if isinstance(x, dict) else {}) for x in (i if isinstance(i, list) else [dict(v, name=k) if isinstance(v, dict) else k for k, v in i.items()])}
for p in out['profiles']: rename(p['assignments'], p['app'])
KEYS = set(re.findall(r'"([^"]+)": \d+', open(os.path.join(HERE, '../Sources/Engine/System.swift')).read().split('static let keyCodes')[1].split('static let modifierFlags')[0]))
assert {'[', ']', '-', '=', '\\\\', 'tab'} <= KEYS, KEYS  # "\\" is how the Swift source spells the backslash key
KEYS.add('\\')
MODS = {'command', 'shift', 'alt', 'control'}
KINDS = {'button': 'press pressOff doublePress pressAndHold pressDown pressUp', 'dial': 'turn pressAndTurn press doublePress doubleTap leftTurn rightTurn pressAndLeftTurn pressAndRightTurn pressDown pressUp',
         'orbiter': 'turn leftTurn rightTurn tiltX tiltY'}
PLAIN = {'name', 'deco', 'color', 'sensitivity', 'turnSensitivity', 'tiltSensitivity', 'tiltMode', 'nudgeSpeedMs', 'holdDelay'}
lists = {p['name'] for p in PANELS}
def check(where, d, app, nudge):
    if 'key' in d: assert d['key'] in KEYS and set(d['modifiers']) <= MODS, (where, d)
    elif 'scroll' in d: assert nudge, where
    elif 'panel' in d: assert d['panel'][5:] in lists and not nudge, (where, d)
    elif 'send' in d or 'open' in d: assert not nudge, where
    elif 'dispatch' in d: assert not nudge, where
    else:
        i = d['input']; own = inputs(app) if app in apps else {}; known = own.get(i, inputs('').get(i))
        assert known is not None, (where, 'unknown input', i)
        if d.get('action') == 'reset': assert 'reset' in known, (where, 'no reset value', i)
        if nudge: assert 'step' in d or 'step' in known, (where, 'no step', i)
for p in out['profiles']:
    types = {m['u']: {8: 'button', 9: 'dial', 24: 'orbiter', 25: 'button'}[m['t']] for m in LAYOUT['modules']}
    for s in p.get('stacks', {}).values():
        for m in s['members']: types[m] = types[s['members'][0]]
    for k, v in p['assignments'].items():
        kind = types[k.split('::')[0]]
        for name, d in v['settings'].items():
            if name in PLAIN: continue
            assert name in KINDS[kind].split(), (p['title'], k, name)
            check((p['title'], k, name), d, p['app'], name in ('turn', 'pressAndTurn', 'tiltX', 'tiltY'))
    assert len(p['assignments']) >= 9, p['title']
for l in PANELS:
    for it in l['items']: check((l['name'], it['label']), it, '', False)
# ---- English: the names above are Korean; starter.json carries these, starter.ko.json the originals ----
EN = {
 '기본': 'Basics', '라이브러리': 'Library', '현상': 'Develop', '편집': 'Edit', '컬러': 'Color',
 '앱 실행': 'Apps', 'Photoshop 도구': 'Photoshop Tools',
 '톤': 'Tone', '질감': 'Texture', '색': 'Color', '현상 다이얼 (층 3개)': 'Develop dials (3 layers)',
 '이동': 'Move', '브러시': 'Brush', '지우개': 'Eraser', '복제 도장': 'Clone Stamp', '스팟 복구': 'Spot Healing', '올가미': 'Lasso',
 '자르기': 'Crop', '그레이디언트': 'Gradient', '닷지 · 번': 'Dodge · Burn', '문자': 'Type',
 'RAW 색온도': 'RAW temperature', 'RAW 색조': 'RAW tint',
 'Spotlight · 길게 누르면 앱 실행 목록': 'Spotlight · hold for the Apps list',
 '감마 (Power)': 'Gamma (Power)', '게인 (Slope)': 'Gain (Slope)', '오프셋': 'Offset',
 '격자 ↔ 확대경 · 누르면 줌': 'Grid ↔ Loupe · press to zoom',
 '그레인 켜기 ↔ 끄기': 'Grain on ↔ off', '헐레이션 켜기 ↔ 끄기': 'Halation on ↔ off',
 '노드 선택': 'Select node', '노드 켜기 ↔ 끄기': 'Node on ↔ off',
 '노출': 'Exposure', '대비': 'Contrast', '하이라이트': 'Highlights', '섀도': 'Shadows', '색온도': 'Temperature', '색조': 'Tint',
 '생동감': 'Vibrance', '채도': 'Saturation', '텍스처': 'Texture', '부분 대비': 'Clarity', '디헤이즈': 'Dehaze', '비네팅': 'Vignette',
 '다음 층 (톤 › 질감 › 색)': 'Next layer (Tone › Texture › Color)',
 '데스크탑 넘기기 · 누르면 Mission Control': 'Switch desktops · press for Mission Control',
 '뒤로 ↔ 앞으로 재생 · 누르면 정지': 'Play backward ↔ forward · press to stop',
 '레이어 선택 · 누르면 복제': 'Select layer · press to duplicate',
 '마커': 'Marker',
 '밝은 영역 · 누른 채 흰색 계열': 'Highlights · press and turn for Whites',
 '어두운 영역 · 누른 채 검정 계열': 'Shadows · press and turn for Blacks',
 '별점 · 누르면 지우기': 'Rating · press to clear', '별점 내리기': 'Rating down', '별점 올리기': 'Rating up',
 '색 라벨 · 누르면 지우기': 'Color label · press to clear',
 '보정 복사 · 길게 누르면 붙여넣기': 'Copy adjustments · hold to apply',
 '브러시 · 두 번 누르면 지우개': 'Brush · double press for Eraser', '브러시 경도': 'Brush hardness', '브러시 크기': 'Brush size',
 '사진 넘기기': 'Previous ↔ next photo', '스크롤': 'Scroll',
 '스틸 저장 · 길게 누르면 CDL 초기화': 'Grab still · hold to reset CDL',
 '시작점 · 두 번 누르면 끝점': 'Mark in · double press for out',
 '실행 취소 · 두 번 누르면 다시 실행 · 길게 누르면 설정 붙여넣기': 'Undo · double press to redo · hold to paste settings',
 '실행 취소 ↔ 다시 실행': 'Undo ↔ redo',
 '음량 · 누르면 음소거': 'Volume · press to mute',
 '이동 도구 · 길게 누르면 도구 목록': 'Move tool · hold for the tool list',
 '인화 노출': 'Print exposure', '인화지': 'Paper', '필름 노출': 'Film exposure', '필름 종류': 'Film stock', '자동 노출': 'Auto exposure',
 '재생 ↔ 정지': 'Play ↔ pause', '재생 ↔ 정지 · 두 번 누르면 다음 곡': 'Play ↔ pause · double press for next track',
 '전/후 비교 · 두 번 누르면 자동 WB · 길게 누르면 설정 복사': 'Before/after · double press for auto WB · hold to copy settings',
 '전경색 ↔ 배경색 · 두 번 누르면 기본색': 'Swap foreground ↔ background · double press for default colors',
 '전체 색 (기울이기) · 사진 넘기기 (돌리기)': 'Global color (tilt) · photos (turn)',
 '제외': 'Reject', '채택': 'Pick', '플래그 해제': 'Unflag',
 '채택하고 다음 · 두 번 누르면 제외하고 다음': 'Pick and next · double press to reject and next',
 '컬러 페이지로': 'To the Color page', '현상 모듈로': 'To Develop',
 '클립 넘기기': 'Previous ↔ next clip', '타임라인 확대 ↔ 축소': 'Timeline zoom out ↔ in', '탭 넘기기': 'Switch tabs',
 '프레임 조그': 'Frame jog', '프로젝트 저장': 'Save project', '혼합 모드': 'Blend mode', '화면 밝기': 'Display brightness',
 '화면 이동 (기울이기) · 확대 (돌리기)': 'Pan (tilt) · zoom (turn)',
 '화면 캡처 · 길게 누르면 캡처 도구': 'Screenshot · hold for the capture tool',
 '확대 ↔ 축소 · 누르면 실제 크기': 'Zoom out ↔ in · press for actual size',
 '확대 ↔ 축소 · 누르면 화면 맞춤': 'Zoom out ↔ in · press to fit',
}
def en(o):  # every Korean string must have its English: a new name without one stops the script
    if isinstance(o, dict): return {k: en(v) for k, v in o.items()}
    if isinstance(o, list): return [en(v) for v in o]
    if isinstance(o, str) and re.search('[가-힣]', o): return 'list:' + EN[o[5:]] if o.startswith('list:') else EN[o]
    return o

# One file per plugin: its profiles, and the 패널 목록 they open. The Core buttons (root) keep the app's own defaults.
for app, d in dirs.items():
    mine = [p for p in out['profiles'] if p['app'] == app]
    used = {x['panel'][5:] for p in mine for a in p['assignments'].values() for x in a['settings'].values() if isinstance(x, dict) and 'panel' in x}
    if not mine: continue
    f = {'profiles': mine}
    if used: f['panels'] = [l for l in PANELS if l['name'] in used]
    json.dump(f, open(os.path.join(d, 'starter.ko.json'), 'w'), ensure_ascii=False, indent=1, sort_keys=True)
    json.dump(en(f), open(os.path.join(d, 'starter.json'), 'w'), ensure_ascii=False, indent=1, sort_keys=True) # the one every language falls back to
    print(os.path.basename(d), len(mine), 'profiles', sum(len(p['assignments']) for p in mine), 'controls', sorted(used))
