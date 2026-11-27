# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034,SC2154
# 003-harness-behind-own-word.sh -- the `not-this-pass` refusal counts into a streak chosen by
# WHICH tree was refused, and the harness tree gets its own escalating word. (#3, H-0408)
#
# Requirement: H-0407 put the harness in its own repository, so from that day the installed unit
# execs a tree this pass supervises-but-may-never-merge (`FACTORY_HARNESS != FACTORY_ROOT`, true
# forever). The #489 gate refused exactly that tree on every activation and counted the refusal
# into `supervisor.stale-streak` -- an escalation whose sentence promises "the loop is reporting,
# not repairing". Measured live on the box that runs the timer on 26 Nov (issue #3): the streak
# armed the unrepaired-STALE sentence while the harness read `behind=0`, because an architectural
# constant was feeding an outage escalation. H-0056 had already chosen report-not-repair for this
# tree, so the report half had to stay loud while the escalation had to move.
#
# Legs, in the order that makes each one's premise the previous one's output:
#   1. the split shape -- unit execs the harness, pass supervises another repository, harness
#      BEHIND: the refusal journals, the tree does not move, `harness-streak` counts, and
#      `stale-streak` is untouched (it is absent, so an armed number cannot hide behind it);
#   2. the same shape with the harness at the trunk: the refusal still journals (H-0056 refuses
#      however current), a seeded `harness-streak` is cleared, nothing else is armed -- the exact
#      live state that read STALE, made green;
#   3. three behind-activations escalate as `HARNESS-STALE`, the word that names the by-hand
#      repair this pass is forbidden to make;
#   4. the #489 control: a tree that is neither the target nor the harness still counts into
#      `stale-streak` and still escalates to STALE -- the pre-split contract, byte for byte;
#   5. where both streaks are armed, STALE is the word printed: the repairable failure outranks
#      the by-design one, because a verdict prints one sentence and it should print the one a
#      reader can act on without becoming the repairer.
#
# The contract this file is written against (see the block above `run_selftest_d_legs` in
# `factory/selftest.sh`): sourced, not executed; the fixture root `$work`, `$HERE`, and `claim_leg`
# are the parent's; assertions go through `claim_leg` and detail to stderr, because `set -e` is on
# and a bare failing command in a sourced file kills the suite.

# Absolute at load, for the same reason 002 states: legs' helpers resolve paths after fixture
# helpers have moved nothing, but a future leg that `cd`s must not move this file's subject.
hb_root=$(cd -- "$HERE/.." && pwd)
hb_work=$work/harness-behind-word
hb_err=$work/harness-behind-word.err

# Loud skip when the fixture builder is not in this tree: the legs stand on `r342_fixture`, the
# two-commits-behind harness clone the #342 family already proves standing (its own debug pass is
# the witness that a fixture which never reaches `behind=2` returns red here, not green).
if ! typeset -f r342_fixture >/dev/null 2>&1; then
	printf '  SKIP  %-40s r342_fixture is not defined in this suite (the legs below\n' \
		"003: the harness behind-ness has its own word"
	printf '        stand on its two-commits-behind harness clone and will not re-invent it)\n'
	return 0
fi

hb_say() { printf '            %s\n' "$1" >&2; }

hb_fixture() { # hb_fixture <dir> -- r342's topology plus the target checkout the split introduces
	local d=$1
	r342_fixture "$d" || return 1
	# The watched repository: a real checkout, because the gate discriminates on path identity
	# resolved from real trees, and a file standing in for a directory would let a symlinked
	# fixture answer the ownership question the leg is asking.
	git init -q -b main "$d/target" || return 1
	git -C "$d/target" config user.email harness-behind@example.invalid || return 1
	git -C "$d/target" config user.name 'selftest harness-behind leg' || return 1
	printf 'the watched repository\n' >"$d/target/README" || return 1
	git -C "$d/target" add -A || return 1
	git -C "$d/target" commit -qm 'fixture: the watched repository the pass supervises' || return 1
	return 0
}

