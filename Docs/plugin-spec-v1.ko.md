# Knobtile 플러그인 규격 v1

상태: 2026-11-22 구현됨. Knobtile 안에 든 플러그인(Lightroom, System)도 이 규격만 쓴다.
이 문서만 읽고 플러그인을 만들 수 있어야 한다. 막히는 곳이 있으면 문서의 결함이다.

## 1. 플러그인이 하는 일

Knobtile 본체는 하드웨어(버튼, 다이얼, 슬라이더, 오비터)의 이벤트와 프로필을 관리한다.
플러그인은 그 이벤트에 연결할 **기능**을 제공한다.

플러그인은 세 수준이 있고, 필요한 만큼만 만든다.

| 수준 | 넣는 파일 | 프로그램 | 할 수 있는 것 |
|---|---|---|---|
| 1 단축키 | `plugin.json`, `keys.json` | 없음 | 버튼·다이얼로 단축키 실행 |
| 2 앱이 포트를 연다 | + `functions.json` | 앱 안의 플러그인이 TCP 포트를 연다 | 값 올리고 내리기, 값 표시, 화면 알림 |
| 3 도우미 | + `functions.json`, 도우미 실행 파일 | Knobtile이 도우미를 띄운다 | 2와 같다. 포트를 열 수 없는 앱용 (AppleScript 등) |

## 2. 설치

폴더 하나가 플러그인 하나다. 여기에 넣으면 Knobtile이 시작할 때 읽는다 (넣은 뒤 Knobtile을 다시 켠다).
Knobtile 안에 든 플러그인과 `id`가 같으면 여기 넣은 것이 대신 쓰인다.

```
~/Library/Application Support/Knobtile/Plugins/<아무 이름>/
    plugin.json        필수
    functions.json     기능이 있을 때
    keys.json          단축키가 있을 때
    starter.json       시작 프로필이 있을 때 (Knobtile에서 내보낸 프로필 파일 그대로. 환경설정 › 플러그인의 "시작 프로필 추가"로 들어간다. `starter.ko.json`처럼 언어 코드를 붙인 파일이 있으면 그 언어에서는 그것을 쓴다)
    (도우미 실행 파일)   수준 3일 때
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

| 필드 | 필수 | 뜻 |
|---|---|---|
| `spec` | 예 | 이 문서의 버전. 지금은 `1` |
| `id` | 예 | 플러그인의 고유 이름. 프로필에 저장되므로 한번 정하면 바꾸지 않는다. 역방향 도메인 꼴을 권한다 |
| `name` | 예 | 화면에 보이는 이름 |
| `version` | 아니오 | 플러그인 자체의 버전. 표시용 |
| `apps` | 예 | 이 플러그인이 다루는 앱의 번들 id 목록. 이 앱이 앞에 오면 그 프로필로 바뀐다. 빈 목록이면 모든 앱에서 쓰는 기능이다 |
| `connect` | 아니오 | 없으면 수준 1. 아래 4절 |
| `screens` | 아니오 | 앱 안의 화면(모듈, 페이지) 목록. 프로필을 화면에 묶을 때 쓴다. `recommended`는 그 화면에서 먼저 보여 줄 기능의 `label` |
| `recommended` | 아니오 | 화면이 없는 프로필, 또는 자기 목록이 없는 화면에서 먼저 보여 줄 기능의 `label` 목록 |

모르는 필드는 무시한다. 플러그인도 본체가 보내는 모르는 줄을 무시해야 한다.

플러그인 하나가 Knobtile의 "앱" 하나가 된다. 프로필은 플러그인 하나의 기능을 쓴다. 단축키(`keys.json`)는 어느 플러그인 것이든 어느 프로필에서나 골라 쓸 수 있다.
같은 앱을 다루는 플러그인이 여럿이어도 된다 (`id`만 다르면 된다).

## 4. connect

**TCP** (앱 쪽이 `127.0.0.1`의 포트를 열고 기다린다. Knobtile이 접속한다.)

```json
{ "type": "tcp", "port": 50200 }
{ "type": "tcp", "port": 50200, "valuesPort": 50201 }
```

`valuesPort`는 한 소켓으로 보내기와 받기를 같이 못 하는 앱(Lightroom SDK 등)을 위한 것이다.
있으면 Knobtile은 `port`로 보내기만 하고 `valuesPort`에서 받기만 한다.

**도우미** (Knobtile이 프로그램을 띄우고 표준입력으로 보내고 표준출력에서 받는다.)

```json
{ "type": "run", "command": ["./helper.py"] }
```

- 작업 폴더는 플러그인 폴더다. 언어는 무엇이든 된다. `command`의 첫 항목은 절대 경로이거나 플러그인 폴더 기준 경로다 (실행 권한이 있어야 한다).
- 처음 필요할 때 띄운다: 그 플러그인의 프로필이 켜질 때, `apps`의 앱이 앞에 올 때, 또는 보낼 줄이 생길 때.
- Knobtile이 끝나면 표준입력이 닫힌다. 도우미는 그때 끝나야 한다.
- 도우미가 죽으면 다시 띄운다: 그 플러그인의 프로필이 켜져 있으면 5초 뒤, 아니면 다음 줄을 보낼 때. 표준오류는 Knobtile 로그에 남는다.
- 표준입력을 계속 읽어야 한다. 읽지 않고 살아만 있으면 Knobtile이 멈출 수 있다.
- 출력은 줄마다 바로 내보내야 한다 (버퍼를 비운다).

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

| 필드 | 뜻 |
|---|---|
| `name` | 플러그인이 받는 기능 이름. 프로필에 저장되므로 바꾸지 않는다. 탭과 줄바꿈은 쓸 수 없다 |
| `label` | 화면에 보이는 이름. 점으로 나누면 묶음이 된다: `"묶음.이름"` |
| `step` | 다이얼 한 칸에 바뀌는 양 |
| `stepMin` | 이보다 작은 변화는 모았다가 보낸다 |
| `range` | `[최소, 최대]`. 있으면 값이 있는 기능이다 (슬라이더에 연결할 수 있고 값이 표시된다) |
| `reset` | 초기값. 있으면 "초기화"를 연결할 수 있다 |
| `options` | 고르는 값의 이름 목록 |
| `screens` | 이 기능이 동작하는 화면의 `key`. 없으면 어디서나 |

**프리셋은 쓰지 않아도 된다.** 본체가 `inputs`에서 기본 연결을 만든다.

- `range`가 있다: 다이얼 = 돌리면 `step`, 누르고 돌리면 `step`×10, 누르면 초기화(`reset`이 있을 때). 슬라이더 = 범위 전체.
- `range`가 없다: 버튼 = 누르면 실행. `options`가 있으면 값마다 버튼 하나.
- 종류별로 따진다: `presets`의 다이얼 프리셋이 어떤 기능을 쓰면 그 기능의 기본 다이얼 연결은 만들지 않는다 (슬라이더, 버튼도 같다).

다르게 하고 싶을 때만 `presets`를 쓴다 (선택):

```json
{ "presets": { "dial": [
  { "name": "exposure-fine", "label": "Tone.Exposure (fine)",
    "turn": { "input": "exposure", "step": 0.01 },
    "press": { "input": "exposure", "action": "reset" } } ] } }
