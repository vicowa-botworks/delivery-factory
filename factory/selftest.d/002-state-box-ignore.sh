# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034,SC2154
# 002-state-box-ignore.sh -- the state box the supervisor writes beside its own code is not dirt in the
# harness' own checkout, and the four rules that keep it invisible are pinned with their absence. (#2)
#
# Requirement: `H-0407` put the state box (journal, ledger, run lock, `HALT`) beside the harness code, so
# the loop's own normal output lands inside the checkout the hygiene gate judges. That gate must therefore
# read the checkout clean while the box is being written, exactly as it does in the product checkout the
# box moved out of (`vicowa-botworks/parental-lockout`, lines 65 to 68 of its own `.gitignore`, #216).
#
# The defect (#2, live on the machine that runs the timer from 26 Nov 20:55Z): the harness `.gitignore`
# was written before the box arrived and still asserted the opposite, so every activation journalled
#   SUPERVISOR-AT 3fafef6 dirty=1378 main=3fafef6 behind=0
#   MAIN-CHECKOUT-REFUSED cause=not-restorable shapes=untracked
#   SUPERVISOR-FF-REFUSED not-this-pass
# over a count that grew 1378 -> 1385 across five passes, because the refusal was being written into the
# directory it was refusing over. The rows standing at 22:02Z were 1376 under `factory/ledger`, 5 under
# `factory/run/stop-window`, 3 under `factory/log`, 1 under `factory/run/claim`, 1 under `factory/run` --
# the box, and nothing else -- and the same read with the four rules supplied through `core.excludesFile`
# answered nothing.
#
# The mechanism: `.gitignore` at the tip ignored only the pre-extraction dot-dirs (`.factory-run/`,
# `.factory-log/`, ...), while `factory/common.sh` resolves `FACTORY_LOG`, `FACTORY_LEDGER`, `FACTORY_RUN`
# and `FACTORY_HALT` under the code tree. The rules and the defaults are two ends of one contract, and
# only one end shipped.
#
# Controls, because every claim here can pass on an empty fixture:
#   - leg 2 asks `common.sh` where the box actually lands, so four strings that merely match today cannot
#     go stale-green when the box moves out from under them;
#   - leg 4 is the precondition of leg 3: the same bytes in the same fixture draw the refusal with the
#     four rules stripped and the clean verdict with them restored, so the rules are the only variable.
#     A host-level `core.excludesFile` that hid the box would pass leg 3 silently -- it cannot pass this
#     one, because its stripped half would read clean too.
#   - both failure legs read the verdict `factory_main_tree_check` journals rather than asking git the
#     stat question: `no stat-question dirt test` refuses `status --porcelain` in any shipped script
#     (#228, it exits 128 printing nothing on a broken exclude file), and the refusal this leg reproduces
#     is that function's own journal line.
#
# Restored, not edited: the strip is applied to the fixture's own copy of the file. The first draft of
# this leg ran `sed -i` over `$HERE/../.gitignore` itself and restored it with `git checkout --`, which is
# a control that destroys the very change it tests whenever the rules are still uncommitted -- measured
# here, because on this branch they are.
#
# The contract this file is written against (see the block above `run_selftest_d_legs` in
# `factory/selftest.sh`): sourced, not executed; the fixture root `$work`, `$HERE`, and `claim_leg` are
# the parent's; assertions go through `claim_leg` and detail to stderr, because `set -e` is on and a bare
# failing command in a sourced file kills the suite.

# Absolute at load, for 457-branch-body-claims' reason: legs `cd` into fixtures, and a relative `$HERE`
# resolved after one would read that fixture's root instead of the harness'.
sbox_root=$(cd -- "$HERE/.." && pwd)
sbox_ignore=$sbox_root/.gitignore
sbox_work=$work/state-box

# Loud skip when the subject is not in this tree, the shape 469-pinned-fetch-retry and
# 476-cgroup-constraints already use: a fixture repository's root is not the harness root, and a leg that
# wrote its own four rules would pass on bytes nothing ships.
if [ ! -f "$sbox_ignore" ]; then
	printf '  SKIP  %-40s %s is not in this tree (the state-box rules belong\n' \
		"002: state box is not dirt" "$sbox_ignore"
	printf '        to the harness checkout, and this suite is running outside one)\n'
	return 0
fi

sbox_say() { printf '            %s\n' "$1" >&2; }

