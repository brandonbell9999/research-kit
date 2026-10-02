#!/usr/bin/env bash
# experiment.sh -- Research Experiment Orchestrator for Claude Code
#
# Usage:
#   ./experiment.sh survey  <question>          # Survey prior work relevant to a research question
#   ./experiment.sh frame   <spec-file>         # Design experiment from hypothesis
#   ./experiment.sh run     <spec-file>         # Execute experiment (spec is locked)
#   ./experiment.sh read    <spec-file>         # Analyze results against pre-stated criteria
#   ./experiment.sh log     <spec-file>         # Commit results, update research log
#   ./experiment.sh cycle   <spec-file>         # Run frame -> run -> read -> log
#   ./experiment.sh full    <question> <spec>    # Run survey -> frame -> run -> read -> log
#   ./experiment.sh status                       # Show research program status (questions, results, budget)
#   ./experiment.sh program [--max-cycles N] [--dry-run]   # Auto-advance through open questions
#   ./experiment.sh synthesize [reason]          # Generate cumulative SYNTHESIS.md report
#   ./experiment.sh complete-handoff [file]      # Validate + archive HANDOFF.md to handoffs/completed/
#   ./experiment.sh validate-handoff [file]      # Check a handoff document for required sections
#   ./experiment.sh watch   [phase] [--resolve]  # Live-tail or summarize a phase log
#   ./experiment.sh help                         # Print usage
#
# Configure via environment variables or edit the defaults below.

set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Configuration -- edit these to match your project
# ──────────────────────────────────────────────────────────────

# Directories
EXPERIMENTS_DIR="${EXPERIMENTS_DIR:-experiments}"     # Experiment spec files
RESULTS_DIR="${RESULTS_DIR:-results}"                 # Results output
SRC_DIR="${SRC_DIR:-src}"                             # Model / training code
DATA_DIR="${DATA_DIR:-data}"                          # Datasets
CONFIGS_DIR="${CONFIGS_DIR:-configs}"                 # Training configs
NOTEBOOKS_DIR="${NOTEBOOKS_DIR:-notebooks}"           # Analysis notebooks (optional)

PROMPT_DIR=".claude/prompts"
HOOK_DIR=".claude/hooks"

# Commands -- override these for your project
TRAIN_CMD="${TRAIN_CMD:-echo 'Set TRAIN_CMD for your project'}"
EVAL_CMD="${EVAL_CMD:-echo 'Set EVAL_CMD for your project'}"
TEST_CMD="${TEST_CMD:-echo 'Set TEST_CMD for your project'}"       # Unit tests for infra code

# Resource constraints
MAX_GPU_HOURS="${MAX_GPU_HOURS:-4}"
MAX_RUNS="${MAX_RUNS:-10}"

# Log directory -- per-project isolation under /tmp
_project_name="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
EXP_LOG_DIR="${EXP_LOG_DIR:-/tmp/exp-${_project_name}}"
export EXP_LOG_DIR
mkdir -p "$EXP_LOG_DIR"

# Git / PR settings
EXP_AUTO_MERGE="${EXP_AUTO_MERGE:-false}"
EXP_DELETE_BRANCH="${EXP_DELETE_BRANCH:-false}"
EXP_BASE_BRANCH="${EXP_BASE_BRANCH:-main}"

# ──────────────────────────────────────────────────────────────
# Colors
# ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ──────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────

experiment_id_from_spec() {
  # Extract experiment ID from spec filename: experiments/exp-003-reward-shaping.md -> exp-003
  local spec="$1"
  local base
  base="$(basename "$spec" .md)"
  echo "$base"
}

results_dir_for_spec() {
  local spec="$1"
  local exp_id
  exp_id="$(experiment_id_from_spec "$spec")"
  echo "$RESULTS_DIR/$exp_id"
}

