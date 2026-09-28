# snn-research kit

A self-contained snapshot of a research workspace (computational neuroscience), for handing
over or restoring from scratch.

- The workspace itself — code, notes, reports, git history — is **encrypted**
  ([age](https://age-encryption.org), one password unlocks it all).
- Raw experiment outputs (`runs/*` assets) are **public**, unencrypted, with credentials redacted.

## Install

```bash
curl -fsSLO https://raw.githubusercontent.com/spicysauce1955-stack/snn-research-kit/main/setup.sh
bash setup.sh            # enter the kit password
```

Two ways in, stated honestly:

- **Simple: URL + password.** Verified from the moment `setup.sh` starts (the password also
  names the key that signed the kit, and every file is checked against that signature before
  anything is installed), but it trusts that the GitHub repo is genuine when you first
  download `setup.sh`: a trojaned first `setup.sh` could steal the password.
- **Strong: also the fingerprint block from your sender** (below). Protects even if the repo
  was compromised.

Note: this kit uses one password for everything, including the maintainer's signing key, so
only share it with people you would trust to publish the kit.
Either way the key and snapshot date are saved under `~/.config/snn-kit/roots/`, so later runs
verify on their own and refuse an older kit:

```bash
bash ~/.superset/projects/setup.sh --list             # layers and sizes
bash ~/.superset/projects/setup.sh --layers 'runs/*'  # add layers later
```

The simple mode's first install also has no rollback floor (you get the latest signed
snapshot) and cannot tell a leaked *retired* signing key from the current one; the strong mode
can. `bash setup.sh --list` without a password prints an *unverified* listing.

### Stronger: if your sender gave you a fingerprint

Then check `setup.sh` before running anything. The fingerprint and date came with the password;
if the copy of these commands in your message differs from this page, use the message's.

```bash
mkdir -p snn-kit && cd snn-kit || exit
FP=SHA256:... NB=...    # both from your handover message, never from this repo
K=https://raw.githubusercontent.com/spicysauce1955-stack/snn-research-kit/main
for f in setup.sh SHA256SUMS SHA256SUMS.sig signing_key.pub; do curl -fsSLO "$K/$f"; done
head -1 signing_key.pub | cut -d' ' -f1,2 > key.pub && grep -qxE 'ssh-ed25519 [A-Za-z0-9+/]+=*' key.pub &&
[ "$(ssh-keygen -lf key.pub | cut -d' ' -f2)" = "$FP" ] && echo "snn-kit $(cat key.pub)" > allowed_signers &&
ssh-keygen -Y verify -f allowed_signers -I snn-kit -n snn-kit -s SHA256SUMS.sig < SHA256SUMS &&
grep '  setup\.sh$' SHA256SUMS | sha256sum -c - && echo 'KIT VERIFIED' || echo 'STOP: do not run setup.sh'
bash setup.sh --fingerprint "$FP" --not-before "$NB"
```

A new fingerprint only ever arrives the way the first one did, from your sender, out of band
(`bash setup.sh --new-fingerprint SHA256:...`). Never believe one from this repo, this page or
a script's output.

Needs Linux (macOS with GNU coreutils) and `curl tar zstd git python3 ssh-keygen` (and `age`,
fetched automatically on Linux x86-64). `--insecure` skips all verification; don't.

`manifest.json` lists the current snapshot; `manifests/` keeps every earlier one. Assets live
in the `store` release and are content-addressed; they are kept until the maintainer prunes the
ones the current snapshot no longer uses (after a key rotation), so older snapshots may no
longer be installable.
