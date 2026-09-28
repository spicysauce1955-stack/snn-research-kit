#!/usr/bin/env bash
# setup.sh — rebuild the snn-research workspace from the handover kit.
#
#   curl -fsSLO https://raw.githubusercontent.com/spicysauce1955-stack/snn-research-kit/main/setup.sh
#   bash setup.sh --list                        # what's in the kit, sizes, which parts are public
#   bash setup.sh                               # interactive: Enter = recommended, password once
#   bash setup.sh --check                       # PASS/FAIL health check of an installed workspace
#   bash setup.sh --layers 'campaigns papers'   # non-interactive; `core` is always included
#   bash setup.sh --layers 'runs/202609-*'      # add layers later; installed ones are skipped
#
# Layers: core (required) · campaign/<name> · papers · artifacts · history · lab-ledger ·
#         runs/<YYYYMM>-<nn>.  Group words select all of a kind: campaigns, runs, all.
#
# Options: --root DIR (default ~/.superset/projects — keep it: 300+ docs cite absolute paths
#          under it) · --no-sync (skip `uv sync`) · --claude-user (also copy the author's
#          user-level Claude agents/skills into ~/.claude, never overwriting) · --keep-downloads ·
#          --from DIR (install from a local copy of the kit instead of GitHub) ·
#          --password-cmd CMD (read the password from a password manager instead of the
#          keyboard, e.g. 'pass show snn-kit' or 'op read op://vault/snn-kit/password') ·
#          --identity FILE (an already-unlocked age key) · --claude (install the author's
#          Claude Code plugins + MCP servers; needs `claude` on PATH)
set -euo pipefail

KIT_REPO=${KIT_REPO:-spicysauce1955-stack/snn-research-kit}
AGE_VERSION=v1.2.1
AGE_SHA256=7df45a6cc87d4da11cc03a539a7470c15b1041ab2b396af088fe9990f7c79d50   # age-v1.2.1-linux-amd64.tar.gz
ROOT=$HOME/.superset/projects LAYERS="" LAYERS_GIVEN=0 FROM="" KEYFILE="" PWCMD=${KIT_PASSWORD_CMD:-} SYNC=1 CLAUDE_USER=0 KEEP=0 LIST=0 CHECK=0 CLAUDE_SETUP=0
while (($#)); do
  case $1 in
    --root) ROOT=$2; shift ;; --layers) LAYERS=$2 LAYERS_GIVEN=1; shift ;; --from) FROM=$(cd "$2" && pwd); shift ;;
    --identity) KEYFILE=$2; shift ;; --password-cmd) PWCMD=$2; shift ;; --no-sync) SYNC=0 ;; --claude-user) CLAUDE_USER=1 ;;
    --keep-downloads) KEEP=1 ;; --list) LIST=1 ;; --check) CHECK=1 ;; --claude) CLAUDE_SETUP=1 ;; -h | --help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac; shift
done

die() { echo "setup: $*" >&2; exit 1; }
say() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
for c in curl tar zstd git python3 sha256sum; do command -v "$c" >/dev/null || die "please install $c"; done
mkdir -p "$ROOT"; ROOT=$(cd "$ROOT" && pwd)
[[ $EUID -ne 0 ]] || say "running as root: fine on a throwaway VM, but the notes assume an ordinary user (the author's was 'user')"

