#!/usr/bin/env python3
"""
Experiment Sub-Agent Monitor — a live dashboard for experiment.sh stream-json logs.

Usage:
    python3 scripts/experiment-watch.py              # auto-detects most recent phase
    python3 scripts/experiment-watch.py run           # watch the run phase
    python3 scripts/experiment-watch.py read          # watch the read phase
    python3 scripts/experiment-watch.py survey --resolve  # one-shot summary of survey phase
    python3 scripts/experiment-watch.py run --verbose  # show tool result output (build logs, metrics)

Parses the stream-json events emitted by `claude --output-format stream-json`
and renders a compact, human-readable live view.
"""

import json
import os
import re
import sys
import time
import glob
import signal
import textwrap
from datetime import datetime
from pathlib import Path

# ── ANSI helpers ──────────────────────────────────────────────────────────────

BOLD      = "\033[1m"
DIM       = "\033[2m"
RESET     = "\033[0m"
RED       = "\033[31m"
GREEN     = "\033[32m"
YELLOW    = "\033[33m"
BLUE      = "\033[34m"
MAGENTA   = "\033[35m"
CYAN      = "\033[36m"
WHITE     = "\033[37m"

CLEAR_LINE = "\033[2K"
MOVE_UP    = "\033[A"

PHASES = {"survey", "frame", "run", "read", "log"}

PHASE_COLORS = {
    "survey": CYAN,
    "frame": RED,
    "run": GREEN,
    "read": BLUE,
    "log": MAGENTA,
}

def strip_ansi(s: str) -> str:
    return re.sub(r'\033\[[0-9;]*m', '', s)


# ── State tracker ─────────────────────────────────────────────────────────────

