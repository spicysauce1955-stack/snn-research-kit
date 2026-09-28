#!/usr/bin/env bash
# setup.sh — rebuild the snn-research workspace from the handover kit.
#
#   bash setup.sh                   # enter the kit password: it unlocks the kit AND names its
#                                   # signing key, then everything is verified before install
#   bash setup.sh --fingerprint SHA256:... --not-before DATE   # stronger, if your sender gave them
#   The fingerprint and newest snapshot date are saved in ~/.config/snn-kit/ after the first
#   verified run; every later run under the same root verifies against them.
#   bash setup.sh --list                        # what's in the kit, sizes, which parts are public
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
#          Claude Code plugins + MCP servers; needs `claude` on PATH) ·
#          --fingerprint SHA256:... (or env KIT_FINGERPRINT) the signing key's fingerprint ·
#          --not-before DATE refuse a snapshot older than DATE (rollback) · --new-fingerprint
#          SHA256:... accept a rotated key (only a value your maintainer sent out of band) ·
#          --insecure install WITHOUT any verification (not advised)
set -euo pipefail

KIT_REPO=${KIT_REPO:-spicysauce1955-stack/snn-research-kit}
AGE_VERSION=v1.2.1
AGE_SHA256=7df45a6cc87d4da11cc03a539a7470c15b1041ab2b396af088fe9990f7c79d50   # age-v1.2.1-linux-amd64.tar.gz
ROOT=$HOME/.superset/projects LAYERS="" LAYERS_GIVEN=0 FROM="" KEYFILE="" PWCMD=${KIT_PASSWORD_CMD:-} SYNC=1 CLAUDE_USER=0 KEEP=0 LIST=0 CHECK=0 CLAUDE_SETUP=0
FP="" FP_SET=0 NB="" NB_SET=0 INSECURE=0 NEWFP=""
if [[ -n ${KIT_FINGERPRINT+set} ]]; then FP=$KIT_FINGERPRINT FP_SET=1; fi
KIT_RAW=${KIT_RAW:-https://raw.githubusercontent.com/$KIT_REPO/main}              # mirrors/testing;
KIT_STORE=${KIT_STORE:-https://github.com/$KIT_REPO/releases/download/store}     # trust comes from FP
while (($#)); do
  case $1 in
    --root) ROOT=$2; shift ;; --layers) LAYERS=$2 LAYERS_GIVEN=1; shift ;; --from) FROM=$(cd "$2" && pwd); shift ;;
    --identity) KEYFILE=$2; shift ;; --password-cmd) PWCMD=$2; shift ;; --no-sync) SYNC=0 ;; --claude-user) CLAUDE_USER=1 ;;
    --keep-downloads) KEEP=1 ;; --list) LIST=1 ;; --check) CHECK=1 ;; --claude) CLAUDE_SETUP=1 ;;
    --fingerprint) FP=$2 FP_SET=1; shift ;; --not-before) NB=$2 NB_SET=1; shift ;;
    --insecure) INSECURE=1 ;;
    --new-fingerprint) [[ $# -ge 2 && $2 == SHA256:* ]] || { echo "setup: --new-fingerprint needs the new SHA256:... value, \
sent by your maintainer out of band (never taken from the kit or the password)" >&2; exit 2; }; NEWFP=$2; shift ;; -h | --help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac; shift
done

die() { echo "setup: $*" >&2; exit 1; }
say() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
for c in curl tar zstd git python3 sha256sum; do command -v "$c" >/dev/null || die "please install $c"; done
mkdir -p "$ROOT"; ROOT=$(cd "$ROOT" && pwd -P)   # physical path: an alias must not look like a new tree
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
# everything that decides trust lives OUTSIDE the tree, keyed on the physical root: no layer's
# tar can write, replace or symlink it, and no alias of the root escapes it
CONF=${XDG_CONFIG_HOME:-$HOME/.config}/snn-kit
ROOT_ID=$(printf '%s' "$ROOT" | sha256sum | cut -c1-16)
SDIR=$CONF/roots/$ROOT_ID
SAVED=$SDIR/fingerprint INSEC_CONF=$SDIR/insecure STATE=$SDIR/installed
INSEC_MARK=$ROOT/.kit-insecure   # in-tree copy: a hint for humans only, never trusted
CACHE=$ROOT/.kit-cache TRUST=$ROOT/.kit-cache/trust
fetch() {  # fetch NAME DEST  (from --from dir, the repo's main branch, or the `store` release)
  if [[ -n $FROM ]]; then cp "$FROM/$1" "$2"
  elif [[ $1 == *.part* ]]; then curl -fsSL --retry 5 -C - -o "$2" "$KIT_STORE/$1"
  else curl -fsSL --retry 5 -o "$2" "$KIT_RAW/$1"; fi
}

KEYDIR=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/kit.XXXXXX"); chmod 700 "$KEYDIR"
trap 'if [[ -f $KEYDIR/id ]]; then shred -u "$KEYDIR/id" || rm -f "$KEYDIR/id"; fi; rm -rf "$KEYDIR"' EXIT
ensure_age() {  # age (pinned, checksum-verified) if the system has none
  command -v age >/dev/null && return
  [[ $(uname -sm) == "Linux x86_64" ]] || die "install age (https://age-encryption.org) and re-run"
  say "fetching age $AGE_VERSION"
  curl -fsSL -o "$CACHE/age.tgz" "https://github.com/FiloSottile/age/releases/download/$AGE_VERSION/age-$AGE_VERSION-linux-amd64.tar.gz"
  echo "$AGE_SHA256  $CACHE/age.tgz" | sha256sum -c --quiet - || die "age download checksum mismatch"
  tar -C "$CACHE" -xzf "$CACHE/age.tgz"; PATH=$CACHE/age:$PATH
}
id_fingerprint() {  # the signing fingerprint the password holder put inside the identity ('' if none)
  local l; l=$(grep -E '^# snn-kit-signing-fingerprint: ' "$KEYDIR/id" || true)
  [[ -z $l ]] && return 0
  [[ $(wc -l <<<"$l") == 1 && ${l#*: } =~ $FP_RE ]] || die "identity.age carries a malformed signing fingerprint line. STOP."
  echo "${l#*: }"
}
unlock_identity() {  # -> $KEYDIR/id, the only password prompt. identity.age is checked against the
                     #    signed SHA256SUMS whenever the chain is already known (FP set)
  [[ -s $KEYDIR/id ]] && return 0
  ensure_age
  if [[ -n $KEYFILE ]]; then cp "$KEYFILE" "$KEYDIR/id"
  else
    fetch identity.age "$CACHE/identity.age"
    [[ -n $FP ]] && trusted identity.age "$CACHE/identity.age"
    if [[ -n $PWCMD ]]; then
      # age reads passphrases only from a terminal: run it on a pseudo-terminal and type for it
      KIT_PW=$(bash -c "$PWCMD") || die "--password-cmd failed"
      KIT_PW=$KIT_PW python3 - "$KEYDIR/id" "$CACHE/identity.age" <<'EOF' || die "wrong password (from --password-cmd)"
import os, pty, select, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvpe("age", ["age", "-d", "-o", sys.argv[1], sys.argv[2]],
               {k: v for k, v in os.environ.items() if k != "KIT_PW"})   # the child never holds the password
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
      [[ -t 0 ]] || die "the kit password is needed: run in a terminal, or pass --password-cmd"
      say "enter the kit password"
      age -d -o "$KEYDIR/id" "$CACHE/identity.age" || die "wrong password"
    fi
  fi
  local idfp; idfp=$(id_fingerprint)
  if [[ -n $FP && -n $idfp && $idfp != "$FP" ]]; then
    die "the signing fingerprint inside identity.age ($idfp) is not $FP. STOP. (A rotated key only counts if
       your maintainer sent its fingerprint out of band: --new-fingerprint SHA256:...)"
  fi
}
derive_fp() {  # password-only mode: the password holder's identity names the signing key
  say "no fingerprint given: the kit password will vouch for the kit's signing key"
  unlock_identity
  FP=$(id_fingerprint)
  [[ -n $FP ]] || die "this kit's identity.age carries no signing fingerprint: the kit predates password-rooted
       verification. Ask your sender for the fingerprint (bash setup.sh --fingerprint SHA256:...), or use --insecure."
  say "identity.age names signing key $FP"
}

# ---- chain of trust: fingerprint (given out of band, with the password) -> signing_key.pub
#      -> SHA256SUMS.sig -> SHA256SUMS -> manifest.json, identity.age, recipient.txt -> every part
FP_RE='^SHA256:[A-Za-z0-9+/]{43}$' DATE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$'
NOFP="if your sender gave you a fingerprint (SHA256:...) and date, they came with the password"
PWROOT=0 UNVERIFIED_LIST=0
resolve_trust() {  # FP/NB from the command line, else from the first verified install; never silently off
  ((FP_SET)) && [[ -z $FP ]] && die "empty --fingerprint (or KIT_FINGERPRINT=): $NOFP"
  ((NB_SET)) && [[ -z $NB ]] && die "empty --not-before: $NOFP"
  [[ -z $FP || $FP =~ $FP_RE ]] || die "--fingerprint must look like SHA256:<43 characters>, got '$FP'"
  [[ -z $NB || $NB =~ $DATE_RE ]] || die "--not-before must look like 2026-09-28 or 2026-09-28T09:12:56Z, got '$NB'"
  local sfp="" snb=""
  if [[ -f $SAVED ]]; then
    sfp=$(sed -n 's/^fingerprint=//p' "$SAVED"); snb=$(sed -n 's/^not_before=//p' "$SAVED")
    [[ $sfp =~ $FP_RE && ( -z $snb || $snb =~ $DATE_RE ) ]] || die "$SAVED is damaged; re-run with --fingerprint and --not-before ($NOFP)"
  fi
  if [[ -n $NEWFP ]]; then   # a rotation: only ever an explicit value from the maintainer, out of band
    [[ $NEWFP =~ $FP_RE ]] || die "--new-fingerprint must look like SHA256:<43 characters>, got '$NEWFP'"
    [[ -z $FP || $FP == "$NEWFP" ]] || die "--fingerprint and --new-fingerprint differ"
    FP=$NEWFP
  elif [[ -z $FP ]]; then FP=$sfp
  elif [[ -n $sfp && $FP != "$sfp" ]]; then
    die "fingerprint $FP differs from $sfp, saved at your first verified install ($SAVED). If your maintainer \
sent a new one out of band (key rotation), use --new-fingerprint SHA256:<it>. Otherwise STOP."
  fi
  [[ -z $snb || $NB > $snb ]] || NB=$snb   # the floor only rises
  if [[ -z $FP ]] && ! ((INSECURE)); then
    if ((LIST)); then UNVERIFIED_LIST=1; return 0; fi   # names and sizes only; nothing is run or unpacked
    PWROOT=1                                              # the default: the password vouches for the key
  fi
  if [[ -z $FP ]] && ! ((PWROOT)); then
    say "WARNING: --insecure: kit NOT verified. Whoever controls the kit repo controls what you install."
    # mark the tree before anything is unpacked into it (tar can add files, never remove these)
    ((LIST)) || { mkdir -p "$SDIR"; echo "$ROOT" > "$SDIR/root"
      echo "installed with --insecure $(date -u +%FT%TZ)" > "$INSEC_CONF"
      rm -f "$INSEC_MARK"; echo "installed with --insecure: delete this tree to trust it" > "$INSEC_MARK"; }
    return 0
  fi
  local f tainted=0
  [[ -e $INSEC_CONF || -L $INSEC_CONF ]] && tainted=1
  # in-tree state files are never written by a verified run (any type, dangling links included)
  for f in .kit-insecure .kit-installed .kit-fingerprint; do [[ -e $ROOT/$f || -L $ROOT/$f ]] && tainted=1; done
  [[ -L $CACHE ]] && tainted=1
  if ((tainted)); then
    die "this tree was installed unverified; delete it and reinstall with the fingerprint:
       rm -rf '$ROOT' '$SDIR'
       bash setup.sh --root '$ROOT'   (password; or --fingerprint SHA256:... --not-before DATE)
       (anything an unverified install unpacked may be planted; a verified run cannot tell it apart)"
  fi
}
check_date() {  # after manifest.json is verified: refuse rollback; the floor becomes this snapshot
  [[ -n $FP ]] || return 0
  local created; created=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("created", ""))' "$1")
  [[ $created =~ $DATE_RE ]] || die "signed manifest has no valid 'created' date"
  [[ -z $NB || ! $created < $NB ]] || die "this snapshot ($created) is older than $NB: an old kit is being served (rollback). STOP."
  [[ -n $NB ]] || say "WARNING: no rollback floor (first run without --not-before): accepting the latest signed snapshot, $created"
  [[ $created > $NB ]] && NB=$created
  say "snapshot $created (not older than your floor)"
}
save_trust() {  # only once the whole chain AND the identity agree: remember FP + the new floor
  [[ -n $FP ]] || return 0
  mkdir -p "$SDIR"; echo "$ROOT" > "$SDIR/root"
  printf 'fingerprint=%s\nnot_before=%s\n' "$FP" "$NB" > "$SAVED.tmp" && mv "$SAVED.tmp" "$SAVED"
  say "fingerprint and floor saved in $SAVED"
}
self_check() {  # the running setup.sh must be the signed one; if not, install the signed one and stop
  [[ -n $FP ]] || return 0
  local me=${BASH_SOURCE[0]} want
  want=$(awk '$2 == "setup.sh" { print $1 }' "$TRUST/SHA256SUMS")
  [[ -f $me && $(sha256sum < "$me" | cut -c1-64) == "$want" ]] && return 0
  fetch setup.sh "$TRUST/setup.sh" || die "cannot get the kit's setup.sh"
  trusted setup.sh "$TRUST/setup.sh"
  chmod +x "$TRUST/setup.sh"; mv -f "$TRUST/setup.sh" "$ROOT/setup.sh"   # new inode: a running copy is not disturbed
  say "this setup.sh is not the one the kit signed (an older copy?). The signed one is now $ROOT/setup.sh."
  echo "Re-run it with the same options: bash $ROOT/setup.sh ..." >&2
  exit 3
}
trust_init() {
  [[ -n $FP ]] || return 0
  command -v ssh-keygen >/dev/null || die "please install ssh-keygen (openssh-client) to verify the kit"
  rm -rf "$TRUST"; mkdir -p "$TRUST"
  local f got
  for f in signing_key.pub SHA256SUMS SHA256SUMS.sig; do fetch "$f" "$TRUST/$f" || die "cannot get $f: this kit is not signed. STOP."; done
  head -1 "$TRUST/signing_key.pub" | cut -d' ' -f1,2 > "$TRUST/key.pub"   # one key, no options, no comment
  grep -qxE 'ssh-ed25519 [A-Za-z0-9+/]+=*' "$TRUST/key.pub" || die "signing_key.pub is not a plain ssh-ed25519 key. STOP."
  got=$(ssh-keygen -lf "$TRUST/key.pub" 2>/dev/null | cut -d' ' -f2 || true)
  [[ $got == "$FP" ]] || die "the kit's signing key is ${got:-unreadable}, not $FP. The kit was not signed by your sender. STOP.
       (A rotated key only counts if your maintainer sent its fingerprint out of band: --new-fingerprint SHA256:...)"
  echo "snn-kit $(cat "$TRUST/key.pub")" > "$TRUST/allowed_signers"
  ssh-keygen -Y verify -f "$TRUST/allowed_signers" -I snn-kit -n snn-kit -s "$TRUST/SHA256SUMS.sig" \
    < "$TRUST/SHA256SUMS" >/dev/null 2>&1 || die "SHA256SUMS signature does not verify. STOP."
  fetch recipient.txt "$TRUST/recipient.txt" || die "cannot get recipient.txt"
  trusted recipient.txt "$TRUST/recipient.txt"
  say "kit signature OK ($FP)"
}
trusted() {  # trusted NAME FILE: FILE must equal NAME's entry in the signed SHA256SUMS
  [[ -n $FP ]] || return 0
  local want; want=$(awk -v n="$1" '$2 == n { print $1 }' "$TRUST/SHA256SUMS")
  [[ $want =~ ^[0-9a-f]{64}$ ]] || die "$1 is not listed (exactly once) in the signed SHA256SUMS. STOP."
  [[ $(sha256sum "$2" | cut -c1-64) == "$want" ]] || die "$1 does not match the signed SHA256SUMS: it was changed. STOP."
}
resolve_trust
mkdir -p "$CACHE/parts" "$SDIR"; touch "$STATE"   # only after the tree passed resolve_trust
# password-only: prompt, decrypt, take the fingerprint from inside -- nothing else from the kit is
# read before the chain below verifies (then identity.age itself must match the signed SHA256SUMS)
if ((PWROOT)); then derive_fp; fi
trust_init
if ((PWROOT)) && [[ -z $KEYFILE ]]; then trusted identity.age "$CACHE/identity.age"; fi

fetch manifest.json "$CACHE/manifest.json"
trusted manifest.json "$CACHE/manifest.json"
check_date "$CACHE/manifest.json"
self_check
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
((UNVERIFIED_LIST)) && say "UNVERIFIED listing (no fingerprint, no password): names and sizes as the kit repo claims them; nothing was run or installed"
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

# ---- the identity: unlocked once (in password-only mode it already was, to find the fingerprint)
if grep -q '"encrypted": true' "$SEL"; then unlock_identity; fi
save_trust

if [[ -n $FP && -s $KEYDIR/id ]] && command -v age-keygen >/dev/null \
  && [[ $(age-keygen -y "$KEYDIR/id" 2>/dev/null) != "$(cat "$TRUST/recipient.txt")" ]]; then
  say "warning: this key is not the kit's (signed) recipient.txt key; decryption will fail"
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
    out.append(q["asset"] + ":" + q["sha256"] + ":" + str(int(q["size"])))
print("\n".join(out))
EOF
  )
  ((${#F[@]} >= 5)) || die "manifest entry failed validation: ${line:0:80}"
  name=${F[0]} enc=${F[1]} dest=${F[2]} key=${F[3]} parts=("${F[@]:4}")
  say "$name"
  files=()
  for p in "${parts[@]}"; do
    IFS=: read -r a sha size <<<"$p"; f=$CACHE/parts/$a
    if ! echo "$sha  $f" | sha256sum -c --quiet - >/dev/null 2>&1; then
      # a partial file resumes (curl -C -); a full-size wrong one would "resume" into the same mismatch forever
      [[ -f $f ]] && (($(wc -c < "$f") >= size)) && rm -f "$f"
      fetch "$a" "$f"
      echo "$sha  $f" | sha256sum -c --quiet - || { rm -f "$f"; die "$a: checksum mismatch (corrupt or substituted download)"; }
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
  if [[ -n $FP ]]; then echo "$key"; else echo "$key@insecure"; fi >> "$STATE"; NEW=$((NEW + 1))
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
if [[ -f $0 && $(cd "$(dirname "$0")" && pwd -P)/$(basename "$0") != "$ROOT/setup.sh" ]]; then
  cp "$0" "$ROOT/setup.sh.tmp.$$" && mv -f "$ROOT/setup.sh.tmp.$$" "$ROOT/setup.sh"   # never write through a link
elif [[ ! -f $ROOT/setup.sh ]]; then
  fetch setup.sh "$ROOT/setup.sh.new" && (trusted setup.sh "$ROOT/setup.sh.new") && mv "$ROOT/setup.sh.new" "$ROOT/setup.sh" || rm -f "$ROOT/setup.sh.new"
fi
kit_check || true
cat >&2 <<EOF

Done. Start with $ROOT/START-HERE.md.
$(if [[ -n $FP ]]; then echo "Add layers any time: bash $ROOT/setup.sh --root $ROOT --layers 'runs/*'
  (it verifies against the fingerprint saved in $SAVED; health check: --check)."
else echo "UNVERIFIED install (--insecure). To trust this tree, delete it and reinstall with the fingerprint:
  rm -rf '$ROOT' '$SDIR'; bash setup.sh --fingerprint SHA256:... --not-before DATE"; fi)
Claude Code plugins + MCP servers: bash $CK/setup-claude.sh (or re-run setup with --claude).
EOF