# ---- health check: one PASS/FAIL line per claim a recipient would otherwise verify by hand
kit_check() {
  local pass=0 fail=0 r want
  chk() { if (eval "$2") >/dev/null 2>&1; then echo "  PASS  $1"; pass=$((pass + 1)); else echo "  FAIL  $1"; fail=$((fail + 1)); fi; }
  say "health check of $ROOT"
  for r in snn-research tempotron-capacity; do
    [[ -d $ROOT/$r ]] || { echo "  FAIL  $r missing (core not installed?)"; fail=$((fail + 1)); continue; }
    want=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["commit"])' "$ROOT/KIT-SOURCES.json" "$r" 2>/dev/null || true)
    if [[ -z $want ]]; then echo "  info  $r: no KIT-SOURCES.json (not a kit install) — commit not compared"
    elif [[ -f $ROOT/$r/.git/kit-snapshot ]]; then echo "  info  $r is a snapshot commit (install the history layer for full history)"
    else chk "$r checked out at the kit's commit ${want:0:12}" "[[ \$(git -C '$ROOT/$r' rev-parse HEAD) == $want ]]"; fi
    chk "$r has no modified files" "[[ -z \$(git -C '$ROOT/$r' status --porcelain | grep -v '^ D ') ]]"
    local gone; gone=$(git -C "$ROOT/$r" status --porcelain | grep -c '^ D ' || true)
    ((gone == 0)) || echo "  info  $r: $gone tracked files belong to layers you did not install (campaigns/papers)"
  done
  local lc; lc=$(cd "$ROOT/snn-research" && python3 tools/claim_check.py ledger LEDGER.md 2>&1) && {
    echo "  PASS  LEDGER.md passes claim_check ($(tail -1 <<<"$lc" | xargs))"; pass=$((pass + 1)); } || {
    if ! grep '\[FAIL\]' <<<"$lc" | grep -qv 'evidence path does not resolve: campaigns/'; then
      echo "  info  LEDGER.md: evidence lives in campaign layers you did not install (add 'campaigns' to verify)"
    else echo "  FAIL  LEDGER.md claim_check:"; grep '\[FAIL\]' <<<"$lc" | head -5; fail=$((fail + 1)); fi; }
  if command -v uv >/dev/null && [[ -d $ROOT/snn-research/.venv ]]; then
    chk "snn-research env imports numpy<2 + brian2" "cd '$ROOT/snn-research' && uv run -q python -c 'import numpy, brian2; assert numpy.__version__ < \"2\"'"
  fi
  if command -v uv >/dev/null && [[ -d $ROOT/tempotron-capacity/.venv ]]; then
    chk "lab CLI runs (tempotron-capacity)" "cd '$ROOT/tempotron-capacity' && uv run -q lab --version"
  fi
  echo "  $pass passed, $fail failed"
  return $((fail > 0))
}
if ((CHECK)); then kit_check; exit $?; fi
CACHE=$ROOT/.kit-cache; mkdir -p "$CACHE/parts"
STATE=$ROOT/.kit-installed; touch "$STATE"
fetch() {  # fetch NAME DEST  (from --from dir, the repo's main branch, or the `store` release)
  if [[ -n $FROM ]]; then cp "$FROM/$1" "$2"
  elif [[ $1 == *.part* ]]; then curl -fsSL --retry 5 -C - -o "$2" "https://github.com/$KIT_REPO/releases/download/store/$1"
  else curl -fsSL --retry 5 -o "$2" "https://raw.githubusercontent.com/$KIT_REPO/main/$1"; fi
}

fetch manifest.json "$CACHE/manifest.json"
M=$CACHE/manifest.json
py() { python3 - "$M" "$@"; }

table() { py <<'EOF'
import json, sys
m = json.load(open(sys.argv[1])); tot = 0
print(f"kit snapshot {m.get('created', '?')}")
for L in m["layers"]:
    s = sum(p["size"] for p in L["parts"]); tot += s
    print(f"  {L['name']:<42} {s / 2**20:>9.0f} MB  {'encrypted' if L['encrypted'] else 'public   '}  {L.get('desc', '')}")
print(f"  {'(everything)':<42} {tot / 2**20:>9.0f} MB")
EOF
}
table
((LIST)) && exit 0

if ! ((LAYERS_GIVEN)); then
  [[ -t 0 ]] || die "no --layers given and no terminal to ask on"
  echo; echo "core is always installed. Press Enter for the recommended set (everything except the"
  echo "raw runs), or type names/globs:  all · campaigns papers · history · runs/202609-* · none"
  read -rp "layers [recommended]> " LAYERS
  [[ -n $LAYERS ]] || LAYERS="campaigns papers artifacts history lab-ledger"
fi

[[ $LAYERS != none ]] || LAYERS=""
SEL=$CACHE/selected.jsonl
python3 - "$M" "$STATE" "$LAYERS" > "$SEL" <<'EOF'
import fnmatch, json, sys
m = json.load(open(sys.argv[1]))
done = set(open(sys.argv[2]).read().split())
sel = sys.argv[3].replace(",", " ").split()
for L in m["layers"]:
    pick = L["name"] == "core" or any(
        s == "all" or fnmatch.fnmatch(L["name"], s) or s in (L["group"], L["group"] + "s") for s in sel)
    if pick and f"{L['name']}@{L['content_sha256']}" not in done:
        print(json.dumps(L))