sbox_dump() { # sbox_dump <caption> <text> -- detail lines, one per row, without word-splitting paths
	local caption=$1 body=$2
	printf '            %s\n' "$caption" >&2
	printf '%s\n' "$body" | sed 's/^/              /' >&2
}

sbox_plant() { # sbox_plant <dir> <ignore-file> -- a harness-shaped checkout, one commit, identity set
	mkdir -p "$1" || return 1
	git init -q -b main "$1" || return 1
	git -C "$1" config user.email state-box@example.invalid
	git -C "$1" config user.name 'selftest state-box leg'
	git -C "$1" config commit.gpgsign false
	cp "$2" "$1/.gitignore" || return 1
	git -C "$1" add -A || return 1
	git -C "$1" commit -q -m 'ship the harness .gitignore' || return 1
}

sbox_box() { # sbox_box <dir> -- the four paths a live pass writes, in the shapes it writes them
	mkdir -p "$1/factory/log" "$1/factory/ledger" "$1/factory/run/claim" || return 1
	printf '2026-11-26T21:57:30Z END rc=0 ticks_started=0\n' >"$1/factory/log/supervisor.log" || return 1
	printf '6\n' >"$1/factory/ledger/supervisor.stale-streak" || return 1
	printf 'human:probe held.claim\n' >"$1/factory/run/claim/held.claim" || return 1
	printf 'do not dispatch\n' >"$1/factory/HALT" || return 1
}

# The gate's own verdict, read the way `mtj_exec` reads it: only the lines this call appended, and only
# the classification among them. `factory_main_tree_check` returns 0 on every path by design -- an
# advisory function must never stop the pass that calls it -- so the assertion is about the journal line,
# and rc is asserted separately for the same reason the inline leg asserts it.
sbox_verdict() { # sbox_verdict <tree> -- sets sbox_line and sbox_rc
	local before=0
	[ -f "$FACTORY_LOG/supervisor.log" ] && before=$(wc -l <"$FACTORY_LOG/supervisor.log")
	sbox_rc=0
	factory_main_tree_check "$1" >/dev/null 2>&1 || sbox_rc=$?
	if [ -s "$FACTORY_LOG/supervisor.log" ]; then
		sbox_line=$(tail -n +"$((before + 1))" "$FACTORY_LOG/supervisor.log" |
			{ grep 'MAIN-CHECKOUT' || true; } | tail -n 1)
	else
		sbox_line=''
	fi
}

sbox_no_verdict() {
	sbox_say "the shipped gate journalled no MAIN-CHECKOUT line into $FACTORY_LOG/supervisor.log,"
	sbox_say 'so the fixture above was never classified and this leg proves nothing.'
}

# Leg 1. The rules are in the file the checkout ships, spelled the way the box needs them: a directory
# rule with its trailing slash, and the halt marker as a file. This is the claim that goes red first if
# somebody prunes the block, and the legs below take their fixture from this file, not from a
# transcription of it.
sbox_rules_shipped() {
	local missing='' rule
	for rule in '/factory/log/' '/factory/ledger/' '/factory/run/' '/factory/HALT'; do
		if ! grep -qxF "$rule" "$sbox_ignore"; then
			missing="$missing$rule "
		fi
	done
	if [ -n "$missing" ]; then
		sbox_say "$sbox_ignore does not carry: $missing"
		sbox_say 'the supervisor writes its state box beside this file; without the rules the hygiene'
		sbox_say 'gate calls that box untracked work and refuses its own main checkout (#2).'
		return 1
	fi
}