next_experiment_number() {
  local max=0
  for f in "$EXPERIMENTS_DIR"/exp-*.md; do
    [[ -f "$f" ]] || continue
    local num
    num=$(basename "$f" | sed -n 's/^exp-\([0-9]*\).*/\1/p')
    num=${num:-0}
    num=$((10#$num))  # Force base-10
    if (( num > max )); then
      max=$num
    fi
  done
  printf "%03d" $((max + 1))
}

lock_experiment_spec() {
  local spec="$1"
  if [[ -f "$spec" ]]; then
    chmod 444 "$spec"
    echo -e "   ${YELLOW}locked:${NC} $spec"
  fi
}

unlock_experiment_spec() {
  local spec="$1"
  if [[ -f "$spec" ]]; then
    chmod 644 "$spec"
    echo -e "   ${BLUE}unlocked:${NC} $spec"
  fi
}

lock_previous_results() {
  # Lock all existing result directories (prevent contamination)
  if [[ -d "$RESULTS_DIR" ]]; then
    find "$RESULTS_DIR" -type f -name "*.json" -exec chmod 444 {} \;
    find "$RESULTS_DIR" -type f -name "*.csv" -exec chmod 444 {} \;
    echo -e "   ${YELLOW}locked:${NC} previous results in $RESULTS_DIR"
  fi
}

unlock_all() {
  # Restore write permissions on everything
  if [[ -d "$RESULTS_DIR" ]]; then
    find "$RESULTS_DIR" -type f \( -name "*.json" -o -name "*.csv" \) -exec chmod 644 {} \; 2>/dev/null || true
    find "$RESULTS_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
  fi
  for f in "$EXPERIMENTS_DIR"/*.md; do
    [[ -f "$f" ]] && chmod 644 "$f" 2>/dev/null || true
  done
  echo -e "   ${BLUE}all files unlocked${NC}"
}

ensure_hooks_executable() {
  if [[ -f "$HOOK_DIR/pre-tool-use.sh" ]]; then
    chmod +x "$HOOK_DIR/pre-tool-use.sh"
  fi
}

_phase_summary() {
  # Extract the final agent message from the stream-json log and print a
  # compact summary.  This keeps the orchestrator's context window lean —
  # the full transcript stays on disk at $EXP_LOG_DIR/{phase}.log.
  local phase="$1"
  local exit_code="$2"
  local log="$EXP_LOG_DIR/${phase}.log"

  local summary
  summary=$(tail -20 "$log" 2>/dev/null | python3 -c "
import json, sys
texts = []
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        if d.get('type') == 'assistant':
            for c in d.get('message', {}).get('content', []):
                if c.get('type') == 'text':
                    texts.append(c['text'])
    except Exception:
        pass
if texts:
    print(texts[-1][:500])
" 2>/dev/null)

  if [[ -n "$summary" ]]; then
    echo -e "${YELLOW}[${phase}]${NC} $summary"
  fi
  echo -e "${YELLOW}[${phase}]${NC} Phase complete (exit: $exit_code). Log: $log"
  return "$exit_code"
}

list_experiment_specs() {
  find "$EXPERIMENTS_DIR" -maxdepth 1 -name "exp-*.md" -type f 2>/dev/null | sort || echo "none"
}

list_result_dirs() {
  find "$RESULTS_DIR" -maxdepth 1 -type d -name "exp-*" 2>/dev/null | sort || echo "none"
}

# ──────────────────────────────────────────────────────────────
# Status
# ──────────────────────────────────────────────────────────────

run_status() {
  echo ""
  echo -e "${BOLD}Research Program Status${NC}"
  echo -e "${BOLD}======================${NC}"
  echo ""

  # ── Open questions from QUESTIONS.md ──
  if [[ -f QUESTIONS.md ]]; then
    echo -e "${CYAN}Open Questions (QUESTIONS.md §4):${NC}"
    local in_section=false
    local q_total=0 q_not_started=0 q_in_progress=0 q_blocked=0 q_deferred=0
    while IFS= read -r line; do
      if [[ "$line" =~ ^##\ 4\. ]]; then
        in_section=true
        continue
      fi
      if $in_section && [[ "$line" =~ ^--- ]]; then
        break
      fi
      if $in_section && [[ "$line" =~ ^\|\ *P[0-9] ]]; then
        # Apply the same placeholder filter as select_next_question so the
        # counts match what `program` will actually pick up.
        local q_text
        q_text="$(printf '%s' "$line" | awk -F'|' '{print $3}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [[ "$q_text" == -* || "$q_text" == "Question" ]]; then
          continue
        fi
        if [[ "$q_text" == _*_ ]]; then
          continue   # template placeholder row, e.g. _Most important question_
        fi
        q_total=$((q_total + 1))
        if echo "$line" | grep -qi "not started"; then
          q_not_started=$((q_not_started + 1))
        elif echo "$line" | grep -qi "in progress"; then
          q_in_progress=$((q_in_progress + 1))
        elif echo "$line" | grep -qi "blocked"; then
          q_blocked=$((q_blocked + 1))
        elif echo "$line" | grep -qi "deferred"; then
          q_deferred=$((q_deferred + 1))
        fi
      fi
    done < QUESTIONS.md
    echo "  Total: $q_total  Not started: $q_not_started  In progress: $q_in_progress  Blocked: $q_blocked  Deferred: $q_deferred"
  else
    echo -e "  ${YELLOW}QUESTIONS.md not found${NC}"
  fi

  echo ""

  # ── Experiment results ──
  echo -e "${CYAN}Experiments:${NC}"
  local e_total=0 e_confirmed=0 e_refuted=0 e_inconclusive=0 e_incomplete=0
  if [[ -d "$RESULTS_DIR" ]]; then
    for d in "$RESULTS_DIR"/exp-*/; do
      [[ -d "$d" ]] || continue
      e_total=$((e_total + 1))
      local analysis="$d/analysis.md"
      if [[ -f "$analysis" ]]; then
        local verdict
        verdict=$(grep -m1 '^## Verdict:' "$analysis" 2>/dev/null | sed 's/^## Verdict:[[:space:]]*//' || true)
        case "$verdict" in
          *CONFIRMED*)    e_confirmed=$((e_confirmed + 1)) ;;
          *REFUTED*)      e_refuted=$((e_refuted + 1)) ;;
          *INCONCLUSIVE*) e_inconclusive=$((e_inconclusive + 1)) ;;
          *)              e_incomplete=$((e_incomplete + 1)) ;;
        esac
      else
        e_incomplete=$((e_incomplete + 1))
      fi
    done
  fi
  echo "  Total: $e_total  Confirmed: $e_confirmed  Refuted: $e_refuted  Inconclusive: $e_inconclusive  Incomplete: $e_incomplete"

  echo ""

  # ── Program state ──
  local state_file="${PROGRAM_STATE_FILE:-program_state.json}"
  if [[ -f "$state_file" ]]; then
    echo -e "${CYAN}Program State ($state_file):${NC}"
    python3 -c "
import json, sys
with open('$state_file') as f:
    s = json.load(f)
