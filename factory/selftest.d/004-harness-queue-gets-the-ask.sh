# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034,SC2154,SC1090,SC1091,SC2163
# 004-harness-queue-gets-the-ask.sh -- the pass ends by sweeping the HARNESS repository's open
# pulls for the reviewer ask (#3 half 2, H-0409).
#
# Requirement: `AGENTS.md` -- "Requesting a reviewer is part of opening a pull request, not a later
# courtesy -- and the component that does it is the supervisor's poke, not whoever opened the pull
# request." Since H-0407 the unit execs the harness while supervising another repository, and
# `factory_request_review` posts only to `$FACTORY_OWNER/$FACTORY_NAME` -- the target's repository.
# Measured (issue #3): a pull request opened against the harness was invisible to the component the
# rule says owns the ask; #1 merged only because a person read it by hand.
#
# Legs:
#   1. an unasked harness pull gets the team ask through the harness repository's endpoint, and a
#      dry run only says WOULD;
#   2. a pull somebody already holds is not re-asked;
#   3. the throttle lives in its own `harness-pr:` namespace: a fresh stamp silences the ask, and
#      the same NUMBER stamped in the target queue's namespace does not;
#   4. no split -- harness remote equals the target repository -- is silent and makes no call: the
#      pass just worked that queue arm by arm;
#   5. a refused POST reads back: 422-with-a-held-request is `ALREADY` and rc 0, nothing-held is
#      `FAILED` and rc 1, and both stamp the throttle so a bad name is not retried every pass;
#   6. `FACTORY_HARNESS_POKE=0` refuses, journals which knob, and touches no endpoint.
#
# Journal assertions never grep a raw path: this suite's measured lesson (H-0408's own branch name
# reddened `install_current_silent`) is that a leg which greps words must not read the checkout
# path. Fixture paths here are clean anyway, but the assertions compare whole lines with masked
# detail, never bare words.

hs_root=$(cd -- "$HERE/.." && pwd)
hs_work=$work/harness-poke-sweep

hs_say() { printf '            %s\n' "$1" >&2; }

mkdir -p "$hs_work/bin"

# Fixture `gh`. Same one-payload-behind-one-endpoint arrangement as the poke family above: the
# caller's own `--jq` runs over the payload, with `--raw-field who=` bound as `--arg who` -- a shim
# that dumps raw bodies makes every read-back fail for reasons unrelated to the code under test.
# Per-pull state arrives through the env: HS_LIST is the open-number list, HS_REQUESTED the
# requested_reviewers payload, HS_POST_FAIL the 422/404 stand-in.
cat >"$hs_work/bin/gh" <<'HSGH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HS_CALLS"
answer() { # answer <payload> -> through the caller's --jq, with --raw-field who bound as --arg
	local payload=$1 jqprog='' who='' pair
	local args=("$@") i=0
	while [ "$i" -lt "${#args[@]}" ]; do
		case "${args[$i]}" in
		--jq) jqprog=${args[$((i + 1))]} ;;
		--raw-field)
			pair=${args[$((i + 1))]}
			case "$pair" in
			who=*) who=${pair#*=} ;;
			*)
				printf 'sweep-shim: a --raw-field this fixture does not bind: %s\n' "$pair" >&2
				exit 9
				;;
			esac ;;
		esac
		i=$((i + 1))
	done
	if [ -n "$jqprog" ]; then
		printf '%s\n' "$payload" | jq -r --arg who "$who" "$jqprog"
	else
		printf '%s\n' "$payload"
	fi
}
# POST first: a POST matches the requested_reviewers arm too.
case "$*" in
*'-X POST'*)
	if [ "${HS_POST_FAIL-0}" = 1 ]; then
		printf 'gh: HTTP 422 or 404, the sweep must tell them apart by reading\n' >&2
		exit 1
	fi
	answer '{"users":[],"teams":[]}' "$@"
	exit 0
	;;
*'/pulls?state=open'*)
	HS_LIST=${HS_LIST:-[]}
	printf '[%s]\n' "$HS_LIST" | { if [ -n "${HS_LIST:-}" ]; then printf '%s\n' "[$HS_LIST]"; else printf '[]\n'; fi; } |
		{ payload=$(cat); answer "$payload" "$@"; }
	exit 0
	;;
*'/requested_reviewers'*)
	answer "${HS_REQUESTED-{\"users\":[],\"teams\":[]}}" "$@"
	exit 0
	;;
esac
printf 'sweep-shim: unhandled call: %s\n' "$*" >&2
exit 9
HSGH
chmod +x "$hs_work/bin/gh"