# Leg 2. The two ends meet: the paths `common.sh` resolves for a reader standing in the TARGET are paths
# the rules cover. Sourced the way `split_state_box_beside_the_code` sources it, with every knob unset, so
# what is read is the shipped default and not this suite's environment. Both plants are real checkouts
# because the split discriminates on git-ness, and because a `$work` under a stray repository would
# otherwise answer with somebody else's tree.
sbox_box_under_the_rules() {
	local code=$sbox_work/code tgt=$sbox_work/target out p rel missing=''
	mkdir -p "$code/factory" "$tgt" || return 1
	git init -q -b main "$code" || return 1
	git -C "$code" config user.email state-box@example.invalid
	cp "$HERE/common.sh" "$code/factory/common.sh" || return 1
	cp "$HERE/escalation-label.sh" "$code/factory/" || return 1
	git init -q -b main "$tgt" || return 1
	git -C "$tgt" config user.email state-box@example.invalid
	if ! out=$(cd -- "$tgt" && env -u FACTORY_DIR -u FACTORY_ROOT -u FACTORY_HARNESS \
		-u FACTORY_TREES -u FACTORY_LOG -u FACTORY_LEDGER -u FACTORY_RUN -u FACTORY_HALT \
		-u FACTORY_AT_RISK \
		bash -c '. "'"$code"'/factory/common.sh" >/dev/null 2>&1 || exit 3
		printf "%s\n" "$FACTORY_LOG" "$FACTORY_LEDGER" "$FACTORY_RUN" "$FACTORY_HALT"'); then
		sbox_say 'sourcing the shipped common.sh from a planted target did not answer'
		sbox_say "got: ${out:-<nothing>}"
		return 1
	fi
	while IFS= read -r p; do
		rel=${p#"$code"/}
		if [ "$rel" = "$p" ]; then
			sbox_say "a default resolved outside the code tree, so this leg cannot judge it: $p"
			return 1
		fi
		# The defaults answer the directory itself (`$code/factory/log`), not a path inside it, so the
		# bare prefix is the case the shipped rules actually have to cover.
		case "$rel" in
		factory/log | factory/log/* | factory/ledger | factory/ledger/* | factory/run | \
			factory/run/* | factory/HALT) : ;;
		*) missing="$missing$rel " ;;
		esac
	done <<<"$out"
	if [ -n "$missing" ]; then
		sbox_say "the box moved where the four rules do not reach: $missing"
		sbox_say 'the rules and the defaults are one contract; move them together (#2).'
		return 1
	fi
}

# Leg 3. The failure, in a fixture, asked of the gate that produced it: the box appears in a checkout
# carrying the shipped rules, and `factory_main_tree_check` -- the read whose refusal is in the live
# journal -- answers `cause=verdict-clean`. The second question is not decoration: a unit's hygiene step
# is `git add -A`, so an ignore shape that hid the box from the verdict while `add` still took it would
# not stop the failure it is filed for.
sbox_state_box_is_not_dirt() {
	local repo=$sbox_work/box dirt
	sbox_plant "$repo" "$sbox_ignore" || {
		sbox_say 'the harness-shaped fixture could not be written'
		return 1
	}
	sbox_box "$repo" || {
		sbox_say 'the state box could not be planted'
		return 1
	}
	# The fixture's own precondition: the bytes are really there, or a clean verdict proves nothing.
	for dirt in factory/log/supervisor.log factory/ledger/supervisor.stale-streak \
		factory/run/claim/held.claim factory/HALT; do
		if [ ! -e "$repo/$dirt" ]; then
			sbox_say "the fixture has no $dirt, so a clean verdict would prove nothing"
			return 1
		fi
	done
	sbox_verdict "$repo"
	case "$sbox_line" in
	*MAIN-CHECKOUT-CLEAN*cause=verdict-clean*) : ;;
	'')
		sbox_no_verdict
		return 1
		;;
	*)
		sbox_say 'the state box the harness holds did not read clean to the gate that refuses a dirty'
		sbox_say 'main checkout. This is the shape the live tree journalled all evening:'
		printf '              %s\n' "$sbox_line" >&2
		return 1
		;;
	esac
	if [ "$sbox_rc" -ne 0 ]; then
		sbox_say "the classification exited $sbox_rc beside a CLEAN line; it must never be able to"
		sbox_say 'stop the pass that calls it'
		return 1
	fi
	if ! git -C "$repo" add -A 2>"$sbox_work/add-err"; then
		sbox_say 'git add -A failed over a tree whose whole content is ignored state:'
		sbox_dump 'stderr' "$(sed -n '1,2p' "$sbox_work/add-err")"
		return 1
	fi
	if git -C "$repo" diff --cached --name-only | grep -qE '^factory/(log|ledger|run|HALT)'; then
		sbox_dump 'git add -A staged state-box files: the verdict hides them, the verb a unit uses does not' \
			"$(git -C "$repo" diff --cached --name-only | sed -n '1,4p')"
		return 1
	fi
}

# Leg 4. The control, on its own fixture: the same bytes and shape with the four rules stripped out of the
# fixture's copy -- the gate refuses, in the live journal's own shape, naming the box; then the shipped
# file restored -- clean. Both halves run against one fixture so the rules are the only variable, and the
# strip is verified to have changed bytes, because a control that mutates nothing passes vacuously and
# this file's own draft history contains that shape.
sbox_stripped_rules_make_dirt() {
	local repo=$sbox_work/stripped stripped=$sbox_work/gitignore-stripped d
	sbox_plant "$repo" "$sbox_ignore" || {
		sbox_say 'the control fixture could not be written'
		return 1
	}
	sbox_box "$repo" || {
		sbox_say 'the control fixture has no state box'
		return 1
	}
	# `%` as the address delimiter, not `|`: GNU sed reads `\|` inside a regex as BRE alternation, so the
	# `|`-delimited form this draft first carried died with `Unmatched ( or \(` before the control had
	# mutated anything -- and a strip step that cannot run is a control that tests nothing.
	sed -E '\%^/factory/(log|ledger|run)/$%d; \%^/factory/HALT$%d' "$sbox_ignore" >"$stripped" || {
		sbox_say 'the strip step could not write its copy'
		return 1
	}
	if grep -qE '^/factory/(log|ledger|run)/$|^/factory/HALT$' "$stripped"; then
		sbox_say 'the strip step left a rule standing, so the control would mutate nothing'
		return 1
	fi
	if cmp -s "$stripped" "$sbox_ignore"; then
		sbox_say 'the stripped copy is byte-identical to the shipped file: nothing was taken away'
		return 1
	fi
	cp "$stripped" "$repo/.gitignore" || {
		sbox_say 'the stripped copy could not be installed in the fixture'
		return 1
	}
	# Committed, so the box is the ONLY dirt the gate can find. Leaving the strip as a working-tree edit
	# made the refusal read `shapes=untracked,modified` and put one of the four paths behind git's own
	# elision (`+1 more, 4 in all`), which is a true answer this leg cannot assert on path by path.
	git -C "$repo" commit -q -am 'strip the four state-box rules' || {
		sbox_say 'the stripped copy could not be committed in the fixture'
		return 1
	}
	sbox_verdict "$repo"
	case "$sbox_line" in
	*MAIN-CHECKOUT-REFUSED*cause=not-restorable*untracked*) : ;;
	'')
		sbox_no_verdict
		return 1
		;;
	*)
		sbox_say 'with the four rules gone the box still did not draw the refusal it draws in the live'
		sbox_say 'tree, so this fixture is not that box -- or a host-level core.excludesFile is'
		sbox_say 'answering for the rules, in which case the leg above passes on this host, not the file:'
		printf '              %s\n' "$sbox_line" >&2
		return 1
		;;
	esac
	# The refusal has to name the box, and account for all four paths: git prints three and elides the
	# rest as `(+N more, M in all)`, so the tally is the claim that the whole box is untracked work and
	# the named rows are the claim that it is THIS dirt being refused and not something else.
	local named=0
	case "$sbox_line" in
	*'4 in all)'*) : ;;
	*)
		sbox_say 'the refusal counts something other than the four planted paths:'
		printf '              %s\n' "$sbox_line" >&2
		return 1
		;;
	esac
	for d in factory/log/ factory/ledger/ factory/run/ factory/HALT; do
		case "$sbox_line" in
		*"$d"*) named=$((named + 1)) ;;
		esac
	done
	if [ "$named" -lt 2 ]; then
		sbox_say "the refusal names only $named of the four paths, so it is not the box it refuses:"
		printf '              %s\n' "$sbox_line" >&2
		return 1
	fi
	cp "$sbox_ignore" "$repo/.gitignore" || {
		sbox_say 'the shipped rules could not be restored in the fixture'
		return 1
	}
	git -C "$repo" commit -q -am 'restore the four state-box rules' || {
		sbox_say 'the shipped rules could not be committed back in the fixture'
		return 1
	}
	sbox_verdict "$repo"
	case "$sbox_line" in
	*MAIN-CHECKOUT-CLEAN*cause=verdict-clean*) : ;;
	*)
		sbox_say 'the box is still refused with the shipped rules restored, so the refusal above was'
		sbox_say 'not caused by them: the fixture and the file disagree about what a rule covers.'
		printf '              %s\n' "$sbox_line" >&2
		return 1
		;;
	esac
}

claim_leg 'the four ignore rules ship in the harness' sbox_rules_shipped
claim_leg 'the box the defaults resolve is under them' sbox_box_under_the_rules
claim_leg 'the state box the harness holds is not dirt' sbox_state_box_is_not_dirt
claim_leg 'control: stripped rules make the box dirt' sbox_stripped_rules_make_dirt
