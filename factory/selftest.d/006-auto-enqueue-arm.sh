# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034,SC2154,SC1090,SC1091,SC2163
# 006-auto-enqueue-arm.sh -- an approved pull whose checks are only PENDING may be handed to
# GitHub's auto-merge (H-0411), and the queue must collect what the server then merges.
#
# Requirement (user's, 27 Nov): "the factory should merge any fully approved PR that is passing
# CI and has no conflicts... It would even be better for it to enable auto-merge if that is
# enabled on the repo." The direct arm already merges approved+green+clean; what it could not do
# is stop re-reading an approved pull whose checks are still RUNNING every activation forever.
# `allow_auto_merge` lets GitHub run that wait; this leg pins the three shapes that make that
# safe: the offer is narrow (pending checks only, fully approved, repository opted in), the
# enqueue is judged by reading `autoMergeRequest` back and never by gh's exit status (#1180),
# and a merge GitHub completes is CLOSED OUT exactly like one the queue made itself -- the same
# ledger record, the same tree and branch retirement.
#
# Legs:
#   1. the offer enqueues the pending+approved+opted-in shape, reads the queueing back, stamps
#      the ledger with the branch;
#   2. a repository without `allow_auto_merge` is refused into the plain wait -- never into a
#      direct merge (fail closed);
#   3. every other `awaiting_merge` shape (approved but checks not pending) makes NO call at all,
#      not even the repository read;
#   4. an already-stamped enqueue is not re-offered: one queueing per pull;
#   5. `FACTORY_AUTO_ENQUEUE=0` journals `AUTO-ENQUEUE-OFF` and touches nothing;
#   6. an enqueue whose read-back says `null` is `AUTO-ENQUEUE-REFUSED` and stamps nothing;
#   7. a dry run says WOULD and writes neither call nor stamp;
#   8. the sweep closes out a merged pull through `factory_merge_finalize` -- `merged-at`
#      stamped, queueing stamps cleared, closure asked;
#   9. the sweep drops the queueing on a pull closed UNMERGED, and survives an unreadable pull
#      with rc 1 and the stamp INTACT (a dropped stamp on a failed read is how a finished merge
#      becomes an orphan tree);
#  10. a still-pending queueing keeps its stamp, says PENDING, and escalates through
#      `factory_maybe_notice` on the enqueue clock -- the wait is not lost, it moved;
#  11. a queueing that has vanished from the server -- auto-merge switched off behind the queue's
#      back, or GitHub dropping the queueing -- is `AUTO-ENQUEUE-CANCELLED`: the stamp is cleared,
#      nothing escalates, and the offer re-presents next pass; an UNREADABLE queueing read keeps
#      the stamp, because guessing here orphans a queueing that is really still there;
#  12. (control) the closed-unmerged fixture of 9a, run against an extracted arm with the boundary
#      `ascii_upcase` removed from the `state` read, must NOT drop the queueing -- proof that 9a
#      measures the wire rather than the code's own spelling.
#
# `state` casing is a fixture-honesty rule, not cosmetics. Every read in this leg goes through the
# shipped `api_get`, which is plain REST (`gh api repos/... --jq`), and REST answers a pull's
# `state` in LOWERCASE (#424; re-measured under review 27 Nov: `gh api
# repos/vicowa-botworks/delivery-factory/pulls/6 --jq .state` is `closed`). So the payloads below
# answer `open`/`closed` the way the wire does, and the arm's boundary normalisation is what makes
# `[ "$state" = "CLOSED" ]` true. A fixture welded to the code's spelling is how the drop branch
# stayed green while being dead on the wire -- the defect class this file exists to catch.

# The identity rule of leg 000's scan applies to every `git init` below: an identity line sits
# within three lines of each one.
ae_root=$(cd -- "$HERE/.." && pwd)
ae_work=$work/auto-enqueue-arm

ae_say() { printf '            %s\n' "$1" >&2; }

mkdir -p "$ae_work/bin" "$ae_work/trees"

