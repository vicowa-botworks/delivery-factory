#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016
# install.sh -- the agent's front door to this harness: check the machine, install, verify.
#
# Why a front door: `install-timer.sh` is strict on purpose -- it refuses a tree that is not
# `origin/<trunk>` (#249), it needs four knobs thought about (target, reviewer team, reviewer,
# interval), and its success message is prose written for the person who chose them. An
# automation wants the other three things: preflight answers BEFORE a refusal mid-sequence,
# the knobs as flags, and a machine-readable verdict that says what the machine now holds.
# This script adds exactly those and no policy: every install, removal or check of the units is
# executed or read through `install-timer.sh` and `systemctl` themselves, so there is one writer
# of unit files and the front door can never disagree with it.
#
# The checks are the whole product, and they are the checks a fresh box actually fails on: the
# reviewer defaults in `common.sh` name the harness author's own team (`workers`), so an install
# that says no team asks strangers -- or nobody (H-0116 makes the poke refuse both-empty); a `gh`
# that works in a terminal is not a `gh` the unit can find, because the unit reads no shell
# profile, so one check runs with a bare machine PATH; and a user timer without linger dies at
# logout (install-timer prints the command; the front door repeats it as a check so an agent sees
# it in the envelope, not only in prose).
#
# Non-interactive always, and loudly so: no prompt, no default action that surprises. `--json`
# is a one-line envelope on stdout; every sentence goes to stderr, so a caller can keep both.
# Exit codes are the automation's branch points -- see usage.
set -euo pipefail

# ---------- pre-scan: the two things the sourced preamble needs before it runs ----------
# `common.sh` resolves the target at SOURCE time and refuses (exit 2, prose) when the resolved
# target is the harness itself -- correct for factory.sh, fatal for this script: the standard
# agent invocation is `cd <harness> && factory/install.sh --target <new-repo>`, and the preamble
# would answer "no target: ... is the harness itself" before a single flag was read. So the
# front door takes the target from argv (or names the CWD for the no-target verbs, which read
# the truth from the unit files and systemd anyway) and lets the preamble stand aside: an
# explicit FACTORY_ROOT is accepted by design ("watched is a decision, not a default").
_fd_pre_target=
_fd_pre_mode=install
_fd_pre_prev=
for _fd_pre_a in "$@"; do
	case "$_fd_pre_prev" in --target) _fd_pre_target=$_fd_pre_a ;; esac
	case "$_fd_pre_a" in
	--verify) _fd_pre_mode=verify ;;
	--uninstall) _fd_pre_mode=uninstall ;;
	esac
	_fd_pre_prev=$_fd_pre_a
done
if [ -z "${FACTORY_ROOT:-}" ]; then
	if [ -n "$_fd_pre_target" ]; then
		export FACTORY_ROOT="$_fd_pre_target"
	elif [ "$_fd_pre_mode" != install ]; then
		# --verify/--uninstall name their unit by --name, not by a root; point the preamble at
		# the CWD so it stays quiet, and let the unit's own Environment line drive verdicts.
		export FACTORY_ROOT="$PWD"
	fi
fi
unset _fd_pre_target _fd_pre_mode _fd_pre_prev _fd_pre_a

# shellcheck source=./common.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
	cat <<'USAGE'
usage: install.sh --target PATH [options] | --verify [options] | --uninstall [options]

  --target PATH        the repository to deliver against: a git checkout whose `origin` the
                       `gh` CLI can act on. Required for --install (the default verb).
  --reviewer-team SLUG which team to request reviews from (default: FACTORY_REVIEWER_TEAM,
                       which in a fresh clone is the harness author's own team -- wrong for
                       any other organisation, so name yours; pass "" to mean no team).
  --reviewer LOGIN     an individual to ask alongside the team (default: FACTORY_REVIEWER).
  --interval DUR       timer cadence (default: FACTORY_INTERVAL, else 10m).
  --name NAME          unit name without suffix (default: <repo>-factory).
  --dry-run            run every check and print what --install would do; write nothing.
  --json               one JSON object on stdout: ok, command, checks{}, optional unit,
                       target, reason. Prose always goes to stderr; a caller may keep both.
  --uninstall          remove the unit pair (by --name, else the target's repo name, else
                       the single *-factory timer installed on this machine).
  --verify             do not install; report what the machine holds: unit files, enablement,
                       armed elapse, ExecStart, pinned target, and one --status verdict.

