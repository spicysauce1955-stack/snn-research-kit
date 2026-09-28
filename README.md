# snn-research kit

A self-contained snapshot of a research workspace (computational neuroscience), for handing
over or restoring from scratch.

- The workspace itself — code, notes, reports, git history — is **encrypted**
  ([age](https://age-encryption.org), one password unlocks it all).
- Raw experiment outputs (`runs/*` assets) are **public**, unencrypted, with credentials redacted.

## Install

Your handover message carries the password, the fingerprint of the kit's signing key
(`SHA256:...`) and a date, with these same commands. If the two copies differ, use the one in
the message: this page is served by the repo it is meant to check.

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

The block checks that the signing key is the one you were told about, that it signed
`SHA256SUMS`, and that `setup.sh` matches it, using only `curl` and `ssh-keygen` (OpenSSH ≥ 8.1).
`setup.sh` then checks `manifest.json`, `identity.age` and `recipient.txt` the same way, every
download against the signed manifest, refuses a snapshot older than the date (an old kit
served again), and replaces itself if it is not the signed `setup.sh`. It saves the fingerprint
and date under `~/.config/snn-kit/roots/`, so later runs verify on their own:

```bash
bash ~/.superset/projects/setup.sh --list             # layers and sizes
bash ~/.superset/projects/setup.sh --layers 'runs/*'  # add layers later
```

Without a fingerprint, given or saved, `setup.sh` refuses (`--insecure` overrides; don't: a
tree installed that way can only be deleted and reinstalled). A new fingerprint only ever
arrives the way the first one did, from your sender, out of band; never believe one from this
repo, this page or a script's output.
Needs Linux (macOS with GNU coreutils) and `curl tar zstd git python3 ssh-keygen` (and `age`,
fetched automatically on Linux x86-64).

`manifest.json` lists the current snapshot; `manifests/` keeps every earlier one. Assets live
in the `store` release and are content-addressed, so old snapshots stay installable.