# Fixture `gh`: one payload behind one endpoint, the caller's own --jq run over it, strict exit
# 9 on anything unhandled -- the 004 family's shape. AE_AUTOMERGE is the repository's opt-in,
# AE_AUTOREQ the autoMergeRequest read-back, AE_PULL the pull's own {merged,state}, AE_ENQ_FAIL
# makes the enqueue itself fail.
cat >"$ae_work/bin/gh" <<'AEGH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AE_CALLS"
answer() { # answer <payload> -- run the call's own --jq when it carried one
	local payload=$1 jqprog='' args=("$@") i=0
	while [ "$i" -lt "${#args[@]}" ]; do
		[ "${args[$i]}" = "--jq" ] && jqprog=${args[$((i + 1))]}
		i=$((i + 1))
	done
	if [ -n "$jqprog" ]; then printf '%s\n' "$payload" | jq -r "$jqprog"; else printf '%s\n' "$payload"; fi
}
case "$*" in
*'pr merge'*)
	if [ "${AE_ENQ_FAIL-0}" = 1 ]; then
		printf 'gh: could not enable auto-merge (fixture)\n' >&2
		exit 1
	fi
	exit 0
	;;
*'-X POST'* | *'issue comment'* | *'pr comment'*)
	printf 'auto-enqueue-shim: an unhandled write: %s\n' "$*" >&2
	exit 9
	;;
*autoMergeRequest*)
	# `fail` is the plant leg 11b needs and nothing else: the QUEUEING read going down while the
	# pull's own merged/state read stays healthy. `AE_PULL=fail` cannot express that -- it fails the
	# merged/state reads, which is leg 9b's different question.
	if [ "${AE_AUTOREQ-}" = fail ]; then
		printf 'gh: HTTP 502 (fixture)\n' >&2
		exit 1
	fi
	answer "${AE_AUTOREQ:-{\"autoMergeRequest\":{\"mergeMethod\":\"MERGE\"}}}" "$@"
	exit 0
	;;
*api*pulls*)
	case "${AE_PULL-}" in
	fail) # the endpoint itself unreachable: gh exits 1, api_get falls back to its default
		printf 'gh: HTTP 404 (fixture)\n' >&2
		exit 1
	;;
	# lowercase `state`, because that is what REST answers for a pull (#424) -- see the header.
	'') answer '{"merged":false,"state":"open"}' "$@" ;;
	*) answer "$AE_PULL" "$@" ;;
	esac
	exit 0
	;;
*api*repos/example/repo*)
	answer "{\"allow_auto_merge\":${AE_AUTOMERGE:-true}}" "$@"
	exit 0
	;;
*)
	printf 'auto-enqueue-shim: an unhandled call: %s\n' "$*" >&2
	exit 9
	;;
esac
AEGH
chmod +x "$ae_work/bin/gh"

# Built BEFORE the extract, and the extract is a guard, not a precondition step: on a tree that
# lacks the arm the leg must die loudly, never pass by reading nothing (#3276).
ae_extract() { # cut the functions under test out of the shipped file
	local fn
	: >"$ae_work/arm.sh"
	for fn in factory_auto_merge_allowed factory_auto_enqueue_offer factory_auto_enqueue \
		factory_auto_enqueue_sweep factory_merge_finalize; do
		# index(), not `$0 ~ pat`: gawk eats the backslashes through -v and an UNESCAPED `()`
		# in an ERE is an empty group, so `^fn\(\)` measured as `^fn()` silently matched
		# `factory_auto_enqueue_offer() {` first -- a leg reading the wrong body passes for
		# the wrong reason. A literal prefix compare cannot do that.
		awk -v pat="$fn() {" 'index($0, pat) == 1 { p = 1 } p { print } p && /^\}/ { exit }' \
			"$ae_root/factory/factory.sh" >>"$ae_work/arm.sh"
	done
	[ "$(grep -c '() {' "$ae_work/arm.sh")" -eq 5 ] || {
		ae_say "extracted $(grep -c '() {' "$ae_work/arm.sh") of 5 functions from $ae_root/factory/factory.sh -- the leg would read nothing"
		return 1
	}
	[ "$(grep -c '^factory_auto_enqueue() {' "$ae_work/arm.sh")" -eq 1 ] || {
		ae_say "the extraction did not isolate factory_auto_enqueue -- prefix matching went wrong"
		return 1
	}
}
ae_extract

