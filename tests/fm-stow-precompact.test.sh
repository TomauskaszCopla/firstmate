#!/usr/bin/env bash
# Focused behavior tests for durable pre-compaction Stow.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-stow-precompact)
BASE_PATH=$PATH
REAL_JQ=$(command -v jq)

make_home() { # <name>
  local home=$TMP_ROOT/$1 fakebin=$TMP_ROOT/$1-fakebin plugin claude_plugin
  mkdir -p "$home/bin" "$home/state" "$home/data" "$home/.agents/skills/stow" "$fakebin"
  git -C "$home" init -q
  git -C "$home" config user.name test
  git -C "$home" config user.email test@example.invalid
  printf 'fixture\n' > "$home/AGENTS.md"
  git -C "$home" add AGENTS.md
  git -C "$home" commit -qm fixture

  cp "$ROOT/bin/fm-stow-precompact.sh" "$home/bin/"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$home/bin/"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$home/bin/"
  cp "$ROOT/bin/fm-wake-lib.sh" "$home/bin/"
  cp "$ROOT/bin/fm-config-inherit-lib.sh" "$home/bin/"
  cp "$ROOT/bin/fm-classify-lib.sh" "$home/bin/"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$home/bin/"
  cp "$ROOT/bin/fm-startup-memory-budget-lib.sh" "$home/bin/"
  printf '%s\n' '# stow fixture' > "$home/.agents/skills/stow/SKILL.md"
  cat > "$home/bin/fm-session-lock-lib.sh" <<'EOF'
fm_session_lock_owned_by_self() { return 0; }
EOF
  cat > "$home/bin/fm-fleet-snapshot.sh" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FM_TEST_SNAPSHOT_HOLD:-}" ]; then
  printf '%s\n' "$PPID" > "$FM_TEST_SNAPSHOT_HOLD.pid"
  : > "$FM_TEST_SNAPSHOT_HOLD.ready"
  while [ -e "$FM_TEST_SNAPSHOT_HOLD" ]; do sleep 0.05; done
fi
printf '%s\n' '{"schema":"fm-fleet-snapshot.v1","tasks":[],"backlog":{"records":[]}}'
EOF
  chmod +x "$home/bin/fm-stow-precompact.sh" "$home/bin/fm-fleet-snapshot.sh"
  cat > "$fakebin/mv" <<EOF
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = -- ] && [ -n "\${FM_TEST_PROMOTE_HOLD:-}" ]; then
  printf '%s\\n' "\$PPID" > "\$FM_TEST_PROMOTE_HOLD.pid"
  : > "\$FM_TEST_PROMOTE_HOLD.ready"
  while [ -e "\$FM_TEST_PROMOTE_HOLD" ]; do sleep 0.05; done
  exit 1
fi
exec $(command -v mv) "\$@"
EOF
  chmod +x "$fakebin/mv"
  printf '%s\n' "$$" > "$home/state/.lock"

  plugin=$home/codex-home/plugins/cache/ai-team-skills/ai-team-tomas-skills/9.8.7/skills/retrospective
  mkdir -p "$plugin"
  printf '%s\n' '# retrospective fixture' > "$plugin/SKILL.md"
  claude_plugin=$home/claude-plugin/skills/retrospective
  mkdir -p "$claude_plugin"
  printf '%s\n' '# retrospective fixture' > "$claude_plugin/SKILL.md"

  cat > "$fakebin/codex" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = plugin ] && [ "${2:-}" = list ]; then
  if [ "${FM_TEST_RETRO_MISSING:-}" = 1 ]; then
    printf '%s\n' '[]'
  else
    printf '%s\n' '[{"pluginId":"ai-team-tomas-skills@ai-team-skills","name":"ai-team-tomas-skills","marketplaceName":"ai-team-skills","version":"9.8.7","installed":true,"enabled":true}]'
  fi
  exit 0
fi
result=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-last-message|-o) result=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$result" ] || exit 2
cat >/dev/null
case "$result" in */combined-result.json) ;; *) exit 2 ;; esac
printf 'codex\n' >> "${FM_TEST_AGENT_LOG:?}"
if [ -n "${FM_TEST_AGENT_HOLD:-}" ]; then
  : > "$FM_TEST_AGENT_HOLD.ready"
  while [ -e "$FM_TEST_AGENT_HOLD" ]; do sleep 0.05; done
fi
if [ -n "${FM_TEST_OLD_AGENT_PGID:-}" ] \
  && kill -0 -- "-$FM_TEST_OLD_AGENT_PGID" 2>/dev/null; then
  : > "${FM_TEST_AGENT_OVERLAP:?}"
fi
[ "${FM_TEST_AGENT_PROCESS_FAIL:-}" != 1 ] || exit 9
stow_status=complete
stow_safe=true
retro_status=no-change
[ "${FM_TEST_STOW_FAIL:-}" != 1 ] || { stow_status=failed; stow_safe=false; }
[ "${FM_TEST_STOW_INCOMPLETE:-}" != 1 ] || { stow_status=incomplete; stow_safe=false; }
[ "${FM_TEST_RETRO_FAIL:-}" != 1 ] || retro_status=failed
jq -n --arg stow_status "$stow_status" --argjson stow_safe "$stow_safe" \
  --argjson empty_evidence "${FM_TEST_EMPTY_EVIDENCE:-0}" \
  --argjson effective_budget "${FM_TEST_EFFECTIVE_BUDGET:-7500}" \
  --argjson tokens_before "${FM_TEST_TOKENS_BEFORE:-3}" \
  --argjson tokens_after "${FM_TEST_TOKENS_AFTER:-3}" \
  --arg retro_status "$retro_status" \
  --arg stow_exception "${FM_TEST_STOW_EXCEPTION:-}" \
  --arg retro_exception "${FM_TEST_RETRO_EXCEPTION:-}" \
  --arg entry "$CODEX_HOME/plugins/cache/ai-team-skills/ai-team-tomas-skills/9.8.7/skills/retrospective/SKILL.md" '
  {stow:(({status:$stow_status,reset_safe:$stow_safe,summary:"stowed",
         memory_actions:(if $empty_evidence == 1 then [] else [
           {path:"data/captain.md",action:"unchanged",detail:"within budget"},
           {path:"data/captain-shared.md",action:"unchanged",detail:"within budget"},
           {path:"data/learnings.md",action:"unchanged",detail:"within budget"}
         ] end),durable_findings:[],open_work:[],
         exceptions:($stow_exception | if length == 0 then [] else [.] end)})
         + (if $empty_evidence == 1 then {} else {
           effective_budget_tokens:$effective_budget,
           total_estimated_tokens_before:$tokens_before,
           total_estimated_tokens_after:$tokens_after
         } end)),
   retrospective:{entrypoint:$entry,status:$retro_status,summary:"reviewed",
                  proof:(if $empty_evidence == 1 then [] else ["stow","retrospective"] end),
                  exceptions:($retro_exception | if length == 0 then [] else [.] end)}}
' > "$result"
EOF
  chmod +x "$fakebin/codex"

  cat > "$fakebin/claude" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = plugin ] && [ "${2:-}" = list ]; then
  if [ "${FM_TEST_RETRO_MISSING:-}" = 1 ]; then
    printf '%s\n' '[]'
  else
    jq -n --arg path "$FM_HOME/claude-plugin" \
      '[{id:"ai-team-tomas-skills@ai-team-skills",enabled:true,installPath:$path}]'
  fi
  exit 0
fi
cat >/dev/null
printf 'claude\n' >> "${FM_TEST_AGENT_LOG:?}"
if [ -n "${FM_TEST_AGENT_HOLD:-}" ]; then
  : > "$FM_TEST_AGENT_HOLD.ready"
  while [ -e "$FM_TEST_AGENT_HOLD" ]; do sleep 0.05; done