```

종류는 `button`, `dial`, `slider`, `orbiter`. 쓸 수 있는 동작 이름:

- 버튼: `press`, `doublePress`, `pressAndHold`, `pressDown`, `pressUp`
- 다이얼: `turn`, `pressAndTurn`, `press`, `doublePress`, `leftTurn`, `rightTurn`, `pose`
- 슬라이더: `pose`
- 오비터: `turn`, `leftTurn`, `rightTurn`, `tiltX`, `tiltY`

동작의 값은 `{ "input": 이름, "step": 수, "action": "reset" | "increment" | "decrement" | "apply", "invert": 참거짓 }`.

## 6. keys.json

```json
[
  { "id": "ex.undo", "label": "Edit.Undo", "key": "z", "modifiers": ["command"], "opposite": "ex.redo" },
  { "id": "ex.redo", "label": "Edit.Redo", "key": "z", "modifiers": ["command", "shift"], "opposite": "ex.undo" }
]
```

- `id`는 모든 플러그인을 통틀어 유일해야 한다. 플러그인만의 머리말을 붙인다 (`ex.`).
- `modifiers`: `command`, `shift`, `alt`, `control`.
- `opposite`가 있으면 다이얼에 연결할 때 왼쪽/오른쪽 짝이 된다.
- 사용자는 Knobtile 안에서 키를 바꿀 수 있다. 바꾼 내용은 사용자 쪽에 저장되고 이 파일은 바뀌지 않는다.

## 7. 줄 형식 (TCP와 도우미가 같다)

UTF-8, 한 줄에 하나, 줄 끝은 `\n`, 칸은 탭으로 나눈다. `@`로 시작하는 줄은 제어, 나머지는 기능이다.

### 본체 → 플러그인

| 줄 | 뜻 |
|---|---|
| `@hello` ⇥ `1` | 연결 직후 한 번. 뒤의 수는 본체가 아는 가장 높은 규격 버전 |
| `이름` ⇥ `+` ⇥ `양` [⇥ `최소` ⇥ `최대`] | 값을 `양`만큼 바꿔라 (음수면 내림) |
| `이름` ⇥ `=` ⇥ `값` [⇥ `최소` ⇥ `최대`] | 값을 이것으로 해라. `options`가 있으면 그 이름 |
| `이름` ⇥ `?` ⇥ (빈 칸) [⇥ `최소` ⇥ `최대`] | 지금 값을 알려 달라. 값이 없는 플러그인은 무시한다 |
| `이름` | 실행해라 (값 없는 기능) |
| `@screen` ⇥ `key` | 앱을 이 화면으로 바꿔라 |
| `@screen` ⇥ `?` | 지금 화면을 알려 달라. `screens`가 있고 그 앱이 맨 앞인 동안 1초마다 온다. 화면이 바뀔 때 스스로 알리는 플러그인은 무시해도 된다 |

`최소`·`최대`는 이 연결의 범위다: 사용자가 따로 정했으면 그것, 아니면 `functions.json`의 `range`. `range`가 없는 기능에는 오지 않는다. 값은 그 안으로 맞춘다.

### 플러그인 → 본체

| 줄 | 뜻 |
|---|---|
| `@hello` ⇥ `1` | `@hello`의 답. 플러그인이 쓰는 규격 버전 (본체가 보낸 수 이하) |
| `이름` ⇥ `값` [⇥ `최소` ⇥ `최대`] | 지금 값. `?`의 답이기도 하고, 앱에서 값이 바뀌면 묻지 않아도 보낸다. `최소`·`최대`는 이번에만 범위가 다를 때 |
| `@screen` ⇥ `key` | 앱이 지금 이 화면이다. 바뀔 때마다 보낸다 |
| `@function` ⇥ `줄` ⇥ `label` | 실행 중에 생기는 기능 하나 (예: 사용자가 만든 프리셋). 사용자가 버튼에 연결하면 본체가 `줄`을 그대로 돌려보낸다. `줄`에는 탭을 쓸 수 없다 |
| `@key` ⇥ `키` ⇥ `수식키,수식키` | 이 키를 대신 눌러 달라. `apps`의 앱이 맨 앞일 때만 눌린다 |
| `!` ⇥ `글` | 방금 줄을 하지 못했다. 로그에 남는다 |

- 값은 실제 값이다 (하드웨어의 0~255가 아니다). 수는 `.`을 소수점으로 쓴다.
- 답을 꼭 하지 않아도 된다. 답이 없다고 본체가 멈추지 않는다. 값을 보내지 않으면 맵에 값이 안 보일 뿐이다.
- `@hello`를 보낸 뒤 3초 동안 아무 줄도 오지 않으면 본체는 연결을 끊고(도우미는 끝내고) 5초 뒤 다시 건다. 그러니 `@hello`에는 꼭 답한다.
- `valuesPort`가 있으면 본체는 두 포트가 모두 연결된 뒤에 `@hello`를 보낸다.

## 8. 버전과 호환

- `spec`은 정수다. 본체는 자기 버전 이하의 모든 `spec`을 받는다.
- 같은 `spec` 안에서는 필드와 줄을 더하기만 한다. 뜻을 바꾸거나 빼려면 `spec`을 올린다.
- 양쪽 모두 모르는 필드, 모르는 `@줄`은 무시한다.

## 9. 가장 작은 예 (수준 3, 도우미)

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

이 예는 `Docs/examples/counter/`에 있고, 자동 테스트(`PluginTests.testExamplePluginEndToEnd`)가 이 폴더를 그대로 넣어 돌린다.
다이얼 한 칸을 보내고 값이 돌아오기까지 약 3ms였다 (M 시리즈 Mac, 2026-11-22).

더 큰 예는 저장소 `Plugins/` 폴더의 `lightroom`이다 (TCP, `LightroomPlugin/`과 함께). 앱 안에 들어 있는 것은 `system` 하나(`Sources/Engine/Resources/Plugins/system`)뿐이고, 나머지는 폴더를 `~/Library/Application Support/Knobtile/Plugins/`에 복사해 설치한다.

## 10. 정한 것 (2026-11-22)

1. 한 앱에 플러그인 여럿: 된다. `id`가 다르면 각각 따로 등록된다.
2. `@key`: 넣었다. 그 플러그인의 `apps`에 있는 앱이 맨 앞일 때만 눌린다. `apps`가 빈 플러그인은 쓸 수 없다.
3. 이름의 번역: v1에는 없다. `label` 하나뿐이다.
