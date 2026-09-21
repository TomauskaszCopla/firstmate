# Startup-memory `/stow` verification

Audience: maintainer verification.

This record supports the active guarantee that Firstmate can discover and JIT-load a user-owned local skill excluded through the clone's `.git/info/exclude`.
The internal [`stow` skill](../../.agents/skills/stow/SKILL.md) owns tiering, curation, archival, offload, and completion-receipt behavior.
[`docs/configuration.md`](../configuration.md) owns the current operator-facing startup-memory setting and estimate.

## Pre-compaction execution boundary

[`bin/fm-stow-precompact.sh`](../../bin/fm-stow-precompact.sh) owns the automatic path and its private receipt schemas.
The [automatic pre-compaction Stow contract](../configuration.md#automatic-pre-compaction-stow) owns provider matching, completion, primary-only scope, serialization, recovery, and retention behavior.
The live guard deliberately holds the detached worker across hook return to prove survival and later completion without claiming that every fast run finishes after hook return.

Focused coverage is in [`tests/fm-stow-precompact.test.sh`](../../tests/fm-stow-precompact.test.sh).
Real Codex hook coverage is in [`tests/fm-stow-precompact-live-e2e.test.sh`](../../tests/fm-stow-precompact-live-e2e.test.sh) and must use a disposable standalone repository because installed Codex project-hook discovery from linked worktrees is not a reliable proof surface.

On 2026-09-21, the focused portable suite passed with:

```text
ok - manual and automatic boundaries capture, run in order, and deduplicate
ok - each hook runs one provider-matched agent with no fallback
ok - empty Stow and Retrospective evidence cannot certify reset safety
ok - post-pass totals must not exceed the effective memory budget
ok - worker failure stays incomplete and still runs Retrospective
ok - provider preflight blocks missing Retrospective and a failed pass refuses reset safety
ok - running duplicates stay single-flight and restart retires uncertain work without replay
ok - an interruption before agent ownership remains restartable
ok - manual Stow serializes the writer and non-primary sessions stand down
ok - snapshot failure blocks compaction with durable Codex and Claude receipts
ok - session-start reconciliation clears stale manual Stow reservations
ok - secondmates serialize explicit Stow while automatic hooks remain primary-only
ok - live-state guard rejects a dead original session owner
ok - reconciliation never replays an interrupted or settled combined agent
ok - unresolved Stow and Retrospective exceptions prevent reset safety
ok - session reconciliation recovers a snapshot-captured job
ok - a failed JSON producer cannot replace a valid receipt
ok - retention prunes only settled evidence after 14 days
ok - the real session-lock predicate gates automatic Stow ownership
ok - Codex and Claude register one compaction hook and one ordinary SessionStart hook
all pre-compaction Stow tests passed
```

On 2026-09-21, the live suite passed against one combined Codex agent and one combined result artifact:

```text
ok - codex-cli 0.155.1 manual /compact freezes the boundary before returning and its detached worker survives parent exit
ok - codex-cli 0.155.1 automatic compaction fires trigger=auto and its detached worker survives parent exit
ok - codex-cli 0.155.1 isolated real worker completed Stow then the current installed Retrospective without production-memory changes
all real Codex pre-compaction Stow assertions passed
```

Installed-Claude compaction also remains unproved: Claude Code returned `credits_required` before a disposable conversation could be created.
Do not treat the portable provider fakes or source inspection as live Claude proof.

## Git-excluded local skill discovery and loading

The internal skill's offload destination relies on the harness discovering and JIT-loading a skill directory whose path is listed in the clone's local `.git/info/exclude`.
This check ran on 2026-08-08 with Claude Code 2.1.226 in a disposable scratch repository.
The unique sentinel appeared only in the skill body below the frontmatter, so returning it required the fresh session to load the excluded skill rather than merely see its indexed name or description.

The exact commands run from this repository root were:

```bash
set -eu
claude --version
PROBE_ROOT="$PWD/.stow-excluded-probe-tmp"
rm -rf "$PROBE_ROOT"
mkdir -p "$PROBE_ROOT"
cd "$PROBE_ROOT"
git init -q .
mkdir -p .claude/skills/excluded-probe
cat >.claude/skills/excluded-probe/SKILL.md <<'EOF'
---
name: excluded-probe
description: A neutral probe used when explicitly requested by name.
---

# Excluded probe

The sentinel token is STOW-EXCLUDE-LOAD-8F3K1.
EOF
printf '.claude/skills/excluded-probe/\n' >>.git/info/exclude
git check-ignore -v .claude/skills/excluded-probe/SKILL.md
claude --model haiku --allowedTools Skill -p "Use your Skill tool to load the skill named 'excluded-probe', then reply with exactly the sentinel token stated inside its body and nothing else."
cd ..
rm -rf "$PROBE_ROOT"
```

The exact observed output was:

```text
2.1.226 (Claude Code)
.git/info/exclude:7:.claude/skills/excluded-probe/	.claude/skills/excluded-probe/SKILL.md
STOW-EXCLUDE-LOAD-8F3K1
```

The `git check-ignore` line proves that the local exclude rule covered the skill body, and the exact sentinel reply proves that a fresh Claude Code session loaded that body through the Skill tool.
The same day, a `.gitignore`-ignored probe directory under this repository's own `.agents/skills/` was also listed by a fresh session alongside the tracked control skill through the `.claude/skills` symlink.
The direct local-exclude probe establishes the load-bearing guarantee, while the in-repository probe independently corroborates that ignore status does not suppress filesystem discovery.
