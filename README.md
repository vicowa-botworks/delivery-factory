# delivery-factory

An unattended delivery harness. A supervisor wakes on a timer, looks at the
issues and pull requests of the repositories it is pointed at, and drives
work — implement, open a pull request, answer reviews, merge — through a
coding harness (the `factory` agent for [OpenCode](https://opencode.ai), or
any harness invoked the same way). It was extracted from
`vicowa-botworks/parental-lockout`, its first production, so it can deliver
against any repository, not just that one.

## The two trees

Everything in this harness hangs off one distinction:

- **the harness tree** — `$FACTORY_HARNESS`, a checkout of *this* repository.
  It holds the code that runs and the agent configuration (`.opencode/`) the
  coding harness resolves from its working directory. It also holds the
  supervisor's own state box — the journal, the issue ledger, the run lock, the
  worktree claims and the `HALT` marker — because each of those defaults to
  `$FACTORY_DIR/…`, beside the code that writes it. Override any of them
  (`FACTORY_LOG`, `FACTORY_LEDGER`, `FACTORY_RUN`, `FACTORY_HALT`) to move it.
- **the target tree** — `$FACTORY_ROOT`, a checkout of the repository being
  delivered against. The per-unit working trees live beside it
  (`$FACTORY_TREES`, by default `../wt` of the target's primary checkout).

One consequence follows from where the state box sits: **one harness checkout
supervises one target's state.** Arming a second target from the same checkout
shares one ledger, one lock and one `HALT` between two repositories — an issue
`#7` in one and `#7` in the other would write the same ledger file, and a halt
raised for either stops both. Until per-target state lands (the next phase,
below), give each target its own harness checkout or point the four knobs at
per-target paths.

The harness repository is **not** a target by default. Pointing the factory
at its own source is a decision an operator makes explicitly
(`FACTORY_ROOT=<this checkout>` is accepted); the default never makes it, and
a run with no resolvable target refuses with exit 2 and names the knob. The
supervisor's staleness guards judge the harness tree (it is the code the
timer execs); the target is resolved fresh by every pass. See
`factory/DECISIONS/H-0406.md` (the extraction) and `H-0407` (the split).

## Running it

Against one target checkout today:

```sh
# what would happen, without touching GitHub
FACTORY_ROOT=~/prj/some-repo factory/factory.sh --dry-run

# the same questions, read-only
FACTORY_ROOT=~/prj/some-repo factory/factory.sh --status

# arm the per-target systemd user timer pair (some-repo-factory.{service,timer})
FACTORY_ROOT=~/prj/some-repo factory/install-timer.sh --install
```

The generated unit execs *this* harness and pins the target with
`Environment=FACTORY_ROOT=`; one timer per target. `docs/factory.md` is the
operations manual — the journal vocabulary, the HALT path, the lock and
claim rules, and the failure histories each guard exists because of.

A target must be a git checkout whose `origin` the `gh` CLI can act on; the
reviewer team, escalation label and budgets are environment knobs documented
in `factory/common.sh` and `docs/factory.md`.

## Layout

```
factory/            the supervisor: factory.sh (a pass), common.sh (every rule),
                    install-timer.sh, triage.sh, selftest.sh (~1058 legs)
.opencode/          the `factory` agent, its deny rules, and its skill
docs/factory.md     operations manual
DECISIONS.md        this harness's decision log (H- ids)
factory/DECISIONS/  one file per entry (the log is migrating; both read)
scripts/          gates that run inside `make verify` (decision-log, close-verb,
                    shell and commit-verb checkers)
```

## Verification

```sh
make verify
```

Runs the decision-log gate (every `path:line` citation in the logs must open
at its quoted anchor), the commit/close-verb guards, and `factory/selftest.sh`.
Keep it green at every intermediate step; the gates refuse prose that stopped
being true.

## Where this is going

The extraction (phase 1) and the harness/target split (phase 2) are done
here. Next, per the plan in the issue queue: a `factory watch` / `unwatch`
verb holding a watchlist of repositories (forge, url, reviewer team, budget,
enabled per entry), per-target clones and state under
`~/.local/state/factory/<repo>/`, and a per-project context brief injected
into every tick so the agent starts each issue knowing the project it
belongs to. Until that lands, "watched" means "a timer armed against it".