# The harness tree: a git checkout whose origin names a repository DIFFERENT from the target's.
# The identity read is `git remote get-url`, offline, so the URL only has to parse; no network.
# Built BEFORE the extract, and the extract is a guard, not a precondition step: a sourced leg
# runs top to bottom under `set -e`, so a failing guard here kills the suite -- and building the
# tree after the functions is what made every run read HARNESS-POKE-UNKNOWN the first time this
# leg was exercised.
hs_harness=$hs_work/harness-tree
hs_extract() { # cut the function under test out of the shipped file
	awk '/^factory_harness_review_sweep\(\)/{f=1} f{print} f&&/^\}/{exit}' "$hs_root/factory/factory.sh" \
		>"$hs_work/sweep.sh"
	[ -s "$hs_work/sweep.sh" ] || { hs_say "no factory_harness_review_sweep() in $hs_root/factory/factory.sh -- the leg would read nothing"; return 1; }
}
hs_extract
git init -q -b main "$hs_harness"
git -C "$hs_harness" config user.email harness@example.invalid
git -C "$hs_harness" remote add origin https://example.invalid/harness/repo.git

# hs_run <calls-file> <journal-file> [VAR=VAL ...] -- the sweep alone, fake gh on PATH, ledger
# and journal in the fixture. Every run gets a FRESH ledger unless the leg names one with
# HS_LEDGER: a leg that measures a POST would otherwise be throttled by the successful POST of
# the leg before it -- the age-gate trap of H-0408 arriving from the other direction. Extra
# assignments come last so a leg can override any default.
hs_run() {
	local calls=$1 journal=$2 ledger=${HS_LEDGER:-}
	shift 2
	: >"$calls"
	[ -n "$ledger" ] || ledger=$(mktemp -d "$hs_work/ledger-XXXXXX")
	# SC2094 fires on the redirect below because the subshell WRITES $journal; nothing in it
	# ever reads that file -- every reader is an assertion in a leg function, outside the
	# subshell, after it has returned. Quoted to stay an honest false positive for the next
	# reader, who should check that claim before trusting this comment.
	# shellcheck disable=SC2094
	(
		set -eu
		# shellcheck disable=SC1091
		. "$hs_root/factory/common.sh"
		# shellcheck disable=SC1090
		. "$hs_work/sweep.sh"
		# Assignments reach the function through `export`, not command prefixes: bash reads a
		# prefix assignment at PARSE time, so a `VAR=VAL` that arrives via "$@" is not an
		# assignment at all but a command name -- measured as `command not found` on this leg's
		# first exercise. Exports first, the caller's overrides last.
		export HS_CALLS=$calls HS_LIST=${HS_LIST:-} HS_REQUESTED=${HS_REQUESTED:-} \
			HS_POST_FAIL=${HS_POST_FAIL:-0} \
			PATH="$hs_work/bin:$PATH" \
			FACTORY_ROOT=$hs_work/target-tree FACTORY_HARNESS=$hs_harness \
			FACTORY_REPO=example/repo FACTORY_OWNER=example FACTORY_NAME=repo \
			FACTORY_LOG=$hs_work/log FACTORY_LEDGER=$ledger FACTORY_RUN=$hs_work/run \
			FACTORY_REVIEWER=hermesvicowa FACTORY_REVIEWER_TEAM=workers \
			FACTORY_HARNESS_POKE=1 FACTORY_REVIEW_POKES=1800 DRY_RUN=${DRY_RUN:-0}
		local a
		for a in "$@"; do export -- "$a"; done
		factory_harness_review_sweep
	) >"$journal" 2>&1
}

hs_calls_has() { # <file> <needle>
	if grep -qF -- "$2" "$1"; then return 0; fi
	hs_say "the recorded calls were:"
	sed 's/^/              /' "$1" >&2
	hs_say "none of them carries: $2"
	return 1
}
hs_calls_no_post_with() { # <file> <needle>
	if awk -v n="$2" '/-X POST/ && index($0, n) { f = 1 } END { exit !f }' "$1"; then
		hs_say "a POST carries $2, and it must not:"
		sed 's/^/              /' "$1" >&2
		return 1
	fi
	return 0
}
hs_calls_empty() { # <file>
	if [ -s "$1" ]; then
		hs_say "the sweep made $(wc -l <"$1") call(s) where it must make none:"
		sed 's/^/              /' "$1" >&2
		return 1
	fi
	return 0
}
hs_journal_has() { # <journal> <needle>
	if grep -qF -- "$2" "$1"; then return 0; fi
	hs_say "the journal was:"
	sed 's/^/              /' "$1" >&2
	hs_say "with nothing matching: $2"
	return 1
}
hs_journal_silent() { # <journal> <needle>
	if grep -qF -- "$2" "$1"; then
		hs_say "the journal says $2, and it must stay silent:"
		sed 's/^/              /' "$1" >&2
		return 1
	fi
	return 0
}


