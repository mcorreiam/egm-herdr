#!/usr/bin/env bash
# egm-herdr offline verification.
# Validates what the SKILL.md relies on, using the RESOLVED opencode config
# (debug agents) as source of truth. Does NOT prove live model behavior,
# runtime permission enforcement, or Goldfish isolation — the manual
# isolation procedure in README.md covers those.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
META_DIR="$HOME/.config/egm-herdr"
OC="$HOME/.config/opencode"
STATUS=0

ok()   { printf '  [OK]   %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; STATUS=1; }

echo "== egm-herdr verification =="

# 1. Environment
if [ "${HERDR_ENV:-}" = 1 ]; then ok "HERDR_ENV=1 (inside a Herdr pane)"; else
  warn "Not inside a Herdr-managed pane (HERDR_ENV unset) — reviewer dispatch will refuse to run"
fi

# 2. Metadata + paths (single source of truth)
for f in paths.json installation.json; do
  [ -f "$META_DIR/$f" ] && ok "$f present" || fail "missing $META_DIR/$f — run scripts/install.sh"
done

if [ -f "$META_DIR/installation.json" ]; then
  python3 - "$REPO_ROOT" <<'PY' && ok "adapter hashes match installation record" \
    || fail "adapter files changed since install — re-run scripts/install.sh"
import hashlib, json, pathlib, sys
meta = json.loads((pathlib.Path.home()/".config/egm-herdr/installation.json").read_text())
repo = pathlib.Path(sys.argv[1])
for rel, want in meta.get("hashes", {}).items():
    if rel.startswith("agents/"):
        continue  # installed copies carry resolved paths; sources keep placeholders
    p = repo / rel
    if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest() != want:
        sys.exit(1)
PY
fi

# 3. Upstream bundle
UPSTREAM="$(python3 -c "import json,pathlib;print(json.loads((pathlib.Path.home()/'.config/egm-herdr/paths.json').read_text())['upstream_root'])" 2>/dev/null || true)"
if [ -n "$UPSTREAM" ] && [ -d "$UPSTREAM/agents" ] && [ -d "$UPSTREAM/resources/document_standards" ]; then
  ok "upstream bundle at $UPSTREAM"
  for f in comprehension.md design_critic.md structural.md style.md zoom_out.md \
           implementation_readiness.md codebase_details.md inventive_catalyst.md; do
    [ -f "$UPSTREAM/agents/$f" ] || fail "upstream persona missing: agents/$f"
  done
else
  fail "upstream bundle not installed or incomplete — run scripts/install.sh"
fi

# 4. Reviewer matrix (valid + unique reports)
python3 - "$REPO_ROOT/config/egm-herdr.json" <<'PY' && ok "reviewer matrix valid (8 reviewers, unique reports, kinds, models)" \
  || fail "reviewer matrix invalid — fix config/egm-herdr.json"
import json, sys
m = json.loads(open(sys.argv[1]).read())
assert len(m["reviewers"]) == 8
reports = set()
for name, r in m["reviewers"].items():
    assert r["kind"] in ("opencode", "agy"), name
    assert r.get("model"), name
    assert r.get("persona_file"), name
    assert r.get("report"), name
    assert r["report"] not in reports, f"duplicate report: {r['report']}"
    reports.add(r["report"])
for k in ("implementer", "fallbacks", "brainstorm_reviewers", "review_stages"):
    assert m.get(k), k
PY

# 5. Installed adapter surfaces (file-based, no config edits)
for a in egm.md egm-reviewer.md egm-implementer.md; do
  [ -f "$OC/agents/$a" ] && ok "agent file: $OC/agents/$a" || fail "missing $OC/agents/$a"
done
if grep -q '__REPO_ROOT__\|__UPSTREAM_ROOT__' "$OC/agents"/*.md 2>/dev/null; then
  fail "unresolved path placeholders in installed agents"
else
  ok "installed agents have resolved absolute paths"
fi
[ -L "$OC/skills/egm-herdr" ] && ok "skill symlink: $OC/skills/egm-herdr" || fail "missing skill symlink $OC/skills/egm-herdr"
for c in egm-brainstorm egm-draft egm-review egm-resolve egm-drift-report; do
  [ -f "$OC/commands/$c.md" ] || fail "missing command $OC/commands/$c.md"
done
ok "commands present (5)" 2>/dev/null || true

# 6. RESOLVED config: agents actually loaded by this opencode build
if command -v opencode >/dev/null; then
  opencode debug agents >/tmp/egm-herdr/verify-agents.json 2>/dev/null
  python3 - /tmp/egm-herdr/verify-agents.json <<'PY' && ok "opencode loads egm, egm-reviewer, egm-implementer (resolved config)" \
    || fail "opencode does NOT load the egm agents — check $OC/agents/ and restart opencode"
import json, sys
try:
    agents = {a["id"] for a in json.load(open(sys.argv[1]))}
except Exception:
    sys.exit(1)
missing = {"egm", "egm-reviewer", "egm-implementer"} - agents
sys.exit(1 if missing else 0)
PY
else
  warn "opencode CLI not found — skipped resolved-config check"
fi

# 7. Permission semantics (ordering + SKILL coverage + no overbroad rules)
if [ -f "$REPO_ROOT/scripts/check-permissions.py" ]; then
  python3 "$REPO_ROOT/scripts/check-permissions.py" --repo-root "$REPO_ROOT" \
    && ok "permission semantics: broad-first order, SKILL shell/external coverage" \
    || fail "permission semantics violated — fix agents/*.md or SKILL.md (see output above)"
else
  warn "scripts/check-permissions.py missing — skipped permission-semantics check"
fi

echo
if [ "$STATUS" = 0 ]; then
  echo "All offline checks passed."
  echo "Remaining manual verification (see README): isolation marker test + read-only denial test."
else
  echo "Some checks failed. Fix the items above before running a review."
fi
exit "$STATUS"