print(f\"  Cycles completed: {s.get('cycles_completed', 0)}\")
print(f\"  GPU hours used:   {s.get('gpu_hours_used', 0):.1f}\")
print(f\"  Started:          {s.get('started_at', 'N/A')}\")
print(f\"  Last cycle:       {s.get('last_cycle_at', 'N/A')}\")
" 2>/dev/null || echo "  (could not parse $state_file)"
  fi

  echo ""

  # ── Handoff / Synthesis status ──
  if [[ -f HANDOFF.md ]]; then
    echo -e "  ${YELLOW}HANDOFF.md exists${NC} — program loop is paused pending handoff resolution"
  fi
  if [[ -f SYNTHESIS.md ]]; then
    echo -e "  ${GREEN}SYNTHESIS.md exists${NC} — synthesis report has been generated"
  fi

  echo ""
}

# ──────────────────────────────────────────────────────────────
# Handoff Management
# ──────────────────────────────────────────────────────────────

validate_handoff() {
  local file="${1:-HANDOFF.md}"
  if [[ ! -f "$file" ]]; then
    echo -e "${RED}Error: $file not found${NC}" >&2
    return 1
  fi
  local valid=true
  for header in "# Handoff:" "**Date:**" "**Reason:**" "## What Is Needed" "## After Resolution"; do
    if ! grep -qF "$header" "$file"; then
      echo -e "${RED}Missing required section: $header${NC}" >&2
      valid=false
    fi
  done
  if $valid; then
    echo -e "${GREEN}HANDOFF.md is valid${NC}"
    return 0
  else
    return 1
  fi
}

complete_handoff() {
  local file="${1:-HANDOFF.md}"
  if [[ ! -f "$file" ]]; then
    echo -e "${RED}Error: $file not found${NC}" >&2
    return 1
  fi
  validate_handoff "$file" || return 1
  mkdir -p handoffs/completed
  local slug
  slug=$(grep -m1 '^# Handoff:' "$file" | sed 's/^# Handoff:[[:space:]]*//' | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
  local dest="handoffs/completed/$(date +%Y%m%d-%H%M%S)-${slug}.md"
  mv "$file" "$dest"
  echo -e "${GREEN}Handoff archived:${NC} $dest"
}

# ──────────────────────────────────────────────────────────────
# Phase Runners
# ──────────────────────────────────────────────────────────────

run_survey() {
  local question="${1:?Usage: experiment.sh survey <research-question-or-topic>}"

  echo ""
  echo -e "${CYAN}======================================================${NC}"
  echo -e "${CYAN}  SURVEY PHASE -- Prior Work & Codebase Review${NC}"
  echo -e "${CYAN}======================================================${NC}"
  echo -e "  Question: $question"
  echo ""

  export EXP_PHASE="survey"

  local exit_code=0
  claude \
    --output-format stream-json \
    --verbose \
    --append-system-prompt "$(cat "$PROMPT_DIR/survey.md")

## Context
- Research question / topic: $question
- Source directory: $SRC_DIR
- Existing experiments: $(list_experiment_specs | wc -l | tr -d ' ') spec(s) in $EXPERIMENTS_DIR (use Glob to discover)
- Existing results: $(list_result_dirs | wc -l | tr -d ' ') result dir(s) in $RESULTS_DIR (use Glob to discover)
- Research log: RESEARCH_LOG.md
- Research questions: QUESTIONS.md
- Train command: $TRAIN_CMD
- Eval command: $EVAL_CMD

Start by reading RESEARCH_LOG.md and QUESTIONS.md, then survey the codebase and prior experiments." \
    --allowed-tools "Read,Bash,Glob,Grep,Write" \
    -p "Survey the current state of knowledge on: $question" \
    > "$EXP_LOG_DIR/survey.log" 2>&1 || exit_code=$?

  _phase_summary "survey" "$exit_code"
}

run_frame() {
  local spec_file="${1:?Usage: experiment.sh frame <spec-file>}"

  # If spec_file doesn't exist yet, that's fine -- the agent will create it.
  # But the path should be in the experiments directory.
  if [[ "$(dirname "$spec_file")" != "$EXPERIMENTS_DIR" && "$(dirname "$spec_file")" != "." ]]; then
    echo -e "${YELLOW}Warning: Spec file not in $EXPERIMENTS_DIR/. Consider placing it there.${NC}"
  fi

  echo ""
  echo -e "${RED}======================================================${NC}"
  echo -e "${RED}  FRAME PHASE -- Hypothesis & Experiment Design${NC}"
  echo -e "${RED}======================================================${NC}"
  echo -e "  Spec:    $spec_file"
  echo -e "  Results: $RESULTS_DIR"
  echo ""

  # Ensure spec is writable for the design agent
  unlock_experiment_spec "$spec_file" 2>/dev/null || true

  export EXP_PHASE="frame"

  local exit_code=0
  claude \
    --output-format stream-json \
    --verbose \
    --append-system-prompt "$(cat "$PROMPT_DIR/frame.md")

## Context
- Experiment spec to write: $spec_file
- Source directory: $SRC_DIR
- Results directory: $RESULTS_DIR
- Existing experiments: $(list_experiment_specs | wc -l | tr -d ' ') spec(s) in $EXPERIMENTS_DIR (use Glob to discover)
- Existing results: $(list_result_dirs | wc -l | tr -d ' ') result dir(s) in $RESULTS_DIR (use Glob to discover)
- Research log: RESEARCH_LOG.md
- Train command: $TRAIN_CMD
- Eval command: $EVAL_CMD
- Max GPU hours budget: $MAX_GPU_HOURS
- Max runs budget: $MAX_RUNS

Read the RESEARCH_LOG.md and any survey output first, then design the experiment." \
    --allowed-tools "Read,Write,Edit,Bash,Glob,Grep" \
    -p "Design the experiment and write the spec to $spec_file" \
    > "$EXP_LOG_DIR/frame.log" 2>&1 || exit_code=$?

  _phase_summary "frame" "$exit_code"
}

run_run() {
  local spec_file="${1:?Usage: experiment.sh run <spec-file>}"

  if [[ ! -f "$spec_file" ]]; then
    echo -e "${RED}Error: Spec file not found: $spec_file${NC}" >&2
    exit 1
  fi

  local results_path
  results_path="$(results_dir_for_spec "$spec_file")"
  mkdir -p "$results_path"

  echo ""
  echo -e "${GREEN}======================================================${NC}"
  echo -e "${GREEN}  RUN PHASE -- Executing Experiment${NC}"
  echo -e "${GREEN}======================================================${NC}"
  echo -e "  Spec:    $spec_file ${YELLOW}(READ-ONLY)${NC}"
  echo -e "  Results: $results_path"
  echo -e "  Source:  $SRC_DIR"
  echo ""

  # OS-level enforcement: lock the spec and previous results
  lock_experiment_spec "$spec_file"
  lock_previous_results
  ensure_hooks_executable

  export EXP_PHASE="run"
  export EXP_SPEC_FILE="$spec_file"
  export EXP_RESULTS_DIR="$results_path"

  # Unlock on exit regardless of success/failure
  trap unlock_all EXIT

  # Freeze the spec into the results directory for reproducibility
  cp "$spec_file" "$results_path/spec.md"
  chmod 444 "$results_path/spec.md"

  local exit_code=0
  claude \
    --output-format stream-json \
    --verbose \
    --append-system-prompt "$(cat "$PROMPT_DIR/run.md")

## Context
- Experiment spec: $spec_file (READ-ONLY -- do not attempt to modify)
- Results output directory: $results_path
- Source directory: $SRC_DIR
- Config directory: $CONFIGS_DIR
- Data directory: $DATA_DIR
- Train command: $TRAIN_CMD
- Eval command: $EVAL_CMD
- Test command (unit tests): $TEST_CMD
- Max GPU hours: $MAX_GPU_HOURS
- Max runs: $MAX_RUNS

Read the experiment spec first. Implement and execute the experiment. Write ALL metrics to $results_path/metrics.json." \
    --allowed-tools "Read,Write,Edit,Bash,Glob,Grep" \
    -p "Read the experiment spec, implement, and execute. Write all metrics to $results_path/metrics.json" \
    > "$EXP_LOG_DIR/run.log" 2>&1 || exit_code=$?

  _phase_summary "run" "$exit_code"
}

run_read() {
  local spec_file="${1:?Usage: experiment.sh read <spec-file>}"

  if [[ ! -f "$spec_file" ]]; then
    echo -e "${RED}Error: Spec file not found: $spec_file${NC}" >&2
    exit 1
  fi

  local results_path
  results_path="$(results_dir_for_spec "$spec_file")"

  if [[ ! -d "$results_path" ]]; then
    echo -e "${RED}Error: Results directory not found: $results_path${NC}" >&2
    echo -e "${RED}Run 'experiment.sh run $spec_file' first.${NC}" >&2
    exit 1
  fi

  echo ""
  echo -e "${BLUE}======================================================${NC}"
  echo -e "${BLUE}  READ PHASE -- Analyzing Results${NC}"
  echo -e "${BLUE}======================================================${NC}"
  echo -e "  Spec:    $spec_file"
  echo -e "  Results: $results_path"
  echo ""

  export EXP_PHASE="read"
  export EXP_SPEC_FILE="$spec_file"
  export EXP_RESULTS_DIR="$results_path"

  # Lock metrics (can't change the numbers after the fact)
  if [[ -f "$results_path/metrics.json" ]]; then
    chmod 444 "$results_path/metrics.json"
    echo -e "   ${YELLOW}locked:${NC} $results_path/metrics.json"
  fi

  local exit_code=0
  claude \
    --output-format stream-json \
    --verbose \
    --append-system-prompt "$(cat "$PROMPT_DIR/read.md")

## Context
- Experiment spec: $spec_file
- Results directory: $results_path
- Metrics file: $results_path/metrics.json (READ-ONLY -- these are the ground truth numbers)
- Research log: RESEARCH_LOG.md
- Previous experiments: $(list_experiment_specs | wc -l | tr -d ' ') spec(s) in $EXPERIMENTS_DIR (use Glob to discover)
- Previous results: $(list_result_dirs | wc -l | tr -d ' ') result dir(s) in $RESULTS_DIR (use Glob to discover)

Read the spec and metrics, then write your analysis to $results_path/analysis.md. Address EVERY metric in the spec." \
    --allowed-tools "Read,Write,Edit,Bash,Glob,Grep" \
    -p "Analyze the experiment results. Write analysis to $results_path/analysis.md" \
    > "$EXP_LOG_DIR/read.log" 2>&1 || exit_code=$?

  _phase_summary "read" "$exit_code"
}

run_log() {
  local spec_file="${1:?Usage: experiment.sh log <spec-file>}"
  local exp_id
  exp_id="$(experiment_id_from_spec "$spec_file")"
  local results_path
  results_path="$(results_dir_for_spec "$spec_file")"

  echo ""
  echo -e "${MAGENTA}======================================================${NC}"
  echo -e "${MAGENTA}  LOG PHASE -- Committing & Updating Research Log${NC}"
  echo -e "${MAGENTA}======================================================${NC}"
  echo ""

  # Ensure everything is unlocked for commit
  unlock_all 2>/dev/null || true

  # Create feature branch
  local branch="experiment/${exp_id}"
  git checkout -b "$branch" 2>/dev/null || git checkout "$branch"

  # Stage all changes
  git add -A
  git commit -m "experiment(${exp_id}): complete SURVEY-FRAME-RUN-READ cycle

Spec: ${spec_file}
Results: ${results_path}/
Analysis: ${results_path}/analysis.md"

  # Push and create PR
  git push -u origin "$branch"

  local pr_body
  pr_body="## Experiment: ${exp_id}

**Spec:** \`${spec_file}\`
**Results:** \`${results_path}/\`

### Phases completed
- [x] SURVEY — prior work reviewed
- [x] FRAME — hypothesis and experiment designed
- [x] RUN — experiment executed, metrics collected
- [x] READ — results analyzed against pre-stated criteria

### Key files
- \`${results_path}/spec.md\` — frozen experiment spec
- \`${results_path}/metrics.json\` — raw metrics
- \`${results_path}/analysis.md\` — analysis and conclusions

---
*Generated by claude-research-kit*"

  local pr_url
  pr_url=$(gh pr create \
    --base "$EXP_BASE_BRANCH" \
    --title "experiment(${exp_id}): results and analysis" \
    --body "$pr_body")

  echo -e "  ${GREEN}PR created:${NC} $pr_url"

  if [[ "$EXP_AUTO_MERGE" == "true" ]]; then
    echo -e "  ${YELLOW}Auto-merging...${NC}"
    gh pr merge "$pr_url" --merge
    echo -e "  ${GREEN}Merged.${NC}"
    git checkout "$EXP_BASE_BRANCH"
    git pull
    if [[ "$EXP_DELETE_BRANCH" == "true" ]]; then
      git branch -d "$branch" 2>/dev/null || true
      echo -e "  ${GREEN}Branch deleted.${NC}"
    fi
  fi

  echo ""
  echo -e "${GREEN}======================================================${NC}"
  echo -e "${GREEN}  Logged! PR: $pr_url${NC}"
  echo -e "${GREEN}======================================================${NC}"
}

run_cycle() {
  # frame -> run -> read -> log (no survey -- assumes you've already surveyed)
  local spec_file="${1:?Usage: experiment.sh cycle <spec-file>}"

  echo -e "${BOLD}Running experiment cycle: FRAME -> RUN -> READ -> LOG${NC}"
  echo ""

  run_frame "$spec_file"
  echo -e "\n${YELLOW}--- Frame complete. Running experiment... ---${NC}\n"

  run_run "$spec_file"
  echo -e "\n${YELLOW}--- Run complete. Analyzing results... ---${NC}\n"

  run_read "$spec_file"
  echo -e "\n${YELLOW}--- Analysis complete. Logging... ---${NC}\n"

  run_log "$spec_file"

  echo ""
  echo -e "${BOLD}${GREEN}Experiment cycle complete.${NC}"
}

run_full() {
  # survey -> frame -> run -> read -> log
  local question="${1:?Usage: experiment.sh full <question> <spec-file>}"
  local spec_file="${2:?Usage: experiment.sh full <question> <spec-file>}"

  echo -e "${BOLD}Running full research cycle: SURVEY -> FRAME -> RUN -> READ -> LOG${NC}"
  echo ""

  run_survey "$question"
  echo -e "\n${YELLOW}--- Survey complete. Designing experiment... ---${NC}\n"

  run_frame "$spec_file"
  echo -e "\n${YELLOW}--- Frame complete. Running experiment... ---${NC}\n"

  run_run "$spec_file"
  echo -e "\n${YELLOW}--- Run complete. Analyzing results... ---${NC}\n"

  run_read "$spec_file"
  echo -e "\n${YELLOW}--- Analysis complete. Logging... ---${NC}\n"

  run_log "$spec_file"

  echo ""
  echo -e "${BOLD}${GREEN}Full research cycle complete.${NC}"
}

# ──────────────────────────────────────────────────────────────
# Synthesize
# ──────────────────────────────────────────────────────────────

run_synthesize() {
  local trigger="${1:-manual}"

  echo ""
  echo -e "${MAGENTA}======================================================${NC}"
  echo -e "${MAGENTA}  SYNTHESIZE PHASE -- Research Synthesis Report${NC}"
  echo -e "${MAGENTA}======================================================${NC}"
  echo -e "  Trigger: $trigger"
  echo ""

  # Build context listing
  local analysis_files
  analysis_files=$(find "$RESULTS_DIR" -name "analysis.md" -type f 2>/dev/null | wc -l | tr -d ' ')
  local completed_handoffs
  completed_handoffs=$(find handoffs/completed -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
  local state_info="N/A"
  if [[ -f "${PROGRAM_STATE_FILE:-program_state.json}" ]]; then
    state_info="${PROGRAM_STATE_FILE:-program_state.json}"
  fi

  export EXP_PHASE="synthesize"

  local exit_code=0
  claude \
    --output-format stream-json \
    --verbose \
    --append-system-prompt "$(cat "$PROMPT_DIR/synthesize.md")

## Context
- Trigger reason: $trigger
- Research questions: QUESTIONS.md
- Research log: RESEARCH_LOG.md
- Analysis files: ${analysis_files:-0} file(s) in $RESULTS_DIR/*/analysis.md (use Glob to discover)
- Completed handoffs: ${completed_handoffs:-0} file(s) in handoffs/completed/ (use Glob to discover)
- Program state: $state_info
- Results directory: $RESULTS_DIR

Read RESEARCH_LOG.md for summaries first. Use Glob to discover analysis files, then selectively read those you need detail on." \
    --allowed-tools "Read,Write,Glob,Grep" \
    -p "Synthesize all experiment results into SYNTHESIS.md. Trigger: $trigger" \
    > "$EXP_LOG_DIR/synthesize.log" 2>&1 || exit_code=$?

  _phase_summary "synthesize" "$exit_code"
}

# ──────────────────────────────────────────────────────────────
# Program Loop
# ──────────────────────────────────────────────────────────────

# Program mode configuration
MAX_PROGRAM_CYCLES="${MAX_PROGRAM_CYCLES:-10}"
MAX_PROGRAM_GPU_HOURS="${MAX_PROGRAM_GPU_HOURS:-40}"
INCONCLUSIVE_THRESHOLD="${INCONCLUSIVE_THRESHOLD:-3}"
PROGRAM_STATE_FILE="${PROGRAM_STATE_FILE:-program_state.json}"

init_program_state() {
  if [[ ! -f "$PROGRAM_STATE_FILE" ]]; then
    python3 -c "
import json, datetime
state = {
    'cycles_completed': 0,
    'gpu_hours_used': 0.0,
    'started_at': datetime.datetime.now().isoformat(),
    'last_cycle_at': None,
    'question_history': {},
    'cycle_log': []
}
with open('$PROGRAM_STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
"
    echo -e "${GREEN}Initialized:${NC} $PROGRAM_STATE_FILE"
  else
    echo -e "${BLUE}Resuming from:${NC} $PROGRAM_STATE_FILE"
  fi
}

record_cycle_result() {
  local question="$1" verdict="$2" gpu_hours="$3" spec_file="$4"
  python3 -c "
import json, datetime
with open('$PROGRAM_STATE_FILE') as f:
    state = json.load(f)
state['cycles_completed'] += 1
state['gpu_hours_used'] += float('$gpu_hours')
state['last_cycle_at'] = datetime.datetime.now().isoformat()
q = '''$question'''
if q not in state['question_history']:
    state['question_history'][q] = []
state['question_history'][q].append('$verdict')
state['cycle_log'].append({
    'cycle': state['cycles_completed'],
    'question': q,
    'verdict': '$verdict',
    'gpu_hours': float('$gpu_hours'),
    'spec_file': '$spec_file',
    'timestamp': datetime.datetime.now().isoformat()
})
with open('$PROGRAM_STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
"
}

select_next_question() {
  # Parses QUESTIONS.md §4 for the highest-priority non-Blocked/Deferred question
  # Skips questions with >= INCONCLUSIVE_THRESHOLD consecutive INCONCLUSIVEs
  # Skips sub-questions whose parent is already resolved
  # Deprioritizes questions with no decision gate when others have one
  # Outputs: the question text (or empty if none found)
  python3 -c "
import re, json, sys

threshold = int('$INCONCLUSIVE_THRESHOLD')

# Read question history
history = {}
try:
    with open('$PROGRAM_STATE_FILE') as f:
        state = json.load(f)
    history = state.get('question_history', {})
except (FileNotFoundError, json.JSONDecodeError):
    pass

# Parse QUESTIONS.md
try:
    with open('QUESTIONS.md') as f:
        content = f.read()
except FileNotFoundError:
    sys.exit(1)

# Find section 4 — collect all rows first to check parent status
lines = content.split('\n')
in_section = False
all_rows = []
for line in lines:
    if re.match(r'^## 4\.', line):
        in_section = True
        continue
    if in_section and line.strip() == '---':
        break
    if not in_section:
        continue
    # Split table cells
    cells = [c.strip() for c in line.split('|')]
    # Filter out empty strings from leading/trailing pipes
    cells = [c for c in cells if c]
    if len(cells) < 3:
        continue
    priority = cells[0]
    if not re.match(r'^P\d+$', priority):
        continue
    question = cells[1]
    status = cells[2].lower()
    # Skip header-like and placeholder rows
    if question.startswith('-') or question == 'Question':
        continue
    if question.startswith('_') and question.endswith('_'):
        continue
    # Extract optional columns (backward compatible with 4, 5, 6, or 7-col tables)
    parent = cells[3].strip() if len(cells) > 3 else '—'
    blocker = cells[4].strip() if len(cells) > 4 else '—'
    decision_gate = cells[5].strip() if len(cells) > 5 else '—'
    all_rows.append({
        'priority': priority,
        'question': question,
        'status': status,
        'parent': parent,
        'decision_gate': decision_gate,
    })

# Build set of resolved questions (by priority label or text) for parent check
resolved = set()
for r in all_rows:
    if r['status'] in ('answered', 'deferred'):
        resolved.add(r['priority'])
        resolved.add(r['question'])

# Also check §5 answered questions
in_answered = False
for line in lines:
    if re.match(r'^## 5\.', line):
        in_answered = True
        continue
    if in_answered and line.strip() == '---':
        break
    if in_answered and line.startswith('|'):
        cells = [c.strip() for c in line.split('|')]
        cells = [c for c in cells if c]
        if cells and not cells[0].startswith('-') and cells[0] != 'Question':
            resolved.add(cells[0])

# Filter candidates
candidates = []
for r in all_rows:
    if r['status'] in ('blocked', 'deferred', 'answered'):
        continue
    # Skip sub-questions whose parent is resolved
    if r['parent'] not in ('—', '-', ''):
        if r['parent'] in resolved:
            continue
    # Check consecutive INCONCLUSIVE count
    q_hist = history.get(r['question'], [])
    consec = 0
    for v in reversed(q_hist):
        if v == 'INCONCLUSIVE':
            consec += 1
        else:
            break
    if consec >= threshold:
        continue
    p_num = int(r['priority'][1:])
    has_gate = r['decision_gate'] not in ('—', '-', '', '_What decision changes?_')
    candidates.append((p_num, has_gate, r['question']))

if candidates:
    # Sort: priority first, then prefer questions with a decision gate
    candidates.sort(key=lambda x: (x[0], not x[1]))
    print(candidates[0][2])
"
}

extract_verdict() {
  local analysis_file="$1"
  if [[ -f "$analysis_file" ]]; then
    grep -m1 '^## Verdict:' "$analysis_file" 2>/dev/null | sed 's/^## Verdict:[[:space:]]*//' | tr -d '[:space:]' || echo "ERROR"
  else
    echo "ERROR"
  fi
}

extract_gpu_hours() {
  local metrics_file="$1"
  if [[ -f "$metrics_file" ]]; then
    python3 -c "
import json
try:
    with open('$metrics_file') as f:
        m = json.load(f)
    print(m.get('resource_usage', {}).get('gpu_hours', 0))
except:
    print(0)
" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

question_to_slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-40
}

run_program() {
  local max_cycles="$MAX_PROGRAM_CYCLES"
  local dry_run=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max-cycles) max_cycles="$2"; shift 2 ;;
      --dry-run)    dry_run=true; shift ;;
      *)            echo -e "${RED}Unknown argument: $1${NC}" >&2; return 1 ;;
    esac
  done

  echo ""
  echo -e "${BOLD}${CYAN}======================================================${NC}"
  echo -e "${BOLD}${CYAN}  PROGRAM MODE -- Auto-advancing Research Loop${NC}"
  echo -e "${BOLD}${CYAN}======================================================${NC}"
  echo -e "  Max cycles:     $max_cycles"
  echo -e "  GPU budget:     $MAX_PROGRAM_GPU_HOURS hours"
  echo -e "  Inconclusive threshold: $INCONCLUSIVE_THRESHOLD"
  echo -e "  Dry run:        $dry_run"
  echo ""

  init_program_state

  # SIGINT trap for clean interruption
  trap 'echo -e "\n${YELLOW}Program loop interrupted. State saved in $PROGRAM_STATE_FILE.${NC}"; exit 130' INT

  while true; do
    local cycles_completed
    cycles_completed=$(python3 -c "
import json
with open('$PROGRAM_STATE_FILE') as f:
    print(json.load(f).get('cycles_completed', 0))
" 2>/dev/null || echo "0")

    local gpu_hours_used
    gpu_hours_used=$(python3 -c "
import json
with open('$PROGRAM_STATE_FILE') as f:
    print(json.load(f).get('gpu_hours_used', 0))
" 2>/dev/null || echo "0")

    echo ""
    echo -e "${CYAN}── Cycle check (completed: $cycles_completed, GPU hours: $gpu_hours_used) ──${NC}"

    # ── Termination check 1: HANDOFF.md exists ──
    if [[ -f HANDOFF.md ]]; then
      echo -e "${YELLOW}HANDOFF.md exists — program loop paused.${NC}"
      echo -e "Resolve the handoff and run: ${BOLD}./experiment.sh complete-handoff${NC}"
      echo -e "Then resume: ${BOLD}./experiment.sh program${NC}"
      run_status
      return 0
    fi

    # ── Termination check 2: Max cycles reached ──
    if (( cycles_completed >= max_cycles )); then
      echo -e "${YELLOW}Max cycles reached ($max_cycles). Generating synthesis...${NC}"
      if ! $dry_run; then
        run_synthesize "max_cycles"
      else
        echo -e "  ${BLUE}[dry-run] Would run: synthesize max_cycles${NC}"
      fi
      return 0
    fi

    # ── Termination check 3: GPU budget exhausted ──
    local budget_exceeded
    budget_exceeded=$(python3 -c "print('yes' if float('$gpu_hours_used') >= float('$MAX_PROGRAM_GPU_HOURS') else 'no')")
    if [[ "$budget_exceeded" == "yes" ]]; then
      echo -e "${YELLOW}GPU budget exhausted (${gpu_hours_used}h / ${MAX_PROGRAM_GPU_HOURS}h). Generating synthesis...${NC}"
      if ! $dry_run; then
        run_synthesize "budget_exhausted"
      else
        echo -e "  ${BLUE}[dry-run] Would run: synthesize budget_exhausted${NC}"
      fi
      return 0
    fi

    # ── Termination check 4: No unblocked questions ──
    local next_question
    next_question=$(select_next_question)
    if [[ -z "$next_question" ]]; then
      echo -e "${GREEN}No unblocked questions remaining. Generating synthesis...${NC}"
      if ! $dry_run; then
        run_synthesize "all_resolved"
      else
        echo -e "  ${BLUE}[dry-run] Would run: synthesize all_resolved${NC}"
      fi
      return 0
    fi

    # ── Pick next question and generate spec filename ──
    local next_num
    next_num=$(next_experiment_number)
    local slug
    slug=$(question_to_slug "$next_question")
    local spec_file="$EXPERIMENTS_DIR/exp-${next_num}-${slug}.md"

    echo -e "${BOLD}Next question:${NC} $next_question"
    echo -e "${BOLD}Spec file:${NC}    $spec_file"

    if $dry_run; then
      echo -e "  ${BLUE}[dry-run] Would run: survey → frame → run → read → log${NC}"
      # Simulate cycle completion for dry-run state
      record_cycle_result "$next_question" "DRY_RUN" "0" "$spec_file"
      continue
    fi

    # ── Check if survey already exists for this question ──
    local survey_exists=false
    for sf in "$EXPERIMENTS_DIR"/survey-*.md; do
      [[ -f "$sf" ]] || continue
      # Simple heuristic: check if the survey file mentions key words from the question
      if grep -qi "$(echo "$next_question" | cut -d' ' -f1-3)" "$sf" 2>/dev/null; then
        survey_exists=true
        echo -e "  ${BLUE}Existing survey found:${NC} $sf (skipping survey phase)"
        break
      fi
    done

    # ── Run survey if needed ──
    if ! $survey_exists; then
      echo -e "\n${CYAN}── SURVEY ──${NC}"
      run_survey "$next_question" || {
        echo -e "${YELLOW}Survey failed, continuing to frame...${NC}"
      }
    fi

    # ── Run frame/run/read in a SUBSHELL to isolate trap ──
    echo -e "\n${CYAN}── FRAME / RUN / READ (subshell) ──${NC}"
    local subshell_exit=0
    (
      run_frame "$spec_file"
      echo -e "\n${YELLOW}--- Frame complete. Running experiment... ---${NC}\n"
      run_run "$spec_file"
      echo -e "\n${YELLOW}--- Run complete. Analyzing results... ---${NC}\n"
      run_read "$spec_file"
    ) || subshell_exit=$?

    if (( subshell_exit != 0 )); then
      echo -e "${RED}Cycle failed (exit code: $subshell_exit). Recording ERROR and continuing...${NC}"
      record_cycle_result "$next_question" "ERROR" "0" "$spec_file"
      continue
    fi

    # ── Run LOG outside subshell (needs git state in parent) ──
    echo -e "\n${CYAN}── LOG ──${NC}"
    run_log "$spec_file" || {
      echo -e "${YELLOW}Log phase failed, but experiment results are saved.${NC}"
    }

    # ── Extract verdict and GPU hours, record in state ──
    local results_path
    results_path="$(results_dir_for_spec "$spec_file")"
    local verdict
    verdict=$(extract_verdict "$results_path/analysis.md")
    local gpu_hours
    gpu_hours=$(extract_gpu_hours "$results_path/metrics.json")

    record_cycle_result "$next_question" "$verdict" "$gpu_hours" "$spec_file"

    echo -e "\n${GREEN}Cycle complete:${NC} $verdict (${gpu_hours}h GPU)"

    # ── Warn on consecutive INCONCLUSIVE ──
    if [[ "$verdict" == "INCONCLUSIVE" ]]; then
      local consec_count
      consec_count=$(python3 -c "
import json
with open('$PROGRAM_STATE_FILE') as f:
    state = json.load(f)
q = '''$next_question'''
hist = state.get('question_history', {}).get(q, [])
c = 0
for v in reversed(hist):
    if v == 'INCONCLUSIVE':
        c += 1
    else:
        break
print(c)
" 2>/dev/null || echo "0")
      if (( consec_count >= INCONCLUSIVE_THRESHOLD )); then
        echo -e "${YELLOW}Warning: $consec_count consecutive INCONCLUSIVE for this question. It will be skipped in future cycles.${NC}"
      elif (( consec_count >= 2 )); then
        echo -e "${YELLOW}Note: $consec_count consecutive INCONCLUSIVE for this question (threshold: $INCONCLUSIVE_THRESHOLD).${NC}"
      fi
    fi
  done
}

# ──────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────

case "${1:-help}" in
  survey)     shift; run_survey "$@" ;;
  frame)      shift; run_frame "$@" ;;
  run)        shift; run_run "$@" ;;
  read)       shift; run_read "$@" ;;
  log)        shift; run_log "$@" ;;
  cycle)      shift; run_cycle "$@" ;;
  full)       shift; run_full "$@" ;;
  status)     shift; run_status "$@" ;;
  program)    shift; run_program "$@" ;;
  synthesize)        shift; run_synthesize "${1:-manual}" ;;
  complete-handoff)  shift; complete_handoff "$@" ;;
  validate-handoff)  shift; validate_handoff "$@" ;;
  watch)             shift; python3 scripts/experiment-watch.py "$@" ;;
  help|*)
    echo "Usage: experiment.sh <phase> [args]"
    echo ""
    echo "Phases:"
    echo "  survey      <question>             Survey prior work for a research question"
    echo "  frame       <spec-file>            Design experiment (write spec)"
    echo "  run         <spec-file>            Execute experiment (spec is locked)"
    echo "  read        <spec-file>            Analyze results against spec"
    echo "  log         <spec-file>            Commit results, create PR"
    echo "  cycle       <spec-file>            Run frame -> run -> read -> log"
    echo "  full        <question> <spec-file> Run survey -> frame -> run -> read -> log"
    echo "  status                             Show research program status"
    echo "  program     [--max-cycles N] [--dry-run]  Auto-advance through research questions"
    echo "  synthesize  [reason]               Generate synthesis report"
    echo "  complete-handoff [file]            Validate and archive HANDOFF.md to handoffs/completed/"
    echo "  validate-handoff [file]            Check a handoff document for required sections"
    echo "  watch       [phase]                Live-tail a running phase (--resolve for summary, --help for usage)"
    echo ""
    echo "Environment:"
    echo "  SRC_DIR='src'                  Source / model code directory"
    echo "  DATA_DIR='data'                Dataset directory"
    echo "  CONFIGS_DIR='configs'          Config directory"
    echo "  TRAIN_CMD='...'                Training command"
    echo "  EVAL_CMD='...'                 Evaluation command"
    echo "  TEST_CMD='...'                 Unit test command"
    echo "  EXP_LOG_DIR='/tmp/exp-<project>'  Log directory (auto-derived from repo name)"
    echo "  MAX_GPU_HOURS='4'              Budget per experiment"
    echo "  MAX_RUNS='10'                  Max training runs per experiment"
    echo "  MAX_PROGRAM_CYCLES='10'        Max cycles in program mode"
    echo "  MAX_PROGRAM_GPU_HOURS='40'     Total GPU budget for program mode"
    echo "  INCONCLUSIVE_THRESHOLD='3'     Max consecutive INCONCLUSIVE before skipping"
    echo "  EXP_AUTO_MERGE='false'         Auto-merge PR after creation"
    echo "  EXP_BASE_BRANCH='main'         Base branch for PRs"
    ;;
esac