exit codes (an automation's branch points):
  0  installed / removed / verified healthy
  1  a named check failed (the envelope names it)
  2  bad arguments
  3  this machine cannot host the harness at all (git, gh, or no user systemd)
USAGE
}

TARGET=
REVIEWER=$FACTORY_REVIEWER REVIEWER_TEAM=$FACTORY_REVIEWER_TEAM
REVIEW_TEAM_SET=0 REVIEW_SET=0
NAME=""
# FACTORY_INTERVAL is read `${FACTORY_INTERVAL:-10m}` by install-timer -- it is not a sourced
# default in common.sh, and this script runs under `set -u`, so the fallback belongs here too.
INTERVAL=${FACTORY_INTERVAL:-10m}
MODE=install
JSON=0
DRY=0

while [ $# -gt 0 ]; do
	case "$1" in
	--target)
		[ $# -ge 2 ] || {
			printf 'install: --target wants a path\n' >&2
			exit 2
		}
		TARGET=$2
		shift
		;;
	--reviewer-team)
		[ $# -ge 2 ] || {
			printf 'install: --reviewer-team wants a slug\n' >&2
			exit 2
		}
		REVIEWER_TEAM=$2
		REVIEW_TEAM_SET=1
		shift
		;;
	--reviewer)
		[ $# -ge 2 ] || {
			printf 'install: --reviewer wants a login\n' >&2
			exit 2
		}
		REVIEWER=$2
		REVIEW_SET=1
		shift
		;;
	--interval)
		[ $# -ge 2 ] || {
			printf 'install: --interval wants a duration\n' >&2
			exit 2
		}
		INTERVAL=$2
		shift
		;;
	--name)
		[ $# -ge 2 ] || {
			printf 'install: --name wants a unit name\n' >&2
			exit 2
		}
		NAME=$2
		shift
		;;
	--dry-run) DRY=1 ;;
	--json) JSON=1 ;;
	--uninstall) MODE=uninstall ;;
	--verify) MODE=verify ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'install: unknown argument: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	esac
	shift
done

say() { printf '%s\n' "$*" >&2; }

# CHECKS is the envelope's checks object, REASONS the human one; BLOCK is set by any failed
# check. Every front-door run journalls itself: an install that happened at 03:12Z is answered
# from the journal, not from the terminal the installer had open.
CHECKS=
REASONS=
BLOCK=0
check() { # check <name> <pass|fail|warn> [detail]
	local name=$1 state=$2 detail=${3-}
	[ -z "$CHECKS" ] && CHECKS="\"$name\":\"$state\"" || CHECKS="$CHECKS,\"$name\":\"$state\""
	if [ "$state" = "fail" ]; then
		REASONS="${REASONS:+$REASONS; }$name: $detail"
		BLOCK=1
	fi
	say "  [$state] $name${detail:+ -- $detail}"
}
j_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
finish() { # finish <true|false> <reason> <exit-code>
	# The envelope is stdout's ONLY line: the whole point of --json is that an agent may parse
	# it, and a journal echo appended after the object would poison every parse. So the
	# front door writes its own journal lines straight to the file -- log_event deliberately
	# also echoes to stdout, which is right for factory.sh and fatal here.
	local ok=$1 reason=${2-} rc=$3
	if [ "$JSON" = "1" ]; then
		# Each optional field is an if-statement, not `A && B`: under `set -e` a failing test
		# in command position ends the script where it stands, and an empty --target would
		# truncate the envelope mid-object -- the one output whose whole job is parseability.
		printf '{"ok":%s,"command":"install.sh %s","checks":{%s}' "$ok" "$MODE" "$CHECKS"
		if [ -n "$NAME" ]; then
			printf ',"unit":"%s"' "$(j_escape "$NAME")"
		fi
		if [ -n "$TARGET" ]; then
			printf ',"target":"%s"' "$(j_escape "$TARGET")"
		fi
		if [ -n "$reason" ]; then
			printf ',"reason":"%s"' "$(j_escape "$reason")"
		fi
		printf '}\n'
	fi
	if [ -n "$reason" ]; then
		say "install: $reason"
	fi
	factory_paths
	log "INSTALL-$ok $MODE rc=$rc target=${TARGET:-unset} unit=${NAME:-unset}${REASONS:+ refusals: $REASONS}" \
		>>"$FACTORY_LOG/supervisor.log" 2>/dev/null || true
	if [ -n "$REASONS" ]; then
		log "INSTALL-REFUSALS $MODE $REASONS" >>"$FACTORY_LOG/supervisor.log" 2>/dev/null || true
	fi
	exit "$rc"
}

