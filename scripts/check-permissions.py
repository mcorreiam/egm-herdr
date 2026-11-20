#!/usr/bin/env python3
"""egm-herdr permission-semantics check.

Catches what `verify.sh` sections 1-6 cannot: the *meaning* of the
permission lists, not just their presence.

1. Ordering (last-match-wins): for every action with a broad `"*"` rule,
   the broad rule must come FIRST and specific exceptions AFTER it.
   Checked against the RESOLVED config (`opencode debug agents`, the
   source of truth this build actually enforces), with a source-file
   fallback when the CLI is unavailable.
2. Shell coverage: every shell command in SKILL.md ```bash blocks (plus
   documented prose commands like `agy models`) must match an `allow`
   prefix on the egm agent. A new SKILL command without a matching
   allow fails here instead of mid-run as a permission prompt.
3. External-directory coverage: every absolute directory the SKILL and
   the egm agent body reference must match an `allow` prefix; and no
   overbroad rule (e.g. `~/projects/*`) may exist.

Exit 0 when all checks pass, 1 with a human-readable report otherwise.
"""
import json
import pathlib
import re
import shlex
import subprocess
import sys

REPO = pathlib.Path(sys.argv[sys.argv.index("--repo-root") + 1]) \
    if "--repo-root" in sys.argv else pathlib.Path(__file__).resolve().parent.parent
SKILL = REPO / "skills/egm-herdr/SKILL.md"
EGM_SRC = REPO / "agents/egm.md"
FAILURES: list[str] = []


def fail(msg: str) -> None:
    FAILURES.append(msg)
    print(f"  [FAIL] {msg}")


def ok(msg: str) -> None:
    print(f"  [OK]   {msg}")


def load_resolved() -> dict | None:
    """Agent id -> ordered permission list, from `opencode debug agents`."""
    try:
        out = subprocess.run(["opencode", "debug", "agents"],
                             capture_output=True, text=True, timeout=30)
        if out.returncode != 0:
            return None
        agents = json.loads(out.stdout)
        if isinstance(agents, dict):  # some builds wrap in {"agents": [...]}
            agents = agents.get("agents", [])
        return {a["id"]: a.get("permissions", []) for a in agents}
    except Exception:
        return None


def parse_source_permissions(text: str) -> list[dict]:
    """Fallback: frontmatter permission lines in file order."""
    perms: list[dict] = []
    action = None
    for line in text.splitlines():
        m = re.match(r"^  (\w+):\s*$", line)
        if m:
            action = m.group(1)
            continue
        m = re.match(r'^\s+"([^"]+)":\s*(allow|ask|deny)\s*$', line)
        if m and action:
            perms.append({"action": action, "resource": m.group(1),
                          "effect": m.group(2)})
    return perms


def matches(rule_res: str, target: str) -> bool:
    """Does rule resource `rule_res` also match everything `target` matches?"""
    if rule_res == "*":
        return True
    return rule_res == target


def check_ordering(agent_id: str, source: list[dict],
                   resolved: list[dict] | None) -> None:
    # Two halves. (1) Source intent: within the agent FILE, a divergent
    # exception must come AFTER the broad '*' (broad first) — this is the
    # authoring bug that buried the reviewer's report-write allow.
    # (2) Effective outcome: for each source exception, the LAST
    # same-action resolved rule matching its paths must carry the source
    # effect. Server defaults prepended before the file rules are supposed
    # to be overridden by the file — that is intent, not burial.
    by_action: dict[str, list[dict]] = {}
    for p in source:
        by_action.setdefault(p["action"], []).append(p)
    res_by_action: dict[str, list[dict]] = {}
    for p in (resolved or []):
        res_by_action.setdefault(p["action"], []).append(p)
    bad_order, bad_effect, count = [], [], 0
    for action, items in by_action.items():
        broad_at = [i for i, p in enumerate(items)
                    if p["resource"] == "*"]
        broad_eff = broad_at and items[broad_at[0]]["effect"]
        for i, p in enumerate(items):
            if p["resource"] == "*":
                continue
            count += 1
            if broad_at and p["effect"] != broad_eff and i < broad_at[0]:
                bad_order.append(f"{action} '{p['resource']}'")
            if resolved is not None:
                same = res_by_action.get(action, [])
                matching = [q for q in same
                            if matches(q["resource"], p["resource"])]
                if matching and matching[-1]["effect"] != p["effect"]:
                    bad_effect.append(f"{action} '{p['resource']}' (file: "
                                      f"{p['effect']}, live: "
                                      f"{matching[-1]['effect']})")
    if bad_order:
        fail(f"{agent_id}: exception(s) BEFORE broad '*' in the agent file "
             f"(last-match-wins buries them): " + ", ".join(bad_order))
    if bad_effect:
        fail(f"{agent_id}: live config contradicts the agent file: "
             + "; ".join(bad_effect))
    if not bad_order and not bad_effect:
        extra = " + live outcomes match" if resolved is not None else ""
        ok(f"{agent_id}: broad-first source order ({count} exception(s))"
           + extra)