class AgentState:
    def __init__(self):
        self.phase = "?"
        self.start_time = None
        self.model = None
        self.tool_calls = 0
        self.api_turns = 0
        self.files_read = []
        self.files_written = []
        self.files_edited = []
        self.bash_commands = []
        self.agent_texts = []
        self.metric_snapshots = []  # list of (metric_name, value) from metrics.json writes
        self.current_action = None
        self.current_tool_id = None
        self.sub_agents = 0
        self.errors = []
        self.done = False

    @property
    def elapsed(self) -> str:
        if not self.start_time:
            return "—"
        delta = datetime.now() - self.start_time
        mins = int(delta.total_seconds() // 60)
        secs = int(delta.total_seconds() % 60)
        return f"{mins}m {secs:02d}s"

    def phase_color(self) -> str:
        return PHASE_COLORS.get(self.phase, WHITE)


# ── Event processor ───────────────────────────────────────────────────────────

def process_banner_line(line: str, state: AgentState):
    """Handle non-JSON banner lines from experiment.sh."""
    plain = strip_ansi(line)
    if "SURVEY PHASE" in plain:
        state.phase = "survey"
    elif "FRAME PHASE" in plain:
        state.phase = "frame"
    elif "RUN PHASE" in plain:
        state.phase = "run"
    elif "READ PHASE" in plain:
        state.phase = "read"
    elif "LOG PHASE" in plain:
        state.phase = "log"


def process_event(data: dict, state: AgentState, verbose: bool = False) -> list[str]:
    """Process one stream-json event. Returns lines to display."""
    lines = []
    etype = data.get("type", "")

    if etype == "system":
        if not state.start_time:
            state.start_time = datetime.now()
        return []

    if etype != "assistant":
        msg = data.get("message", {})
        for c in msg.get("content", []):
            if c.get("type") == "tool_result":
                result_text = c.get("content", "")
                if isinstance(result_text, list):
                    result_text = " ".join(
                        r.get("text", "") for r in result_text if isinstance(r, dict)
                    )
                _extract_metrics(result_text, state)
                if verbose and isinstance(result_text, str) and result_text.strip():
                    lines.extend(_format_tool_result(result_text))
        return lines

    msg = data.get("message", {})
    if msg.get("model") and not state.model:
        state.model = msg["model"]

    state.api_turns += 1
    if not state.start_time:
        state.start_time = datetime.now()

    for c in msg.get("content", []):
        ct = c.get("type")

        if ct == "text":
            text = c["text"].strip()
            if text:
                state.agent_texts.append(text)
                wrapped = textwrap.fill(text, width=90, subsequent_indent="    ")
                lines.append(f"  {CYAN}> {RESET}{wrapped}")

        elif ct == "tool_use":
            state.tool_calls += 1
            name = c.get("name", "?")
            inp = c.get("input", {})
            tool_id = c.get("id", "")
            state.current_tool_id = tool_id
            line = _format_tool_call(name, inp, state)
            if line:
                lines.append(line)

    return lines


# Max lines of tool result output to show in verbose mode
VERBOSE_MAX_LINES = 30

def _format_tool_result(text: str) -> list[str]:
    """Format tool result output for verbose display. Shows errors prominently."""
    result_lines = text.strip().split("\n")
    is_error = any(kw in text.lower() for kw in [
        "error", "failed", "failure", "fatal", "undefined reference",
        "no such file", "permission denied", "traceback", "assert",
        "nan", "diverge",
    ])

    color = RED if is_error else DIM
    prefix = f"  {color}|{RESET} "

    formatted = []
    if len(result_lines) > VERBOSE_MAX_LINES:
        head = result_lines[:10]
        tail = result_lines[-15:]
        skipped = len(result_lines) - 25
        for rl in head:
            formatted.append(f"{prefix}{color}{rl[:200]}{RESET}")
        formatted.append(f"{prefix}{DIM}... ({skipped} lines omitted) ...{RESET}")
        for rl in tail:
            formatted.append(f"{prefix}{color}{rl[:200]}{RESET}")
    else:
        for rl in result_lines:
            formatted.append(f"{prefix}{color}{rl[:200]}{RESET}")

    return formatted


def _format_tool_call(name: str, inp: dict, state: AgentState) -> str:
    """Format a tool call into a single display line."""
    if name == "Read":
        fp = inp.get("file_path", "?")
        short = _short_path(fp)
        state.files_read.append(short)
        state.current_action = f"Reading {short}"
        return f"  {DIM}[read]{RESET}   {short}"

    elif name == "Write":
        fp = inp.get("file_path", "?")
        short = _short_path(fp)
        content = inp.get("content", "")
        state.files_written.append(short)
        state.current_action = f"Writing {short}"
        # Highlight metrics.json and analysis.md writes
        if "metrics.json" in short:
            return f"  {GREEN}[metrics]{RESET} {short}  {DIM}({len(content)} chars){RESET}"
        elif "analysis.md" in short:
            return f"  {BLUE}[analysis]{RESET} {short}  {DIM}({len(content)} chars){RESET}"
        return f"  {GREEN}[write]{RESET}  {short}  {DIM}({len(content)} chars){RESET}"

    elif name == "Edit":
        fp = inp.get("file_path", "?")
        short = _short_path(fp)
        old = inp.get("old_string", "")
        new = inp.get("new_string", "")
        state.files_edited.append(short)
        state.current_action = f"Editing {short}"
        delta = len(new) - len(old)
        sign = "+" if delta >= 0 else ""
        return f"  {YELLOW}[edit]{RESET}   {short}  {DIM}({sign}{delta} chars){RESET}"

    elif name == "Bash":
        cmd = inp.get("command", "?")
        desc = inp.get("description", "")
        display = desc if desc else cmd
        if len(display) > 80:
            display = display[:77] + "..."
        state.bash_commands.append(cmd)
        state.current_action = f"Running: {display}"

        # Categorize commands
        if any(kw in cmd for kw in ["python train", "python run", "./train", "torchrun"]):
            return f"  {MAGENTA}[train]{RESET}  {display}"
        elif any(kw in cmd for kw in ["python eval", "./eval", "python test"]):
            return f"  {MAGENTA}[eval]{RESET}   {display}"
        elif any(kw in cmd for kw in ["pytest", "unittest", "cargo test", "npm test"]):
            return f"  {MAGENTA}[test]{RESET}   {display}"
        elif any(kw in cmd for kw in ["pip install", "conda install", "npm install"]):
            return f"  {YELLOW}[deps]{RESET}   {display}"
        else:
            return f"  {BLUE}[bash]{RESET}   {display}"

    elif name == "Task":
        state.sub_agents += 1
        desc = inp.get("description", "sub-agent")
        state.current_action = f"Sub-agent: {desc}"
        return f"  {MAGENTA}[agent]{RESET}  {desc}"

    elif name == "Glob":
        pattern = inp.get("pattern", "?")
        state.current_action = f"Glob {pattern}"
        return f"  {DIM}[glob]{RESET}   {pattern}"

    elif name == "Grep":
        pattern = inp.get("pattern", "?")
        state.current_action = f"Grep {pattern}"
        return f"  {DIM}[grep]{RESET}   {pattern}"

    else:
        state.current_action = f"{name}"
        return f"  {DIM}[{name.lower()}]{RESET}   "


def _extract_metrics(text: str, state: AgentState):
    """Pull metric values from tool results."""
    if not isinstance(text, str):
        return
    # Look for common metric patterns in training output
    patterns = [
        (r'episodic_return[:\s=]+([0-9.e+-]+)', 'return'),
        (r'episode_length[:\s=]+([0-9.e+-]+)', 'ep_len'),
        (r'loss[:\s=]+([0-9.e+-]+)', 'loss'),
        (r'reward[:\s=]+([0-9.e+-]+)', 'reward'),
        (r'entropy[:\s=]+([0-9.e+-]+)', 'entropy'),
        (r'value_loss[:\s=]+([0-9.e+-]+)', 'v_loss'),
        (r'policy_loss[:\s=]+([0-9.e+-]+)', 'pi_loss'),
        (r'accuracy[:\s=]+([0-9.e+-]+)', 'acc'),
    ]
    for pattern, name in patterns:
        m = re.search(pattern, text, re.IGNORECASE)
        if m:
            try:
                val = float(m.group(1))
                state.metric_snapshots.append((name, val))
            except ValueError:
                pass


def _short_path(fp: str) -> str:
    """Shorten an absolute path to project-relative."""
    cwd = os.getcwd()
    if fp.startswith(cwd):
        return fp[len(cwd):].lstrip("/")
    return os.path.basename(fp)


# ── Display ───────────────────────────────────────────────────────────────────

def print_header(state: AgentState):
    """Print a sticky header bar."""
    pc = state.phase_color()
    phase_display = state.phase.upper() if state.phase != "?" else "STARTING"
    model_short = (state.model or "?").replace("claude-", "").split("-202")[0]

    unique_reads = len(set(state.files_read))
    unique_writes = len(set(state.files_written))
    unique_edits = len(set(state.files_edited))

    bar = (
        f"{BOLD}{pc}| EXP {phase_display} {RESET}"
        f" {DIM}|{RESET} {BOLD}{state.elapsed}{RESET}"
        f" {DIM}|{RESET} model: {model_short}"
        f" {DIM}|{RESET} turns: {state.api_turns}"
        f" {DIM}|{RESET} tools: {state.tool_calls}"
        f" {DIM}|{RESET} R:{unique_reads} W:{unique_writes} E:{unique_edits}"
    )

    if state.sub_agents:
        bar += f" {DIM}|{RESET} agents:{state.sub_agents}"

    metrics_summary = _latest_metrics_summary(state)
    if metrics_summary:
        bar += f" {DIM}|{RESET} {metrics_summary}"

    print(f"\n{bar}")
    print(f"  {DIM}{'─' * 88}{RESET}")


def _latest_metrics_summary(state: AgentState) -> str:
    """Summarize the most recent metric snapshots."""
    if not state.metric_snapshots:
        return ""
    # Show the latest value for each unique metric name
    latest = {}
    for name, val in state.metric_snapshots:
        latest[name] = val
    parts = []
    for name, val in list(latest.items())[-4:]:
        parts.append(f"{name}={val:.3g}")
    return " ".join(parts)


def print_summary(state: AgentState):
    """Print a final summary."""
    pc = state.phase_color()
    phase_display = state.phase.upper()

    print(f"\n{'=' * 60}")
    print(f"{BOLD}{pc}  EXP {phase_display} — COMPLETE{RESET}")
    print(f"{'=' * 60}")
    print(f"  Elapsed:      {state.elapsed}")
    print(f"  Model:        {state.model or '?'}")
    print(f"  API turns:    {state.api_turns}")
    print(f"  Tool calls:   {state.tool_calls}")
    print(f"  Files read:   {len(set(state.files_read))}")
    print(f"  Files written:{len(set(state.files_written))}")
    print(f"  Files edited: {len(set(state.files_edited))}")
    if state.sub_agents:
        print(f"  Sub-agents:   {state.sub_agents}")

    if state.files_written:
        print(f"\n  {GREEN}Files created/written:{RESET}")
        for f in sorted(set(state.files_written)):
            print(f"    + {f}")
    if state.files_edited:
        print(f"\n  {YELLOW}Files edited:{RESET}")
        for f in sorted(set(state.files_edited)):
            print(f"    ~ {f}")

    if state.metric_snapshots:
        latest = {}
        for name, val in state.metric_snapshots:
            latest[name] = val
        print(f"\n  {CYAN}Latest metrics:{RESET}")
        for name, val in latest.items():
            print(f"    {name}: {val}")

    if state.agent_texts:
        print(f"\n  {CYAN}Agent notes:{RESET}")
        for t in state.agent_texts[-5:]:
            wrapped = textwrap.fill(t, width=80, initial_indent="    ", subsequent_indent="    ")
            print(wrapped)

    print(f"{'=' * 60}\n")


# ── Main loop ─────────────────────────────────────────────────────────────────

def _get_log_dir() -> str:
    """Get the per-project log directory from env or derive it."""
    log_dir = os.environ.get("EXP_LOG_DIR")
    if log_dir:
        return log_dir
    import subprocess
    try:
        toplevel = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL, text=True
        ).strip()
        project = os.path.basename(toplevel)
    except (subprocess.CalledProcessError, FileNotFoundError):
        project = os.path.basename(os.getcwd())
    return f"/tmp/exp-{project}"