# Which unit do we mean? Explicit, else the target's repo name, else -- on a box with exactly
# one factory install -- that one. More than one and no name is a refusal with the list in it,
# because the wrong --uninstall takes away someone else's timer.
resolve_name() {
	[ -n "$NAME" ] && return 0
	if [ -n "$TARGET" ]; then
		NAME="$(basename -- "${TARGET%/}")-factory"
		return 0
	fi
	local found n
	found=$(systemctl --user list-unit-files --no-legend --no-pager '*-factory.timer' 2>/dev/null |
		awk '{print $1}' | sed 's/\.timer$//' | grep . || true)
	n=$(printf '%s\n' "$found" | grep -c . || true)
	case "$n" in
	1) NAME=$found ;;
	0) return 1 ;;
	*)
		say "install: $n factory timers on this machine -- name the one you mean with --name:"
		say "  $(printf '%s' "$found" | tr '\n' ' ')"
		return 1
		;;
	esac
}

# ---------- verify: what does the machine actually hold? ----------
# Read from systemd and the files, never from an install's own stdout: a timer that failed to
# enable reads enabled only to whoever believes the installer's last line (#1180's lesson, one
# level down).
do_verify() {
	local units_dir service timer st nextline execline rootline verdict rc
	units_dir=$(factory_units_dir)
	service="$units_dir/$NAME.service"
	timer="$units_dir/$NAME.timer"
	if [ -f "$service" ] && [ -f "$timer" ]; then
		check unit-files pass "dir=$units_dir"
	else
		check unit-files fail "missing $service or $timer"
	fi
	if systemctl --user list-unit-files --no-legend --no-pager "$NAME.timer" 2>/dev/null | grep -q enabled; then
		check timer-enabled pass ""
	else
		check timer-enabled fail "$NAME.timer is not enabled"
	fi
	st=$(systemctl --user is-active "$NAME.timer" 2>/dev/null || true)
	if [ "$st" = "active" ]; then
		check timer-active pass ""
	else
		check timer-active warn "state=$st (idle is fine; missing is not)"
	fi
	nextline=$( { systemctl --user list-timers --no-pager "$NAME.timer" 2>/dev/null || true; } | sed -n '2p' | awk '{print $1, $2}')
	if [ -n "$nextline" ]; then
		check timer-scheduled pass "next=$nextline"
	else
		check timer-scheduled fail "no elapse armed: a timer that will not fire"
	fi
	# Every substitution below pipes a command that MAY exit non-zero (`cat` on a unit that was
	# never written is the ordinary case in --verify). Under `pipefail` the pipeline's status
	# becomes the ASSIGNMENT's status, and set -e then kills the script before the envelope --
	# rc 1 with no reason line, the worst shape a machine-facing tool can have.
	execline=$( { systemctl --user cat "$NAME.service" 2>/dev/null || true; } | sed -n 's/^ExecStart=//p' | head -1)
	if [ -n "$execline" ]; then
		check exec-path pass "execs ${execline%% *}"
	else
		check exec-path fail "systemd holds no ExecStart for $NAME -- the unit file never loaded"
	fi
	rootline=$( { systemctl --user cat "$NAME.service" 2>/dev/null || true; } | sed -n 's/^Environment=FACTORY_ROOT=//p' | head -1)
	if [ -n "$rootline" ]; then
		check target-pinned pass "$rootline"
	else
		check target-pinned fail "the unit does not pin FACTORY_ROOT: it would supervise whatever CWD it got"
	fi
	# `|| true` inside the substitution, and not outside it: the pipeline's status under
	# `pipefail` is the assignment's status, and a `--status` that exits non-zero while still
	# printing a first line (a tree git cannot fully position is enough) would otherwise kill
	# this script mid-claim and leave the envelope unparsed -- rc 1 with no reason.
	verdict=$( { FACTORY_ROOT=${rootline:-${FACTORY_ROOT:-}} "$FACTORY_HARNESS/factory/factory.sh" --status 2>/dev/null || true; } | sed -n '1p')
	if [ -n "$verdict" ]; then
		check verdict pass "${verdict%% *}"
		say "install: verdict: $verdict"
	else
		check verdict fail "factory.sh --status answered nothing"
	fi
	[ "$BLOCK" = "1" ] && finish false "$REASONS" 1
	finish true "healthy" 0
}