ae_tree=$ae_work/main-tree
git init -q -b main "$ae_tree"
git -C "$ae_tree" config user.email autoenqueue@example.invalid

# ae_run <out-file-journal> <out-file-calls> <fn> [args...] [VAR=VAL ...] -- one function of the
# arm, fake gh on PATH, fresh fixture ledger unless AE_LEDGER names one. Overrides come last.
ae_run() {
	local journal=$1 calls=$2 fn=$3
	shift 3
	: >"$calls"
	local ledger=${AE_LEDGER:-}
	[ -n "$ledger" ] || ledger=$(mktemp -d "$ae_work/ledger-XXXXXX")
	# SC2094 as in 004: the subshell WRITES $journal; every reader is an assertion outside it.
	# shellcheck disable=SC2094
	(
		set -eu
		# shellcheck disable=SC1091
		. "$ae_root/factory/common.sh"
		# AE_ARM is the mutant seam: leg 12 runs the same fixtures against an extracted arm with
		# one token removed, and a control that cannot be aimed at a different body is a control
		# that proves nothing. Unset, every caller gets the shipped extraction.
		# shellcheck disable=SC1090
		. "${AE_ARM:-$ae_work/arm.sh}"
		# The two collaborators this leg is NOT about, stubbed loudly rather than silently
		# absent: a finalize that never asks closure, or a wait that never escalates, would
		# pass for the wrong reason. SC2317: their bodies are called only from the extracted
		# arm sourced above, which shellcheck cannot follow.
		# shellcheck disable=SC2317
		factory_verify_closure() { printf 'closure-checked %s\n' "$1" >>"$AE_CALLS"; }
		# shellcheck disable=SC2317
		factory_maybe_notice() { printf 'notice %s %s clock=%s\n' "$1" "$2" "$3" >>"$AE_CALLS"; }
		# shellcheck disable=SC2317
		factory_wait() { printf 'wait %s %s\n' "$2" "$3" >>"$AE_CALLS"; }
		# Exports for the fixture's OWN state; the caller's overrides reached the subshell as
		# prefix assignments on the leg's `ae_run` call and are re-exported here because a
		# prefix assignment to a function is a shell variable, not an exported one.
		export AE_CALLS=$calls AE_AUTOMERGE=${AE_AUTOMERGE:-true} AE_AUTOREQ=${AE_AUTOREQ:-} \
			AE_PULL=${AE_PULL:-} AE_ENQ_FAIL=${AE_ENQ_FAIL:-0} \
			PATH="$ae_work/bin:$PATH" \
			FACTORY_ROOT=$ae_tree FACTORY_HARNESS=$ae_tree \
			FACTORY_REPO=example/repo FACTORY_OWNER=example FACTORY_NAME=repo \
			FACTORY_LOG=$ae_work/log FACTORY_LEDGER=$ledger FACTORY_RUN=$ae_work/run \
			FACTORY_TREES=$ae_work/trees DRY_RUN=${DRY_RUN:-0} FACTORY_AUTO_ENQUEUE=${FACTORY_AUTO_ENQUEUE:-1}
		"$fn" "$@"
	) >"$journal" 2>&1
}
ae_ledger() { printf '%s/%s.%s' "$1" "$2" "$3"; }
ae_calls_has() {
	if grep -qF -- "$2" "$1"; then return 0; fi
	ae_say "the recorded calls were:"; sed 's/^/              /' "$1" >&2
	ae_say "none of them carries: $2"; return 1
}
ae_calls_no() {
	if grep -qF -- "$2" "$1"; then
		ae_say "a call carries $2, and there must be none:"; sed 's/^/              /' "$1" >&2
		return 1
	fi
	return 0
}
ae_journal_has() {
	if grep -qF -- "$2" "$1"; then return 0; fi
	ae_say "the journal was:"; sed 's/^/              /' "$1" >&2
	ae_say "with nothing matching: $2"; return 1
}
ae_journal_no() {
	if grep -qF -- "$2" "$1"; then
		ae_say "the journal carries $2, and it must not:"; sed 's/^/              /' "$1" >&2
		return 1
	fi
	return 0
}

