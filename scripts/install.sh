#!/usr/bin/env bash
# egm-herdr installer.
# 1. Clones/pins the upstream EGM bundle (personas + standards are canonical there).
# 2. Records absolute paths + integrity metadata under ~/.config/egm-herdr/.
# 3. Installs the adapter the way THIS opencode build actually loads things:
#    - agents:   ~/.config/opencode/agents/egm*.md        (file-based agents)
#    - commands: ~/.config/opencode/commands/egm-*.md     (file-based commands)
#    - skill:    ~/.config/opencode/skills/egm-herdr -> symlink into this repo
#    It NEVER edits ~/.config/opencode/opencode.json(c).
#
# Env overrides:
#   EGM_COMMIT       upstream commit SHA or branch to pin (default: main)
#   EGM_UPSTREAM_DIR default: ~/tools/elephant-goldfish-model
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EGM_COMMIT="${EGM_COMMIT:-main}"
EGM_UPSTREAM_DIR="${EGM_UPSTREAM_DIR:-$HOME/tools/elephant-goldfish-model}"
OC="$HOME/.config/opencode"
META_DIR="$HOME/.config/egm-herdr"

log() { printf '[egm-herdr] %s\n' "$*"; }

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

# --- 1. Upstream bundle (pinned, remote-validated) ---------------------------
if [ -d "$EGM_UPSTREAM_DIR/.git" ]; then
  REMOTE="$(git -C "$EGM_UPSTREAM_DIR" remote get-url origin 2>/dev/null || true)"
  case "$REMOTE" in
    *google/elephant-goldfish-model*) ;;
    *) echo "Refusing: $EGM_UPSTREAM_DIR has origin '$REMOTE', not google/elephant-goldfish-model" >&2; exit 1 ;;
  esac
  log "Updating existing upstream clone at $EGM_UPSTREAM_DIR"
  git -C "$EGM_UPSTREAM_DIR" fetch --quiet origin
else
  log "Cloning google/elephant-goldfish-model to $EGM_UPSTREAM_DIR"
  mkdir -p "$(dirname "$EGM_UPSTREAM_DIR")"
  git clone --quiet https://github.com/google/elephant-goldfish-model "$EGM_UPSTREAM_DIR"
fi

if [[ "$EGM_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  git -C "$EGM_UPSTREAM_DIR" checkout --quiet --detach "$EGM_COMMIT"
else
  # branch: reset local branch to the fetched origin state (real pin, repeatable)
  git -C "$EGM_UPSTREAM_DIR" fetch --quiet origin "$EGM_COMMIT"
  git -C "$EGM_UPSTREAM_DIR" checkout --quiet -B "$EGM_COMMIT" "origin/$EGM_COMMIT"
fi
UPSTREAM_SHA="$(git -C "$EGM_UPSTREAM_DIR" rev-parse HEAD)"

for d in agents resources/document_standards skills; do
  [ -d "$EGM_UPSTREAM_DIR/$d" ] || { echo "Upstream missing $d/ — refusing to install" >&2; exit 1; }
done
log "Upstream pinned at $EGM_COMMIT ($UPSTREAM_SHA)"

# --- 2. Adapter metadata ------------------------------------------------------
mkdir -p "$META_DIR" /tmp/egm-herdr/prompts
python3 - "$REPO_ROOT" "$EGM_UPSTREAM_DIR" "$UPSTREAM_SHA" "$EGM_COMMIT" <<'PY'
import hashlib, json, pathlib, sys
repo_root, upstream_root, sha, ref = sys.argv[1:5]
repo, upstream = pathlib.Path(repo_root), pathlib.Path(upstream_root)
paths = {}
def add(p, base):
    if p.is_file():
        paths[str(p.relative_to(base))] = hashlib.sha256(p.read_bytes()).hexdigest()
for p in sorted((repo / "skills").rglob("*")): add(p, repo)
for p in sorted((repo / "agents").glob("*.md")): add(p, repo)
for p in sorted((repo / "commands").glob("*.md")): add(p, repo)
add(repo / "config/egm-herdr.json", repo)
for name in ("comprehension", "design_critic", "structural", "style", "zoom_out",
             "implementation_readiness", "codebase_details", "inventive_catalyst"):
    add(upstream / "agents" / f"{name}.md", upstream)
(pathlib.Path.home() / ".config/egm-herdr/installation.json").write_text(
    json.dumps({
        "repo_root": str(repo), "upstream_root": str(upstream),
        "upstream_ref": ref, "upstream_sha": sha, "hashes": paths,
    }, indent=2) + "\n", encoding="utf-8")
(pathlib.Path.home() / ".config/egm-herdr/paths.json").write_text(
    json.dumps({"repo_root": str(repo), "upstream_root": str(upstream)}) + "\n",
    encoding="utf-8")
PY
log "Wrote $META_DIR/paths.json and installation.json"

# --- 3a. Agents (file-based, the format this opencode build loads) ------------
mkdir -p "$OC/agents"
for src in "$REPO_ROOT"/agents/*.md; do
  name="$(basename "$src")"
  dst="$OC/agents/$name"
  [ -f "$dst" ] && cp "$dst" "$dst.bak.$(date +%Y%m%d%H%M%S)"
  python3 - "$src" "$dst" "$REPO_ROOT" "$EGM_UPSTREAM_DIR" <<'PY'
import pathlib, sys
src, dst, repo, upstream = sys.argv[1:5]
text = pathlib.Path(src).read_text(encoding="utf-8")
text = text.replace("__REPO_ROOT__", repo).replace("__UPSTREAM_ROOT__", upstream)
pathlib.Path(dst).write_text(text, encoding="utf-8")
PY
  log "agent installed: $dst"
done

# --- 3b. Commands ---------------------------------------------------------------
mkdir -p "$OC/commands"
for src in "$REPO_ROOT"/commands/*.md; do
  name="$(basename "$src")"
  dst="$OC/commands/$name"
  [ -f "$dst" ] && cp "$dst" "$dst.bak.$(date +%Y%m%d%H%M%S)"
  cp "$src" "$dst"
  log "command installed: $dst"
done

# --- 3c. Skill (symlink so upstream of THIS repo updates the skill) -----------
mkdir -p "$OC/skills"
SKILL_LINK="$OC/skills/egm-herdr"
if [ -L "$SKILL_LINK" ]; then
  rm "$SKILL_LINK"
elif [ -e "$SKILL_LINK" ]; then
  echo "Refusing to overwrite existing non-symlink $SKILL_LINK" >&2; exit 1
fi
ln -s "$REPO_ROOT/skills/egm-herdr" "$SKILL_LINK"
log "skill linked: $SKILL_LINK -> $REPO_ROOT/skills/egm-herdr"

cat <<EOF

Done. Next steps:
  1. Restart opencode (agents, commands and skills load at startup).
  2. Verify: $REPO_ROOT/scripts/verify.sh
  3. Open a Herdr pane in your target project and run: /egm-review <draft>
     (or start the Elephant directly: opencode mini --model opencode-go/glm-5.3 --agent egm)

Upstream pinned at $UPSTREAM_SHA (ref: $EGM_COMMIT).
For a reproducible pin: EGM_COMMIT=<full-sha> ./scripts/install.sh
EOF