# ---------- uninstall ----------
do_uninstall() {
	local out rc=0 dry=()
	[ "$DRY" = "1" ] && dry=(--dry-run)
	out=$("$FACTORY_DIR/install-timer.sh" --remove "${dry[@]}" --name "$NAME" 2>&1) || rc=$?
	if [ -n "$out" ]; then
		printf '%s\n' "$out" >&2
	fi
	if [ "$rc" -ne 0 ]; then
		check install-timer-remove fail "rc=$rc (its sentences above name the condition)"
		finish false "removal refused" 1
	fi
	check install-timer-remove pass "units removed"
	finish true "removed $NAME" 0
}

if [ "$MODE" = "verify" ]; then
	resolve_name || finish false "no --name, no --target, and no single factory install to infer it from" 2
	do_verify
fi
if [ "$MODE" = "uninstall" ]; then
	resolve_name || finish false "no --name, no --target, and no single factory install to infer it from" 2
	do_uninstall
fi

# ---------- install: the checks, in the order a fresh box fails them ----------
[ -n "$TARGET" ] || {
	usage >&2
	finish false "--install needs --target: the harness never guesses which repository to deliver against" 2
}
say "install: checking the machine for ${TARGET:-<no target>} ..."

if command -v git >/dev/null 2>&1; then
	check git pass "$(git --version | head -1)"
else
	check git fail "git is not on PATH"
	finish false "git missing" 3
fi
if command -v gh >/dev/null 2>&1; then
	check gh-present pass "$(gh --version | head -1)"
else
	check gh-present fail "the gh CLI is not installed: every GitHub verb of the factory runs through it"
	finish false "gh missing" 3
fi
if gh auth status >/dev/null 2>&1; then
	check gh-auth pass ""
else
	check gh-auth fail "gh is installed but not authenticated: run 'gh auth login' as $(id -un)"
	finish false "gh not authenticated" 1
fi
if systemctl --user is-system-running >/dev/null 2>&1 || [ -n "${XDG_RUNTIME_DIR:-}" ]; then
	check user-systemd pass ""
else
	check user-systemd fail "no user systemd instance: this harness is a per-user timer pair; it needs a systemd login session (then linger to survive logout)"
	finish false "no user systemd" 3