# 1. the pending+approved+opted-in shape enqueues, reads back, and stamps the branch.
ae_offer_lands() {
	local j=$ae_work/j1 c=$ae_work/c1 rc=0 led
	led=$(mktemp -d "$ae_work/ledger-XXXXXX")
	AE_LEDGER=$led AE_AUTOMERGE=true \
		ae_run "$j" "$c" factory_auto_enqueue_offer 9 fix/widget 'approved; mergeStateStatus=BLOCKED, checks=pending' || rc=$?
	[ "$rc" -eq 0 ] || { ae_say "the offer returned $rc, not 0:"; sed 's/^/              /' "$j" >&2; return 1; }
	ae_calls_has "$c" 'pr merge 9 --auto --merge --delete-branch' || return 1
	ae_journal_has "$j" 'AUTO-ENQUEUED pr:9 method=MERGE branch:fix/widget' || return 1
	[ -s "$(ae_ledger "$led" 'pr:9' auto-enqueue)" ] || { ae_say "no auto-enqueue stamp"; return 1; }
	[ "$(cat "$(ae_ledger "$led" 'pr:9' auto-enqueue-branch)")" = "fix/widget" ] || { ae_say "the branch was not carried"; return 1; }
}
claim_leg "006: the pending approved shape is enqueued and stamped" ae_offer_lands

# 2. no opt-in at the repository: refused into the wait, never into a direct merge.
ae_repo_refuses() {
	local j=$ae_work/j2 c=$ae_work/c2 rc=0
	AE_AUTOMERGE=false ae_run "$j" "$c" factory_auto_enqueue_offer 9 fix/widget 'approved; mergeStateStatus=CLEAN, checks=pending' || rc=$?
	[ "$rc" -eq 1 ] || { ae_say "the offer returned $rc, not 1 (the wait must stand):"; return 1; }
	ae_calls_has "$c" 'repos/example/repo' || return 1
	ae_calls_no "$c" '--auto' || return 1
	# And the refusal has a voice -- the H-0409 principle applied to this arm under review: a silent
	# repository-level NO reads the same in the journal as never reaching the offer at all. The
	# decision entry and the PR body both promise this line, so a leg plants it (a branch nobody
	# plants is a branch nobody has seen run).
	ae_journal_has "$j" 'AUTO-ENQUEUE-REPO-NO pr:9' || return 1
}
claim_leg "006: a repository without auto-merge fails closed to the wait" ae_repo_refuses

# 3. checks are not pending (approved-but-behind, approved-green-unstable): the arm must not
#    even read the repository -- the offer is narrow or it is not the pending-wait fix it claims.
ae_other_shapes_quiet() {
	local j c rc
	for detail in 'approved; mergeStateStatus=BEHIND, checks=pass' 'approved; mergeStateStatus=UNSTABLE, checks=fail'; do
		rc=0
		j=$ae_work/j3 c=$ae_work/c3
		ae_run "$j" "$c" factory_auto_enqueue_offer 9 fix/widget "$detail" || rc=$?
		[ "$rc" -eq 1 ] || { ae_say "detail [$detail] returned $rc, not 1"; return 1; }
		[ -s "$c" ] || continue
		ae_say "detail [$detail] made calls where it must make none:"; sed 's/^/              /' "$c" >&2
		return 1
	done
}
claim_leg "006: every non-pending awaiting_merge shape makes no call at all" ae_other_shapes_quiet

