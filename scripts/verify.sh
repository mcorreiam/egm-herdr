#!/usr/bin/env bash
# egm-herdr offline verification.
# Checks preconditions the SKILL.md relies on. Does NOT prove live model
# behavior, runtime permission enforcement, or Goldfish isolation — the
# manual isolation procedure in README.md covers those.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META_DIR="$HOME/.config/egm-herdr"
OPENCODE_GLOBAL="${OPENCODE_GLOBAL:-$HOME/.config/opencode/opencode.json}"
STATUS=0

ok()   { printf '  [OK]   %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; STATUS=1; }

echo "== egm-herdr verification =="

# 1. Environment
if [ "${HERDR_ENV:-}" = 1 ]; then ok "HERDR_ENV=1 (inside a Herdr pane)"; else
  fail "Not inside a Herdr-managed pane (HERDR_ENV unset) — reviewer dispatch will refuse to run"
fi

# 2. Metadata + paths
if [ -f "$META_DIR/paths.json" ]; then ok "paths.json present"; else
  fail "missing $META_DIR/paths.json — run scripts/install.sh"
fi

if [ -f "$META_DIR/installation.json" ]; then
  ok "installation.json present"
  python3 - "$REPO_ROOT" <<'PY' && echo "  [OK]   adapter skill hashes match installation record" \
    || echo "  [WARN] adapter skills changed since install — re-run scripts/install.sh"
import hashlib, json, pathlib, sys
meta = json.loads((pathlib.Path.home()/".config/egm-herdr/installation.json").read_text())
repo = pathlib.Path(sys.argv[1])
for rel, want in meta.get("hashes", {}).items():
    p = repo / rel
    if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest() != want:
        sys.exit(1)
PY
else
  fail "missing installation.json — run scripts/install.sh"
fi

# 3. Upstream bundle
UPSTREAM=$(python3 -c "import json,pathlib;p=pathlib.Path.home()/'.config/egm-herdr/installation.json';print(json.loads(p.read_text())['upstream_root'])" 2>/dev/null || true)
if [ -n "$UPSTREAM" ] && [ -d "$UPSTREAM/agents" ] && [ -d "$UPSTREAM/resources/document_standards" ]; then
  ok "upstream bundle at $UPSTREAM"
  for f in comprehension.md design_critic.md structural.md style.md zoom_out.md \
           implementation_readiness.md codebase_details.md inventive_catalyst.md; do
    [ -f "$UPSTREAM/agents/$f" ] || fail "upstream persona missing: agents/$f"
  done
else
  fail "upstream bundle not installed or incomplete — run scripts/install.sh"
fi

# 4. Reviewer matrix
python3 - "$REPO_ROOT/config/egm-herdr.json" <<'PY' && ok "reviewer matrix valid (8 reviewers, kinds, models, persona files)" \
  || fail "reviewer matrix invalid — fix config/egm-herdr.json"
import json, sys
m = json.loads(open(sys.argv[1]).read())
assert len(m["reviewers"]) == 8
for name, r in m["reviewers"].items():
    assert r["kind"] in ("opencode", "agy"), name
    assert r.get("model"), name
    assert r.get("persona_file"), name
    assert r.get("report"), name
for k in ("orchestrator", "implementer", "fallbacks", "brainstorm_reviewers", "review_stages"):
    assert m.get(k), k
PY

# 5. Global opencode config
if [ -f "$OPENCODE_GLOBAL" ]; then
  python3 - "$OPENCODE_GLOBAL" "$REPO_ROOT" <<'PY' && ok "global opencode config has egm agents, commands and skills path (placeholders resolved)" \
    || fail "global opencode config incomplete — re-run scripts/install.sh"
import json, sys
cfg = json.loads(open(sys.argv[1]).read())
blob = json.dumps(cfg)
assert "egm" in cfg.get("agent", {}), "agent egm missing"
assert "egm-reviewer" in cfg.get("agent", {}), "agent egm-reviewer missing"
assert "egm-review" in cfg.get("command", {}), "commands missing"
assert sys.argv[2] + "/skills" in cfg.get("skills", {}).get("paths", []), "skills path missing"
assert "__REPO_ROOT__" not in blob and "__UPSTREAM_ROOT__" not in blob, "unresolved placeholders"
perm = cfg["agent"]["egm-reviewer"].get("permission", {})
assert perm.get("glob") == "allow" and perm.get("grep") == "deny", "reviewer permissions wrong"
assert perm.get("read", {}).get("*.env") == "deny", ".env read not denied for reviewer"
PY
else
  fail "no global opencode config at $OPENCODE_GLOBAL — run scripts/install.sh"
fi

echo
if [ "$STATUS" = 0 ]; then
  echo "All offline checks passed."
  echo "Remaining manual verification (see README): isolation marker test + read-only denial test."
else
  echo "Some checks failed. Fix the items above before running a review."
fi
exit "$STATUS"
