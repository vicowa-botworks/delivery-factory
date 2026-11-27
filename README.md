# delivery-factory

An unattended delivery harness for a GitHub repository. A supervisor wakes on
a timer, reads the repository's open issues and pull requests, and drives the
work — implement an issue and open a pull request, answer review comments,
request reviewers, keep checks green — through a coding agent
(the `factory` agent for [OpenCode](https://opencode.ai), or any harness
invoked the same way). You file issues and hold the reviews; the factory does
everything in between, unattended — including merging, once a pull request is
fully approved with every check green and nothing in conflict.

## Quick start

What you need: a Linux machine with a systemd user session, `git`, the `gh`
CLI ([authenticated](https://cli.github.com/): `gh auth status` must pass),
and your repository already on GitHub. `opencode` is needed for the coding
work itself; without it the mechanical half (review asks, merges, conflicts)
still runs.

**One harness checkout supervises one project.** Give each project its own
clone — the ledger, the journal and the halt flag live inside the checkout,
and two projects sharing one clone would share them.

```sh
# 1. clone the harness next to (or wherever, it doesn't matter) your project
git clone https://github.com/vicowa-botworks/delivery-factory ~/tools/my-project-factory
cd ~/tools/my-project-factory

# 2. rehearse: runs every machine check and prints what it would install,
#    writes nothing
factory/install.sh --target ~/prj/my-project --reviewer-team <your-team> --dry-run

# 3. install: arms a systemd user timer (<repo>-factory.timer, every 10 min)
factory/install.sh --target ~/prj/my-project --reviewer-team <your-team>

# 4. watch it work (also: journalctl --user -u <repo>-factory.service -n 50)
journalctl --user -u <repo>-factory.service -f
```

The installer refuses rather than guesses: it stops when `gh` cannot act on
the repository, when nobody is configured to receive review requests, or when
the harness checkout is behind its trunk, and it tells you the exact fix. If
it mentions **linger**, run the `loginctl enable-linger` command it prints —
without linger a user timer stops at logout.

Then open an issue in your project's repository. Within one interval the
factory claims it, opens a pull request against it, asks your team for a
review, answers review comments — and when the pull request is `APPROVED`,
every check has passed, and nothing conflicts, the supervisor merges it itself,
in bash, after re-reading all four facts from the API at the moment of the
merge (never on a triage verdict that aged a few minutes). What you hold is the
review: nothing merges without your approval, and a review you change pulls
the merge back. To stop the queue at any moment, touch the halt flag
(`touch factory/HALT` in the harness checkout); to take the timer off
entirely:

```sh
factory/install.sh --uninstall
```

### Installing it from an agent

The same front door is built for automation: `--json` prints a machine-readable
verdict on stdout (prose goes to stderr), exit codes branch, and nothing is
ever installed or removed unless you name the verb. An agent can go from a
fresh clone to a supervised project with:

```sh
git clone https://github.com/vicowa-botworks/delivery-factory <dir> && cd <dir>
factory/install.sh --json --target <project-checkout> --reviewer-team <team-slug>
```

`{"ok":true,"checks":{...}}` means the timer is armed and read back from
systemd; `"ok":false` names the failed check in `reason`, and no unit was
written. Branch on the exit code: `0` done, `1` a named check failed, `2` bad
arguments, `3` this machine cannot host the harness at all. Checks that
matter to an operator: `"linger":"warn"` (the timer dies at logout until
`loginctl enable-linger <user>`), `"opencode":"warn"` (ticks will fail until
the CLI is on PATH), `"harness-current":"warn"` (pull the harness first). A
dry run with `--dry-run` answers the same questions without writing anything;
`--verify` re-checks a machine that already has an install. The full unit
file, knob table and journal vocabulary are in
[`docs/factory.md`](docs/factory.md); [`factory/install.sh --help`](factory/install.sh)
prints every option.

## How it works

Everything hangs off one distinction, the two trees:

- **the harness tree** — `$FACTORY_HARNESS`, a checkout of *this* repository.
  It holds the code that runs, the agent configuration (`.opencode/`) the
  coding harness resolves from its working directory, and the supervisor's
  state box — journal, issue ledger, run lock, worktree claims, `HALT` marker
  — because each defaults to a path beside the code that writes it. Override
  any of them (`FACTORY_LOG`, `FACTORY_LEDGER`, `FACTORY_RUN`, `FACTORY_HALT`)
  to move one.
- **the target tree** — `$FACTORY_ROOT`, a checkout of the repository being
  delivered against. Per-unit working trees live beside it
  (`$FACTORY_TREES`, default `../wt` of the target's primary checkout).

One consequence follows from where the state box sits: one harness checkout
supervises one target's state. Arming a second target from the same checkout
shares one ledger, one lock and one halt between two repositories — issue
`#7` in one and `#7` in the other write the same ledger file, and a halt
raised for either stops both. Per-target state is the next phase (below), so
until then: one checkout per target, or point the four knobs at per-target
paths.

The harness repository is **not** a target by default. Pointing the factory
at its own source is a decision an operator makes explicitly
(`FACTORY_ROOT=<this checkout>` is accepted); the default never makes it, and
a run with no resolvable target refuses with exit 2 and names the knob. The
supervisor's staleness guards judge the harness tree (it is the code the
timer execs); the target is resolved fresh by every pass. See
`factory/DECISIONS/H-0406.md` (the extraction) and `H-0407` (the split).

### Running a pass by hand

```sh
# what would happen, without touching GitHub
FACTORY_ROOT=~/prj/my-project factory/factory.sh --dry-run

# the same questions, read-only
FACTORY_ROOT=~/prj/my-project factory/factory.sh --status
```

The timer installed above runs that same pass on a cadence; `install.sh` is a
front door over `install-timer.sh`, which remains the only writer of unit
files. `docs/factory.md` is the operations manual — the journal vocabulary,
the HALT path, the lock and claim rules, and the failure histories each guard
exists because of. A target must be a git checkout whose `origin` the `gh`
CLI can act on; reviewer, escalation label and budgets are environment knobs
documented in `factory/common.sh` and `docs/factory.md`.

### Layout

```
factory/            the supervisor: factory.sh (a pass), common.sh (every rule),
                    install.sh (agent front door), install-timer.sh (the unit
                    writer), triage.sh, selftest.sh (~1090 legs)
.opencode/          the `factory` agent, its deny rules, and its skill
docs/factory.md     operations manual
DECISIONS.md        this harness's decision log (H- ids)
factory/DECISIONS/  one file per entry (the log is migrating; both read)
scripts/            gates that run inside `make verify` (decision-log, close-verb,
                    shell and commit-verb checkers)
```

### Verification

```sh
make verify
```

Runs the decision-log gate (every `path:line` citation in the logs must open
at its quoted anchor), the commit/close-verb guards, shellcheck, and
`factory/selftest.sh`. Keep it green at every intermediate step; the gates
refuse prose that stopped being true.

### Where this is going

The extraction (phase 1) and the harness/target split (phase 2) are done. The
next phase — still the plan, not implemented: a `factory watch` / `unwatch`
verb holding a watchlist of repositories (forge, url, reviewer team, budget,
enabled per entry), per-target clones and state under
`~/.local/state/factory/<repo>/`, and a per-project context brief injected
into every tick so the agent starts each issue knowing the project it belongs
to. Until that lands, "watched" means "a timer armed against it" — which is
what the quick start above does.
