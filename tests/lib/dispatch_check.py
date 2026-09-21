#!/usr/bin/env python3
"""Every subcommand a shell script dispatches must exist, and every subcommand a workflow calls must be
dispatched. BLOCKED.md B16: resolve-upstream.sh dispatched `cmd_drift` and `cmd_update`, defined
neither, and `bash -n` passed — the nightly died on "command not found" every night. gate1-exit.yml
separately called a `mirror` subcommand the script never had.

  dispatch_check.py ROOT [SCRIPT...]   exit 0 clean, 1 with every problem printed.

Rule 1 (scripts): a single-line case arm `pat) WORD ... ;;` whose WORD is not a shell builtin/keyword,
not on PATH and not in KNOWN_EXTERNALS must be a function defined in the script or in a file it
sources. Multi-line arms are not parsed — ponytail: extend if a dispatcher ever uses them.
Rule 2 (workflows): `./path/x.sh WORD` in .github/workflows/*.yml must name a case-arm pattern in x.sh,
when x.sh dispatches on case arms at all.
"""
import os, re, shutil, subprocess, sys

# Commands a shipped script calls in a case arm that exist on the image/runner but not on a laptop.
KNOWN_EXTERNALS = {"rpm-ostree", "pkcheck"}

ARM = re.compile(r"^\s*([^()#\s][^()#]*)\)\s+([A-Za-z_][A-Za-z0-9_-]*)(?![=+\[\w-])[^\n]*;;")
FUNC = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_-]*)\s*\(\)", re.M)
SOURCE = re.compile(r"^\s*(?:\.|source)\s+.*?([\w.-]+\.sh)\b", re.M)  # last-resort: match by basename
WF_CALL = re.compile(r"\./([A-Za-z0-9_./-]+\.sh)[ \t]+([a-z][a-z0-9-]*)\b")

def builtin_or_path(word):
    if word in KNOWN_EXTERNALS or shutil.which(word):
        return True
    r = subprocess.run(["bash", "-c", 'type -t -- "$1"', "_", word], capture_output=True, text=True)
    return r.stdout.strip() in ("builtin", "keyword")

def shell_files(root):
    out = []
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in (".git", "node_modules", "tests")]
        for f in files:
            p = os.path.join(d, f)
            if f.endswith(".sh"):
                out.append(p)
                continue
            try:
                with open(p, "rb") as fh:
                    head = fh.readline(80)
            except OSError:
                continue
            if re.match(rb"#!.*\b(ba)?sh\b", head):
                out.append(p)
    return out

def functions(path, root, seen=None):
    seen = seen if seen is not None else set()
    if path in seen or not os.path.isfile(path):
        return set()
    seen.add(path)
    text = open(path, errors="replace").read()
    names = set(FUNC.findall(text))
    for ref in SOURCE.findall(text):
        base = os.path.basename(ref)
        for cand in shell_files(root):
            if os.path.basename(cand) == base:
                names |= functions(cand, root, seen)
    return names

def arms(path):
    for n, line in enumerate(open(path, errors="replace"), 1):
        m = ARM.match(line)
        if m:
            yield n, m.group(1), m.group(2)

def main(root, scripts):
    problems = []
    for s in scripts or shell_files(root):
        defined = None
        for n, _, word in arms(s):
            if builtin_or_path(word):
                continue
            defined = functions(s, root) if defined is None else defined
            if word not in defined:
                problems.append(f"{os.path.relpath(s, root)}:{n}: dispatches '{word}', which is not a "
                                f"function in this file or anything it sources, and not a command. "
                                f"Defined here: {', '.join(sorted(defined)) or '(none)'}")
    wf = os.path.join(root, ".github", "workflows")
    for f in sorted(os.listdir(wf)) if os.path.isdir(wf) and not scripts else []:
        if not f.endswith((".yml", ".yaml")):
            continue
        for n, line in enumerate(open(os.path.join(wf, f)), 1):
            for script, word in WF_CALL.findall(line):
                target = os.path.join(root, script)
                if not os.path.isfile(target):
                    problems.append(f".github/workflows/{f}:{n}: calls ./{script}, which does not exist")
                    continue
                pats = {p.strip().strip("\"'") for _, pat, _ in arms(target) for p in pat.split("|")}
                # A script with no case-arm dispatch takes positional arguments, not subcommands
                # (probe-matrix-verdict.sh takes a directory). Only a dispatcher can lack a subcommand.
                if pats and word not in pats:
                    problems.append(f".github/workflows/{f}:{n}: calls './{script} {word}', but {script} "
                                    f"dispatches only: {', '.join(sorted(p for p in pats if p not in ('*', '')))}")
    for p in problems:
        print("FAIL  " + p)
    return 1 if problems else 0

if __name__ == "__main__":
    sys.exit(main(os.path.abspath(sys.argv[1]), [os.path.abspath(a) for a in sys.argv[2:]]))
