#!/usr/bin/env bash
# setup.sh — rebuild the snn-research workspace from the handover kit.
#
#   curl -fsSLO https://raw.githubusercontent.com/spicysauce1955-stack/snn-research-kit/main/setup.sh
#   bash setup.sh --list                        # what's in the kit, sizes, which parts are public
#   bash setup.sh                               # interactive: pick layers, enter the password once
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
#          --identity FILE (an already-unlocked key; testing)
set -euo pipefail

KIT_REPO=${KIT_REPO:-spicysauce1955-stack/snn-research-kit}
AGE_VERSION=v1.2.1
AGE_SHA256=7df45a6cc87d4da11cc03a539a7470c15b1041ab2b396af088fe9990f7c79d50   # age-v1.2.1-linux-amd64.tar.gz
ROOT=$HOME/.superset/projects LAYERS="" LAYERS_GIVEN=0 FROM="" KEYFILE="" SYNC=1 CLAUDE_USER=0 KEEP=0 LIST=0
while (($#)); do
  case $1 in
    --root) ROOT=$2; shift ;; --layers) LAYERS=$2 LAYERS_GIVEN=1; shift ;; --from) FROM=$(cd "$2" && pwd); shift ;;
    --identity) KEYFILE=$2; shift ;; --no-sync) SYNC=0 ;; --claude-user) CLAUDE_USER=1 ;;
    --keep-downloads) KEEP=1 ;; --list) LIST=1 ;; -h | --help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac; shift
done

die() { echo "setup: $*" >&2; exit 1; }
say() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
for c in curl tar zstd git python3 sha256sum; do command -v "$c" >/dev/null || die "please install $c"; done
mkdir -p "$ROOT"; ROOT=$(cd "$ROOT" && pwd)
CACHE=$ROOT/.kit-cache; mkdir -p "$CACHE/parts"
STATE=$ROOT/.kit-installed; touch "$STATE"
fetch() {  # fetch NAME DEST  (from --from dir, the repo's main branch, or the `store` release)
  if [[ -n $FROM ]]; then cp "$FROM/$1" "$2"
  elif [[ $1 == *.part* ]]; then curl -fL --retry 5 -C - -o "$2" "https://github.com/$KIT_REPO/releases/download/store/$1"
  else curl -fsSL --retry 5 -o "$2" "https://raw.githubusercontent.com/$KIT_REPO/main/$1"; fi
}

# ---- age (pinned, checksum-verified) if the system has none
if ! command -v age >/dev/null; then
  [[ $(uname -sm) == "Linux x86_64" ]] || die "install age (https://age-encryption.org) and re-run"
  say "fetching age $AGE_VERSION"
  curl -fsSL -o "$CACHE/age.tgz" "https://github.com/FiloSottile/age/releases/download/$AGE_VERSION/age-$AGE_VERSION-linux-amd64.tar.gz"
  echo "$AGE_SHA256  $CACHE/age.tgz" | sha256sum -c --quiet - || die "age download checksum mismatch"
  tar -C "$CACHE" -xzf "$CACHE/age.tgz"; PATH=$CACHE/age:$PATH
fi

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
  echo; echo "core is always installed. Add more as space-separated names or globs, e.g."
  echo "  campaigns papers history      all campaigns + papers + git history"
  echo "  runs/202609-*                 raw runs of Sept 2026        all   everything"
  read -rp "layers> " LAYERS
fi

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

# ---- unlock the identity once (the only password prompt)
KEYDIR=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/kit.XXXXXX"); chmod 700 "$KEYDIR"
trap 'shred -u "$KEYDIR"/* 2>/dev/null; rm -rf "$KEYDIR"' EXIT
if grep -q '"encrypted": true' "$SEL"; then
  if [[ -n $KEYFILE ]]; then cp "$KEYFILE" "$KEYDIR/id"
  else
    fetch identity.age "$CACHE/identity.age"
    say "enter the kit password"
    age -d -o "$KEYDIR/id" "$CACHE/identity.age" || die "wrong password"
  fi
fi

# ---- download, verify, decrypt, unpack
while read -r line; do
  [[ -n $line ]] || continue
  eval "$(python3 -c 'import json,shlex,sys
L=json.loads(sys.argv[1])
print("name=%s enc=%d dest=%s key=%s" % (shlex.quote(L["name"]), L["encrypted"], L["dest"], shlex.quote(L["name"]+"@"+L["content_sha256"])))
print("parts=(%s)" % " ".join(shlex.quote(p["asset"]+":"+p["sha256"]) for p in L["parts"]))' "$line")"
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
  echo "$key" >> "$STATE"
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

# ---- Claude Code: project memory goes where Claude Code looks for it
CK=$ROOT/claude-kit
if [[ -d $CK/memory ]]; then
  mem=$HOME/.claude/projects/$(printf '%s' "$ROOT/snn-research" | sed 's/[^a-zA-Z0-9-]/-/g')/memory
  if [[ -e $mem ]]; then say "Claude memory exists at $mem — left alone (kit copy: $CK/memory)"
  else mkdir -p "$(dirname "$mem")"; cp -r "$CK/memory" "$mem"; say "Claude memory -> $mem"; fi
fi
if ((CLAUDE_USER)) && [[ -d $CK/user ]]; then
  mkdir -p "$HOME/.claude"; cp -rn "$CK/user/." "$HOME/.claude/"; say "user-level agents/skills copied (existing files kept)"
fi

# ---- Python environments
if ((SYNC)); then
  if command -v uv >/dev/null; then
    for repo in snn-research tempotron-capacity; do say "uv sync: $repo"; (cd "$ROOT/$repo" && uv sync -q) || echo "  uv sync failed in $repo (see SETUP.md)" >&2; done
  else echo "uv not found: install it (https://docs.astral.sh/uv/) then run 'uv sync' in both repos" >&2; fi
fi

[[ $ROOT == /home/user/.superset/projects ]] || say "note: docs cite /home/user/.superset/projects/...; your tree is at $ROOT"
cat >&2 <<EOF

Done. Installed layers are recorded in $STATE; re-run with --layers to add more.
Next: read $ROOT/snn-research/tools/backup/SETUP.md (accounts, Claude Code plugins/MCP,
credentials, first commands). The Claude setup to reproduce is in $CK/claude-setup.json.
EOF