def bash_blocks(skill_text: str) -> list[str]:
    return re.findall(r"```bash\n(.*?)```", skill_text, re.DOTALL)


def logical_lines(block: str) -> list[str]:
    block = re.sub(r"\\\n", " ", block)
    lines = []
    for raw in block.splitlines():
        line = raw.strip()
        if line.startswith("$"):
            line = line[1:].strip()
        if not line or line.startswith("#"):
            continue
        lines.append(line)
    return lines


def skill_commands(skill_text: str) -> list[str]:
    """Distinct command shapes the SKILL procedure runs, in `allow`-rule form."""
    shapes: list[str] = []
    for block in bash_blocks(skill_text):
        for line in logical_lines(block):
            try:
                toks = shlex.split(line, posix=True)
            except Exception:
                toks = line.split()
            if not toks:
                continue
            verb = toks[0]
            if verb == "herdr":
                shapes.append("herdr")
            elif verb in ("test", "mkdir", "echo", "pwd", "ls", "head",
                          "tail", "wc", "find", "grep", "stat", "sort",
                          "uniq", "sleep"):
                shapes.append(verb)
            elif verb == "sed" and len(toks) > 1:
                shapes.append(f"sed {toks[1]}")
            elif verb == "git" and len(toks) > 1:
                shapes.append(f"git {toks[1]}")
            else:
                # Unknown verb: deny-by-default. If the SKILL procedure
                # gains a command like `awk` or `cd`, the check fails
                # until a matching allow is deliberately added.
                shapes.append(verb)
            # inner $(cat <path>) subcommands are extracted below by regex
    for m in re.finditer(r"cat\s+(/[^\s\"'`)\\]+)", skill_text):
        shapes.append(f"cat {m.group(1)}")
    if re.search(r"`agy models`", skill_text):
        shapes.append("agy models")
    # de-dup, preserve order
    seen, out = set(), []
    for s in shapes:
        if s not in seen:
            seen.add(s)
            out.append(s)
    return out


def rule_covers(rules: list[dict], shape: str) -> bool:
    """Does any shell `allow` rule cover this command shape?"""
    if shape.startswith("cat "):
        path = shape[4:]
        for r in rules:
            res = r["resource"]
            if r["effect"] != "allow" or not res.startswith("cat "):
                continue
            prefix = res[4:].rstrip("*")
            if path.startswith(prefix) or path == prefix.rstrip("/"):
                return True
        return False
    for r in rules:
        if r["effect"] != "allow":
            continue
        if r["resource"] == f"{shape} *" or r["resource"] == shape:
            return True
    return False


def check_shell_coverage(shapes: list[str], shell_rules: list[dict]) -> None:
    uncovered = [s for s in shapes if not rule_covers(shell_rules, s)]
    if uncovered:
        fail("SKILL commands without a matching shell allow: "
             + ", ".join(f"'{s}'" for s in uncovered)
             + " — add the prefix to agents/egm.md or stop using the command")
    else:
        ok(f"SKILL shell coverage ({len(shapes)} command shape(s) all allowed)")


def check_dangerous_absent(shell_rules: list[dict]) -> None:
    bad = [r["resource"] for r in shell_rules
           if r["effect"] == "allow" and re.match(
               r"^(bash|timeout|python3?|sh|perl|ruby|node|opencode)\b",
               r["resource"])]
    if bad:
        fail("overbroad execution allows (must stay gated): "
             + ", ".join(bad))
    else:
        ok("no execution-wrapper allows (bash -c / timeout / python3 stay gated)")