fi
[ "${FM_TEST_AGENT_PROCESS_FAIL:-}" != 1 ] || exit 9
stow_status=complete
stow_safe=true
retro_status=no-change
[ "${FM_TEST_STOW_FAIL:-}" != 1 ] || { stow_status=failed; stow_safe=false; }
[ "${FM_TEST_RETRO_FAIL:-}" != 1 ] || retro_status=failed
jq -n --arg stow_status "$stow_status" --argjson stow_safe "$stow_safe" \
  --arg retro_status "$retro_status" \
  --arg entry "$FM_HOME/claude-plugin/skills/retrospective/SKILL.md" '
  {structured_output:{
    stow:{status:$stow_status,reset_safe:$stow_safe,summary:"stowed",
           effective_budget_tokens:7500,total_estimated_tokens_before:3,total_estimated_tokens_after:3,
           memory_actions:[
             {path:"data/captain.md",action:"unchanged",detail:"within budget"},
             {path:"data/captain-shared.md",action:"unchanged",detail:"within budget"},
             {path:"data/learnings.md",action:"unchanged",detail:"within budget"}
           ],durable_findings:[],open_work:[],exceptions:[]},
    retrospective:{entrypoint:$entry,status:$retro_status,summary:"reviewed",
                   proof:["stow","retrospective"],exceptions:[]}}}
'
EOF
  chmod +x "$fakebin/claude"
  printf '%s\t%s\n' "$home" "$fakebin"
}

payload() { # <home> <transcript> <trigger> <event>
  jq -n --arg session session-1 --arg transcript "$2" --arg cwd "$1" \
    --arg trigger "$3" --arg event "${4:-PreCompact}" \
    '{session_id:$session,transcript_path:$transcript,cwd:$cwd,
      hook_event_name:$event,trigger:$trigger}'
}

run_hook() { # <home> <fakebin> <payload> <codex|claude> [extra env...]
  local home=$1 fakebin=$2 input=$3 harness=$4
  shift 4
  if [ "$harness" = codex ]; then
    printf '%s' "$input" | env "$@" PATH="$fakebin:$BASE_PATH" \
      CODEX_HOME="$home/codex-home" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_TEST_AGENT_LOG="$home/agent.log" \
      "$home/bin/fm-stow-precompact.sh" hook
  else
    printf '%s' "$input" | env "$@" PATH="$fakebin:$BASE_PATH" \
      CODEX_HOME="$home/codex-home" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_TEST_AGENT_LOG="$home/agent.log" \
      "$home/bin/fm-stow-precompact.sh" hook --claude
  fi
}

run_reconcile() { # <home> <fakebin>
  local home=$1 fakebin=$2
  shift 2
  env "$@" PATH="$fakebin:$BASE_PATH" \
    CODEX_HOME="$home/codex-home" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_TEST_AGENT_LOG="$home/agent.log" \
    "$home/bin/fm-stow-precompact.sh" reconcile-owned
}

job_dir() { # <home>
  find "$1/data/stow-precompact" -mindepth 1 -maxdepth 1 -type d \
    ! -name attempts | LC_ALL=C sort | tail -1
}