# 4. one queueing per pull: a stamped row is not re-offered -- no config read, no merge call.
ae_no_double() {
	local j=$ae_work/j4 c=$ae_work/c4 rc=0 led
	led=$(mktemp -d "$ae_work/ledger-XXXXXX")
	printf '2026-11-27T00:00:00Z' >"$(ae_ledger "$led" 'pr:9' auto-enqueue)"
	AE_LEDGER=$led ae_run "$j" "$c" factory_auto_enqueue_offer 9 fix/widget 'approved; mergeStateStatus=BLOCKED, checks=pending' || rc=$?
	[ "$rc" -eq 0 ] || { ae_say "an enqueued row returned $rc, not 0 (the sweep owns it now)"; return 1; }
	[ -s "$c" ] && { ae_say "a stamped row made calls:"; sed 's/^/              /' "$c" >&2; return 1; }
	return 0
}
claim_leg "006: an enqueued row is not re-offered" ae_no_double

# 5. the knob: OFF journals which knob and touches nothing.
ae_knob_off() {
	local j=$ae_work/j5 c=$ae_work/c5 rc=0
	FACTORY_AUTO_ENQUEUE=0 ae_run "$j" "$c" factory_auto_enqueue_offer 9 fix/widget 'approved; mergeStateStatus=CLEAN, checks=pending' || rc=$?
	[ "$rc" -eq 1 ] || { ae_say "the knob-off offer returned $rc, not 1"; return 1; }
	ae_journal_has "$j" 'AUTO-ENQUEUE-OFF pr:9' || return 1
	[ -s "$c" ] && { ae_say "the knob-off path made calls:"; sed 's/^/              /' "$c" >&2; return 1; }
	return 0
}
claim_leg "006: FACTORY_AUTO_ENQUEUE=0 refuses loudly" ae_knob_off

# 6. gh exits 0 but the server records no queueing: the read-back is the verdict (#1180), the
#    stamps must stay empty so the wait keeps escalating the real state.
ae_readback_null() {
	local j=$ae_work/j6 c=$ae_work/c6 rc=0 led
	led=$(mktemp -d "$ae_work/ledger-XXXXXX")
	AE_AUTOREQ='{"autoMergeRequest":null}' AE_LEDGER=$led \
		ae_run "$j" "$c" factory_auto_enqueue_offer 9 fix/widget 'approved; mergeStateStatus=CLEAN, checks=pending' || rc=$?
	[ "$rc" -eq 1 ] || { ae_say "a null read-back returned $rc, not 1"; return 1; }
	ae_journal_has "$j" 'AUTO-ENQUEUE-REFUSED pr:9' || return 1
	[ ! -s "$(ae_ledger "$led" 'pr:9' auto-enqueue)" ] || { ae_say "a refused enqueue stamped the ledger"; return 1; }
	return 0
}
claim_leg "006: an enqueue is judged by its read-back, not gh's exit" ae_readback_null

# 7. dry run: WOULD, no write call, no stamp. The repository read DOES happen -- a rehearsal
# that skipped the capability check would rehearse a call the real pass might never make.
ae_dry_run() {
	local j=$ae_work/j7 c=$ae_work/c7 rc=0 led
	led=$(mktemp -d "$ae_work/ledger-XXXXXX")
	DRY_RUN=1 AE_LEDGER=$led ae_run "$j" "$c" factory_auto_enqueue_offer 9 fix/widget 'approved; mergeStateStatus=CLEAN, checks=pending' || rc=$?
	[ "$rc" -eq 0 ] || { ae_say "the dry run returned $rc, not 0"; return 1; }
	ae_journal_has "$j" 'WOULD-AUTO-ENQUEUE pr:9' || return 1
	ae_calls_no "$c" 'pr merge' || return 1
	[ ! -s "$(ae_ledger "$led" 'pr:9' auto-enqueue)" ] || { ae_say "the dry run stamped the ledger"; return 1; }
	return 0
}
claim_leg "006: a dry run rehearses the enqueue and writes nothing" ae_dry_run