def referenced_dirs(skill_text: str, agent_text: str,
                     paths: dict) -> list[str]:
    refs = set()
    for text in (skill_text, agent_text):
        for m in re.finditer(r"~\/\.config\/egm-herdr(?:\/\S*)?", text):
            refs.add(str(pathlib.Path.home() / ".config/egm-herdr"))
        for m in re.finditer(r"\/tmp\/egm-herdr(?:\/\S*)?", text):
            refs.add("/tmp/egm-herdr")
        for m in re.finditer(r"\/tmp\/opencode(?:\/\S*)?", text):
            refs.add("/tmp/opencode")
        if "__REPO_ROOT__" in text or "<repo_root>" in text \
                or "repo_root" in text:
            refs.add(paths.get("repo_root", ""))
        if "__UPSTREAM_ROOT__" in text or "<upstream_root>" in text \
                or "upstream_root" in text:
            refs.add(paths.get("upstream_root", ""))
    return sorted(r for r in refs if r)


def check_external_coverage(dirs: list[str], ext_rules: list[dict]) -> None:
    allows = [r["resource"].rstrip("*").rstrip("/") for r in ext_rules
              if r["effect"] == "allow"]
    missing = [d for d in dirs
               if not any(d == a or d.startswith(a + "/") for a in allows)]
    if missing:
        fail("referenced directories without an external_directory allow: "
             + ", ".join(missing))
    else:
        ok(f"external_directory coverage ({len(dirs)} referenced dir(s))")
    broad = [r["resource"] for r in ext_rules
             if r["effect"] == "allow" and r["resource"] in
             ("~/projects/*", "/home/marco/projects/*", "~/*", "/*")]
    if broad:
        fail("overbroad external_directory allows (rejected pattern, "
             "fix the path instead): " + ", ".join(broad))
    else:
        ok("no overbroad external_directory allows")


def main() -> int:
    skill_text = SKILL.read_text(encoding="utf-8")
    agent_text = EGM_SRC.read_text(encoding="utf-8")
    try:
        paths = json.loads((pathlib.Path.home()
                            / ".config/egm-herdr/paths.json").read_text())
    except Exception:
        paths = {"repo_root": str(REPO),
                 "upstream_root": str(pathlib.Path.home()
                                      / "tools/elephant-goldfish-model")}

    resolved = load_resolved()
    egm_src_rules = parse_source_permissions(agent_text)
    rev_src_rules = parse_source_permissions(
        (REPO / "agents/egm-reviewer.md").read_text(encoding="utf-8"))
    # The installer resolves placeholders into the live config — do the
    # same before comparing source intent with live outcomes.
    for rules in (egm_src_rules, rev_src_rules):
        for r in rules:
            r["resource"] = r["resource"].replace(
                "__REPO_ROOT__", paths.get("repo_root", ""))
            r["resource"] = r["resource"].replace(
                "__UPSTREAM_ROOT__", paths.get("upstream_root", ""))
            # The server expands a leading `~` (installed file keeps it
            # literal) — compare on expanded form.
            if r["resource"].startswith("~"):
                r["resource"] = str(pathlib.Path(
                    r["resource"]).expanduser())
    if resolved and "egm" in resolved:
        print("source: agent files + live outcomes "
              "(`opencode debug agents`)")
        egm_live = resolved["egm"]
        rev_live = resolved.get("egm-reviewer")
    else:
        print("source: agent source files only (opencode CLI unavailable)")
        egm_live, rev_live = None, None

    # Coverage checks run against the INSTALLED (live) rules when
    # available — that is what the running server enforces.
    live_egm = egm_live if egm_live is not None else egm_src_rules
    shell_rules = [r for r in live_egm if r["action"] in ("shell", "bash")]
    ext_rules = [r for r in live_egm
                 if r["action"] == "external_directory"]

    check_ordering("egm", egm_src_rules, egm_live)
    check_ordering("egm-reviewer", rev_src_rules, rev_live)
    check_shell_coverage(skill_commands(skill_text), shell_rules)
    check_dangerous_absent(shell_rules)
    check_external_coverage(referenced_dirs(skill_text, agent_text, paths),
                            ext_rules)

    print()
    if FAILURES:
        print(f"{len(FAILURES)} permission-semantics check(s) failed.")
        return 1
    print("All permission-semantics checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