wait_for_file() { # <file> [attempts]
  local file=$1 attempts=${2:-200} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ -f "$file" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

wait_for_receipt_state() { # <receipt> <state> [attempts]
  local receipt=$1 expected=$2 attempts=${3:-200} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ "$(jq -r '.state // empty' "$receipt" 2>/dev/null)" = "$expected" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

test_manual_and_auto_boundaries_deduplicate() {
  local record home fakebin transcript input out job first_launches jobs
  record=$(make_home success)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  transcript=$home/transcript.jsonl
  printf '%s\n' '{"message":"first"}' > "$transcript"
  input=$(payload "$home" "$transcript" manual)
  out=$(run_hook "$home" "$fakebin" "$input" codex) \
    || fail "manual PreCompact hook failed: $out"
  [ -z "$out" ] || fail "successful manual hook emitted output: $out"
  job=$(job_dir "$home")
  wait_for_file "$job/completion.json" || fail "manual hook did not complete"
  jq -e '
    .state == "complete" and .reset_safe == true
    and .sequence == ["stow_local","retrospective"]
    and .agent == {harness:"codex",process_rc:0}
    and (.retrospective.entrypoint
      | endswith("/9.8.7/skills/retrospective/SKILL.md"))
    and .retrospective.result.proof == ["stow","retrospective"]
  ' "$job/completion.json" >/dev/null || fail "manual completion receipt is wrong"
  [ "$(cat "$home/agent.log")" = codex ] \
    || fail "one Codex agent did not run both ordered passes"

  first_launches=$(jq -r '.launch_attempts' "$job/receipt.json")
  out=$(run_hook "$home" "$fakebin" "$input" codex) \
    || fail "duplicate hook failed: $out"
  [ -z "$out" ] || fail "completed duplicate hook emitted output"
  [ "$(jq -r '.launch_attempts' "$job/receipt.json")" = "$first_launches" ] \
    || fail "duplicate boundary launched another worker"
  [ "$(wc -l < "$home/agent.log" | tr -d ' ')" = 1 ] \
    || fail "duplicate boundary reran the combined agent"
  jq -e 'has("duplicate_events") | not' "$job/receipt.json" >/dev/null \
    || fail "duplicate boundary added unrequired receipt bookkeeping"

  printf '%s\n' '{"message":"second"}' >> "$transcript"
  input=$(payload "$home" "$transcript" auto)
  run_hook "$home" "$fakebin" "$input" codex >/dev/null \
    || fail "automatic PreCompact hook failed"
  jobs=$(find "$home/data/stow-precompact" -mindepth 1 -maxdepth 1 -type d ! -name attempts | wc -l | tr -d ' ')
  [ "$jobs" = 2 ] || fail "automatic boundary did not create a distinct job"
  job=$(job_dir "$home")
  wait_for_file "$job/completion.json" || fail "automatic hook did not complete"
  [ "$(jq -r '.trigger' "$job/receipt.json")" = auto ] || fail "automatic trigger was not retained"
  [ "$(wc -l < "$home/agent.log" | tr -d ' ')" = 2 ] \
    || fail "each distinct boundary did not run exactly one agent"
  pass "manual and automatic boundaries capture, run in order, and deduplicate"
}

test_provider_matched_single_agent() {
  local harness record home fakebin transcript input job
  for harness in codex claude; do
    record=$(make_home "provider-$harness")
    IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
    transcript=$home/transcript.jsonl
    printf '%s\n' '{}' > "$transcript"
    input=$(payload "$home" "$transcript" manual)
    run_hook "$home" "$fakebin" "$input" "$harness" >/dev/null \
      || fail "$harness provider hook failed"
    job=$(job_dir "$home")
    wait_for_file "$job/completion.json" || fail "$harness provider job did not complete"
    jq -e --arg harness "$harness" '
      .state == "complete" and .agent.harness == $harness
      and .agent.process_rc == 0
      and .retrospective.result.proof == ["stow","retrospective"]
      and (.retrospective.entrypoint | contains($harness))
    ' "$job/completion.json" >/dev/null \
      || fail "$harness provider result did not preserve ordered same-provider work"
    [ "$(cat "$home/agent.log")" = "$harness" ] \
      || fail "$harness hook invoked another provider or more than one agent"
  done
  pass "each hook runs one provider-matched agent with no fallback"
}

test_empty_evidence_prevents_reset_safety() {
  local record home fakebin transcript input job
  record=$(make_home empty-evidence)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  transcript=$home/transcript.jsonl
  printf '%s\n' '{}' > "$transcript"
  input=$(payload "$home" "$transcript" manual)
  run_hook "$home" "$fakebin" "$input" codex FM_TEST_EMPTY_EVIDENCE=1 >/dev/null \
    || fail "empty-evidence case did not start"
  job=$(job_dir "$home")
  wait_for_file "$job/completion.json" || fail "empty-evidence case published no completion"
  jq -e '
    .state == "incomplete" and .reset_safe == false
    and .stow.result.memory_actions == []
    and .retrospective.result.status == "failed"
    and .retrospective.result.proof == []
  ' "$job/completion.json" >/dev/null \
    || fail "empty Stow or Retrospective evidence certified reset safety"
  [ -f "$job/combined-result.invalid.json" ] \
    || fail "empty evidence was not retained as an invalid provider result"
  pass "empty Stow and Retrospective evidence cannot certify reset safety"
}

test_budget_bound_controls_reset_safety() {
  local record home fakebin transcript input job
  record=$(make_home over-budget)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  transcript=$home/transcript.jsonl
  printf '%s\n' '{}' > "$transcript"
  input=$(payload "$home" "$transcript" manual)
  run_hook "$home" "$fakebin" "$input" codex \
    FM_TEST_EFFECTIVE_BUDGET=100 FM_TEST_TOKENS_BEFORE=80 FM_TEST_TOKENS_AFTER=120 >/dev/null \
    || fail "over-budget case did not start"
  job=$(job_dir "$home")
  wait_for_file "$job/completion.json" || fail "over-budget case published no completion"
  jq -e '
    .state == "incomplete" and .reset_safe == false
    and .stow.result.status == "complete"
    and .stow.result.effective_budget_tokens == 100
    and .stow.result.total_estimated_tokens_after == 120
    and .retrospective.result.status == "no-change"
    and .agent.process_rc == 0
  ' "$job/completion.json" >/dev/null \
    || fail "an over-budget Stow certified reset safety or lost its reported totals"

  record=$(make_home equal-budget)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  transcript=$home/transcript.jsonl
  printf '%s\n' '{}' > "$transcript"
  input=$(payload "$home" "$transcript" manual)
  run_hook "$home" "$fakebin" "$input" codex \
    FM_TEST_EFFECTIVE_BUDGET=100 FM_TEST_TOKENS_BEFORE=80 FM_TEST_TOKENS_AFTER=100 >/dev/null \
    || fail "equal-budget case did not start"
  job=$(job_dir "$home")
  wait_for_file "$job/completion.json" || fail "equal-budget case published no completion"
  jq -e '.state == "complete" and .reset_safe == true' "$job/completion.json" >/dev/null \
    || fail "an equal-to-budget Stow was rejected"

  record=$(make_home honest-incomplete)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  transcript=$home/transcript.jsonl
  printf '%s\n' '{}' > "$transcript"
  input=$(payload "$home" "$transcript" manual)
  run_hook "$home" "$fakebin" "$input" codex \
    FM_TEST_STOW_INCOMPLETE=1 FM_TEST_EFFECTIVE_BUDGET=100 \
    FM_TEST_TOKENS_BEFORE=140 FM_TEST_TOKENS_AFTER=120 \
    FM_TEST_STOW_EXCEPTION="pinned captain memory cannot be pruned below the budget" >/dev/null \
    || fail "honest incomplete case did not start"
  job=$(job_dir "$home")
  wait_for_file "$job/completion.json" || fail "honest incomplete case published no completion"
  jq -e '
    .state == "incomplete" and .reset_safe == false
    and .stow.result.status == "incomplete"
    and .stow.result.effective_budget_tokens == 100
    and .stow.result.total_estimated_tokens_before == 140
    and .stow.result.total_estimated_tokens_after == 120
    and (.stow.result.exceptions
      == ["pinned captain memory cannot be pruned below the budget"])
    and .retrospective.result.status == "no-change"
    and (.retrospective.result.proof | length > 0)
    and .agent.process_rc == 0
  ' "$job/completion.json" >/dev/null \
    || fail "an honest over-budget incomplete result was replaced by a generic failure"
  pass "post-pass totals must not exceed the effective memory budget"
}

test_failures_are_terminal_and_retrospective_still_runs() {
  local record home fakebin transcript input job
  record=$(make_home failure)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  transcript=$home/transcript.jsonl
  printf '%s\n' '{}' > "$transcript"
  input=$(payload "$home" "$transcript" manual)
  run_hook "$home" "$fakebin" "$input" codex \
    FM_TEST_STOW_FAIL=1 >/dev/null || fail "failure case did not start"
  job=$(job_dir "$home")
  wait_for_file "$job/completion.json" || fail "failure case published no completion"
  jq -e '
    .state == "incomplete" and .reset_safe == false
    and .stow.result.status == "failed"
    and .retrospective.result.status == "no-change"
  ' "$job/completion.json" >/dev/null || fail "Stow failure receipt is inaccurate"
  [ "$(cat "$home/agent.log")" = codex ] \
    || fail "Stow failure did not stay inside one combined agent"
  pass "worker failure stays incomplete and still runs Retrospective"
}

test_missing_and_failed_retrospective_preserve_stow() {
  local record home fakebin transcript input job out
  record=$(make_home retro-missing)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  transcript=$home/transcript.jsonl
  printf '%s\n' '{}' > "$transcript"
  input=$(payload "$home" "$transcript" manual)
  out=$(run_hook "$home" "$fakebin" "$input" codex FM_TEST_RETRO_MISSING=1) \
    || fail "missing Retrospective preflight did not return a Codex refusal"
  printf '%s' "$out" | jq -e '
    .continue == false and (.stopReason | contains("provider"))
  ' >/dev/null || fail "missing Retrospective did not block compaction at preflight"
  [ ! -e "$home/agent.log" ] || fail "preflight failure launched a provider agent"

  record=$(make_home retro-failed)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  transcript=$home/transcript.jsonl
  printf '%s\n' '{}' > "$transcript"
  input=$(payload "$home" "$transcript" manual)
  run_hook "$home" "$fakebin" "$input" codex FM_TEST_RETRO_FAIL=1 >/dev/null \
    || fail "failed Retrospective case did not start"
  job=$(job_dir "$home")
  wait_for_file "$job/completion.json" || fail "failed Retrospective case published no completion"
  jq -e '
    .state == "incomplete" and .reset_safe == false
    and .stow.result.status == "complete"
    and .retrospective.result.status == "failed"
  ' "$job/completion.json" >/dev/null \
    || fail "failed Retrospective receipt lost the completed Stow"
  pass "provider preflight blocks missing Retrospective and a failed pass refuses reset safety"
}

test_duplicate_running_worker_and_restart_recovery() {
  local record home fakebin transcript input hold job pid pgid launches overlap
  record=$(make_home restart)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  transcript=$home/transcript.jsonl
  printf '%s\n' '{}' > "$transcript"
  input=$(payload "$home" "$transcript" manual)
  hold=$home/hold
  : > "$hold"
  run_hook "$home" "$fakebin" "$input" codex \
    FM_TEST_AGENT_HOLD="$hold" >/dev/null || fail "held worker did not start"
  wait_for_file "$hold.ready" || fail "held worker never entered the combined agent"
  job=$(job_dir "$home")
  run_hook "$home" "$fakebin" "$input" codex \
    FM_TEST_AGENT_HOLD="$hold" >/dev/null || fail "running duplicate hook failed"
  [ "$(jq -r '.launch_attempts' "$job/receipt.json")" = 1 ] \
    || fail "running duplicate launched a second worker"
  pid=$(jq -r '.worker.pid' "$job/receipt.json")
  pgid=$(jq -r '.active_agent.pgid' "$job/receipt.json")
  kill -9 "$pid" 2>/dev/null || fail "could not interrupt fixture worker"
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  rm -f -- "$hold"
  overlap=$home/agent-overlap
  run_reconcile "$home" "$fakebin" FM_TEST_OLD_AGENT_PGID="$pgid" \
    FM_TEST_AGENT_OVERLAP="$overlap" || fail "session-start reconciliation failed"
  wait_for_file "$job/completion.json" || fail "restarted worker did not complete"
  launches=$(jq -r '.launch_attempts' "$job/receipt.json")
  [ "$launches" = 2 ] || fail "interrupted worker was not restarted exactly once: $launches"
  jq -e '
    .state == "incomplete" and .reset_safe == false
    and .stow.result.status == "failed"
    and (.stow.result.summary | contains("did not publish a settled result"))
    and .retrospective.result.status == "failed"
    and .agent.process_rc == null
  ' "$job/completion.json" >/dev/null \
    || fail "restarted worker replayed or misreported the uncertain combined pass"
  [ "$(cat "$home/agent.log")" = codex ] \
    || fail "an unsettled combined pass was replayed during reconciliation"
  [ ! -e "$overlap" ] || fail "replacement work overlapped the prior agent process group"
  kill -0 -- "-$pgid" 2>/dev/null \
    && fail "the prior agent process group survived replacement"
  pass "running duplicates stay single-flight and restart retires uncertain work without replay"
}

test_orphaned_agent_blocks_a_second_boundary() {
  local record home fakebin input hold job_a job_b pid_a pgid_a overlap i=0
  record=$(make_home cross-job)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  printf '%s\n' '{"a":1}' > "$home/transcript-a.jsonl"
  printf '%s\n' '{"b":2}' > "$home/transcript-b.jsonl"
  hold=$home/hold
  : > "$hold"
  input=$(payload "$home" "$home/transcript-a.jsonl" manual)
  run_hook "$home" "$fakebin" "$input" codex FM_TEST_AGENT_HOLD="$hold" >/dev/null \
    || fail "the first boundary did not start"
  wait_for_file "$hold.ready" || fail "the first agent never started"
  job_a=$(job_dir "$home")
  pid_a=$(jq -r '.worker.pid' "$job_a/receipt.json")
  pgid_a=$(jq -r '.active_agent.pgid' "$job_a/receipt.json")
  overlap=$home/agent-overlap

  input=$(payload "$home" "$home/transcript-b.jsonl" manual)
  run_hook "$home" "$fakebin" "$input" codex \
    FM_TEST_OLD_AGENT_PGID="$pgid_a" FM_TEST_AGENT_OVERLAP="$overlap" >/dev/null \
    || fail "the second boundary did not start"
  job_b=$(find "$home/data/stow-precompact" -mindepth 1 -maxdepth 1 -type d \
    ! -name attempts ! -path "$job_a" | head -1)
  [ -n "$job_b" ] && [ "$job_b" != "$job_a" ] || fail "the second boundary reused the first job"

  kill -9 "$pid_a" 2>/dev/null || fail "could not interrupt the first worker"
  while kill -0 "$pid_a" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done

  wait_for_file "$job_b/completion.json" 400 \
    || fail "the second boundary never settled after the first worker died"
  [ ! -e "$overlap" ] \
    || fail "the second agent ran while the orphaned first agent group was alive"
  kill -0 -- "-$pgid_a" 2>/dev/null \
    && fail "the orphaned first agent group survived the second boundary"
  rm -f -- "$hold"
  pass "an orphaned agent group cannot overlap a second boundary's agent"
}

test_pre_agent_interruption_remains_restartable() {
  local record home fakebin transcript input hold job pid agent_pid real_ps launches i=0
  record=$(make_home pre-agent-restart)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  transcript=$home/transcript.jsonl
  printf '%s\n' '{}' > "$transcript"
  input=$(payload "$home" "$transcript" manual)
  hold=$home/pre-agent-ownership-hold
  : > "$hold"
  real_ps=$(command -v ps)
  cat > "$fakebin/ps" <<EOF
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = -o ] && [ "\${2:-}" = pgid= ] && [ "\${3:-}" = -p ] \
  && [ -n "\${FM_TEST_AGENT_OWNERSHIP_HOLD:-}" ]; then
  printf '%s\n' "\${4:-}" > "\${FM_TEST_AGENT_OWNERSHIP_HOLD}.agent.pid"
  : > "\${FM_TEST_AGENT_OWNERSHIP_HOLD}.ready"
  while [ -e "\${FM_TEST_AGENT_OWNERSHIP_HOLD}" ]; do sleep 0.05; done
fi
exec "$real_ps" "\$@"
EOF
  chmod +x "$fakebin/ps"
  run_hook "$home" "$fakebin" "$input" codex \
    FM_TEST_AGENT_OWNERSHIP_HOLD="$hold" >/dev/null \
    || fail "pre-agent restart fixture did not start"
  wait_for_file "$hold.ready" || fail "worker did not reach the pre-agent boundary"
  job=$(job_dir "$home")
  jq -e '.active_agent == null and (.stages.agent_started? == null)' \
    "$job/receipt.json" >/dev/null \
    || fail "receipt claimed an agent before process ownership existed"
  agent_pid=$(cat "$hold.agent.pid")
  pid=$(jq -r '.worker.pid' "$job/receipt.json")
  kill -9 "$pid" 2>/dev/null || fail "could not interrupt the pre-agent worker"
  kill -9 -- "-$agent_pid" 2>/dev/null || true
  kill -9 "$agent_pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  rm -f -- "$hold"
  run_reconcile "$home" "$fakebin" || fail "pre-agent reconciliation failed"
  wait_for_file "$job/completion.json" || fail "pre-agent reconciliation did not complete"
  launches=$(jq -r '.launch_attempts' "$job/receipt.json")
  [ "$launches" = 2 ] || fail "pre-agent interruption was not restarted exactly once: $launches"
  jq -e '.state == "complete" and .reset_safe == true and .agent.process_rc == 0' \
    "$job/completion.json" >/dev/null \
    || fail "pre-agent interruption was treated as uncertain side effects"
  [ "$(cat "$home/agent.log")" = codex ] \
    || fail "pre-agent reconciliation did not run exactly one combined agent"
  pass "an interruption before agent ownership remains restartable"
}

test_manual_reservation_and_non_primary_stand_down() {
  local record home fakebin transcript input out foreign hold job rc hook_pid receipt
  record=$(make_home reservation)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  transcript=$home/transcript.jsonl
  printf '%s\n' '{}' > "$transcript"
  input=$(payload "$home" "$transcript" auto)
  env PATH="$fakebin:$BASE_PATH" CODEX_HOME="$home/codex-home" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" "$home/bin/fm-stow-precompact.sh" manual-begin \
    || fail "manual Stow reservation failed"
  out=$(run_hook "$home" "$fakebin" "$input" codex) \
    || fail "Codex-shaped manual-reservation refusal did not return structured output"
  printf '%s' "$out" | jq -e '.continue == false and (.stopReason | contains("manual Stow"))' >/dev/null \
    || fail "automatic compaction did not refuse an active manual Stow"
  run_reconcile "$home" "$fakebin" \
    || fail "session-start reconciliation failed during a manual Stow"
  [ -f "$home/state/.stow-manual-reservation.json" ] \
    || fail "session-start reconciliation removed an active manual Stow reservation"
  env PATH="$fakebin:$BASE_PATH" CODEX_HOME="$home/codex-home" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" "$home/bin/fm-stow-precompact.sh" manual-end \
    || fail "manual Stow reservation did not release"

  hold=$home/snapshot-hold
  : > "$hold"
  run_hook "$home" "$fakebin" "$input" codex \
    FM_TEST_SNAPSHOT_HOLD="$hold" > "$home/race.stdout" 2> "$home/race.stderr" &
  hook_pid=$!
  wait_for_file "$hold.ready" || fail "held snapshot never entered boundary capture"
  env PATH="$fakebin:$BASE_PATH" CODEX_HOME="$home/codex-home" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" "$home/bin/fm-stow-precompact.sh" manual-begin \
    || fail "manual Stow could not reserve during boundary capture"
  rm -f -- "$hold"
  wait "$hook_pid" || fail "capture-race refusal returned a process failure"
  jq -e '.continue == false and (.stopReason | contains("manual Stow began during boundary capture"))' \
    "$home/race.stdout" >/dev/null \
    || fail "boundary capture silently raced an explicit Stow reservation"
  receipt=$(find "$home/data/stow-precompact/attempts" -name receipt.json -type f | head -1)
  jq -e '.state == "failed" and .reset_safe == false' "$receipt" >/dev/null \
    || fail "capture-race refusal left no durable failed receipt"
  env PATH="$fakebin:$BASE_PATH" CODEX_HOME="$home/codex-home" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" "$home/bin/fm-stow-precompact.sh" manual-end \
    || fail "capture-race manual reservation did not release"

  hold=$home/hold
  : > "$hold"
  run_hook "$home" "$fakebin" "$input" codex \
    FM_TEST_AGENT_HOLD="$hold" >/dev/null || fail "held automatic worker did not start"
  wait_for_file "$hold.ready" || fail "held automatic worker never entered the combined agent"
  rc=0
  env PATH="$fakebin:$BASE_PATH" CODEX_HOME="$home/codex-home" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" "$home/bin/fm-stow-precompact.sh" manual-begin \
    > "$home/manual.stdout" 2> "$home/manual.stderr" || rc=$?
  if [ "$rc" -ne 1 ] \
    || ! grep -q 'automatic Stow job is pending' "$home/manual.stderr"; then
    fail "manual Stow reservation raced a launched automatic worker"
  fi
  rm -f -- "$hold"
  job=$(job_dir "$home")
  wait_for_file "$job/completion.json" \
    || fail "held automatic worker did not complete after release"

  foreign=$TMP_ROOT/not-firstmate
  mkdir -p "$foreign/state"
  out=$(printf '%s' "$input" | env PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$foreign" \
    FM_HOME="$foreign" FM_STATE_OVERRIDE="$foreign/state" FM_DATA_OVERRIDE="$foreign/data" \
    "$home/bin/fm-stow-precompact.sh" hook) || fail "non-Firstmate stand-down failed"
  [ -z "$out" ] && [ ! -e "$foreign/data" ] \
    || fail "non-Firstmate session mutated or emitted output"
  pass "manual Stow serializes the writer and non-primary sessions stand down"
}

test_snapshot_failure_refuses_both_hook_hosts() {
  local host record home fakebin transcript input out receipt rc
  for host in codex claude; do
    record=$(make_home "snapshot-$host")
    IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
    cat > "$home/bin/fm-fleet-snapshot.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"invalid"}'
exit 1
EOF
    chmod +x "$home/bin/fm-fleet-snapshot.sh"
    transcript=$home/transcript.jsonl
    printf '%s\n' '{}' > "$transcript"
    input=$(payload "$home" "$transcript" manual)
    if [ "$host" = codex ]; then
      out=$(run_hook "$home" "$fakebin" "$input" codex) \
        || fail "Codex-shaped snapshot refusal returned a process failure"
      printf '%s' "$out" | jq -e '
        .continue == false
        and (.stopReason | contains("structured open-work snapshot failed"))
      ' >/dev/null || fail "Codex-shaped snapshot refusal did not block compaction"
    else
      rc=0
      printf '%s' "$input" | env PATH="$fakebin:$BASE_PATH" \
        CODEX_HOME="$home/codex-home" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
        FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
        "$home/bin/fm-stow-precompact.sh" hook --claude \
        > "$home/claude.stdout" 2> "$home/claude.stderr" || rc=$?
      if [ "$rc" -ne 2 ] || [ -s "$home/claude.stdout" ] \
        || ! grep -q 'structured open-work snapshot failed' "$home/claude.stderr"; then
        fail "Claude-shaped snapshot refusal did not exit 2 on stderr only"
      fi
    fi
    receipt=$(find "$home/data/stow-precompact/attempts" -name receipt.json \
      -type f | head -1)
    [ -n "$receipt" ] \
      || fail "$host snapshot refusal did not preserve its attempt receipt"
    jq -e '
      .state == "failed" and .reset_safe == false
      and .error == "the structured open-work snapshot failed"
      and .stages.hook_fired != null and .stages.failed != null
    ' "$receipt" >/dev/null \
      || fail "$host snapshot refusal receipt is not durable and accurate"
  done
  pass "snapshot failure blocks compaction with durable Codex and Claude receipts"
}

test_stale_manual_reservation_reconciles() {
  local record home fakebin
  record=$(make_home stale-reservation)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  jq -n --argjson pid "$$" '
    {schema:"fm-stow-manual-reservation.v1",session_lock_pid:$pid,
     session_lock_identity:"stale-identity",started:"2026-01-01T00:00:00Z"}
  ' > "$home/state/.stow-manual-reservation.json"
  run_reconcile "$home" "$fakebin" \
    || fail "session-start reconciliation failed for a stale manual reservation"
  [ ! -e "$home/state/.stow-manual-reservation.json" ] \
    || fail "session-start reconciliation retained a stale manual reservation"
  pass "session-start reconciliation clears stale manual Stow reservations"
}

test_secondmate_manual_reservation_without_automatic_hook() {
  local record home fakebin transcript input out
  record=$(make_home secondmate)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  printf '%s\n' secondmate-test > "$home/.fm-secondmate-home"
  env PATH="$fakebin:$BASE_PATH" CODEX_HOME="$home/codex-home" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" "$home/bin/fm-stow-precompact.sh" manual-begin \
    || fail "a secondmate explicit Stow could not reserve its own memory writer"
  [ -f "$home/state/.stow-manual-reservation.json" ] \
    || fail "a secondmate explicit Stow published no manual reservation"
  env PATH="$fakebin:$BASE_PATH" CODEX_HOME="$home/codex-home" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" "$home/bin/fm-stow-precompact.sh" manual-end \
    || fail "a secondmate explicit Stow could not release its reservation"

  transcript=$home/transcript.jsonl
  printf '%s\n' '{}' > "$transcript"
  input=$(payload "$home" "$transcript" auto)
  out=$(run_hook "$home" "$fakebin" "$input" codex) \
    || fail "a secondmate automatic hook did not stand down cleanly"
  [ -z "$out" ] && [ ! -e "$home/data/stow-precompact" ] \
    || fail "a secondmate automatic hook launched primary-only Stow work"
  pass "secondmates serialize explicit Stow while automatic hooks remain primary-only"
}

test_guard_requires_live_original_session() {
  local record home fakebin transcript input job job_id dead_pid rc=0
  record=$(make_home live-guard)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  transcript=$home/transcript.jsonl
  printf '%s\n' '{}' > "$transcript"
  input=$(payload "$home" "$transcript" manual)
  run_hook "$home" "$fakebin" "$input" codex >/dev/null \
    || fail "live-guard fixture hook failed"
  job=$(job_dir "$home")
  wait_for_file "$job/completion.json" || fail "live-guard fixture did not complete"
  job_id=${job##*/}
  env PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$home/bin/fm-stow-precompact.sh" guard --job "$job_id" \
    || fail "guard rejected the live original session"

  sleep 30 &
  dead_pid=$!
  kill "$dead_pid"
  wait "$dead_pid" 2>/dev/null || true
  jq --argjson pid "$dead_pid" \
    '.session_lock_pid=$pid | .session_lock_identity="dead-session"' \
    "$job/receipt.json" > "$job/receipt.tmp"
  mv "$job/receipt.tmp" "$job/receipt.json"
  printf '%s\n' "$dead_pid" > "$home/state/.lock"
  env PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$home/bin/fm-stow-precompact.sh" guard --job "$job_id" || rc=$?
  [ "$rc" -eq 1 ] || fail "guard accepted a dead original session owner"
  pass "live-state guard rejects a dead original session owner"
}

kill_held_hook() { # <hold>
  local hold=$1 pid i=0
  pid=$(cat "$hold.pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -9 "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  rm -f -- "$hold"
}

expire_session_lock() { # <home>
  local home=$1 dead_pid
  sleep 30 &
  dead_pid=$!
  kill "$dead_pid" 2>/dev/null || true
  wait "$dead_pid" 2>/dev/null || true
  printf '%s\n' "$dead_pid" > "$home/state/.lock"
}

test_ambiguous_agent_group_leaves_a_boundary_restartable() {
  local record home fakebin input job_a job_b sleeper sleeper_pgid dead_pid

  record=$(make_home ambiguous-group)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  printf '%s\n' '{"a":1}' > "$home/transcript-a.jsonl"
  printf '%s\n' '{"b":2}' > "$home/transcript-b.jsonl"
  input=$(payload "$home" "$home/transcript-a.jsonl" manual)
  run_hook "$home" "$fakebin" "$input" codex >/dev/null \
    || fail "the first boundary did not start"
  job_a=$(job_dir "$home")
  wait_for_file "$job_a/completion.json" || fail "the first boundary never settled"

  set -m
  sleep 60 &
  sleeper=$!
  set +m
  sleeper_pgid=$(ps -o pgid= -p "$sleeper" | tr -d '[:space:]')
  [ -n "$sleeper_pgid" ] || fail "no surviving agent group could be created"
  sleep 30 &
  dead_pid=$!
  kill "$dead_pid" 2>/dev/null || true
  wait "$dead_pid" 2>/dev/null || true
  jq --argjson pid "$dead_pid" --argjson pgid "$sleeper_pgid" \
    '.active_agent={pid:$pid,identity:"gone-leader",pgid:$pgid}' \
    "$job_a/receipt.json" > "$job_a/receipt.tmp"
  mv "$job_a/receipt.tmp" "$job_a/receipt.json"

  input=$(payload "$home" "$home/transcript-b.jsonl" manual)
  run_hook "$home" "$fakebin" "$input" codex >/dev/null \
    || fail "the second boundary did not start"
  job_b=$(find "$home/data/stow-precompact" -mindepth 1 -maxdepth 1 -type d \
    ! -name attempts ! -path "$job_a" | head -1)
  [ -n "$job_b" ] || fail "the second boundary published no job"
  wait_for_receipt_state "$job_b/receipt.json" interrupted \
    || fail "an unprovable foreign agent group did not leave the boundary restartable"
  [ ! -f "$job_b/completion.json" ] || fail "the blocked boundary published a completion"
  [ "$(wc -l < "$home/agent.log" | tr -d ' ')" = 1 ] \
    || fail "the blocked boundary started an overlapping agent"

  kill -9 "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  run_reconcile "$home" "$fakebin" || fail "reconciliation after the conflict failed"
  wait_for_file "$job_b/completion.json" \
    || fail "the blocked boundary never resumed after the foreign group exited"
  jq -e '.state == "complete" and .reset_safe == true' "$job_b/completion.json" >/dev/null \
    || fail "the resumed boundary did not complete normally"
  pass "an unprovable foreign agent group defers a boundary instead of failing it"
}

test_stopped_capture_attempts_are_reconciled() {
  local record home fakebin transcript input hold attempts attempt job

  record=$(make_home capture-incomplete)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  transcript=$home/transcript.jsonl
  printf '%s\n' '{}' > "$transcript"
  input=$(payload "$home" "$transcript" manual)
  attempts=$home/data/stow-precompact/attempts
  hold=$home/snapshot-hold
  : > "$hold"
  run_hook "$home" "$fakebin" "$input" codex FM_TEST_SNAPSHOT_HOLD="$hold" >/dev/null 2>&1 &
  wait_for_file "$hold.ready" || fail "capture never entered the open-work snapshot"
  kill_held_hook "$hold" || fail "the held capture hook could not be stopped"
  attempt=$(find "$attempts" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -n "$attempt" ] || fail "the stopped capture left no attempt"
  jq -e '.state == "hook_fired"' "$attempt/receipt.json" >/dev/null \
    || fail "the stopped capture was not left mid-capture"
  expire_session_lock "$home"
  run_reconcile "$home" "$fakebin" || fail "attempt reconciliation failed"
  jq -e '
    .state == "failed" and .reset_safe == false
    and (.finished | type == "string")
    and (.error | contains("interrupted before publication"))
  ' "$attempt/receipt.json" >/dev/null \
    || fail "an incomplete capture attempt was left without an explicit outcome"
  [ -z "$(job_dir "$home")" ] || fail "an incomplete capture attempt was promoted to a job"
  [ ! -s "$home/agent.log" ] || fail "an incomplete capture attempt replayed model work"

  record=$(make_home capture-unpromoted)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  transcript=$home/transcript.jsonl
  printf '%s\n' '{}' > "$transcript"
  input=$(payload "$home" "$transcript" manual)
  attempts=$home/data/stow-precompact/attempts
  hold=$home/promote-hold
  : > "$hold"
  run_hook "$home" "$fakebin" "$input" codex FM_TEST_PROMOTE_HOLD="$hold" >/dev/null 2>&1 &
  wait_for_file "$hold.ready" || fail "capture never reached job publication"
  kill_held_hook "$hold" || fail "the held publication hook could not be stopped"
  attempt=$(find "$attempts" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -n "$attempt" ] || fail "the unpromoted capture left no attempt"
  jq -e '.state == "snapshot_captured" and (.job_id | length == 32)' \
    "$attempt/receipt.json" >/dev/null \
    || fail "the unpromoted capture did not freeze a complete boundary"
  [ -z "$(job_dir "$home")" ] || fail "the capture was promoted before reconciliation"
  expire_session_lock "$home"
  run_reconcile "$home" "$fakebin" || fail "unpromoted attempt reconciliation failed"
  [ ! -d "$attempt" ] || fail "a complete capture attempt was not promoted"
  job=$(job_dir "$home")
  [ -n "$job" ] || fail "a complete capture attempt reached no canonical job"
  wait_for_file "$job/completion.json" \
    || fail "the recovered boundary never settled"
  jq -e '.state == "complete" and .reset_safe == true' "$job/completion.json" >/dev/null \
    || fail "the recovered boundary did not complete normally"
  [ "$(wc -l < "$home/agent.log" | tr -d ' ')" = 1 ] \
    || fail "the recovered boundary did not run exactly one combined agent"
  pass "stopped capture attempts are promoted or explicitly settled"
}

test_combined_agent_is_not_replayed() {
  local mode record home fakebin transcript input job before
  for mode in interrupted settled nonzero; do
    record=$(make_home "resume-$mode")
    IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
    transcript=$home/transcript.jsonl
    printf '%s\n' '{}' > "$transcript"
    input=$(payload "$home" "$transcript" manual)
    run_hook "$home" "$fakebin" "$input" codex >/dev/null \
      || fail "$mode resume fixture did not start"
    job=$(job_dir "$home")
    wait_for_file "$job/completion.json" || fail "$mode resume fixture did not complete"
    wait_for_receipt_state "$job/receipt.json" complete \
      || fail "$mode resume fixture receipt did not settle"
    before=$(wc -l < "$home/agent.log" | tr -d ' ')
    rm -f -- "$job/completion.json"
    if [ "$mode" = interrupted ]; then
      jq '
        .state="running" | .reset_safe=false | del(.finished)
        | .worker={pid:null,identity:null,attempt:"interrupted",started:null}
        | .active_agent=null
        | del(.stages.agent_finished,.stages.completion_published)
        | .stages.agent_started="2026-09-16T00:00:00Z"
        | .agent_rc=null | del(.stow_status,.retrospective_status)
      ' "$job/receipt.json" > "$job/receipt.tmp"
    elif [ "$mode" = settled ]; then
      jq '
        .state="running" | .reset_safe=false | del(.finished)
        | .worker={pid:null,identity:null,attempt:"interrupted",started:null}
        | .active_agent=null | del(.stages.completion_published)
      ' "$job/receipt.json" > "$job/receipt.tmp"
    else
      jq '
        .state="running" | .reset_safe=false | del(.finished)
        | .worker={pid:null,identity:null,attempt:"interrupted",started:null}
        | .active_agent=null | del(.stages.completion_published)
        | .agent_rc=9
      ' "$job/receipt.json" > "$job/receipt.tmp"
    fi
    mv "$job/receipt.tmp" "$job/receipt.json"
    run_reconcile "$home" "$fakebin" || fail "$mode resume reconciliation failed"
    wait_for_file "$job/completion.json" \
      || fail "$mode resume did not republish completion: $(cat "$job/receipt.json")"
    [ "$(wc -l < "$home/agent.log" | tr -d ' ')" = "$before" ] \
      || fail "$mode resume replayed the combined agent"
    if [ "$mode" = nonzero ]; then
      jq -e '
        .state == "incomplete" and .reset_safe == false
        and .agent.process_rc == 9
        and .stow.result.status == "failed"
        and (.stow.result.summary | contains("rc=9"))
        and .retrospective.result.status == "failed"
      ' "$job/completion.json" >/dev/null \
        || fail "nonzero settled agent result was accepted"
      jq -e '.stow.status == "complete" and .retrospective.status == "no-change"' \
        "$job/combined-result.invalid.json" >/dev/null \
        || fail "nonzero settled agent result was not preserved as failure evidence"
    elif [ "$mode" != settled ]; then
      jq -e '
        .state == "incomplete" and .reset_safe == false
        and .stow.result.status == "failed"
        and .retrospective.result.status == "failed"
        and (.retrospective.result.summary | contains("did not publish a settled"))
      ' "$job/completion.json" >/dev/null \
        || fail "$mode uncertain pass was replayed or reported as settled"
    else
      jq -e '
        .state == "complete" and .reset_safe == true
        and .stow.result.status == "complete"
        and .retrospective.result.status == "no-change"
      ' "$job/completion.json" >/dev/null \
        || fail "settled pass results were not reused for completion recovery"
    fi
  done
  pass "reconciliation never replays an interrupted or settled combined agent"
}

test_exceptions_prevent_reset_safety() {
  local kind record home fakebin transcript input job variable
  for kind in stow retrospective; do
    record=$(make_home "exception-$kind")
    IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
    transcript=$home/transcript.jsonl
    printf '%s\n' '{}' > "$transcript"
    input=$(payload "$home" "$transcript" manual)
    if [ "$kind" = stow ]; then
      variable=FM_TEST_STOW_EXCEPTION=unresolved-stow
    else
      variable=FM_TEST_RETRO_EXCEPTION=unresolved-retrospective
    fi
    run_hook "$home" "$fakebin" "$input" codex "$variable" >/dev/null \
      || fail "$kind exception fixture hook failed"
    job=$(job_dir "$home")
    wait_for_file "$job/completion.json" || fail "$kind exception fixture did not complete"
    jq -e --arg kind "$kind" '
      .state == "incomplete" and .reset_safe == false
      and (if $kind == "stow"
           then .stow.result.exceptions == ["unresolved-stow"]
           else .retrospective.result.exceptions == ["unresolved-retrospective"]
           end)
    ' "$job/completion.json" >/dev/null \
      || fail "$kind exception was reported as reset-safe"
  done
  pass "unresolved Stow and Retrospective exceptions prevent reset safety"
}

test_snapshot_capture_reconciles() {
  local record home fakebin transcript input job
  record=$(make_home snapshot-reconcile)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  transcript=$home/transcript.jsonl
  printf '%s\n' '{}' > "$transcript"
  input=$(payload "$home" "$transcript" manual)
  run_hook "$home" "$fakebin" "$input" codex >/dev/null \
    || fail "snapshot reconciliation fixture did not start"
  job=$(job_dir "$home")
  wait_for_file "$job/completion.json" || fail "snapshot reconciliation fixture did not complete"
  wait_for_receipt_state "$job/receipt.json" complete \
    || fail "snapshot reconciliation fixture receipt did not settle"
  jq '
    .state="snapshot_captured" | .reset_safe=false | .launch_attempts=0
    | .worker=null | .active_agent=null
    | del(.skills,.stow_status,.retrospective_status,.agent_rc,.finished)
    | .stages={hook_fired:.stages.hook_fired,snapshot_captured:.stages.snapshot_captured}
  ' "$job/receipt.json" > "$job/receipt.tmp"
  mv "$job/receipt.tmp" "$job/receipt.json"
  rm -f -- "$job/completion.json" "$job/combined-result.json" "$home/agent.log"
  run_reconcile "$home" "$fakebin" || fail "snapshot-captured reconciliation failed"
  wait_for_file "$job/completion.json" || fail "snapshot-captured job was stranded"
  jq -e '.state == "complete" and .reset_safe == true' "$job/completion.json" >/dev/null \
    || fail "snapshot-captured reconciliation published the wrong outcome"
  [ "$(cat "$home/agent.log")" = codex ] \
    || fail "snapshot-captured reconciliation did not run one combined agent"
  pass "session reconciliation recovers a snapshot-captured job"
}

test_failed_json_update_preserves_receipt() {
  local record home fakebin transcript input out job
  record=$(make_home failing-jq)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  cat > "$fakebin/jq" <<EOF
#!/usr/bin/env bash
for argument in "\$@"; do
  case "\$argument" in
    *'.state="launching"'*) printf '{"partial":'; exit 9 ;;
  esac
done
exec "$REAL_JQ" "\$@"
EOF
  chmod +x "$fakebin/jq"
  transcript=$home/transcript.jsonl
  printf '%s\n' '{}' > "$transcript"
  input=$(payload "$home" "$transcript" manual)
  out=$(run_hook "$home" "$fakebin" "$input" codex) \
    || fail "failed receipt producer did not return a Codex refusal"
  printf '%s' "$out" | "$REAL_JQ" -e '.continue == false' >/dev/null \
    || fail "failed receipt producer did not refuse compaction"
  job=$(job_dir "$home")
  "$REAL_JQ" -e '
    .schema == "fm-stow-precompact-receipt.v1"
    and .state == "failed"
    and .snapshot.transcript_sha256 != null
  ' "$job/receipt.json" >/dev/null \
    || fail "a failing jq producer replaced the valid durable receipt"
  pass "a failed JSON producer cannot replace a valid receipt"
}

test_settled_evidence_retention() {
  local record home fakebin transcript input job old_complete recent_complete staged old_attempt
  record=$(make_home retention)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  transcript=$home/transcript.jsonl
  printf '%s\n' '{}' > "$transcript"
  input=$(payload "$home" "$transcript" manual)
  run_hook "$home" "$fakebin" "$input" codex >/dev/null \
    || fail "retention fixture did not start"
  job=$(job_dir "$home")
  wait_for_file "$job/completion.json" || fail "retention fixture did not complete"
  wait_for_receipt_state "$job/receipt.json" complete \
    || fail "retention fixture receipt did not settle"
  old_complete=$home/data/stow-precompact/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  recent_complete=$home/data/stow-precompact/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  staged=$home/data/stow-precompact/cccccccccccccccccccccccccccccccc
  old_attempt=$home/data/stow-precompact/attempts/old-failed
  cp -R "$job" "$old_complete"
  cp -R "$job" "$recent_complete"
  cp -R "$job" "$staged"
  mkdir -p "$old_attempt"
  jq '.job_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" | .finished="2000-01-01T00:00:00Z"' \
    "$old_complete/receipt.json" > "$old_complete/receipt.tmp"
  mv "$old_complete/receipt.tmp" "$old_complete/receipt.json"
  jq '.job_id="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" | .finished="2099-01-01T00:00:00Z"' \
    "$recent_complete/receipt.json" > "$recent_complete/receipt.tmp"
  mv "$recent_complete/receipt.tmp" "$recent_complete/receipt.json"
  jq '
    .job_id="cccccccccccccccccccccccccccccccc" | .state="hook_fired"
    | .reset_safe=false | .finished="2000-01-01T00:00:00Z"
  ' "$staged/receipt.json" > "$staged/receipt.tmp"
  mv "$staged/receipt.tmp" "$staged/receipt.json"
  jq -n '
    {schema:"fm-stow-precompact-receipt.v1",state:"failed",reset_safe:false,
     finished:"2000-01-01T00:00:00Z",worker:null,active_agent:null}
  ' > "$old_attempt/receipt.json"
  run_reconcile "$home" "$fakebin" || fail "settled evidence pruning failed"
  [ ! -e "$old_complete" ] || fail "settled evidence older than 14 days was retained"
  [ ! -e "$old_attempt" ] || fail "a settled failed attempt older than 14 days was retained"
  [ -d "$recent_complete" ] || fail "recent settled evidence was pruned early"
  [ -d "$staged" ] || fail "unresolved staged evidence was pruned"
  pass "retention prunes only settled evidence after 14 days"
}

test_real_session_lock_ownership() {
  local record home fakebin owner other out
  record=$(make_home real-session-lock)
  IFS=$'\t' read -r home fakebin <<EOF
$record
EOF
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$home/bin/"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$home/bin/"
  owner=$$
  cat > "$fakebin/ps" <<'EOF'
#!/usr/bin/env bash
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
case "$*" in
  *"comm="*)
    if [ "$pid" = "${FM_TEST_ANCESTOR_PID:?}" ]; then printf '/usr/local/bin/codex\n'; else printf '/bin/bash\n'; fi
    exit 0
    ;;
  *"args="*)
    if [ "$pid" = "$FM_TEST_ANCESTOR_PID" ]; then printf 'codex\n'; else printf 'bash\n'; fi
    exit 0
    ;;
  *"ppid="*)
    if [ "$pid" = "$FM_TEST_ANCESTOR_PID" ]; then printf '1\n'; else printf '%s\n' "$FM_TEST_ANCESTOR_PID"; fi
    exit 0
    ;;
esac
exec /bin/ps "$@"
EOF
  chmod +x "$fakebin/ps"
  printf '%s\n' "$owner" > "$home/state/.lock"
  out=$(run_hook "$home" "$fakebin" '{}' codex FM_TEST_ANCESTOR_PID="$owner") \
    || fail "real owning-session predicate did not return a Codex refusal"
  printf '%s' "$out" | jq -e '
    .continue == false and (.stopReason | contains("unexpected hook event"))
  ' >/dev/null || fail "real owning-session predicate stood down before validating the hook"

  sleep 30 &
  other=$!
  printf '%s\n' "$other" > "$home/state/.lock"
  out=$(run_hook "$home" "$fakebin" '{}' codex FM_TEST_ANCESTOR_PID="$owner") \
    || fail "real non-owning-session predicate did not stand down cleanly"
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  [ -z "$out" ] && [ ! -e "$home/data/stow-precompact" ] \
    || fail "a session without the real fleet lock entered automatic Stow"
  pass "the real session-lock predicate gates automatic Stow ownership"
}