# The repair over the shipped common.sh, in the post-split environment: the unit's ExecStart names
# the harness clone (that is what `r342_fixture` writes into the unit file), the pass supervises
# `$d/target`, and `FACTORY_HARNESS` is pinned to the harness exactly as H-0407 made the generated
# unit pin it. `hb_run <dir> <harness>` takes the harness as an argument because the two contracts
# it splits are told apart by nothing else: named as the harness tree, a refusal feeds
# `harness-streak`; unnameable or naming another tree, it is #489's foreign tree and feeds
# `stale-streak`. An empty argument sets the name empty, the shape the shipped gate reads as
# "this pass cannot name its own tree" -- the foreign arm, not a licence.
hb_run() { # hb_run <fixture-dir> <FACTORY_HARNESS> -> stdout of `factory_supervisor_repair`
	local d=$1 har=$2
	FACTORY_DIR=$d/factorydir FACTORY_LOG=$d/factorydir/log \
		FACTORY_LEDGER=$d/factorydir/ledger FACTORY_RUN=$d/factorydir/run \
		FACTORY_HALT=$d/factorydir/HALT FACTORY_UNITS_DIR=$d/units \
		FACTORY_SERVICE_UNIT=plock-factory.service FACTORY_BASE=main \
		FACTORY_HARNESS=$har FACTORY_ROOT=$d/target DRY_RUN=0 \
		bash -c '. "$1"; factory_supervisor_repair' sh "$hb_root/factory/common.sh" 2>"$hb_err"
}

# One verdict, the same two trees, the threshold the leg hands it (mirrors `r342_verdict`).
hb_verdict() { # hb_verdict <fixture-dir> <escalate> <FACTORY_HARNESS> -> `factory_verdict`'s line
	local d=$1 esc=$2 har=$3
	FACTORY_DIR=$d/factorydir FACTORY_LOG=$d/factorydir/log \
		FACTORY_LEDGER=$d/factorydir/ledger FACTORY_RUN=$d/factorydir/run \
		FACTORY_HALT=$d/factorydir/HALT FACTORY_BASE=main \
		FACTORY_HARNESS=$har FACTORY_ROOT=$d/target \
		FACTORY_STALE_ESCALATE=$esc \
		bash -c '. "$1"; factory_verdict' sh "$hb_root/factory/common.sh" 2>"$hb_err"
}

hb_streak() { # hb_streak <fixture-dir> <key> -> the ledger value, or `absent`
	local f=$1/factorydir/ledger/supervisor.$2
	{ [ -f "$f" ] && tr -d '\n' <"$f"; } || printf 'absent\n'
}

# Leg 1. The split shape with the harness behind. Three claims, because the defect was a chain and
# each link has its own way of passing on the wrong thing: a repair that ff'd the harness would
# also leave the streak at 1 if it tallied before merging; a refusal that counted into the OLD
# streak would still print the same stdout; and a fixture whose harness is not actually behind
# would clear a streak it never armed (the precondition probe below is the shape 002 leg 3 states
# as its own rule: a green answer needs its premise measured in the same leg).
hb_behind_harness_arms_its_own_streak() {
	local d=$hb_work/behind out head_before head_after
	hb_fixture "$d" || {
		hb_say 'the two-behind harness fixture could not be built'
		return 1
	}
	head_before=$(git -C "$d/harness" rev-parse HEAD) || return 1
	[ "$(git -C "$d/harness" rev-list --count HEAD..origin/main)" = "2" ] || {
		hb_say 'the fixture harness is not 2 behind, so no leg here can call an armed streak staleness'
		return 1
	}
	out=$(hb_run "$d" "$d/harness") || {
		hb_say 'the repair refused to run over the split fixture'
		return 1
	}
	case "$out" in
	*'SUPERVISOR-FF-REFUSED not-this-pass'*) : ;;
	*)
		hb_say 'the unit execs the harness and the pass supervises another tree, and the gate said'
		hb_say 'nothing about not-this-pass. Without the refusal there is no streak to judge:'
		printf '              %s\n' "$out" >&2
		return 1
		;;
	esac
	head_after=$(git -C "$d/harness" rev-parse HEAD) || return 1
	[ "$head_before" = "$head_after" ] || {
		hb_say 'the pass fast-forwarded the harness tree it was refusing: H-0056 says report, not merge'
		return 1
	}
	case "$(hb_streak "$d" harness-streak)" in
	1) : ;;
	*)
		hb_say "supervisor.harness-streak reads $(hb_streak "$d" harness-streak), not 1, after one"
		hb_say 'behind-activation of the harness tree. The refusal printed; the count went elsewhere.'
		return 1
		;;
	esac
	case "$(hb_streak "$d" stale-streak)" in
	absent | 0) : ;;
	*)
		hb_say "supervisor.stale-streak reads $(hb_streak "$d" stale-streak): the harness tree the"
		hb_say 'unit execs counted into the UNREPAIRED escalation again -- the exact #3 misarm, which'
		hb_say 'promises a reader "the loop is reporting, not repairing" about a tree it may not touch.'
		return 1
		;;
	esac
}