EOF
[[ -s $SEL ]] || { say "nothing new to install"; }
python3 -c 'import json,sys
L=[json.loads(l) for l in open(sys.argv[1])]
print("to install:", ", ".join(x["name"] for x in L) or "-", "| download %.0f MB" % (sum(p["size"] for x in L for p in x["parts"]) / 2**20))' "$SEL" >&2

# ---- age (pinned, checksum-verified) if the system has none
if grep -q '"encrypted": true' "$SEL" && ! command -v age >/dev/null; then
  [[ $(uname -sm) == "Linux x86_64" ]] || die "install age (https://age-encryption.org) and re-run"
  say "fetching age $AGE_VERSION"
  curl -fsSL -o "$CACHE/age.tgz" "https://github.com/FiloSottile/age/releases/download/$AGE_VERSION/age-$AGE_VERSION-linux-amd64.tar.gz"
  echo "$AGE_SHA256  $CACHE/age.tgz" | sha256sum -c --quiet - || die "age download checksum mismatch"
  tar -C "$CACHE" -xzf "$CACHE/age.tgz"; PATH=$CACHE/age:$PATH
fi

# ---- unlock the identity once (the only password prompt)
KEYDIR=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/kit.XXXXXX"); chmod 700 "$KEYDIR"
trap 'if [[ -f $KEYDIR/id ]]; then shred -u "$KEYDIR/id" || rm -f "$KEYDIR/id"; fi; rm -rf "$KEYDIR"' EXIT
if grep -q '"encrypted": true' "$SEL"; then
  if [[ -n $KEYFILE ]]; then cp "$KEYFILE" "$KEYDIR/id"
  else
    fetch identity.age "$CACHE/identity.age"
    if [[ -n $PWCMD ]]; then
      # age reads passphrases only from a terminal: run it on a pseudo-terminal and type for it
      KIT_PW=$(bash -c "$PWCMD") || die "--password-cmd failed"
      KIT_PW=$KIT_PW python3 - "$KEYDIR/id" "$CACHE/identity.age" <<'EOF' || die "wrong password (from --password-cmd)"
import os, pty, select, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp("age", ["age", "-d", "-o", sys.argv[1], sys.argv[2]])
sent, out = False, b""
while True:
    try:
        r, _, _ = select.select([fd], [], [], 30)
        if not r: break
        chunk = os.read(fd, 1024)
    except OSError:
        break
    if not chunk: break
    out += chunk
    if not sent and b"passphrase" in out.lower():
        os.write(fd, os.environ["KIT_PW"].encode() + b"\n"); sent = True
sys.exit(os.waitpid(pid, 0)[1] >> 8)
EOF
      unset KIT_PW
    else
      say "enter the kit password"
      age -d -o "$KEYDIR/id" "$CACHE/identity.age" || die "wrong password"
    fi
  fi
fi

