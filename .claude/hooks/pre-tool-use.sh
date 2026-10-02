#!/usr/bin/env bash
# .claude/hooks/pre-tool-use.sh
#
# Blocks inappropriate file modifications during research experiment phases.
# The EXP_PHASE env var is set by experiment.sh.
#
# Claude Code PreToolUse hooks receive a single JSON object on STDIN:
#   {
#     "tool_name":  "Bash" | "Edit" | "Write" | "MultiEdit" | ...,
#     "tool_input": { "command": "..." }            # for Bash
#                   { "file_path": "...", ... }     # for Edit / Write / MultiEdit
#   }
#
# Exit codes (Claude Code contract):
#   0 -- allow the tool call
#   2 -- BLOCK the tool call; stderr is shown to the agent as the reason
#   (exit 1 is a non-blocking error and must NOT be used to deny)
#
# Requires: jq (https://jqlang.github.io/jq/). If jq is missing the hook
# warns on stderr and allows the call so a session is never broken.
#
# Compatible with bash 3.2 (macOS /bin/bash).

set -euo pipefail

PHASE="${EXP_PHASE:-}"

# Only enforce during run, read, and synthesize phases.
if [[ "$PHASE" != "run" && "$PHASE" != "read" && "$PHASE" != "synthesize" ]]; then
  exit 0
fi

PHASE_UPPER="$(printf '%s' "$PHASE" | tr '[:lower:]' '[:upper:]')"

# ── Read the hook payload once from stdin ──
INPUT_JSON="$(cat)"
if [[ -z "$INPUT_JSON" ]]; then
  # Nothing to inspect; do not break the session.
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "WARNING: pre-tool-use.sh requires jq to parse hook input; jq not found." >&2
  echo "   Phase enforcement is DISABLED for this call. Install jq to restore it." >&2
  exit 0
fi

if ! TOOL_NAME="$(printf '%s' "$INPUT_JSON" | jq -r '.tool_name // empty' 2>/dev/null)"; then
  echo "WARNING: pre-tool-use.sh could not parse hook input as JSON; allowing call." >&2
  exit 0
fi

# INPUT holds the string the phase rules match against:
#   Bash                   -> tool_input.command
#   Edit/Write/MultiEdit   -> tool_input.file_path
case "$TOOL_NAME" in
  Bash)
    INPUT="$(printf '%s' "$INPUT_JSON" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
    ;;
  Edit|Write|MultiEdit)
    INPUT="$(printf '%s' "$INPUT_JSON" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
    ;;
  *)
    # Not a tool we enforce on.
    exit 0
    ;;
esac

# ── Common: Block permission escalation in all enforced phases ──
if [[ "$TOOL_NAME" == "Bash" ]]; then
  # Block permission/ownership changes (and `install`, incl. pip/uv/npm install)
  if echo "$INPUT" | grep -qEi '(chmod|chown|sudo|doas|install\s|uv\s+add\s)'; then
    echo "BLOCKED: Permission-modifying commands are not allowed during ${PHASE_UPPER} phase." >&2
    echo "   File permissions are enforced by the experiment orchestrator." >&2
    exit 2
  fi

  # Block git commands that could revert protected files
  if echo "$INPUT" | grep -qEi 'git\s+(checkout|restore|stash|reset)\s'; then
    echo "BLOCKED: Git revert commands are not allowed during ${PHASE_UPPER} phase." >&2
    echo "   Experiment specs and results must not be reverted or modified." >&2
    exit 2
  fi
fi

# ── RUN phase: Protect experiment specs and previous results ──
if [[ "$PHASE" == "run" ]]; then

  # Patterns that identify experiment spec files
  SPEC_PATTERNS='(experiments/.*\.md|/experiments/.*\.md)'
  # Patterns that identify previous result files (not the current experiment's output dir)
  PREV_RESULTS_PATTERNS='(results/exp-.*/(metrics|analysis|spec)\.(json|md|csv))'

  if [[ "$TOOL_NAME" == "Bash" ]]; then
    # Block direct writes to spec files via bash
    if echo "$INPUT" | grep -qE "$SPEC_PATTERNS"; then
      if echo "$INPUT" | grep -qEi '(>|tee|sed\s+-i|awk.*-i|perl\s+-[pi]|mv\s|cp\s.*>|rm\s)'; then
        echo "BLOCKED: Cannot modify experiment specs via shell during RUN phase." >&2
        echo "   The experiment spec is your contract. Implement to satisfy it." >&2
        exit 2
      fi
    fi

    # Block writes to RESEARCH_LOG.md
    if echo "$INPUT" | grep -qE 'RESEARCH_LOG\.md'; then
      if echo "$INPUT" | grep -qEi '(>|tee|sed\s+-i|awk.*-i|perl\s+-[pi])'; then
        echo "BLOCKED: Cannot modify RESEARCH_LOG.md during RUN phase." >&2
        echo "   The READ agent updates the research log." >&2
        exit 2
      fi
    fi
  fi

  # Block direct file writes to experiment specs
  if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "MultiEdit" ]]; then
    if echo "$INPUT" | grep -qE "$SPEC_PATTERNS"; then
      echo "BLOCKED: Cannot edit experiment specs during RUN phase." >&2
      echo "   The spec is your contract. Implement and execute it as designed." >&2
      exit 2
    fi
    if echo "$INPUT" | grep -qE 'RESEARCH_LOG\.md'; then
      echo "BLOCKED: Cannot modify RESEARCH_LOG.md during RUN phase." >&2
      echo "   The READ agent updates the research log." >&2
      exit 2
    fi
  fi