# Leg 2. The live state that produced #3: harness at the trunk, refusal constant. A seeded streak
# is the evidence -- clearing is something that happens, and cannot be faked by absence.
hb_current_harness_clears_not_arms() {
	local d=$hb_work/current out
	hb_fixture "$d" || {
		hb_say 'the fixture could not be built'
		return 1
	}
	git -C "$d/harness" merge -q --ff-only origin/main || {
		hb_say 'the fixture harness could not be brought to the trunk'
		return 1
	}
	[ "$(git -C "$d/harness" rev-list --count HEAD..origin/main)" = "0" ] || {
		hb_say 'the harness is not at the trunk after the ff, so the premise of this leg is gone'
		return 1
	}
	printf '2\n' >"$d/factorydir/ledger/supervisor.harness-streak" || return 1
	# The live box's actual post-split state, transcribed: the old counting had armed the UNREPAIRED
	# streak to 28 against a harness at the trunk. The harness-current branch owes that streak its
	# documented clear -- #342: "a current tree or a completed repair clears it" -- or the merge
	# replaces the misarm with a stuck arm and `--status` reads STALE forever on the live box.
	printf '28\n' >"$d/factorydir/ledger/supervisor.stale-streak" || return 1
	printf 'not-this-pass installed=/home/rodney/prj/delivery-factory-live\n' \
		>"$d/factorydir/ledger/supervisor.stale-reason" || return 1
	out=$(hb_run "$d" "$d/harness") || {
		hb_say 'the repair refused to run'
		return 1
	}
	case "$out" in
	*'SUPERVISOR-FF-REFUSED not-this-pass'*) : ;;
	*)
		hb_say 'H-0056 refuses a fast-forward of the harness tree however current it is, and this'
		hb_say 'stdout carries no refusal -- a silent activation is the shape #342 filed:'
		printf '              %s\n' "$out" >&2
		return 1
		;;
	esac
	case "$(hb_streak "$d" harness-streak)" in
	0) : ;;
	*)
		hb_say "a current harness left supervisor.harness-streak at $(hb_streak "$d" harness-streak)."
		hb_say 'A constant condition whose count only ever grows escalates forever; the live #3 read'
		hb_say 'STALE at behind=0 for exactly this reason.'
		return 1
		;;
	esac
	case "$(hb_streak "$d" stale-streak)" in
	0) : ;;
	*)
		hb_say "a current harness left supervisor.stale-streak at $(hb_streak "$d" stale-streak) —"
		hb_say 'the seed was the live 28, and a streak that survives the tree it counts being at'
		hb_say 'the trunk is a stuck arm: same dead escalation, different cause.'
		return 1
		;;
	esac
}

# Leg 3. The escalation word. Three behind-activations at the shipped threshold; the verdict names
# the tree it judges (the harness the unit execs), the repair it will not do, and is NOT the STALE
# sentence -- whose promise ("the loop is reporting, not repairing") is about a repair this pass
# is permitted to make and this tree forbids.
hb_behind_escalates_as_harness_stale() {
	local d=$hb_work/escalate i out line
	hb_fixture "$d" || {
		hb_say 'the fixture could not be built'
		return 1
	}
	for i in 1 2 3; do
		if ! out=$(hb_run "$d" "$d/harness"); then
			hb_say "activation $i of the harness-behind loop failed"
			return 1
		fi
	done
	case "$(hb_streak "$d" harness-streak)" in
	3) : ;;
	*)
		hb_say "after three behind-activations supervisor.harness-streak reads $(hb_streak "$d" harness-streak)"
		return 1
		;;
	esac
	# Same journal seed as the #342 escalation legs (selftest.sh plants `PASS units=0 dry=0` for
	# the identical reason): `factory_supervisor_repair` prints its sentences to stdout, and it is
	# the unit's tee that journalled them in the live loop -- a fixture that calls the function
	# directly owes its own fresh journal line, or `factory_verdict` answers STALLED before any
	# streak word and the leg fails on its plumbing instead of its claim.
	printf '%s SUPERVISOR-AT fixture-seed\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		>>"$d/factorydir/log/supervisor.log" || return 1
	line=$(hb_verdict "$d" 3 "$d/harness") || {
		hb_say 'factory_verdict failed'
		return 1
	}
	case "$line" in
	HARNESS-STALE*)
		case "$line" in
		*'the loop is reporting, not repairing'*)
			hb_say 'the HARNESS-STALE sentence still carries the STALE promise about a repair the'
			hb_say 'loop could make; it must name the by-hand repair it is forbidden to make:'
			printf '              %s\n' "$line" >&2
			return 1
			;;
		esac
		case "$line" in
		*'harness tree the installed unit execs'*) : ;;
		*)
			hb_say 'the verdict does not name the tree it judges (the harness the installed unit execs):'
			printf '              %s\n' "$line" >&2
			return 1
			;;
		esac
		;;
	STALE*)
		hb_say "--status read STALE about the harness tree. That word's sentence promises the loop is"
		hb_say 'not repairing what it could repair; behind this word sat the live misarm of 26 Nov:'
		printf '              %s\n' "$line" >&2
		return 1
		;;
	*)
		hb_say "the streak reached the threshold and the verdict read something else entirely:"
		printf '              %s\n' "$line" >&2
		return 1
		;;
	esac
}