test_hook_registration() {
  local fixture log payload command
  fixture=$TMP_ROOT/hook-registration
  log=$fixture/dispatch.log
  payload='{"hook_event_name":"fixture","sentinel":"exact-payload"}'
  mkdir -p "$fixture/.codex" "$fixture/.claude" "$fixture/bin"
  cp "$ROOT/.codex/hooks.json" "$fixture/.codex/hooks.json"
  cp "$ROOT/.claude/settings.json" "$fixture/.claude/settings.json"
  printf 'fixture\n' > "$fixture/AGENTS.md"
  git -C "$fixture" init -q
  cat > "$fixture/bin/fm-stow-precompact.sh" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
printf '%s\t%s\n' "$*" "$input" >> "${FM_TEST_HOOK_LOG:?}"
EOF
  chmod +x "$fixture/bin/fm-stow-precompact.sh"
  cat > "$fixture/bin/fm-sessionstart-run.sh" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
printf 'session-start\t%s\t%s\n' "$*" "$input" >> "${FM_TEST_HOOK_LOG:?}"
EOF
  chmod +x "$fixture/bin/fm-sessionstart-run.sh"
  jq -e '
    (.hooks.PreCompact | length == 1)
    and (.hooks.PreCompact[0].matcher == "manual|auto")
    and (.hooks.PreCompact[0].hooks | length == 1)
    and (.hooks.PreCompact[0].hooks[0].type == "command")
    and (.hooks.SessionStart | length == 1)
    and (.hooks.SessionStart[0].hooks | length == 1)
    and (.hooks.SessionStart[0].hooks[0].type == "command")
  ' "$ROOT/.codex/hooks.json" >/dev/null \
    || fail "Codex hook registration does not expose one PreCompact and one ordinary SessionStart command"
  jq -e '
    (.hooks.PreCompact | length == 1)
    and (.hooks.PreCompact[0].matcher == "manual|auto")
    and (.hooks.PreCompact[0].hooks | length == 1)
    and (.hooks.PreCompact[0].hooks[0].type == "command")
    and (.hooks.SessionStart | length == 1)
    and (.hooks.SessionStart[0].hooks | length == 1)
    and (.hooks.SessionStart[0].hooks[0].type == "command")
  ' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "Claude hook registration does not expose one PreCompact and one ordinary SessionStart command"

  command=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$fixture/.codex/hooks.json")
  printf '%s' "$payload" | (cd "$fixture" && FM_TEST_HOOK_LOG="$log" bash -c "$command") \
    || fail "Codex SessionStart registration did not execute"
  command=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$fixture/.claude/settings.json")
  printf '%s' "$payload" | (cd "$fixture" && CLAUDE_PROJECT_DIR="$fixture" \
    FM_TEST_HOOK_LOG="$log" bash -c "$command") \
    || fail "Claude SessionStart registration did not execute"
  [ "$(cat "$log")" = "$(printf 'session-start\t\t%s\nsession-start\t\t%s' \
      "$payload" "$payload")" ] \
    || fail "SessionStart registrations did not execute only the ordinary startup path: $(cat "$log")"
  : > "$log"

  command=$(jq -r '.hooks.PreCompact[0].hooks[0].command' "$fixture/.codex/hooks.json")
  printf '%s' "$payload" | (cd "$fixture" && FM_TEST_HOOK_LOG="$log" bash -c "$command") \
    || fail "Codex PreCompact registration did not execute"
  command=$(jq -r '.hooks.PreCompact[0].hooks[0].command' "$fixture/.claude/settings.json")
  printf '%s' "$payload" | (cd "$fixture" && CLAUDE_PROJECT_DIR="$fixture" \
    FM_TEST_HOOK_LOG="$log" bash -c "$command") \
    || fail "Claude PreCompact registration did not execute"
  [ "$(cat "$log")" = "$(printf 'hook\t%s\nhook --claude\t%s' \
      "$payload" "$payload")" ] \
    || fail "registered hooks did not dispatch exact arguments and stdin payloads: $(cat "$log")"
  pass "Codex and Claude register one compaction hook and one ordinary SessionStart hook"
}

test_manual_and_auto_boundaries_deduplicate
test_provider_matched_single_agent
test_empty_evidence_prevents_reset_safety
test_budget_bound_controls_reset_safety
test_failures_are_terminal_and_retrospective_still_runs
test_missing_and_failed_retrospective_preserve_stow
test_duplicate_running_worker_and_restart_recovery
test_orphaned_agent_blocks_a_second_boundary
test_pre_agent_interruption_remains_restartable
test_manual_reservation_and_non_primary_stand_down
test_snapshot_failure_refuses_both_hook_hosts
test_stale_manual_reservation_reconciles
test_secondmate_manual_reservation_without_automatic_hook
test_guard_requires_live_original_session
test_ambiguous_agent_group_leaves_a_boundary_restartable
test_stopped_capture_attempts_are_reconciled
test_combined_agent_is_not_replayed
test_exceptions_prevent_reset_safety
test_snapshot_capture_reconciles
test_failed_json_update_preserves_receipt
test_settled_evidence_retention
test_real_session_lock_ownership
test_hook_registration

printf 'all pre-compaction Stow tests passed\n'
