#!/usr/bin/env bash
# tests/hook_test.sh -- exercise .claude/hooks/pre-tool-use.sh with sample
# Claude Code PreToolUse payloads and assert the allow (0) / block (2) exit codes.
#
# Usage:  bash tests/hook_test.sh
# Deps:   bash (3.2+), jq
#
# Set HOOK_BASH=/bin/bash to run the hook under a specific bash binary.

set -u

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$KIT_DIR/.claude/hooks/pre-tool-use.sh"
HOOK_BASH="$(command -v "${HOOK_BASH:-bash}")"   # absolute, so PATH tricks below still work

pass=0
fail=0

# payload <tool_name> <field> <value>  -> prints a hook JSON payload
payload() {
  jq -cn --arg tn "$1" --arg k "$2" --arg v "$3" '{tool_name: $tn, tool_input: {($k): $v}}'
}

# expect <exit> <phase> <tool_name> <value> [description]
#   phase "" means EXP_PHASE unset.
expect() {
  local want="$1" phase="$2" tool="$3" value="$4" desc="${5:-}"
  local field="command"
  [[ "$tool" != "Bash" ]] && field="file_path"
  local json got err
  json="$(payload "$tool" "$field" "$value")"
  if [[ -z "$phase" ]]; then
    err="$(printf '%s' "$json" | env -u EXP_PHASE "$HOOK_BASH" "$HOOK" 2>&1 >/dev/null)"; got=$?
  else
    err="$(printf '%s' "$json" | EXP_PHASE="$phase" "$HOOK_BASH" "$HOOK" 2>&1 >/dev/null)"; got=$?
  fi
  report "$want" "$got" "[${phase:-none}] $tool: $value ${desc:+-- $desc}" "$err"
}

# expect_raw <exit> <phase> <raw-stdin> <description>
expect_raw() {
  local want="$1" phase="$2" raw="$3" desc="$4"
  local got err
  err="$(printf '%s' "$raw" | EXP_PHASE="$phase" "$HOOK_BASH" "$HOOK" 2>&1 >/dev/null)"; got=$?
  report "$want" "$got" "[$phase] $desc" "$err"
}

report() {
  local want="$1" got="$2" label="$3" err="$4"
  if [[ "$want" == "$got" ]]; then
    pass=$((pass + 1))
    printf 'ok   exit=%s  %s\n' "$got" "$label"
  else
    fail=$((fail + 1))
    printf 'FAIL exit=%s (want %s)  %s\n' "$got" "$want" "$label"
    [[ -n "$err" ]] && printf '     stderr: %s\n' "$err"
  fi
}

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to run these tests" >&2
  exit 1
fi

echo "hook: $HOOK"
echo "bash: $("$HOOK_BASH" --version | head -1)"
echo ""

# ── Phases that are not enforced ──
expect 0 ""      Bash  "chmod 644 experiments/exp-001.md"      "no phase set"
expect 0 survey  Write "experiments/survey-topic.md"
expect 0 frame   Edit  "experiments/exp-001.md"
expect 0 log     Bash  "git checkout main"

# ── RUN phase ──
expect 2 run Bash  "chmod 644 experiments/exp-001.md"           "chmod"
expect 2 run Bash  "sudo rm -rf results"                         "sudo"
expect 2 run Bash  "pip install numpy"                           "pip install"
expect 2 run Bash  "uv add polars"                               "uv add"
expect 2 run Bash  "git checkout experiments/exp-001.md"         "git revert"
expect 2 run Bash  "echo hi > experiments/exp-001.md"            "shell write to spec"
expect 2 run Bash  "sed -i '' 's/a/b/' RESEARCH_LOG.md"          "shell write to research log"
expect 0 run Bash  "cat experiments/exp-001.md"                  "read spec"
expect 0 run Bash  "python train.py --config configs/a.yaml"     "training allowed"
expect 2 run Edit  "experiments/exp-001.md"                      "edit spec"
expect 2 run Write "/abs/path/experiments/exp-001.md"            "write spec (abs)"
expect 2 run MultiEdit "RESEARCH_LOG.md"                         "multiedit research log"
expect 0 run Write "src/train.py"                                "write source"
expect 0 run Write "results/exp-001/metrics.json"                "write metrics"
expect 0 run Read  "experiments/exp-001.md"                      "non-enforced tool"

# ── READ phase ──
expect 2 read Bash  "echo '{}' > results/exp-001/metrics.json"   "shell write metrics"
expect 2 read Bash  "python train.py"                            "re-run training"
expect 2 read Bash  "./eval --ckpt best.pt"                      "re-run eval"
expect 0 read Bash  "cat results/exp-001/metrics.json"           "read metrics"
expect 2 read Edit  "results/exp-001/metrics.json"               "edit metrics"
expect 2 read Write "results/exp-001/config.json"                "write config"
expect 2 read Edit  "src/model.py"                               "edit source"
expect 2 read Write "configs/a.yaml"                             "write config yaml"
expect 2 read Edit  "experiments/exp-001.md"                     "edit spec"
expect 0 read Write "results/exp-001/analysis.md"                "write analysis"
expect 0 read Edit  "RESEARCH_LOG.md"                            "update research log"

# ── SYNTHESIZE phase ──
expect 2 synthesize Bash  "echo x > notes.txt"                   "shell write"
expect 2 synthesize Bash  "rm results/exp-001/analysis.md"       "shell rm"
expect 2 synthesize Bash  "python run.py"                        "run"
expect 0 synthesize Bash  "cat RESEARCH_LOG.md"                  "read"
expect 0 synthesize Write "SYNTHESIS.md"                         "write synthesis"
expect 2 synthesize Write "RESEARCH_LOG.md"                      "write other file"
expect 2 synthesize Edit  "QUESTIONS.md"                         "edit other file"

# ── Robustness: never break the session ──
expect_raw 0 run ""            "empty stdin"
expect_raw 0 run "not json {"  "malformed JSON"
expect_raw 0 run '{"tool_name":"Bash"}' "missing tool_input"

# jq missing: run with a PATH containing only the non-jq tools the hook needs.
fakebin="$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX")"
for t in cat grep tr; do ln -s "$(command -v "$t")" "$fakebin/$t"; done
err="$(printf '%s' "$(payload Bash command 'chmod 644 experiments/exp-001.md')" \
  | EXP_PHASE=run PATH="$fakebin" "$HOOK_BASH" "$HOOK" 2>&1 >/dev/null)"; got=$?
rm -rf "$fakebin"
if [[ "$got" == "0" && "$err" == *"requires jq"* ]]; then
  pass=$((pass + 1)); echo "ok   exit=0  [run] jq missing -> allow with warning"
else
  fail=$((fail + 1)); echo "FAIL exit=$got  [run] jq missing -> expected exit 0 with warning; stderr: $err"
fi

echo ""
echo "passed: $pass  failed: $fail"
[[ "$fail" -eq 0 ]]
