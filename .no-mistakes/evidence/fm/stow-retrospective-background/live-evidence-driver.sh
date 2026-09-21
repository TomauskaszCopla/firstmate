#!/usr/bin/env bash
# Opt-in real-Codex proof for the pre-compaction Stow boundary. Each case uses
# a standalone temporary repository because Codex project-hook discovery from a
# linked worktree is not a reliable proof surface. The parent Codex is real;
# only the expensive detached provider-matched agent is replaced with one
# deterministic combined Stow and Retrospective result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_STOW_PRECOMPACT_LIVE_E2E codex jq

CODEX_BIN=$(command -v codex)
CODEX_VERSION=$($CODEX_BIN --version 2>/dev/null | head -1)
REAL_CODEX_HOME=${CODEX_HOME:-$HOME/.codex}
REAL_CODEX_CONFIG=$REAL_CODEX_HOME/config.toml
SELECTED_PROVIDER=$(sed -n 's/^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$REAL_CODEX_CONFIG" | head -1)
SELECTED_MODEL=$(sed -n 's/^[[:space:]]*model[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$REAL_CODEX_CONFIG" | head -1)
SELECTED_EFFORT=$(sed -n 's/^[[:space:]]*model_reasoning_effort[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$REAL_CODEX_CONFIG" | head -1)
[ -n "$SELECTED_PROVIDER" ] && [ -n "$SELECTED_MODEL" ] && [ -n "$SELECTED_EFFORT" ] \
  || fail "the selected Codex provider, model, and reasoning effort could not be read"
PLUGIN_RECORD=$($CODEX_BIN plugin list --json 2>/dev/null | jq -ce '
  [.. | objects
    | select(.pluginId? == "ai-team-tomas-skills@ai-team-skills")
    | select(.installed == true and .enabled == true)
    | {pluginId,marketplaceName,name,version,installed:true,enabled:true}]
  | unique | select(length == 1)
') || fail "the current enabled ai-team-tomas-skills plugin could not be resolved"
PLUGIN_ID=$(printf '%s' "$PLUGIN_RECORD" | jq -er '.[0].pluginId') \
  || fail "the current ai-team-tomas-skills plugin id could not be resolved"
PLUGIN_MARKETPLACE=$(printf '%s' "$PLUGIN_RECORD" | jq -er '.[0].marketplaceName') \
  || fail "the current ai-team-tomas-skills marketplace could not be resolved"
PLUGIN_CONFIG_SECTION=$(awk -v section="[plugins.\"$PLUGIN_ID\"]" '
  $0 == section { emit=1 }
  emit && /^\[/ && $0 != section { exit }
  emit { print }
' "$REAL_CODEX_CONFIG")
[ -n "$PLUGIN_CONFIG_SECTION" ] \
  || fail "the enabled ai-team-tomas-skills config table could not be read"
PLUGIN_MARKETPLACE_SECTION=$(awk -v section="[marketplaces.$PLUGIN_MARKETPLACE]" '
  $0 == section { emit=1 }
  emit && /^\[/ && $0 != section { exit }
  emit { print }
' "$REAL_CODEX_CONFIG")
[ -n "$PLUGIN_MARKETPLACE_SECTION" ] \
  || fail "the ai-team-tomas-skills marketplace config table could not be read"
[ -f "$REAL_CODEX_HOME/auth.json" ] \
  || fail "the real Codex live test requires $REAL_CODEX_HOME/auth.json"

LAB=${TMPDIR:-/tmp}/fm-stow-precompact-live-e2e.$$
MANUAL_PID=
AUTO_PID=

cleanup() {
  local rc=$?
  trap - EXIT
  exec 7>&- 8<&- 2>/dev/null || true
  if [ -n "$MANUAL_PID" ]; then
    kill "$MANUAL_PID" >/dev/null 2>&1 || true
    wait "$MANUAL_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$AUTO_PID" ]; then
    kill "$AUTO_PID" >/dev/null 2>&1 || true
    wait "$AUTO_PID" >/dev/null 2>&1 || true
  fi
  python3 - "$LAB" <<'CAPTURE'
from pathlib import Path
import shutil, sys
root=Path(sys.argv[1])
out=Path('/Users/tb/.no-mistakes/evidence/01M32DWWKP0HVX8V5KS7YP0YW5/live-products')
for pattern in ('**/receipt.json','**/completion.json','**/combined-result.json','**/agent.log','**/app-server.jsonl','**/parent.jsonl'):
    for src in root.glob(pattern):
        target=out/src.relative_to(root)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src,target)
CAPTURE
  rm -rf -- "$LAB"
  exit "$rc"
}
trap cleanup EXIT INT TERM

rpc_send() { printf '%s\n' "$1" >&7; }

rpc_wait_id() { # <id>
  local wanted=$1 line
  while IFS= read -r line <&8; do
    printf '%s\n' "$line" >> "$manual_lab/app-server.jsonl"
    if printf '%s' "$line" | jq -e --argjson id "$wanted" '.id == $id' >/dev/null 2>&1; then
      RPC_RESPONSE=$line
      return 0
    fi
  done
  return 1
}

rpc_wait_method() { # <method>
  local wanted=$1 line
  while IFS= read -r line <&8; do
    printf '%s\n' "$line" >> "$manual_lab/app-server.jsonl"
    if printf '%s' "$line" | jq -e --arg method "$wanted" '.method == $method' >/dev/null 2>&1; then
      RPC_RESPONSE=$line
      return 0
    fi
  done
  return 1
}

write_codex_home() { # <lab>
  local lab=$1 quoted_lab
  mkdir -p "$lab/codex-home"
  ln -s "$REAL_CODEX_HOME/auth.json" "$lab/codex-home/auth.json"
  ln -s "$REAL_CODEX_HOME/plugins" "$lab/codex-home/plugins"
  quoted_lab=$(printf '%s' "$lab" | jq -Rs .)
  {
    sed -n '/^[[:space:]]*model_provider[[:space:]]*=/p; /^[[:space:]]*model[[:space:]]*=/p; /^[[:space:]]*model_reasoning_effort[[:space:]]*=/p' "$REAL_CODEX_CONFIG"
    awk -v section="[model_providers.$SELECTED_PROVIDER]" '
      $0 == section { emit=1 }
      emit && /^\[/ && $0 != section { exit }
      emit { print }
    ' "$REAL_CODEX_CONFIG"
    printf '%s\n' "$PLUGIN_CONFIG_SECTION"
    printf '%s\n' "$PLUGIN_MARKETPLACE_SECTION"
    printf '[projects.%s]\ntrust_level = "trusted"\n' "$quoted_lab"
  } > "$lab/codex-home/config.toml"
}

memory_fingerprint() { # <home>
  local home=$1 path
  for path in data/captain.md data/captain-shared.md data/learnings.md; do
    if [ -f "$home/$path" ] && [ ! -L "$home/$path" ]; then
      shasum -a 256 "$home/$path" | awk -v path="$path" '{print path "=" $1}'
    else
      printf '%s=absent\n' "$path"
    fi
  done
}

wait_for_file() { # <path> [attempts]
  local path=$1 attempts=${2:-900} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ -s "$path" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

job_dir() { # <lab>
  find "$1/data/stow-precompact" -mindepth 1 -maxdepth 1 -type d \
    ! -name attempts | LC_ALL=C sort | tail -1
}

make_lab() { # <name>
  local name lab stub
  name=$1
  lab=$LAB/$name
  mkdir -p "$lab/bin" "$lab/state" "$lab/data" "$lab/.codex" \
    "$lab/.agents/skills/stow" "$lab/codex-home"
  lab=$(cd "$lab" && pwd -P)
  git init -q -b main "$lab"
  git -C "$lab" config user.email fmtest@example.invalid
  git -C "$lab" config user.name fmtest
  printf '# Firstmate pre-compaction lab\n' > "$lab/AGENTS.md"

  cp "$ROOT/bin/fm-stow-precompact.sh" "$lab/bin/"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$lab/bin/"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$lab/bin/"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$lab/bin/"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$lab/bin/"
  cp "$ROOT/bin/fm-wake-lib.sh" "$lab/bin/"
  cp "$ROOT/bin/fm-config-inherit-lib.sh" "$lab/bin/"
  cp "$ROOT/bin/fm-classify-lib.sh" "$lab/bin/"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$lab/bin/"
  cp "$ROOT/bin/fm-startup-memory-budget-lib.sh" "$lab/bin/"
  cp "$ROOT/.agents/skills/stow/SKILL.md" "$lab/.agents/skills/stow/"
  cat >> "$lab/bin/fm-session-lock-lib.sh" <<'SH'

# The disposable harness process owns this fixture. Portable ownership and
# ancestry behavior is covered by fm-stow-precompact.test.sh.
fm_session_lock_owned_by_self() { return 0; }
SH
  cat > "$lab/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"fm-fleet-snapshot.v1","tasks":[],"backlog":{"records":[]}}'
SH
  for stub in fm-sessionstart-run.sh fm-arm-pretool-check.sh fm-cd-pretool-check.sh \
    fm-turnend-guard.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$lab/bin/$stub"
    chmod +x "$lab/bin/$stub"
  done
  chmod +x "$lab/bin/fm-stow-precompact.sh" "$lab/bin/fm-fleet-snapshot.sh"

  cp "$ROOT/.codex/hooks.json" "$lab/.codex/hooks.json"

  cat > "$lab/fake-codex" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = plugin ] && [ "${2:-}" = list ]; then
  printf '%s\n' "${FM_LIVE_PLUGIN_RECORD:?}"
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
printf 'started\n' > "${FM_LIVE_WORKER_HOLD:?}.started"
while [ -e "$FM_LIVE_WORKER_HOLD" ]; do sleep 0.1; done
marketplace=$(printf '%s' "$FM_LIVE_PLUGIN_RECORD" | jq -er '.[0].marketplaceName')
name=$(printf '%s' "$FM_LIVE_PLUGIN_RECORD" | jq -er '.[0].name')
version=$(printf '%s' "$FM_LIVE_PLUGIN_RECORD" | jq -er '.[0].version')
entry=$CODEX_HOME/plugins/cache/$marketplace/$name/$version/skills/retrospective/SKILL.md
jq -n --arg entry "$entry" '
  {stow:{status:"complete",reset_safe:true,summary:"stowed",
         effective_budget_tokens:7500,total_estimated_tokens_before:3,total_estimated_tokens_after:3,
         memory_actions:[
           {path:"data/captain.md",action:"unchanged",detail:"within budget"},
           {path:"data/captain-shared.md",action:"unchanged",detail:"within budget"},
           {path:"data/learnings.md",action:"unchanged",detail:"within budget"}
         ],
         durable_findings:[],open_work:[],exceptions:[]},
   retrospective:{entrypoint:$entry,status:"no-change",summary:"no change",
                  proof:["stow","retrospective"],exceptions:[]}}
' > "$result"
SH
  chmod +x "$lab/fake-codex"

  write_codex_home "$lab"
  printf '%s\n' "$$" > "$lab/state/.lock"
  : > "$lab/worker-hold"
  git -C "$lab" add -A
  git -C "$lab" commit -qm fixture
  printf '%s\n' "$lab"
}

assert_captured_boundary() { # <lab> <trigger>
  local lab=$1 trigger=$2 job receipt transcript bytes expected actual pid i=0
  job=
  while [ "$i" -lt 900 ] && [ -z "$job" ]; do
    job=$(job_dir "$lab" 2>/dev/null)
    [ -n "$job" ] || sleep 0.1
    i=$((i + 1))
  done
  if [ -z "$job" ]; then
    [ ! -f "$lab/parent.jsonl" ] || tail -80 "$lab/parent.jsonl" >&2
    fail "$trigger compaction published no job"
  fi
  receipt=$job/receipt.json
  wait_for_file "$lab/worker-hold.started" \
    || fail "$trigger detached worker never entered the combined agent"
  jq -e --arg trigger "$trigger" '
    .trigger == $trigger and .snapshot.transcript_bytes >= 1
    and (.snapshot.transcript_path | length >= 1)
    and (.snapshot.transcript_sha256 | length == 64)
    and .stages.snapshot_captured != null
    and .stages.worker_started != null
    and .reset_safe == false
  ' "$receipt" >/dev/null || fail "$trigger capture/start receipt is inaccurate"
  [ ! -e "$job/completion.json" ] \
    || fail "$trigger worker_started was incorrectly treated as completion"

  transcript=$(jq -r '.snapshot.transcript_path' "$receipt")
  bytes=$(jq -r '.snapshot.transcript_bytes' "$receipt")
  expected=$(jq -r '.snapshot.transcript_sha256' "$receipt")
  actual=$(head -c "$bytes" "$transcript" | shasum -a 256 | awk '{print $1}')
  [ "$(wc -c < "$job/transcript.jsonl" | tr -d ' ')" = "$bytes" ] \
    && [ "$(shasum -a 256 "$job/transcript.jsonl" | awk '{print $1}')" = "$expected" ] \
    && [ "$actual" = "$expected" ] \
    || fail "$trigger frozen transcript does not match the exact pre-compaction byte boundary"
  pid=$(jq -r '.worker.pid' "$receipt")
  kill -0 "$pid" 2>/dev/null || fail "$trigger detached worker died after hook return"
}

finish_worker() { # <lab> <trigger>
  local lab=$1 trigger=$2 job
  job=$(job_dir "$lab")
  rm -f -- "$lab/worker-hold"
  wait_for_file "$job/completion.json" \
    || fail "$trigger detached worker did not finish after the parent ended"
  jq -e '
    .state == "complete" and .reset_safe == true
    and .sequence == ["stow_local","retrospective"]
    and .agent == {harness:"codex",process_rc:0}
    and .stow.result.status == "complete"
    and .retrospective.result.status == "no-change"
  ' "$job/completion.json" >/dev/null \
    || fail "$trigger completion receipt is inaccurate"
}

manual_lab=$(make_lab manual)
manual_token=FM-STOW-MANUAL-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
printf '%s\n' "$manual_token" > "$manual_lab/ready-token.txt"
mkfifo "$manual_lab/app-server.in" "$manual_lab/app-server.out"
(
  cd "$manual_lab" || exit 1
  exec env CODEX_HOME="$manual_lab/codex-home" \
    FM_HOME="$manual_lab" FM_ROOT_OVERRIDE="$manual_lab" \
    FM_STOW_CODEX_BIN="$manual_lab/fake-codex" \
    FM_LIVE_PLUGIN_RECORD="$PLUGIN_RECORD" \
    FM_LIVE_WORKER_HOLD="$manual_lab/worker-hold" \
    "$CODEX_BIN" app-server --stdio --enable hooks --strict-config
) < "$manual_lab/app-server.in" > "$manual_lab/app-server.out" \
  2> "$manual_lab/app-server.log" &
MANUAL_PID=$!
exec 7> "$manual_lab/app-server.in"
exec 8< "$manual_lab/app-server.out"

rpc_send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"fm-stow-precompact-live","title":"Firstmate Stow live proof","version":"1"},"capabilities":{"experimentalApi":true}}}'
rpc_wait_id 1 || fail "the real Codex app-server did not initialize"
printf '%s' "$RPC_RESPONSE" | jq -e '.result.userAgent != null' >/dev/null \
  || { tail -80 "$manual_lab/app-server.log" >&2; fail "the real Codex app-server initialization failed"; }
rpc_send '{"jsonrpc":"2.0","method":"initialized"}'
rpc_send "$(jq -cn --arg cwd "$manual_lab" '{jsonrpc:"2.0",id:2,method:"thread/start",params:{cwd:$cwd,ephemeral:false,approvalPolicy:"never",sandbox:"read-only",config:{bypass_hook_trust:true}}}')"
rpc_wait_id 2 || fail "the real Codex thread/start response was not received"
manual_thread=$(printf '%s' "$RPC_RESPONSE" | jq -er '.result.thread.id') \
  || { tail -80 "$manual_lab/app-server.log" >&2; fail "the real Codex thread did not start"; }
rpc_send "$(jq -cn --arg thread "$manual_thread" --arg prompt "Reply with exactly $manual_token and nothing else." \
  '{jsonrpc:"2.0",id:3,method:"turn/start",params:{threadId:$thread,input:[{type:"text",text:$prompt,textElements:[]}]}}')"
rpc_wait_id 3 || fail "the real Codex turn/start response was not received"
printf '%s' "$RPC_RESPONSE" | jq -e '.result.turn.id != null' >/dev/null \
  || { tail -80 "$manual_lab/app-server.log" >&2; fail "the real Codex manual seed turn did not start"; }
rpc_wait_method turn/completed \
  || fail "the real Codex manual seed turn did not complete"
printf '%s' "$RPC_RESPONSE" | jq -e '
  .params.turn.status == "completed"
' >/dev/null \
  || { tail -80 "$manual_lab/app-server.log" >&2; tail -80 "$manual_lab/app-server.jsonl" >&2; fail "the real Codex manual seed turn failed"; }
rpc_send "$(jq -cn --arg thread "$manual_thread" '{jsonrpc:"2.0",id:4,method:"thread/compact/start",params:{threadId:$thread}}')"
rpc_wait_id 4 || fail "the real Codex manual compact response was not received"
printf '%s' "$RPC_RESPONSE" | jq -e 'has("result")' >/dev/null \
  || { tail -80 "$manual_lab/app-server.log" >&2; fail "the real Codex manual compact request failed"; }
rpc_wait_method hook/completed \
  || fail "the real Codex manual PreCompact hook did not return"
printf '%s' "$RPC_RESPONSE" | jq -e '
  .params.run.eventName == "preCompact" and .params.run.status == "completed"
' >/dev/null \
  || { tail -80 "$manual_lab/app-server.jsonl" >&2; fail "the real Codex manual PreCompact hook did not complete successfully"; }
assert_captured_boundary "$manual_lab" manual
exec 7>&- 8<&-
kill -TERM "$MANUAL_PID" \
  || fail "the real Codex manual parent could not be interrupted"
wait "$MANUAL_PID" >/dev/null 2>&1 || true
MANUAL_PID=
sleep 1
kill -0 "$(jq -r '.worker.pid' "$(job_dir "$manual_lab")/receipt.json")" 2>/dev/null \
  || fail "the manual detached worker did not survive parent-session interruption"
finish_worker "$manual_lab" manual
pass "$CODEX_VERSION manual /compact freezes the boundary before returning and its detached worker survives parent exit"

auto_lab=$(make_lab auto)
printf '%s\n' 'automatic compaction seed' > "$auto_lab/auto-seed.txt"
(
  cd "$auto_lab" || exit 1
  exec env CODEX_HOME="$auto_lab/codex-home" \
    FM_HOME="$auto_lab" FM_ROOT_OVERRIDE="$auto_lab" \
    FM_STOW_CODEX_BIN="$auto_lab/fake-codex" \
    FM_LIVE_PLUGIN_RECORD="$PLUGIN_RECORD" \
    FM_LIVE_WORKER_HOLD="$auto_lab/worker-hold" \
    "$CODEX_BIN" --enable hooks --strict-config \
      --dangerously-bypass-hook-trust -a never -s read-only \
      -c 'model_auto_compact_token_limit=1000' exec --json \
      'Read auto-seed.txt, then give a detailed 900-word explanation of automatic context compaction.'
) > "$auto_lab/parent.jsonl" 2>&1 &
AUTO_PID=$!
assert_captured_boundary "$auto_lab" auto
kill "$AUTO_PID" >/dev/null 2>&1 || true
wait "$AUTO_PID" >/dev/null 2>&1 || true
AUTO_PID=
sleep 1
kill -0 "$(jq -r '.worker.pid' "$(job_dir "$auto_lab")/receipt.json")" 2>/dev/null \
  || fail "the automatic detached worker did not survive parent-process interruption"
finish_worker "$auto_lab" auto
pass "$CODEX_VERSION automatic compaction fires trigger=auto and its detached worker survives parent exit"

real_lab=$LAB/real-worker
git clone -q "$ROOT" "$real_lab"
real_lab=$(cd "$real_lab" && pwd -P)
mkdir -p "$real_lab/state" "$real_lab/data" "$real_lab/config"
cp "$ROOT/bin/fm-stow-precompact.sh" "$real_lab/bin/"
cp "$ROOT/.agents/skills/stow/SKILL.md" "$real_lab/.agents/skills/stow/"
cat >> "$real_lab/bin/fm-session-lock-lib.sh" <<'SH'

# The disposable live-test process owns this isolated home.
fm_session_lock_owned_by_self() { return 0; }
SH
cat > "$real_lab/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"fm-fleet-snapshot.v1","tasks":[],"backlog":{"records":[]}}'
SH
chmod +x "$real_lab/bin/fm-stow-precompact.sh" "$real_lab/bin/fm-fleet-snapshot.sh"
write_codex_home "$real_lab"
mkdir -p "$real_lab/trace"
cat > "$real_lab/codex-trace" <<'SH'
#!/usr/bin/env bash
set -u
: "${FM_REAL_CODEX_BIN:?}"
: "${FM_REAL_CODEX_TRACE_DIR:?}"
trace=plugin-list-argv.json
for arg in "$@"; do
  case "$arg" in
    */combined-result.json) trace=combined-argv.json ;;
  esac
done
jq -n --args '$ARGS.positional' -- "$@" > "$FM_REAL_CODEX_TRACE_DIR/$trace"
if [ "$trace" = plugin-list-argv.json ]; then
  rc=0
  "$FM_REAL_CODEX_BIN" "$@" \
    > "$FM_REAL_CODEX_TRACE_DIR/plugin-list.stdout" \
    2> "$FM_REAL_CODEX_TRACE_DIR/plugin-list.stderr" || rc=$?
  cat "$FM_REAL_CODEX_TRACE_DIR/plugin-list.stdout"
  cat "$FM_REAL_CODEX_TRACE_DIR/plugin-list.stderr" >&2
  exit "$rc"
fi
exec "$FM_REAL_CODEX_BIN" "$@"
SH
chmod +x "$real_lab/codex-trace"
env CODEX_HOME="$real_lab/codex-home" \
  FM_REAL_CODEX_BIN="$CODEX_BIN" FM_REAL_CODEX_TRACE_DIR="$real_lab/trace" \
  "$real_lab/codex-trace" plugin list --json \
  | jq -e --arg id "$PLUGIN_ID" '
      [.. | objects
       | select(.pluginId? == $id and .installed == true and .enabled == true)]
      | length == 1
    ' >/dev/null \
  || fail "the isolated Codex home cannot resolve the current enabled plugin"
printf '%s\n' "$$" > "$real_lab/state/.lock"
printf '7500\n' > "$real_lab/config/startup-memory-budget"
printf '%s\n' '{"type":"message","role":"user","content":"No durable project or personal knowledge was added in this isolated proof."}' \
  > "$real_lab/real-transcript.jsonl"

production_home=${FM_HOME:-}
production_before=
if [ -n "$production_home" ] && [ -d "$production_home" ]; then
  production_before=$(memory_fingerprint "$production_home")
fi
real_payload=$(jq -cn --arg session real-worker-proof \
  --arg transcript "$real_lab/real-transcript.jsonl" --arg cwd "$real_lab" \
  '{session_id:$session,transcript_path:$transcript,cwd:$cwd,
    hook_event_name:"PreCompact",trigger:"manual"}')
real_out=$(printf '%s' "$real_payload" | env \
  CODEX_HOME="$real_lab/codex-home" FM_ROOT_OVERRIDE="$real_lab" FM_HOME="$real_lab" \
  FM_STATE_OVERRIDE="$real_lab/state" FM_DATA_OVERRIDE="$real_lab/data" \
  FM_CONFIG_OVERRIDE="$real_lab/config" \
  FM_STOW_CODEX_BIN="$real_lab/codex-trace" \
  FM_REAL_CODEX_BIN="$CODEX_BIN" FM_REAL_CODEX_TRACE_DIR="$real_lab/trace" \
  "$real_lab/bin/fm-stow-precompact.sh" hook) \
  || fail "the isolated real Stow worker could not be launched"
[ -z "$real_out" ] || fail "the isolated real Stow hook emitted unexpected output"
real_job=$(job_dir "$real_lab")
[ -n "$real_job" ] || fail "the isolated real Stow worker published no job"
wait_for_file "$real_job/completion.json" 12000 \
  || fail "the isolated real Stow worker did not complete within 20 minutes"
jq -e '
  .state == "complete" and .reset_safe == true
  and .sequence == ["stow_local","retrospective"]
  and .agent == {harness:"codex",process_rc:0}
  and .stow.result.status == "complete"
  and (.retrospective.result.status == "complete"
       or .retrospective.result.status == "no-change")
  and (.retrospective.entrypoint | endswith("/skills/retrospective/SKILL.md"))
' "$real_job/completion.json" >/dev/null \
  || { jq '{state,reset_safe,stow,retrospective}' "$real_job/completion.json" >&2; fail "the isolated real Stow and Retrospective receipt is not complete"; }
if [ -n "$production_before" ]; then
  [ "$production_before" = "$(memory_fingerprint "$production_home")" ] \
    || fail "the isolated real worker changed production startup-memory files"
fi
pass "$CODEX_VERSION isolated real worker completed Stow then the current installed Retrospective without production-memory changes"

printf 'all real Codex pre-compaction Stow assertions passed\n'