fi

# ── READ phase: Protect metrics and source code ──
if [[ "$PHASE" == "read" ]]; then

  METRICS_PATTERNS='(results/.*metrics\.(json|csv)|results/.*config\.json)'
  SOURCE_PATTERNS='(\.py$|\.cpp$|\.cu$|\.h$|\.hpp$|\.c$|\.rs$|\.jl$|\.ts$|\.js$|\.yaml$|\.yml$|\.toml$)'
  # Allow writing to analysis.md and RESEARCH_LOG.md (the READ agent's job)

  if [[ "$TOOL_NAME" == "Bash" ]]; then
    # Block writes to metrics files
    if echo "$INPUT" | grep -qE "$METRICS_PATTERNS"; then
      if echo "$INPUT" | grep -qEi '(>|tee|sed\s+-i|awk.*-i|perl\s+-[pi]|mv\s|cp\s.*>|rm\s)'; then
        echo "BLOCKED: Cannot modify metrics files during READ phase." >&2
        echo "   The numbers are sacred. Analyze them as-is." >&2
        exit 2
      fi
    fi

    # Block running training/evaluation (no re-running experiments)
    if echo "$INPUT" | grep -qEi '(python\s+train|python\s+eval|python\s+run|\.\/train|\.\/eval)'; then
      echo "BLOCKED: Cannot run training or evaluation during READ phase." >&2
      echo "   Analyze the existing results. If more data is needed, propose a follow-up experiment." >&2
      exit 2
    fi
  fi

  # Block direct writes to metrics files
  if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "MultiEdit" ]]; then
    if echo "$INPUT" | grep -qE "$METRICS_PATTERNS"; then
      echo "BLOCKED: Cannot edit metrics files during READ phase." >&2
      echo "   The numbers are sacred. Analyze them as-is." >&2
      exit 2
    fi
    # Block writes to source code during READ
    if echo "$INPUT" | grep -qE "$SOURCE_PATTERNS"; then
      echo "BLOCKED: Cannot modify source code during READ phase." >&2
      echo "   Your job is analysis, not implementation. Write to analysis.md instead." >&2
      exit 2
    fi
    # Block writes to experiment specs during READ
    if echo "$INPUT" | grep -qE '(experiments/.*\.md|/experiments/.*\.md)'; then
      echo "BLOCKED: Cannot modify experiment specs during READ phase." >&2
      echo "   You cannot retroactively change what success means." >&2
      exit 2
    fi
  fi
fi

# ── SYNTHESIZE phase: Only allow writes to SYNTHESIS.md ──
if [[ "$PHASE" == "synthesize" ]]; then

  if [[ "$TOOL_NAME" == "Bash" ]]; then
    # Block all shell write operations
    if echo "$INPUT" | grep -qEi '(>|tee|sed\s+-i|awk.*-i|perl\s+-[pi]|mv\s|cp\s.*>|rm\s)'; then
      echo "BLOCKED: Shell write operations are not allowed during SYNTHESIZE phase." >&2
      echo "   Use the Write tool to create SYNTHESIS.md only." >&2
      exit 2
    fi
    # Block running training/evaluation
    if echo "$INPUT" | grep -qEi '(python\s+train|python\s+eval|python\s+run|\.\/train|\.\/eval)'; then
      echo "BLOCKED: Cannot run training or evaluation during SYNTHESIZE phase." >&2
      exit 2
    fi
  fi

  if [[ "$TOOL_NAME" == "Edit" || "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "MultiEdit" ]]; then
    if ! echo "$INPUT" | grep -qE 'SYNTHESIS\.md'; then
      echo "BLOCKED: During SYNTHESIZE phase, you may only write to SYNTHESIS.md." >&2
      echo "   All other files are read-only during synthesis." >&2
      exit 2
    fi
  fi
fi

exit 0
