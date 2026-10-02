# Claude Research Kit

A drop-in experiment workflow for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Five separate AI agents — a surveyor (`survey`), experiment designer (`frame`), executor (`run`), analyst (`read`), and synthesist (`synthesize`) — each with its own system prompt in `.claude/prompts/` and enforced guardrails that prevent it from stepping outside its role. A sixth step, `log`, is plain shell (commit + PR) with no agent.

Inspired by [claude-tdd-kit](https://github.com/kurtbell87/claude-tdd-kit). Same defense-in-depth philosophy, adapted for ML/DL research where the discipline problem isn't "modifying the tests" but "moving the goalposts after seeing results."

## How It Works

```
You have a question ──► experiment.sh survey      ──► Surveyor reviews prior work & codebase
                        experiment.sh frame       ──► Designer writes experiment spec with pre-committed success criteria
                        experiment.sh run         ──► Executor implements & runs (spec is OS-locked)
                        experiment.sh read        ──► Analyst evaluates against locked metrics (CONFIRMED/REFUTED/INCONCLUSIVE)
                        experiment.sh log         ──► Commit results, PR, update research log
                        experiment.sh synthesize  ──► Synthesist produces cumulative findings report

Or auto-advance:   ──► experiment.sh program      ──► Loops through all open questions automatically
```

**Key idea:** Each phase spawns a separate Claude agent with a dedicated system prompt. During RUN, the experiment spec is `chmod 444` (read-only) and a pre-tool-use hook blocks any attempt to modify it. During READ, the metrics file is locked — the analyst cannot change the numbers. Failure (REFUTED) is a first-class outcome, not an error state.

### Defense in Depth

| Layer | Mechanism | What it prevents |
|-------|-----------|-----------------|
| **System prompt** | Phase-specific agent identity | Agent "wants" to stay in role |
| **File permissions** | `chmod 444` on specs/metrics | OS blocks writes even if agent tries |
| **Pre-tool-use hook** | Blocks `chmod`, `git restore`, `install` commands, spec edits | Prevents workarounds to bypass permissions |

### What It Prevents (Confirmation Bias Guardrails)

| Anti-pattern | How it's blocked |
|-------------|-----------------|
| Redefining "success" after seeing results | Spec is locked during RUN, READ agent can't modify it |
| Dropping a metric that looks bad | READ agent MUST address every metric in the spec |
| Adding a metric that looks good | RUN agent only logs metrics defined in the spec |
| Tweaking numbers after the fact | metrics.json is locked during READ |
| Selective reporting | Analysis template requires all criteria with pass/fail |
| Skipping the baseline | RUN protocol requires baseline reproduction first |
| Running extra seeds until it "works" | Resource budget is pre-committed in the spec |

## Quick Start

```bash
# Install into your project
cd your-project
/path/to/claude-research-kit/install.sh

# Configure for your project
$EDITOR experiment.sh       # Set TRAIN_CMD, EVAL_CMD, SRC_DIR
$EDITOR QUESTIONS.md         # Define your research questions

# Run your first survey
./experiment.sh survey "Does entropy regularization improve PPO on CartPole?"

# Design an experiment from the survey
./experiment.sh frame experiments/exp-001-entropy-reg.md

# Execute it (spec is locked)
./experiment.sh run experiments/exp-001-entropy-reg.md

# Analyze results (metrics are locked)
./experiment.sh read experiments/exp-001-entropy-reg.md

# Commit and PR
./experiment.sh log experiments/exp-001-entropy-reg.md

# Or run the full pipeline:
./experiment.sh full "your question" experiments/exp-001-name.md
```

## Monitoring a Running Phase

Each phase streams structured JSON logs to `$EXP_LOG_DIR/{phase}.log` (defaults to `/tmp/exp-<project-name>/`). The built-in `watch` command parses these into a live dashboard:

```bash
./experiment.sh watch run              # Live-tail the run phase
./experiment.sh watch read             # Live-tail the read phase
./experiment.sh watch survey --resolve # One-shot summary of a completed phase
./experiment.sh watch                  # Auto-detect the most recent phase
./experiment.sh watch run --verbose    # Show full tool output (training logs, metrics)
```

The dashboard shows elapsed time, model, tool call counts, files read/written/edited, agent narration, and metric snapshots from training output.

Phase runners redirect all sub-agent output to disk only (`$EXP_LOG_DIR/{phase}.log`). Stdout receives a compact summary — the last agent message, exit code, and log path — so the orchestrator's context window stays clean. If you need more detail, grep or read the log file directly.

### What the Orchestrator Sees

Each `./experiment.sh` phase returns **only** a compact summary on stdout:

- **Phase output** goes to `$EXP_LOG_DIR/{phase}.log` (not stdout)
- **Stdout receives:** last agent message (≤500 chars) + exit code + log path
- **To get more detail:** grep or read the log file (pull-based)
- **The watch script** reads logs directly and is unaffected by this

This is intentional — it prevents sub-agent verbosity from flooding the orchestrator's context window. The orchestrator should treat the summary as the primary signal and only pull from the log when diagnosing a failure.

## The Six Phases

Five of these phases spawn a dedicated Claude agent (SURVEY, FRAME, RUN, READ, SYNTHESIZE). LOG is a scripted git/PR step with no agent.

### SURVEY — "What do we already know?"

**Agent**: Research Surveyor (read-only access)

Reviews prior experiments, codebase infrastructure, and known failure modes. Produces a briefing document that prevents the FRAME agent from reinventing the wheel.

**Can**: Read everything. Write a survey document.
**Cannot**: Modify code, run training, design experiments.

### FRAME — "What exactly are we testing?"

**Agent**: Research Design Scientist (adversarial toward confirmation bias)

Writes a rigorous experiment spec with:
- Falsifiable hypothesis (direction + magnitude)
- Pre-committed success criteria (binary pass/fail)
- All metrics that must be reported
- Baseline reproduction requirements
- Resource budget and abort criteria

**Can**: Write experiment specs. Read everything.
**Cannot**: Write implementation code, create configs, run experiments.

### RUN — "Execute the protocol"

**Agent**: Experiment Engineer (disciplined executor)

Implements and runs the experiment exactly as specified. Spec is OS-locked. The agent:
1. Reproduces the baseline first
2. Executes the full protocol
3. Writes ALL metrics to metrics.json
4. Does NOT interpret results

**Can**: Write/modify source code, configs, scripts. Run training. Write metrics.
**Cannot**: Modify the spec, change success criteria, modify previous results, editorialize.

### READ — "What do the numbers say?"

**Agent**: Critical Analyst (epistemically honest)

Analyzes metrics against the pre-committed success criteria. Metrics are OS-locked.

Verdict options:
- **CONFIRMED** — All primary criteria passed
- **REFUTED** — One or more primary criteria clearly failed
- **INCONCLUSIVE** — Ambiguous results, high variance, or baseline issues

**Can**: Read everything. Write analysis.md. Update RESEARCH_LOG.md.
**Cannot**: Modify metrics, modify the spec, re-run experiments, modify source code.

### LOG — "Record what happened"

No agent. A shell step that commits results, creates a PR via `gh`, and records the cycle in the research log.

### SYNTHESIZE — "What did we learn overall?"

**Agent**: Research Synthesist (read-only except SYNTHESIS.md)

Produces a cumulative findings report from all completed experiments. Organizes by finding (not chronology), includes negative results, calibrates confidence, and makes actionable recommendations.

**Can**: Read everything. Write SYNTHESIS.md.
**Cannot**: Modify any other file. Run experiments.

## Program Mode

Program mode auto-advances through all open questions in `QUESTIONS.md`:

```bash
./experiment.sh program                    # Run until all questions resolved
./experiment.sh program --max-cycles 5     # Limit to 5 cycles
./experiment.sh program --dry-run          # Preview without executing
./experiment.sh status                     # Check progress at any time
```

### Termination Conditions

| Condition | What happens |
|-----------|-------------|
| All questions resolved | Synthesis report generated |
| Max cycles reached | Partial synthesis report generated |
| GPU budget exhausted | Partial synthesis report generated |
| HANDOFF.md emitted | Loop pauses, awaiting resolution |

### Handoff Protocol

When the READ agent detects that a research question requires infrastructure work outside research scope (environment code, new dependencies, shared interfaces, bug fixes), it creates `HANDOFF.md`. The program loop pauses.

```bash
# After resolving the handoff externally:
./experiment.sh complete-handoff    # Archives to handoffs/completed/
./experiment.sh program             # Resumes the loop
```

The decision heuristic: **"Would a different experiment break if I did this wrong? If yes → handoff."**

## What Gets Installed

```
your-project/
├── experiment.sh                        # Orchestrator (configure this)
├── experiment-aliases.sh                # Shell aliases (optional)
├── CLAUDE.md                            # Workflow rules for Claude
├── RESEARCH_LOG.md                      # Cumulative findings (institutional memory)
├── QUESTIONS.md                         # Research agenda
├── DOMAIN_PRIORS.md                     # Human-injected domain knowledge
├── SYNTHESIS.md                         # Cumulative synthesis report (generated)
├── HANDOFF.md                           # Active handoff to dev tower (if any)
├── program_state.json                   # Program loop state (generated)
├── experiments/                         # Experiment spec files
│   ├── survey-topic.md                  # Survey outputs
│   └── exp-001-name.md                  # Experiment specs
├── results/                             # Experiment results (immutable after RUN)
│   └── exp-001-name/
│       ├── spec.md                      # Frozen copy of the spec
│       ├── config.json                  # Frozen config
│       ├── metrics.json                 # Raw metrics (locked during READ)
│       └── analysis.md                  # READ phase output
├── handoffs/
│   └── completed/                       # Archived resolved handoffs
│       └── 20250115-143022-slug.md
├── scripts/
│   └── experiment-watch.py              # Live dashboard for monitoring phases
├── templates/
│   ├── experiment-spec.md               # Template for experiment specs
│   └── HANDOFF.md                       # Template for handoff documents
└── .claude/
    ├── settings.json                    # Hook registration + Bash permission (see Requirements)
    ├── hooks/
    │   └── pre-tool-use.sh              # Phase enforcement hook
    └── prompts/
        ├── survey.md                    # Surveyor agent prompt
        ├── frame.md                     # Experiment designer prompt
        ├── run.md                       # Executor agent prompt
        ├── read.md                      # Analyst agent prompt
        └── synthesize.md               # Synthesist agent prompt
```

## Configuration

Edit the top of `experiment.sh`:

```bash
TRAIN_CMD="python train.py"              # Your training command
EVAL_CMD="python eval.py"                # Your evaluation command
TEST_CMD="pytest tests/"                 # Unit tests for infrastructure
SRC_DIR="src"                            # Model / training code
DATA_DIR="data"                          # Datasets
CONFIGS_DIR="configs"                    # Training configs
MAX_GPU_HOURS="4"                        # Budget per experiment
MAX_RUNS="10"                            # Max training runs per experiment
MAX_PROGRAM_CYCLES="10"                  # Max cycles in program mode
MAX_PROGRAM_GPU_HOURS="40"               # Total GPU budget for program mode
INCONCLUSIVE_THRESHOLD="3"              # Max consecutive INCONCLUSIVE before skipping question
```

## The Three Documents

| Document | Purpose | Who updates it |
|----------|---------|---------------|
| **DOMAIN_PRIORS.md** | Human-injected domain knowledge and architectural priors | You (research lead) |
| **QUESTIONS.md** | Research agenda, prioritized questions | You / READ agent |
| **RESEARCH_LOG.md** | Cumulative findings from all experiments | READ agent (after each cycle) |
| **experiments/exp-NNN.md** | Single experiment spec (frozen during RUN) | FRAME agent (once per cycle) |
| **SYNTHESIS.md** | Cumulative findings report | SYNTHESIZE agent |
| **HANDOFF.md** | Active infrastructure request to dev tower | READ agent |
| **program_state.json** | Program loop state (cycles, GPU budget) | Program loop |

## Differences from TDD Kit

| TDD Kit | Research Kit | Why |
|---------|-------------|-----|
| Test failure = bug to fix | Hypothesis refuted = knowledge gained | Failure is productive in research |
| RED writes tests that MUST pass | FRAME writes criteria that MIGHT fail | Pre-registration, not specification |
| GREEN must make all tests pass | RUN must execute the protocol fully | Even if early results look bad |
| Linear: red → green → refactor → ship | Can loop: frame → run → read → re-frame | Iteration on hypotheses is expected |
| No SURVEY phase | SURVEY before FRAME | Research requires literature review |
| Tests are the spec | Spec is the contract | Same protection, different semantics |

## Shell Aliases

```bash
source experiment-aliases.sh

exp-survey "question"                     # Survey prior work
exp-frame experiments/exp-001-name.md     # Design experiment
exp-run experiments/exp-001-name.md       # Execute (spec locked)
exp-read experiments/exp-001-name.md      # Analyze (metrics locked)
exp-log experiments/exp-001-name.md       # Commit & PR
exp-cycle experiments/exp-001-name.md     # frame -> run -> read -> log
exp-full "question" experiments/exp-001.md  # Full pipeline
exp-program                               # Auto-advance through questions
exp-synthesize                            # Generate synthesis report
exp-status                                # Show research program status
exp-unlock                                # Emergency: restore permissions
```

## Customizing Agent Prompts

The agent prompts in `.claude/prompts/` are designed to be domain-agnostic. You can customize them for your project:

- **Add domain-specific conventions** (e.g., "always use WandB for logging")
- **Add framework-specific guidance** (e.g., "use PyTorch Lightning Trainer")
- **Add metric-specific instructions** (e.g., "primary metric is always mean episodic return over 100 episodes")

The `## Context` section is appended dynamically by `experiment.sh` at runtime — you don't need to hardcode paths.

## Limitations

- **Architecture search is guided, not automated.** The system prompts nudge agents toward considering architecture as an independent variable, and the SURVEY phase includes an Architectural Priors section, but the system does not perform automated neural architecture search. Domain expertise enters via `DOMAIN_PRIORS.md` — a human-editable file where the research lead can inject structural knowledge (e.g., "this problem has spatial structure, prefer CNNs over MLPs"). Without this file, agents may default to simple architectures.
- **Stopping is mechanical, not information-theoretic.** The program loop stops on budget, cycle count, or question exhaustion — not on diminishing marginal information value. The `Decision Gate` column in QUESTIONS.md partially addresses this by letting the synthesize agent assess whether remaining questions would change downstream decisions.
- **Hook enforcement is heuristic.** The pre-tool-use hook uses pattern matching on tool inputs, which can be bypassed by indirect execution (e.g., `subprocess.run` inside a Python script). This is defense-in-depth, not a security boundary.

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- [GitHub CLI](https://cli.github.com/) (`gh`) for the LOG phase
- [`jq`](https://jqlang.github.io/jq/) — the pre-tool-use hook parses Claude Code's JSON hook payload with it. If `jq` is missing the hook prints a warning and allows the call (enforcement is silently off), so install it.
- `python3` (3.9+) — used by `watch`, `status`/`program` question parsing, and budget tracking
- Bash 3.2+ — the scripts avoid bash-4-only features, so the stock macOS `/bin/bash` works
- Your ML training infrastructure already set up

### Permissions and the hook

`.claude/settings.json` (installed into your project) does two things:

1. Registers `.claude/hooks/pre-tool-use.sh` as a `PreToolUse` hook for `Edit|Write|MultiEdit|Bash`.
2. Sets `"permissions": { "allow": ["Bash"] }`. This lets the phase agents run shell commands (training, tests, git) **without interactive permission prompts**, which is what makes unattended `cycle`/`program` runs possible. It also means the agents can run any shell command the hook does not block; the hook is the guardrail. If you want tighter control, narrow the allow list (e.g. `"Bash(python *)"`, `"Bash(git *)"`) at the cost of prompts during phases.

During the enforced phases (RUN, READ, SYNTHESIZE) the hook blocks, in addition to spec/metrics edits, any shell command matching `chmod`, `chown`, `sudo`, `doas`, `install ` (so `pip install`, `uv pip install`, `npm install`, `apt install`, ...) and `uv add`. New dependencies are deliberately out of scope once the spec is frozen: a RUN agent that installs packages mid-experiment changes the environment the spec was written against and makes results non-reproducible. Add dependencies before `run`, or raise a handoff and address them between cycles.

## Troubleshooting

**Experiment spec or metrics stuck as read-only after a crash:**
```bash
exp-unlock          # If you sourced experiment-aliases.sh
# or manually:
find experiments/ -name "*.md" -exec chmod 644 {} \;
find results/ -type f -exec chmod 644 {} \;
```

**Hook isn't firing:**
- Check `.claude/settings.json` exists and has the PreToolUse hook registered
- Run `chmod +x .claude/hooks/pre-tool-use.sh`
- Make sure `jq` is installed (`which jq`); without it the hook warns and allows every call
- Self-test: `bash tests/hook_test.sh` (from the kit checkout) pipes sample payloads through the hook and checks the allow/block exit codes

**Agent tries to modify the spec during RUN and gets blocked:**
- This is expected! The RUN agent should see the block message and proceed with implementation. If it keeps retrying, the prompt may need strengthening for your use case.

**Agent interprets results during RUN:**
- The RUN prompt instructs the agent not to editorialize. If it does, the analysis won't be as clean, but the metrics are still valid. The READ agent will produce the formal analysis.

## License

MIT