fi
if command -v opencode >/dev/null 2>&1; then
	check opencode pass "$(command -v opencode)"
else
	check opencode warn "opencode is not on PATH: coding ticks fail their first activation; the mechanical half (asks, merges, conflicts) works without it"
fi

# `gh` as the unit will see it: the generated unit reads no shell profile, and its PATH line is
# captured from the machine by install-timer at install time. The class of defect here is the
# binary that works in a terminal and is invisible to the service (measured before: a timer that
# fired and did nothing because the unit's PATH lacked the binary).
if env -i HOME="$HOME" PATH=/usr/local/bin:/usr/bin:/bin command -v gh >/dev/null 2>&1; then
	check gh-on-machine-path pass ""
else
	ghdir=$(dirname -- "$(command -v gh)")
	check gh-on-machine-path warn "gh lives in $ghdir, outside the default PATH; install-timer captures binary directories into the unit's PATH -- keep reading its output"
fi

if [ ! -d "$TARGET/.git" ]; then
	check target-repo fail "--target is not a git checkout: ${TARGET:-<empty>}"
	finish false "target is not a repo" 1
fi
origin=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
if [ -z "$origin" ]; then
	check target-repo fail "the target has no origin: the factory delivers through GitHub"
	finish false "target has no origin" 1
fi
repo=$(printf '%s' "$origin" |
	sed -e 's#^[a-z+]*://[^/]*/##' -e 's#^git@[^:]*:##' -e 's#\.git$##' |
		awk -F/ 'NF>=2{print $(NF-1)"/"$NF}')
if [ -z "$repo" ] || ! printf '%s' "$repo" | grep -Eq '^[^/]+/[^/]+$'; then
	check target-repo fail "origin '$origin' does not name owner/repo"
	finish false "unreadable origin" 1
fi
check target-repo pass "$repo"
# The slug `common.sh` carries must be the slug the origin actually names, before any child
# inherits it: every source of this script (the harness's own deployment, or a caller's shell)
# exports a FACTORY_* pointing at somebody else's repository, and a stale one would both make
# preflight answer about the wrong repository and bake the wrong `Environment=FACTORY_*` lines
# into the unit. The target's identity wins from here to the handoff.
FACTORY_REPO=$repo
FACTORY_OWNER=${repo%%/*}
FACTORY_NAME=${repo##*/}
export FACTORY_REPO FACTORY_OWNER FACTORY_NAME
if gh repo view "$repo" >/dev/null 2>&1; then
	check repo-access pass "gh can act on $repo"
else
	check repo-access fail "gh cannot read $repo with its current token: check 'gh auth status' scopes and access"
	finish false "cannot act on $repo" 1
fi

# The reviewer knobs carry the harness author's defaults, and silence here is the three-days-
# unasked incident re-created for a new org: the default only survives when the caller lets it.
if [ "$REVIEW_TEAM_SET" = "0" ] && [ "$REVIEW_SET" = "0" ]; then
	check reviewer-targets warn "asking team '$REVIEWER_TEAM' / user '$REVIEWER' -- those are the harness defaults; pass --reviewer-team for your org"
elif [ "$REVIEWER_TEAM" = "" ] && [ "$REVIEWER" = "" ]; then
	check reviewer-targets fail "both reviewer knobs empty: no one would ever be asked (H-0116 makes the poke refuse)"
	finish false "no reviewer configured" 1
elif gh api "orgs/${repo%%/*}/teams/$REVIEWER_TEAM" >/dev/null 2>&1 ||
	gh api "users/$REVIEWER" >/dev/null 2>&1; then
	check reviewer-targets pass "${REVIEWER_TEAM:-$REVIEWER}"
else
	check reviewer-targets warn "'${REVIEWER_TEAM:-$REVIEWER}' was not found by gh: asks to it fail at review time, not install time"
fi

if printf '%s' "$INTERVAL" | grep -Eq '^[0-9]+(ns|us|ms|s|sec|min|m|h|d|w)?$'; then
	check interval pass "$INTERVAL"