# Leg 4 (control). #489 survives: a tree that is neither the target nor the tree this pass can name
# as its harness is the foreign-tree outage, and it still counts into `stale-streak` and still
# escalates to STALE at the same threshold. `hb_run "$d" ""` sets the harness name empty -- the
# shape where the pass cannot prove which tree it runs from, so nothing licenses clearing or
# re-routing the old streak.
hb_foreign_tree_still_arms_stale() {
	local d=$hb_work/foreign i out line
	hb_fixture "$d" || {
		hb_say 'the fixture could not be built'
		return 1
	}
	for i in 1 2 3; do
		if ! out=$(hb_run "$d" ""); then
			hb_say "activation $i of the foreign-tree loop failed"
			return 1
		fi
	done
	case "$(hb_streak "$d" stale-streak)" in
	3) : ;;
	*)
		hb_say "three foreign-tree refusals left supervisor.stale-streak at $(hb_streak "$d" stale-streak)."
		hb_say '#489 filed passes aimed at another person'"'"'s checkout as an outage, and the #342'
		hb_say 'escalation is how anyone learns of one; moving it is not this leg'"'"'s to allow.'
		return 1
		;;
	esac
	case "$(hb_streak "$d" harness-streak)" in
	absent | 0) : ;;
	*)
		hb_say 'the foreign tree counted into the harness streak: a pass that cannot name its own'
		hb_say 'tree may not report on it as though it were its harness.'
		return 1
		;;
	esac
	# Journal seed for the same reason as the escalation leg above: STALLED is asked first, and
	# this fixture called the repair function directly, so nobody has journalled anything.
	printf '%s SUPERVISOR-AT fixture-seed\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		>>"$d/factorydir/log/supervisor.log" || return 1
	line=$(hb_verdict "$d" 3 "") || {
		hb_say 'factory_verdict failed'
		return 1
	}
	case "$line" in
	STALE*) : ;;
	*)
		hb_say 'the armed #489 outage no longer reads STALE to --status; #3 fixed a misarm, not the escalation:'
		printf '              %s\n' "$line" >&2
		return 1
		;;
	esac
}

# Leg 5. Precedence where both words are earned: STALE prints. Seeded directly, because standing
# up both outages in one fixture would need a third tree behind AND the harness behind, and the
# ledger is the same state a repair would have produced either way.
hb_stale_outranks_harness_stale() {
	local d=$hb_work/both line
	hb_fixture "$d" || {
		hb_say 'the fixture could not be built'
		return 1
	}
	printf '5\n' >"$d/factorydir/ledger/supervisor.harness-streak" || return 1
	printf 'not-this-pass installed=/elsewhere\n' >"$d/factorydir/ledger/supervisor.harness-reason" || return 1
	printf '4\n' >"$d/factorydir/ledger/supervisor.stale-streak" || return 1
	printf 'diverged ahead=1 installed=/elsewhere\n' >"$d/factorydir/ledger/supervisor.stale-reason" || return 1
	# A fresh journal line first: STALLED is asked before every streak word, and a fixture whose
	# journal does not exist has, by the shipped order, a newer fault than either streak -- this
	# leg judges which streak word wins, so it has to answer STALLED out of the way first.
	printf '%s SUPERVISOR-AT fixture-seed\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		>>"$d/factorydir/log/supervisor.log" || return 1
	line=$(hb_verdict "$d" 3 "$d/harness") || {
		hb_say 'factory_verdict failed'
		return 1
	}
	case "$line" in
	STALE*) : ;;
	*)
		hb_say 'both streaks are armed past the threshold and the verdict did not print STALE -- the'
		hb_say 'repairable failure is the one a reader can hand the loop, and a verdict prints one line:'
		printf '              %s\n' "$line" >&2
		return 1
		;;
	esac
}

claim_leg 'behind harness arms its own streak, not the unrepaired one' hb_behind_harness_arms_its_own_streak
claim_leg 'a current harness clears the harness streak' hb_current_harness_clears_not_arms
claim_leg 'the harness behind escalates as HARNESS-STALE' hb_behind_escalates_as_harness_stale
claim_leg 'control: the foreign tree still escalates as STALE' hb_foreign_tree_still_arms_stale
claim_leg 'a repairable STALE outranks the by-design word' hb_stale_outranks_harness_stale
