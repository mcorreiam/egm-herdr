#!/usr/bin/env bash
# egm-herdr installer.
# 1. Clones/pins the upstream EGM bundle (personas + standards are canonical there).
# 2. Records absolute paths + integrity metadata under ~/.config/egm-herdr/.
# 3. Merges agents/commands/skills of this adapter into the user's global
#    opencode config, with a timestamped backup first.
#
# Env overrides:
#   EGM_COMMIT       upstream commit/branch to pin (default: main)
#   EGM_UPSTREAM_DIR default: ~/tools/elephant-goldfish-model
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EGM_COMMIT="${EGM_COMMIT:-main}"
EGM_UPSTREAM_DIR="${EGM_UPSTREAM_DIR:-$HOME/tools/elephant-goldfish-model}"
OPENCODE_GLOBAL="${OPENCODE_GLOBAL:-$HOME/.config/opencode/opencode.json}"
META_DIR="$HOME/.config/egm-herdr"

log() { printf '[egm-herdr] %s\n' "$*"; }

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

# --- 1. Upstream bundle ------------------------------------------------------
if [ -d "$EGM_UPSTREAM_DIR/.git" ]; then
  log "Updating existing upstream clone at $EGM_UPSTREAM_DIR"
  git -C "$EGM_UPSTREAM_DIR" fetch --all --quiet
else
  log "Cloning google/elephant-goldfish-model to $EGM_UPSTREAM_DIR"
  mkdir -p "$(dirname "$EGM_UPSTREAM_DIR")"
  git clone --quiet https://github.com/google/elephant-goldfish-model "$EGM_UPSTREAM_DIR"
fi
git -C "$EGM_UPSTREAM_DIR" checkout --quiet "$EGM_COMMIT"
UPSTREAM_SHA="$(git -C "$EGM_UPSTREAM_DIR" rev-parse HEAD)"

for d in agents resources/document_standards skills; do
  [ -d "$EGM_UPSTREAM_DIR/$d" ] || { echo "Upstream missing $d/ — refusing to install" >&2; exit 1; }
done
log "Upstream pinned at $EGM_COMMIT ($UPSTREAM_SHA)"

# --- 2. Adapter metadata -----------------------------------------------------
mkdir -p "$META_DIR"
python3 - "$REPO_ROOT" "$EGM_UPSTREAM_DIR" "$UPSTREAM_SHA" "$EGM_COMMIT" <<'PY'
import hashlib, json, pathlib, sys
repo_root, upstream_root, sha, ref = sys.argv[1:5]
meta = {
    "repo_root": repo_root,
    "upstream_root": upstream_root,
    "upstream_ref": ref,
    "upstream_sha": sha,
    "hashes": {
        p.relative_to(repo_root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted((pathlib.Path(repo_root) / "skills").rglob("*"))
        if p.is_file()
    },
}
(pathlib.Path.home() / ".config/egm-herdr/installation.json").write_text(
    json.dumps(meta, indent=2) + "\n", encoding="utf-8")
PY
log "Wrote $META_DIR/installation.json"

# --- 3. Merge into the global opencode config --------------------------------
BACKUP="$OPENCODE_GLOBAL.bak.$(date +%Y%m%d%H%M%S)"
if [ -f "$OPENCODE_GLOBAL" ]; then
  cp "$OPENCODE_GLOBAL" "$BACKUP"
  log "Backup of your opencode config: $BACKUP"
fi

python3 - "$REPO_ROOT" "$EGM_UPSTREAM_DIR" "$OPENCODE_GLOBAL" <<'PY'
import json, pathlib, sys
repo_root, upstream_root, cfg_path = sys.argv[1:4]
cfg_path = pathlib.Path(cfg_path)
cfg_path.parent.mkdir(parents=True, exist_ok=True)

cfg = json.loads(cfg_path.read_text(encoding="utf-8")) if cfg_path.exists() else {}

adapter = json.loads((pathlib.Path(repo_root) / "opencode.json").read_text(encoding="utf-8"))
resolved = json.loads(json.dumps(adapter).replace("__REPO_ROOT__", repo_root)
                                        .replace("__UPSTREAM_ROOT__", upstream_root))

# skills.paths: add adapter skills path if not present
paths = cfg.setdefault("skills", {}).setdefault("paths", [])
if resolved["skills"]["paths"][0] not in paths:
    paths.append(resolved["skills"]["paths"][0])

# agents: install/overwrite egm + egm-reviewer (backup exists)
cfg.setdefault("agent", {}).update(resolved["agent"])

# commands: install/overwrite the five egm-* commands
cfg.setdefault("command", {}).update(resolved["command"])

cfg_path.write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")
print("Merged agents (egm, egm-reviewer), commands (egm-*), skills path into", cfg_path)
PY

cat <<EOF

Done. Next steps:
  1. Restart opencode (config and skills load at startup).
  2. Open a Herdr pane in your target project and run: opencode --agent egm
  3. Verify offline: $REPO_ROOT/scripts/verify.sh

Upstream pinned at $UPSTREAM_SHA (ref: $EGM_COMMIT).
To pin an exact commit: EGM_COMMIT=<sha> ./scripts/install.sh
EOF