def usage() -> str:
    return (
        f"{BOLD}Usage:{RESET} experiment.sh watch [phase|logfile] [--resolve] [--verbose]\n"
        "\n"
        "  phase        one of: survey, frame, run, read, log  (default: most recent log)\n"
        "  logfile      explicit path to a stream-json log\n"
        "  --resolve    one-shot summary instead of live tail (alias: --summary)\n"
        "  --verbose    show tool result output (alias: -v)\n"
        "  --help       show this message\n"
        "\n"
        f"Logs are read from $EXP_LOG_DIR (currently: {_get_log_dir()}).\n"
        "Start a phase first:  ./experiment.sh survey \"your question\""
    )


def find_log_file() -> str:
    """Auto-detect the most recent *.log in the project log directory."""
    log_dir = _get_log_dir()
    candidates = glob.glob(f"{log_dir}/*.log")
    if not candidates:
        print(f"{YELLOW}No log files found in {log_dir}/ -- nothing to watch yet.{RESET}\n")
        print(usage())
        sys.exit(0)
    best = max(candidates, key=os.path.getmtime)
    return best


def tail_follow(filepath: str):
    """Generator that yields new lines from a file, following like tail -f."""
    with open(filepath, "r") as f:
        while True:
            line = f.readline()
            if not line:
                break
            yield line

        while True:
            line = f.readline()
            if line:
                yield line
            else:
                time.sleep(0.3)