# 1. the unasked pull gets the team ask, at the HARNESS repository, and the journal says so.
hs_ask_lands() {
	local calls=$hs_work/c1 journal=$hs_work/j1 rc=0
	HS_LIST='{"number":5}' hs_run "$calls" "$journal" || rc=$?
	[ "$rc" -eq 0 ] || { hs_say "the sweep returned $rc, not 0:"; sed 's/^/              /' "$journal" >&2; return 1; }
	hs_calls_has "$calls" 'POST repos/harness/repo/pulls/5/requested_reviewers'
	hs_calls_has "$calls" 'team_reviewers[]=workers'
	hs_journal_has "$journal" 'HARNESS-POKED pr:5 repo:harness/repo asked team workers'
	hs_journal_has "$journal" 'HARNESS-POKE-SWEEP repo:harness/repo open=1 asked=1 held=0 throttled=0 failed=0'
}
claim_leg "004: the unasked harness pull gets the team ask" hs_ask_lands

# 1b. a dry run says WOULD and POSTs nothing -- the same no-write contract as the target poke.
hs_dry_run() {
	local calls=$hs_work/c1b journal=$hs_work/j1b rc=0
	HS_LIST='{"number":5}' DRY_RUN=1 hs_run "$calls" "$journal" || rc=$?
	[ "$rc" -eq 0 ] || { hs_say "dry-run sweep returned $rc, not 0:"; sed 's/^/              /' "$journal" >&2; return 1; }
	hs_calls_no_post_with "$calls" 'repos/harness/repo/pulls/5'
	hs_journal_has "$journal" 'WOULD-HARNESS-POKE pr:5 repo:harness/repo request review from team workers'
	hs_journal_has "$journal" 'dry=1'
}
claim_leg "004: dry run would ask and does not ask" hs_dry_run

# 2. a pull whose request lists are not empty is already served.
hs_held_not_asked() {
	local calls=$hs_work/c2 journal=$hs_work/j2 rc=0
	HS_LIST='{"number":5}' HS_REQUESTED='{"users":[],"teams":[{"slug":"workers"}]}' \
		hs_run "$calls" "$journal" || rc=$?
	[ "$rc" -eq 0 ] || { hs_say "the sweep returned $rc, not 0:"; sed 's/^/              /' "$journal" >&2; return 1; }
	hs_calls_no_post_with "$calls" 'repos/harness/repo/pulls/5'
	hs_journal_has "$journal" 'open=1 asked=0 held=1'
}
claim_leg "004: a held request is not re-asked" hs_held_not_asked

# 3. the throttle: its own namespace stamps, the target queue's namespace does not. Two runs on
#    ONE named ledger -- a stamp taken through the SAME ledger verbs the sweep uses, and the
#    control's stamp under `pr:5`, which must leave the harness ask alive.
hs_stamp() { # <ledger> <key> <field>
	(
		set -eu
		# shellcheck disable=SC1091
		. "$hs_root/factory/common.sh"
		FACTORY_LEDGER=$1 FACTORY_RUN=$hs_work/run \
			factory_ledger_now "$2" "$3"
	)
}
hs_clear() { # <ledger> <key> <field>
	(
		set -eu
		# shellcheck disable=SC1091
		. "$hs_root/factory/common.sh"
		FACTORY_LEDGER=$1 FACTORY_RUN=$hs_work/run \
			factory_ledger_clear "$2" "$3"
	)
}
hs_throttle() {
	local calls=$hs_work/c3 journal=$hs_work/j3 rc=0
	local ledger3=$hs_work/ledger-3
	mkdir -p "$ledger3"
	hs_stamp "$ledger3" 'harness-pr:5' last-poke
	HS_LEDGER=$ledger3 HS_LIST='{"number":5}' hs_run "$calls" "$journal" || rc=$?
	[ "$rc" -eq 0 ] || { hs_say "throttled sweep returned $rc, not 0:"; sed 's/^/              /' "$journal" >&2; return 1; }
	hs_calls_no_post_with "$calls" 'repos/harness/repo/pulls/5'
	hs_journal_has "$journal" 'throttled=1'
	# and the control: the same NUMBER, the other queue's namespace, asks anyway.
	hs_clear "$ledger3" 'harness-pr:5' last-poke
	hs_stamp "$ledger3" 'pr:5' last-poke
	local calls2=$hs_work/c3b journal2=$hs_work/j3b rc2=0
	HS_LEDGER=$ledger3 HS_LIST='{"number":5}' hs_run "$calls2" "$journal2" || rc2=$?
	[ "$rc2" -eq 0 ] || { hs_say "cross-namespace control returned $rc2, not 0:"; sed 's/^/              /' "$journal2" >&2; return 1; }
	hs_calls_has "$calls2" 'POST repos/harness/repo/pulls/5/requested_reviewers'
}
claim_leg "004: the throttle is per repository namespace" hs_throttle

