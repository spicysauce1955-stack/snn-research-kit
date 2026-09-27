# snn-research kit

A self-contained snapshot of a research workspace (computational neuroscience), for handing
over or restoring from scratch.

- The workspace itself — code, notes, reports, git history — is **encrypted**
  ([age](https://age-encryption.org), one password unlocks it all).
- Raw experiment outputs (`runs/*` assets) are **public**, unencrypted, with credentials redacted.

## Install

```bash
curl -fsSLO https://raw.githubusercontent.com/spicysauce1955-stack/snn-research-kit/main/setup.sh
bash setup.sh --list     # see the layers and sizes
bash setup.sh            # choose layers, enter the password
```

Needs Linux (macOS with GNU coreutils) and `curl tar zstd git python3` (and `age`, fetched automatically on
Linux x86-64). Layers can be added later: `bash setup.sh --layers 'runs/*'`.

`manifest.json` lists the current snapshot; `manifests/` keeps every earlier one. Assets live
in the `store` release and are content-addressed, so old snapshots stay installable.