# 8. the sweep closes a merged enqueue out through the shared finalize: merged-at stamped,
#    queueing stamps cleared, closure verification asked, END-worthy record like a direct merge.
ae_sweep_merged() {
	local j=$ae_work/j8 c=$ae_work/c8 rc=0 led
	led=$(mktemp -d "$ae_work/ledger-XXXXXX")
	printf '2026-11-27T00:00:00Z' >"$(ae_ledger "$led" 'pr:9' auto-enqueue)"
	printf 'fix/widget' >"$(ae_ledger "$led" 'pr:9' auto-enqueue-branch)"
	AE_PULL='{"merged":true,"state":"closed"}' AE_LEDGER=$led ae_run "$j" "$c" factory_auto_enqueue_sweep || rc=$?
	[ "$rc" -eq 0 ] || { ae_say "the sweep returned $rc, not 0:"; sed 's/^/              /' "$j" >&2; return 1; }
	ae_journal_has "$j" 'AUTO-MERGED pr:9' || return 1
	ae_calls_has "$c" 'closure-checked 9' || return 1
	[ -s "$(ae_ledger "$led" 'pr:9' merged-at)" ] || { ae_say "no merged-at stamp after AUTO-MERGED"; return 1; }
	[ ! -s "$(ae_ledger "$led" 'pr:9' auto-enqueue)" ] || { ae_say "the queueing stamp survived its own merge"; return 1; }
	[ ! -s "$(ae_ledger "$led" 'pr:9' auto-enqueue-branch)" ] || { ae_say "the branch stamp survived its own merge"; return 1; }
	return 0
}
claim_leg "006: a merge GitHub completed gets the queue's own closeout" ae_sweep_merged

# 9a. closed UNMERGED: the queueing is dropped, nothing merges, nothing escalates. The payload says
#     `closed`, lowercase, as REST answers it (#424); leg 12 is the control that proves this fixture
#     is what makes the leg measure the wire and not the arm's own spelling.
ae_sweep_closed() {
	local j=$ae_work/j9 c=$ae_work/c9 rc=0 led
	led=$(mktemp -d "$ae_work/ledger-XXXXXX")
	printf '2026-11-27T00:00:00Z' >"$(ae_ledger "$led" 'pr:9' auto-enqueue)"
	AE_PULL='{"merged":false,"state":"closed"}' AE_LEDGER=$led ae_run "$j" "$c" factory_auto_enqueue_sweep || rc=$?
	[ "$rc" -eq 0 ] || { ae_say "the sweep returned $rc, not 0"; return 1; }
	ae_journal_has "$j" 'AUTO-ENQUEUE-CLOSED pr:9' || return 1
	[ ! -s "$(ae_ledger "$led" 'pr:9' auto-enqueue)" ] || { ae_say "a closed-unmerged pull kept its queueing"; return 1; }
	return 0
}
claim_leg "006: a queueing closed without a merge is dropped" ae_sweep_closed

# 9b. an unreadable pull: rc 1, and the stamp SURVIVES -- dropping it on a failed read is how a
# merge that finished later turns into an orphan tree and a silent journal.
ae_sweep_unreadable() {
	local j=$ae_work/j10 c=$ae_work/c10 rc=0 led
	led=$(mktemp -d "$ae_work/ledger-XXXXXX")
	printf '2026-11-27T00:00:00Z' >"$(ae_ledger "$led" 'pr:9' auto-enqueue)"
	AE_PULL=fail AE_LEDGER=$led ae_run "$j" "$c" factory_auto_enqueue_sweep || rc=$?
	[ "$rc" -eq 1 ] || { ae_say "an unreadable pull returned $rc, not 1"; return 1; }
	ae_journal_has "$j" 'AUTO-ENQUEUE-SKIPPED pr:9' || return 1
	[ -s "$(ae_ledger "$led" 'pr:9' auto-enqueue)" ] || { ae_say "the stamp was dropped on an unreadable read"; return 1; }
	return 0
}
claim_leg "006: an unreadable enqueue survives its pass with rc 1" ae_sweep_unreadable