def run_resolve(filepath: str, verbose: bool = False):
    """One-shot: parse entire log and print summary."""
    state = AgentState()
    with open(filepath, "r") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            try:
                data = json.loads(line)
                display_lines = process_event(data, state, verbose=verbose)
                for dl in display_lines:
                    print(dl)
            except json.JSONDecodeError:
                process_banner_line(line, state)

    print_summary(state)


def run_live(filepath: str, verbose: bool = False):
    """Live tail mode: follow the log and display events."""
    state = AgentState()
    header_interval = 15
    event_count = 0

    mode_label = f" {YELLOW}(verbose){RESET}" if verbose else ""
    print(f"{BOLD}Watching:{RESET} {filepath}{mode_label}")
    print(f"{DIM}Press Ctrl+C to stop{RESET}")

    for line in tail_follow(filepath):
        line = line.rstrip("\n")
        if not line:
            continue

        try:
            data = json.loads(line)
            display_lines = process_event(data, state, verbose=verbose)
        except json.JSONDecodeError:
            process_banner_line(line, state)
            plain = strip_ansi(line).strip()
            if plain:
                print(f"  {DIM}{plain}{RESET}")
            continue

        if not display_lines:
            continue

        event_count += 1

        if event_count % header_interval == 1:
            print_header(state)

        for dl in display_lines:
            print(dl)

        for text in state.agent_texts[-1:]:
            if any(phrase in text.lower() for phrase in [
                "all metrics written", "analysis complete", "experiment complete",
                "verdict:", "confirmed", "refuted", "inconclusive",
            ]):
                print_header(state)
                print(f"\n  {GREEN}{BOLD}* Agent appears to be finishing up{RESET}\n")


def main():
    signal.signal(signal.SIGINT, lambda *_: (print(f"\n{RESET}"), sys.exit(0)))

    args = sys.argv[1:]
    if "-h" in args or "--help" in args:
        print(usage())
        sys.exit(0)
    resolve_mode = "--resolve" in args or "--summary" in args
    verbose_mode = "--verbose" in args or "-v" in args
    args = [a for a in args if not a.startswith("-")]

    if args and args[0] in PHASES:
        log_dir = _get_log_dir()
        filepath = f"{log_dir}/{args[0]}.log"
        if not os.path.exists(filepath):
            print(f"{YELLOW}No {args[0]} log yet at {filepath} -- nothing to watch.{RESET}\n")
            print(usage())
            sys.exit(0)
    elif args:
        filepath = args[0]
    else:
        filepath = find_log_file()

    if not os.path.exists(filepath):
        print(f"{RED}File not found: {filepath}{RESET}")
        sys.exit(1)

    if resolve_mode:
        run_resolve(filepath, verbose=verbose_mode)
    else:
        run_live(filepath, verbose=verbose_mode)


if __name__ == "__main__":
    main()