# ---- download, verify, decrypt, unpack
NEW=0
while read -r line; do
  [[ -n $line ]] || continue
  # the manifest comes from a public repo: validate every field instead of eval-ing it
  mapfile -t F < <(python3 - "$line" <<'EOF'
import json, re, sys
L, ok = json.loads(sys.argv[1]), re.fullmatch
out = [L["name"], str(int(L["encrypted"] is True)), L["dest"], L["name"] + "@" + L["content_sha256"]]
assert ok(r"[A-Za-z0-9/_.-]+", L["name"]) and L["dest"] in ("root", "home") and ok(r"[0-9a-f]{64}", L["content_sha256"])
for q in L["parts"]:
    assert ok(r"[A-Za-z0-9_.-]+", q["asset"]) and ok(r"[0-9a-f]{64}", q["sha256"])
    out.append(q["asset"] + ":" + q["sha256"])
print("\n".join(out))
EOF
  )
  ((${#F[@]} >= 5)) || die "manifest entry failed validation: ${line:0:80}"
  name=${F[0]} enc=${F[1]} dest=${F[2]} key=${F[3]} parts=("${F[@]:4}")
  say "$name"
  files=()
  for p in "${parts[@]}"; do
    a=${p%%:*} sha=${p#*:} f=$CACHE/parts/${p%%:*}
    if ! echo "$sha  $f" | sha256sum -c --quiet - >/dev/null 2>&1; then
      fetch "$a" "$f"
      echo "$sha  $f" | sha256sum -c --quiet - || die "$a: checksum mismatch (corrupt download?)"
    fi
    files+=("$f")
  done
  target=$ROOT
  if [[ $dest == home ]]; then
    if [[ -e $HOME/.lab ]]; then target=$ROOT/restored-home; say "  ~/.lab exists: unpacking to $target/.lab instead"; else target=$HOME; fi
  fi
  mkdir -p "$target"
  if ((enc)); then cat "${files[@]}" | age -d -i "$KEYDIR/id" | zstd -dcq | tar -C "$target" -xf -
  else cat "${files[@]}" | zstd -dcq | tar -C "$target" -xf -; fi
  echo "$key" >> "$STATE"; NEW=$((NEW + 1))
  ((KEEP)) || rm -f "${files[@]}"
done < "$SEL"

[[ -d $ROOT/snn-research ]] || die "core is not installed"
SRC=$ROOT/KIT-SOURCES.json   # which branch/commit each repo was on when the kit was built
branch_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["branch"] or "main")' "$SRC" "$1"; }

# ---- git: full history if the history layer is present, else a one-commit snapshot
for repo in snn-research tempotron-capacity; do
  r=$ROOT/$repo b=$(branch_of "$repo") bundle=$ROOT/kit-history/$repo.bundle
  [[ -d $r ]] || continue
  if [[ -f $bundle && ( ! -d $r/.git || -f $r/.git/kit-snapshot ) ]]; then
    say "$repo: importing full history (branch $b)"
    rm -rf "$r/.git"; git -C "$r" init -q
    git -C "$r" fetch -q --update-head-ok "$bundle" 'refs/heads/*:refs/heads/*'
    git -C "$r" symbolic-ref HEAD "refs/heads/$b"; git -C "$r" reset -q
  elif [[ ! -d $r/.git ]]; then
    say "$repo: no history layer — creating a snapshot commit"
    git -C "$r" init -q -b "$b"; git -C "$r" add -A
    git -C "$r" -c user.name=kit -c user.email=kit@localhost commit -qm "kit snapshot of $repo@$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["commit"][:12])' "$SRC" "$repo")"
    touch "$r/.git/kit-snapshot"
  fi
done

# laboratory (the lab runner) — its history ships in the history layer; restore it next to the rest
if [[ -f $ROOT/kit-history/laboratory.bundle && ! -d $ROOT/laboratory ]]; then
  say "laboratory: cloning from the history layer"
  git clone -q "$ROOT/kit-history/laboratory.bundle" "$ROOT/laboratory"
  git -C "$ROOT/laboratory" remote set-url origin https://github.com/spicysauce1955-stack/laboratory.git
fi

# the author worked from a git worktree; ~300 notes and scripts cite that path. Point it here.
WT=$HOME/.superset/worktrees/snn-research/bob/init
if [[ ! -e $WT ]]; then mkdir -p "$(dirname "$WT")"; ln -s "$ROOT/snn-research" "$WT"; say "compat link $WT -> $ROOT/snn-research"; fi

# ---- Claude Code: project memory goes where Claude Code looks for it
CK=$ROOT/claude-kit
if [[ -d $CK/memory ]]; then
  mem=$HOME/.claude/projects/$(printf '%s' "$ROOT/snn-research" | sed 's/[^a-zA-Z0-9-]/-/g')/memory
  if [[ -e $mem ]]; then say "Claude memory exists at $mem — left alone (kit copy: $CK/memory)"
  else mkdir -p "$(dirname "$mem")"; cp -r "$CK/memory" "$mem"; say "Claude memory -> $mem"; fi
fi
if [[ -d $CK/user/skills/laboratory && ! -e $HOME/.claude/skills/laboratory ]]; then
  mkdir -p "$HOME/.claude/skills"; cp -r "$CK/user/skills/laboratory" "$HOME/.claude/skills/"
  say "laboratory skill -> ~/.claude/skills (CLAUDE.md requires it before any lab submit)"
fi
if ((CLAUDE_USER)) && [[ -d $CK/user ]]; then
  mkdir -p "$HOME/.claude"; cp -rn "$CK/user/." "$HOME/.claude/"; say "user-level agents/skills copied (existing files kept)"
fi

# ---- orientation + a generated Claude Code setup script
[[ -f $ROOT/snn-research/tools/backup/START-HERE.md ]] && cp "$ROOT/snn-research/tools/backup/START-HERE.md" "$ROOT/START-HERE.md"
if [[ -f $CK/claude-setup.json ]]; then
  python3 - "$CK/claude-setup.json" > "$CK/setup-claude.sh" <<'EOF'
import json, shlex, sys
c = json.load(open(sys.argv[1]))
print("#!/usr/bin/env bash\n# generated by setup.sh from claude-setup.json: the author's plugins + MCP servers")
print("command -v claude >/dev/null || { echo 'install Claude Code first: npm i -g @anthropic-ai/claude-code'; exit 1; }")
for src in c.get("marketplaces", {}).values():
    if (src or {}).get("source") == "github":
        print(f"claude plugin marketplace add {shlex.quote(src['repo'])} || true")
for pl in c.get("enabledPlugins", []):
    print(f"claude plugin install {shlex.quote(pl)} || true")
for name, m in c.get("mcpServers", {}).items():
    if m.get("type") not in (None, "stdio"):
        continue
    cmd = " ".join(shlex.quote(x) for x in [m["command"], *m.get("args", [])])
    envs = m.get("required_env", [])
    flags = " ".join(f'-e {e}="${e}"' for e in envs)
    line = f"claude mcp add --scope user {flags} {shlex.quote(name)} -- {cmd} || true"
    if m["command"] not in ("npx", "node", "uvx", "python3"):
        line = f"command -v {shlex.quote(m['command'])} >/dev/null || npm i -g {shlex.quote(m['command'])}\n" + line
    if envs:
        cond = " && ".join(f'[[ -n ${{{e}:-}} ]]' for e in envs)
        line = f"if {cond}; then\n  {line}\nelse echo 'skipping MCP {name}: export {' '.join(envs)} first'; fi"
    print(line)
EOF
  chmod +x "$CK/setup-claude.sh"
  if ((CLAUDE_SETUP)); then say "Claude Code plugins + MCP servers"; bash "$CK/setup-claude.sh" || true; fi
fi

# ---- Python environments
if ((SYNC)) && { ((NEW)) || [[ ! -d $ROOT/snn-research/.venv || ! -d $ROOT/tempotron-capacity/.venv ]]; }; then
  if command -v uv >/dev/null; then
    for repo in snn-research tempotron-capacity; do say "uv sync: $repo"; (cd "$ROOT/$repo" && uv sync -q) || echo "  uv sync failed in $repo (see SETUP.md)" >&2; done
  else
    say "installing uv (https://astral.sh/uv)"
    curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null && export PATH=$HOME/.local/bin:$PATH
    for repo in snn-research tempotron-capacity; do say "uv sync: $repo"; (cd "$ROOT/$repo" && uv sync -q) || echo "  uv sync failed in $repo (see SETUP.md)" >&2; done
  fi
fi

[[ $ROOT == /home/user/.superset/projects ]] || say "note: docs cite /home/user/.superset/projects/...; your tree is at $ROOT"
if [[ -f $0 && $(cd "$(dirname "$0")" && pwd)/$(basename "$0") != "$ROOT/setup.sh" ]]; then cp "$0" "$ROOT/setup.sh"
elif [[ ! -f $ROOT/setup.sh ]]; then fetch setup.sh "$ROOT/setup.sh" || true; fi
kit_check || true
cat >&2 <<EOF

Done. Start with $ROOT/START-HERE.md.
Add layers any time (bash setup.sh --layers 'runs/*'); re-check with bash setup.sh --check.
Claude Code plugins + MCP servers: bash $CK/setup-claude.sh (or re-run setup with --claude).
EOF