# 10. still pending: the stamp stays, the line says so, and the escalation clock is the ENQUEUE's
# own -- the wait moved to GitHub, so its age must be GitHub's queueing's age.
ae_sweep_pending() {
	local j=$ae_work/j11 c=$ae_work/c11 rc=0 led
	led=$(mktemp -d "$ae_work/ledger-XXXXXX")
	printf '2026-11-26T00:00:00Z' >"$(ae_ledger "$led" 'pr:9' auto-enqueue)"
	AE_PULL='{"merged":false,"state":"open"}' AE_LEDGER=$led ae_run "$j" "$c" factory_auto_enqueue_sweep || rc=$?
	[ "$rc" -eq 0 ] || { ae_say "a pending queueing returned $rc, not 0"; return 1; }
	ae_journal_has "$j" 'AUTO-ENQUEUE-PENDING pr:9 enqueued 2026-11-26T00:00:00Z' || return 1
	ae_calls_has "$c" 'notice pr:9 awaiting_merge clock=2026-11-26T00:00:00Z' || return 1
	[ -s "$(ae_ledger "$led" 'pr:9' auto-enqueue)" ] || { ae_say "a pending queueing lost its stamp"; return 1; }
	return 0
}
claim_leg "006: a pending queueing keeps its stamp and its escalation clock" ae_sweep_pending

# 11a. the queueing is gone from the server -- auto-merge switched off behind the queue's back, or
#      GitHub dropping the queueing. The pull reads open, unmerged and green, which is the pending
#      shape byte for byte: only re-reading the queueing itself tells the two apart. The answer is
#      CANCELLED with both stamps cleared, so the offer re-presents next pass. Escalating here would
#      be worse than silence: a NOTICE blaming checks that cleared three passes ago points the reader
#      at the one thing that is fine.
ae_sweep_cancelled() {
	local j=$ae_work/j12 c=$ae_work/c12 rc=0 led
	led=$(mktemp -d "$ae_work/ledger-XXXXXX")
	printf '2026-11-26T00:00:00Z' >"$(ae_ledger "$led" 'pr:9' auto-enqueue)"
	printf 'fix/widget' >"$(ae_ledger "$led" 'pr:9' auto-enqueue-branch)"
	AE_PULL='{"merged":false,"state":"open"}' AE_AUTOREQ='{"autoMergeRequest":null}' AE_LEDGER=$led \
		ae_run "$j" "$c" factory_auto_enqueue_sweep || rc=$?
	[ "$rc" -eq 0 ] || { ae_say "a cancelled queueing returned $rc, not 0:"; sed 's/^/              /' "$j" >&2; return 1; }
	ae_journal_has "$j" 'AUTO-ENQUEUE-CANCELLED pr:9' || return 1
	ae_journal_no "$j" 'AUTO-ENQUEUE-PENDING pr:9' || return 1
	ae_calls_no "$c" 'notice pr:9' || return 1
	[ ! -s "$(ae_ledger "$led" 'pr:9' auto-enqueue)" ] || { ae_say "a cancelled queueing kept its stamp, so it will never be re-offered"; return 1; }
	[ ! -s "$(ae_ledger "$led" 'pr:9' auto-enqueue-branch)" ] || { ae_say "a cancelled queueing kept its branch stamp"; return 1; }
	return 0
}
claim_leg "006: a queueing that vanished server-side is cancelled, not escalated" ae_sweep_cancelled

