# Finds Swift string literals holding Korean. list: prints them. wrap: wraps them in L(...) except the (file, key) pairs in skip.txt
import re, sys, glob, json
KO = re.compile('[가-힣]')
def scan(s):
    """yields (start, end, segments) for every string literal, outermost first; segments = list of ('lit', text) | ('expr', (a, b))"""
    out = []; i = 0; n = len(s)
    def literal(i):  # s[i] == '"'
        segs = []; j = i + 1; buf = ''
        while j < n:
            c = s[j]
            if c == '\\' and s[j+1] == '(':
                segs.append(('lit', buf)); buf = ''
                d = 1; k = j + 2; a = k
                while d:
                    if s[k] == '"': k = literal(k)[0]; continue
                    if s[k] == '(': d += 1
                    if s[k] == ')': d -= 1
                    k += 1
                segs.append(('expr', (a, k - 1))); j = k; continue
            if c == '\\': buf += s[j:j+2]; j += 2; continue
            if c == '"': segs.append(('lit', buf)); out.append((i, j + 1, segs)); return j + 1, segs
            buf += c; j += 1
        raise SystemExit('unterminated')
    while i < n:
        if s.startswith('//', i): i = s.find('\n', i) if s.find('\n', i) >= 0 else n; continue
        if s.startswith('/*', i): i = s.find('*/', i) + 2; continue
        if s[i] == '#' and s[i+1:i+2] == '"': i = s.find('"#', i + 2) + 2; continue
        if s[i] == '"': i = literal(i)[0]; continue
        i += 1
    return out
def key(segs):
    interp = any(k == 'expr' for k, _ in segs)
    return ''.join((t.replace('%', '%%') if interp else t) if k == 'lit' else '%@' for k, t in segs)
files = sorted(glob.glob('Sources/Engine/*.swift') + glob.glob('Sources/Knobtile/*.swift'))
mode = sys.argv[1]
skip = set()
if mode == 'wrap':
    skip = {tuple(l.rstrip('\n').split('\t', 1)) for l in open(sys.argv[2], encoding='utf8') if l.strip()}
keys = {}
for f in files:
    s = open(f, encoding='utf8').read()
    lits = [(a, b, segs) for a, b, segs in scan(s) if any(k == 'lit' and KO.search(t) for k, t in segs)]
    name = f.split('/')[-1]
    for a, b, segs in lits:
        line = s.count('\n', 0, a) + 1; k = key(segs)
        if mode == 'list': print(f"{name}:{line}\t{s[max(0, a-28):a].replace(chr(10), ' ').strip()[-26:]}\t{k}")
        elif (name, k) not in skip and not s[:a].endswith('L('): keys[k] = 1
    if mode == 'wrap':
        for a, b, segs in sorted(lits, reverse=True):  # inner literals come first in `out`, positions descend: safe to edit back to front
            if (name, key(segs)) in skip or s[:a].endswith('L('): continue
            s = s[:b] + ')' + s[b:]; s = s[:a] + 'L(' + s[a:]
        open(f, 'w', encoding='utf8').write(s)
if mode == 'wrap': json.dump(list(keys), open(sys.argv[3], 'w', encoding='utf8'), ensure_ascii=False, indent=0)
