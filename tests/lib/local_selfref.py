#!/usr/bin/env python3
"""Find `local` lines that read a name they assign in the same statement.

Bash expands every word of a `local` line before assigning any of them, so in
    local t="$1" dir="/x/${t}"
`${t}` is the OUTER, unset `t`, and under `set -u` the script dies. It stopped a base build
at 40-windows-feel.sh line 46, and a second instance sat in run-update.sh waiting to stop the
update checks. Prints one path:line per hit; prints nothing when clean.
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.')
assign = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|\'[^\']*\'|\S+)')
for f in sorted(root.rglob('*.sh')):
    # The idiom test must CONTAIN the bad pattern, to prove it really misbehaves. Same reason
    # tools/honesty-gate.mjs skips its own rules file.
    if 'node_modules' in f.parts or f.name == 'shell-idioms.test.sh':
        continue
    for n, line in enumerate(f.read_text(errors='replace').split('\n'), 1):
        # re.search, not re.match. The first version anchored at the start of the line, so it found
        # the two real bugs (both began a line) and was blind to `f(){ local a=1 b="$a"; }` — its own
        # canary came back clean. A scanner that only recognises the shape of the bug you already
        # found is not a scanner. Each `local` is checked up to the next `;`, since a one-line
        # function can hold several statements.
        for m in re.finditer(r'(?:^|[;{(\s])local\s+([^;]*)', line):
          seen = []
          for name, value in assign.findall(m.group(1)):
            if any(re.search(r'\$\{?' + re.escape(p) + r'\b', value) for p in seen):
                print(f'{f.relative_to(root)}:{n}')
            seen.append(name)