# 11b. the same sweep with only the QUEUEING read unreachable (leg 9b killed merged/state too, which
#      is a different failure). An unreadable queueing must keep the stamp and keep escalating:
#      clearing it on a failed read orphans a queueing that is still there, and GitHub will merge a
#      pull the ledger has stopped watching -- the phantom in the other direction.
ae_sweep_autoreq_unreadable() {
	local j=$ae_work/j13 c=$ae_work/c13 rc=0 led
	led=$(mktemp -d "$ae_work/ledger-XXXXXX")
	printf '2026-11-26T00:00:00Z' >"$(ae_ledger "$led" 'pr:9' auto-enqueue)"
	AE_PULL='{"merged":false,"state":"open"}' AE_AUTOREQ=fail AE_LEDGER=$led \
		ae_run "$j" "$c" factory_auto_enqueue_sweep || rc=$?
	[ "$rc" -eq 0 ] || { ae_say "an unreadable queueing read returned $rc, not 0:"; sed 's/^/              /' "$j" >&2; return 1; }
	ae_journal_has "$j" 'AUTO-ENQUEUE-PENDING pr:9' || return 1
	ae_journal_no "$j" 'AUTO-ENQUEUE-CANCELLED pr:9' || return 1
	ae_calls_has "$c" 'notice pr:9 awaiting_merge' || return 1
	[ -s "$(ae_ledger "$led" 'pr:9' auto-enqueue)" ] || { ae_say "the stamp died on an unreadable read, orphaning a live queueing"; return 1; }
	return 0
}
claim_leg "006: an unreadable queueing read keeps the stamp and the escalation" ae_sweep_autoreq_unreadable

# 12. (control) leg 9a must be measuring the wire, not the arm. Same closed-unmerged fixture, same
#     ledger, run against the extracted arm with one token removed: the boundary `ascii_upcase`. If
#     the fixture said `CLOSED` the way the arm does, removing the boundary would change nothing and
#     9a would stay green on a branch that is dead on production -- the exact shape of the defect
#     review caught, where four legs pinned a compare that could never fire. This leg fails if the
#     mutant still drops the queueing: that would mean 9a never depended on the boundary at all.
#     Same discipline as 506's named mutants and 442's `jc_ctl_mutant`.
ae_ctl_casing() {
	local m=$ae_work/arm-no-upcase.sh j=$ae_work/j14 c=$ae_work/c14 rc=0 led
	if ! grep -qF 'ascii_upcase' "$ae_work/arm.sh"; then
		ae_say 'the extracted arm carries no ascii_upcase at all: the boundary is gone from'
		ae_say 'factory.sh, so this control has nothing to remove and 9a is unpinned'
		return 1
	fi
	sed 's/ | ascii_upcase//' "$ae_work/arm.sh" >"$m"
	if grep -qF 'ascii_upcase' "$m"; then
		ae_say 'the mutant still carries ascii_upcase -- the sed landed nowhere, so a'
		ae_say 'green control here would prove nothing about which token 9a depends on'
		return 1
	fi
	[ "$(wc -l <"$m")" -eq "$(wc -l <"$ae_work/arm.sh")" ] ||
		{ ae_say 'the mutant changed the line count: the sed removed more than the token'; return 1; }
	led=$(mktemp -d "$ae_work/ledger-XXXXXX")
	printf '2026-11-27T00:00:00Z' >"$(ae_ledger "$led" 'pr:9' auto-enqueue)"
	printf 'fix/widget' >"$(ae_ledger "$led" 'pr:9' auto-enqueue-branch)"
	AE_PULL='{"merged":false,"state":"closed"}' AE_ARM=$m AE_LEDGER=$led \
		ae_run "$j" "$c" factory_auto_enqueue_sweep || rc=$?
	[ "$rc" -eq 0 ] || { ae_say "the mutant sweep returned $rc, not 0:"; sed 's/^/              /' "$j" >&2; return 1; }
	ae_journal_no "$j" 'AUTO-ENQUEUE-CLOSED pr:9' || return 1
	ae_journal_has "$j" 'AUTO-ENQUEUE-PENDING pr:9' || return 1
	# The guarantee, not the word: with the boundary gone the queueing is still stamped, which is
	# the state a closed-unmerged pull must never be left in.
	[ -s "$(ae_ledger "$led" 'pr:9' auto-enqueue)" ] ||
		{ ae_say 'the mutant dropped the stamp anyway, so 9a passes without the boundary'; return 1; }
	return 0
}
claim_leg "006: control: without the boundary upcase the closed-drop goes red" ae_ctl_casing