else
	check interval fail "'$INTERVAL' is not a systemd duration (like 10m or 1h)"
	finish false "bad interval" 2
fi

[ -n "$NAME" ] || NAME="${repo##*/}-factory"

# The harness position: install-timer refuses a tree that is not its trunk (#249), and the
# refusal is the message the agent least wants at the END of a sequence. Say it first and say
# what fixes it.
harness_behind=$(git -C "$FACTORY_HARNESS" rev-list --count "HEAD..origin/${FACTORY_BASE:-main}" 2>/dev/null || printf '')
if [ -n "$harness_behind" ] && [ "$harness_behind" != "0" ]; then
	check harness-current warn "this harness checkout is $harness_behind commit(s) off its trunk: install-timer will REFUSE it; 'git -C $FACTORY_HARNESS pull --ff-only' first"
elif [ -n "$harness_behind" ]; then
	check harness-current pass "at origin/${FACTORY_BASE:-main}"
else
	check harness-current warn "git would not position this harness tree (no origin/${FACTORY_BASE:-main}?); install-timer will make the call"
fi

# ---------- execute: install-timer remains the only writer of units ----------
say "install: handing off to install-timer.sh ..."
dry=()
[ "$DRY" = "1" ] && dry=(--dry-run)
out=
rc=0
out=$(
	FACTORY_ROOT="$TARGET" FACTORY_INTERVAL="$INTERVAL" \
		FACTORY_REVIEWER="$REVIEWER" FACTORY_REVIEWER_TEAM="$REVIEWER_TEAM" \
		"$FACTORY_DIR/install-timer.sh" --install "${dry[@]}" --name "$NAME" 2>&1
) || rc=$?
if [ -n "$out" ]; then
	printf '%s\n' "$out" >&2
fi
if [ "$rc" -ne 0 ]; then
	check install-timer fail "install-timer.sh refused (rc=$rc; its sentences above name the condition)"
	finish false "install refused" 1
fi
if [ "$DRY" = "1" ]; then
	check install-timer pass "dry run: the units it would write are above, nothing was written"
	check linger warn "not probed in a dry run: 'loginctl show-user $(id -un) --property=Linger' -- without linger a user timer dies at logout"
	finish true "dry run only" 0
fi
check install-timer pass "units written"
linger=$(loginctl show-user "$(id -un)" --property=Linger --value 2>/dev/null || printf unknown)
if [ "$linger" = "yes" ]; then
	check linger pass "linger on: the timer survives logout"
else
	check linger warn "linger is $linger: run 'loginctl enable-linger $(id -un)' or the timer stops at logout"
fi

# Read the machine back before declaring success -- the installer's own last line is not proof.
# FACTORY_ROOT is passed explicitly: a --verify in a fresh shell would otherwise let common.sh's
# source-time target preamble answer about the CWD (or refuse in the harness itself, measured),
# and the verdict must be about the target this install just armed.
verify_out=
rc=0
verify_out=$(FACTORY_ROOT="$TARGET" "$FACTORY_DIR/install.sh" --verify --name "$NAME" 2>&1) || rc=$?
[ -n "$verify_out" ] && printf '%s\n' "$verify_out" >&2
if [ "$rc" = "0" ]; then
	check verify pass "the machine holds what was written"
else
	check verify fail "self-verify rc=$rc: systemd did not end up where the install aimed"
fi

say ""
say "next:"
say "  watch it think:  journalctl --user -u $NAME.service -n 50"
say "  read the queue:  FACTORY_ROOT=$TARGET $FACTORY_HARNESS/factory/factory.sh --status"
say "  rehearse again:  $0 --target $TARGET --dry-run"
say "  remove:          $0 --uninstall --name $NAME"
if [ "$BLOCK" = "1" ]; then
	finish false "$REASONS" 1
fi
finish true "installed $NAME against $repo" 0