# 4. no split: the harness remote names the target's own repository. Silent, and NO call at all --
#    not even a list read: the queue it would sweep is the queue this pass just worked.
hs_same_repo_silent() {
	local calls=$hs_work/c4 journal=$hs_work/j4 rc=0
	(
		git init -q -b main "$hs_work/same-tree"
		git -C "$hs_work/same-tree" config user.email same@example.invalid
		git -C "$hs_work/same-tree" remote add origin https://example.invalid/example/repo.git
	)
	HS_LIST='{"number":5}' hs_run "$calls" "$journal" \
		FACTORY_HARNESS="$hs_work/same-tree" || rc=$?
	[ "$rc" -eq 0 ] || { hs_say "no-split sweep returned $rc, not 0:"; sed 's/^/              /' "$journal" >&2; return 1; }
	hs_calls_empty "$calls"
	hs_journal_silent "$journal" 'HARNESS-POKE'
}
claim_leg "004: with no split the sweep is silent" hs_same_repo_silent

# 4b. the FIRST no-split arm: harness and root the SAME directory -- the pre-H-0407 shape, and
#     the shape every fixture pass in `selftest.sh` runs. The guard must sit ahead of the remote
#     read, because a fixture's origin is a temp path whose slug matches nothing: measured on
#     the function's first suite run, the slug-only guard marched 18 proc legs into the strict
#     gh shim and reddened them all with rc=4 over a queue that is not a second queue.
hs_same_dir_silent() {
	local calls=$hs_work/c4b journal=$hs_work/j4b rc=0
	HS_LIST='{"number":5}' hs_run "$calls" "$journal" \
		FACTORY_HARNESS="$hs_work/target-tree" FACTORY_ROOT="$hs_work/target-tree" || rc=$?
	[ "$rc" -eq 0 ] || { hs_say "same-directory sweep returned $rc, not 0:"; sed 's/^/              /' "$journal" >&2; return 1; }
	hs_calls_empty "$calls"
	hs_journal_silent "$journal" 'HARNESS-POKE'
}
claim_leg "004: harness==root as directories is silent first" hs_same_dir_silent

# 5. the refused POST, told apart by reading: held => ALREADY rc 0; not held => FAILED rc 1.
#    Both stamp the throttle, which is what keeps a bad team name from being retried every pass.
#    Each run gets a fresh ledger from hs_run: earlier legs asked the same pull successfully, and
#    a leg that measures a POST through a throttle it did not know it was holding measures
#    nothing -- the age-gate trap that reddened H-0408's legs, arriving from the other direction.
hs_post_refused() {
	local calls=$hs_work/c5 journal=$hs_work/j5 rc=0
	HS_LIST='{"number":5}' HS_POST_FAIL=1 \
		HS_REQUESTED='{"users":[],"teams":[{"slug":"workers"}]}' \
		hs_run "$calls" "$journal" || rc=$?
	[ "$rc" -eq 0 ] || { hs_say "a held-request 422 must be rc 0, got $rc:"; sed 's/^/              /' "$journal" >&2; return 1; }
	hs_journal_has "$journal" 'HARNESS-POKE-ALREADY pr:5 repo:harness/repo team workers already holds a request'
	local calls2=$hs_work/c5b journal2=$hs_work/j5b rc2=0
	HS_LIST='{"number":5}' HS_POST_FAIL=1 HS_REQUESTED='{"users":[],"teams":[]}' \
		hs_run "$calls2" "$journal2" || rc2=$?
	[ "$rc2" -eq 1 ] || { hs_say "a nothing-held refusal must be rc 1, got $rc2:"; sed 's/^/              /' "$journal2" >&2; return 1; }
	hs_journal_has "$journal2" 'HARNESS-POKE-FAILED pr:5 repo:harness/repo'
	hs_journal_has "$journal2" 'failed=1'
}
claim_leg "004: a refused POST is read back, not guessed" hs_post_refused

# 6. the knob off: no endpoint touched, and the refusal names itself every pass.
hs_knob_off() {
	local calls=$hs_work/c6 journal=$hs_work/j6 rc=0
	HS_LIST='{"number":5}' hs_run "$calls" "$journal" FACTORY_HARNESS_POKE=0 || rc=$?
	[ "$rc" -eq 0 ] || { hs_say "a refused sweep is a stance, not a failure: rc $rc"
		sed 's/^/              /' "$journal" >&2; return 1; }
	hs_calls_empty "$calls"
	hs_journal_has "$journal" 'HARNESS-POKE-OFF'
}
claim_leg "004: FACTORY_HARNESS_POKE=0 refuses loudly" hs_knob_off
