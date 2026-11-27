# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034,SC2154,SC1090,SC1091,SC2163
# 005-agent-front-door.sh -- `factory/install.sh` is the agent's front door: named checks before
# any write, `install-timer.sh` as the only writer, and a machine-readable envelope (H-0410).
#
# Requirement: an automation must be able to install this harness unattended and branch on the
# result. The front door adds checks and a verdict and NO policy: units are written by
# `install-timer.sh`, and every success claim is read back from systemd and the files afterwards
# -- never from the installer's own last line.
#
# Legs:
#   1. no --target is a refusal at rc 2 with the reason in the envelope, not an install of nothing;
#   2. `gh` that is present but unauthenticated stops the sequence BEFORE any handoff, and no
#      unit file appears;
#   3. a healthy dry run ends ok:true, writes no unit files, and carries the named checks;
#   4. both reviewer knobs empty is a refusal (H-0116's rule, enforced at install time);
#   5. an install through the fake systemctl writes the pair, pins the target and the reviewer
#      into the unit, enables the timer, and the self-verify reads all of it back;
#   6. --verify on a name with no files fails on unit-files, not on vibes;
#   7. a harness tree its trunk has moved past is warned about BEFORE install-timer refuses, and
#      the refusal lands in the envelope as install-timer:fail, rc 1 (#249's rule, front-displayed).
#
# The fake `gh` here is strict for every verb the FRONT DOOR asserts on (auth status, repo view,
# the two api probes) and deliberately soft for the incidental calls `install-timer.sh` makes
# while rendering units -- those verbs belong to install-timer's own legs, and a shim that
# shrugs is wrong exactly where a leg asserts. The fake `systemctl --user` is a state machine
# over files: enablement is a file, `cat` prints the unit file that was actually written, and
# `list-timers` answers an elapse only when enabled -- so claim 5 cannot pass on an install that
# wrote files but never armed the timer.

h5_root=$(cd -- "$HERE/.." && pwd)
h5_work=$work/agent-front-door
h5_bin=$h5_work/bin
h5_harness=$h5_work/harness
h5_target=$h5_work/target
h5_units=$h5_work/units

h5_say() { printf '            %s\n' "$1" >&2; }

mkdir -p "$h5_bin" "$h5_units" "$h5_work/log" "$h5_work/run" "$h5_work/ledger"

# ---- fake gh: strict on the front door's verbs, soft on the installer's incidental ones ----
cat >"$h5_bin/gh" <<'H5GH'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"$H5_GH_LOG"
case "$1" in
--version) printf 'gh version fixture\n'; exit 0 ;;
auth)
	[ "${H5_AUTH:-0}" = 1 ] && { printf 'gh: not logged in\n' >&2; exit 1; }
	exit 0 ;;
repo)
	[ "${H5_REPO:-0}" = 1 ] && { printf 'gh: could not read that repository\n' >&2; exit 1; }
	exit 0 ;;
api)
	# orgs/<o>/teams/<t> and users/<u>: reviewer probes. H5_TEAM=1 answers "not found".
	[ "${H5_TEAM:-0}" = 1 ] && { printf 'gh: HTTP 404\n' >&2; exit 1; }
	printf '{}\n'
	exit 0 ;;
*)
	# Incidental surface: install-timer's unit rendering may ask gh things. Answering softly is
	# honest HERE because no claim in this leg asserts on these calls; the shim still LOGS them.
	printf '[]\n'
	exit 0 ;;
esac
H5GH
chmod +x "$h5_bin/gh"

# ---- fake systemctl --user: a state machine over files, not a shrug ----
cat >"$h5_bin/systemctl" <<'H5SC'
#!/usr/bin/env bash
printf '%s\n' "systemctl $*" >>"$H5_SC_LOG"
[ "${1-}" = "--user" ] && shift || {
	printf 'fixture systemctl: only --user is modelled, got: %s\n' "$*" >&2
	exit 1
}
cmd=${1-}
shift || true
case "$cmd" in
is-system-running) printf 'running\n'; exit 0 ;;
daemon-reload | reset-failed) exit 0 ;;
enable)
	for a in "$@"; do
		case "$a" in *.timer) printf 'enabled\n' >"$H5_SYSCTL/$(basename "$a").enable" ;; esac
	done
	exit 0 ;;
disable)
	for a in "$@"; do
		case "$a" in *.timer) printf 'disabled\n' >"$H5_SYSCTL/$(basename "$a").enable" ;; esac
	done
	exit 0 ;;
start | restart | stop) exit 0 ;;
is-active)
	[ -f "$H5_SYSCTL/${1}.enable" ] && printf 'active\n' || printf 'inactive\n'
	exit 0 ;;
cat)
	f="$H5_UNITS_DIR/$1"
	[ -f "$f" ] && cat "$f" || {
		printf 'No unit %s.\n' "$1" >&2
		exit 1
	}
	exit 0 ;;
list-unit-files)
	# The pattern is the trailing NON-flag argument (`--no-legend --no-pager NAME.timer`);
	# treating $1 as the pattern makes the shim answer "no such unit" for units that exist --
	# a fixture lie that reads as a real enablement failure.
	pat=
	for h5a in "$@"; do
		case "$h5a" in
		-*) ;;
		*) pat=$h5a ;;
		esac
	done
	[ -n "$pat" ] || pat='*'
	shopt -s nullglob
	for f in "$H5_UNITS_DIR"/$pat; do
		[ -e "$f" ] || continue
		b=$(basename "$f")
		st=disabled
		[ -f "$H5_SYSCTL/$b.enable" ] && st=$(cat "$H5_SYSCTL/$b.enable")
		printf '%s %s static\n' "$b" "$st"
	done
	exit 0 ;;
list-timers)
	t=
	for h5a in "$@"; do
		case "$h5a" in
		-*) ;;
		*) t=$h5a ;;
		esac
	done
	printf 'NEXT LEFT LAST PASSED UNIT ACTIVATES\n'
	if [ -f "$H5_SYSCTL/$t.enable" ]; then
		printf 'Fri 2026-11-27 00:00:00 UTC 9min left n/a n/a %s %s.service\n' "$t" "${t%.timer}"
	fi
	exit 0 ;;
show)
	printf 'ActiveState=active\n'
	exit 0 ;;
*)
	printf 'fixture systemctl: unhandled verb: %s\n' "$cmd" >&2
	exit 9 ;;
esac
H5SC
chmod +x "$h5_bin/systemctl"

cat >"$h5_bin/loginctl" <<'H5LC'
#!/usr/bin/env bash
# `--value` prints the bare value; without it, the property line. The caller passes --value;
# echoing the pair anyway reads as "linger is not yes" and silently degrades a pass to a warn.
for a in "$@"; do
	[ "$a" = "--value" ] && { printf '%s\n' "${H5_LINGER:-no}"; exit 0; }
done
printf 'Linger=%s\n' "${H5_LINGER:-no}"
H5LC
chmod +x "$h5_bin/loginctl"

# ---- fixture trees ----
# The harness tree holds a COPY of the four shipped scripts it needs (the front door, the only
# writer, the rulebook, and the entry point install-timer insists on), on its own origin, at its
# trunk. A copy, not a symlink: install-timer's #249 check positions `$FACTORY_HARNESS` against
# its origin, and the real worktree is dirty and branch-ahead by construction mid-suite.
h5_up=$h5_work/harness-upstream
# The identity scan (leg 000) reads every file under selftest.d/ and reddens ANY repository
# creation without an identity within 3 lines -- including this bare upstream, which commits
# nothing: the rule is textual on purpose, so the bare repo carries the line too.
git init -q --bare -b main "$h5_up"
git -C "$h5_up" config user.email upstream@example.invalid
git init -q -b main "$h5_harness"
git -C "$h5_harness" config user.email front-door@example.invalid
mkdir -p "$h5_harness/factory"
cp "$h5_root/factory/common.sh" "$h5_root/factory/install.sh" "$h5_root/factory/install-timer.sh" \
	"$h5_root/factory/factory.sh" "$h5_harness/factory/"
chmod +x "$h5_harness/factory/"*.sh
printf 'fixture harness\n' >"$h5_harness/README"
git -C "$h5_harness" add -A
git -C "$h5_harness" commit -q -m 'fixture: harness at trunk'
git -C "$h5_harness" remote add origin "$h5_up"
git -C "$h5_harness" push -q -u origin main

git init -q -b main "$h5_target"
git -C "$h5_target" config user.email target@example.invalid
git -C "$h5_target" remote add origin https://example.invalid/newcomer/newproject.git

h5_run() { # h5_run <stdout-file> <stderr-file> [VAR=VAL ...] [install.sh args ...] -> rc
	# Assignments and flags both arrive in "$@": anything shaped like NAME=value becomes an
	# environment override for the child (and wins over the fixture defaults, because env
	# applies last-wins), everything else is an argument. `env A=1 B=2 prog args` is the only
	# position where bash reads assignments -- prefixing them to "$@" verbatim would hand
	# `--json` to env as the program name.
	local out=$1 err=$2
	shift 2
	local envs=() args=() a
	for a in "$@"; do
		case "$a" in
		[A-Za-z_]*=*) envs+=("$a") ;;
		*) args+=("$a") ;;
		esac
	done
	set +e
	env PATH="$h5_bin:$PATH" HOME="$HOME" \
		H5_GH_LOG="$h5_work/gh.log" H5_SC_LOG="$h5_work/sysctl.log" \
		H5_SYSCTL="$h5_work/sysd" H5_UNITS_DIR="$h5_units" \
		FACTORY_UNITS_DIR="$h5_units" FACTORY_LOG="$h5_work/log" FACTORY_RUN="$h5_work/run" \
		FACTORY_LEDGER="$h5_work/ledger" FACTORY_ROOT="$h5_target" \
		"${envs[@]}" "$h5_harness/factory/install.sh" "${args[@]}" >"$out" 2>"$err"
	local rc=$?
	set -e
	return $rc
}
mkdir -p "$h5_work/sysd"
h5_reset() { rm -rf "$h5_work/units" "$h5_work/sysd" "$h5_work/gh.log" "$h5_work/sysctl.log" "$h5_work/log";
	mkdir -p "$h5_work/units" "$h5_work/sysd" "$h5_work/log"; : >"$h5_work/gh.log"; : >"$h5_work/sysctl.log"; }
# units_empty: the strongest negative claim available -- nothing was handed to the writer.
h5_units_empty() {
	local n
	n=$(find "$h5_units" -maxdepth 1 -name '*-factory.*' | grep -c . || true)
	[ "$n" = "0" ] || { h5_say "expected no unit files, found $n:"; find "$h5_units" -maxdepth 1 | sed 's/^/              /' >&2; return 1; }
}
h5_json_has() { # <envelope-file> <jq> <label> -- and its failure is the CLAIM's failure:
	# an assertion that only prints while the function returns the NEXT command's status is a
	# check that passes because the command after it was innocent.
	jq -e "$2" "$1" >/dev/null 2>&1 && return 0
	h5_say "envelope failed: $2 ($3)"
	sed 's/^/              /' "$1" >&2
	return 1
}

# 1. install with no target: refusal, reason in the envelope, no handoff.
h5_no_target() {
	h5_reset
	local rc=0
	h5_run "$h5_work/out" "$h5_work/err" --json || rc=$?
	[ "$rc" = 2 ] || { h5_say "no-target rc=$rc, want 2"; return 1; }
	h5_json_has "$h5_work/out" '.ok == false' 'ok' || return 1
	h5_json_has "$h5_work/out" '.reason | contains("--target")' 'reason names --target' || return 1
	h5_units_empty
	if grep -q 'install-timer.sh' "$h5_work/sysctl.log"; then
		h5_say 'systemd was touched before the target check'
		return 1
	fi
}
claim_leg "005: no target is a refusal with the reason in the envelope" h5_no_target

# 2. gh present, not authenticated: the sequence stops before the handoff.
h5_no_auth() {
	h5_reset
	local rc=0
	h5_run "$h5_work/out" "$h5_work/err" --json --target "$h5_target" H5_AUTH=1 || rc=$?
	[ "$rc" = 1 ] || { h5_say "no-auth rc=$rc, want 1"; return 1; }
	h5_json_has "$h5_work/out" '.checks["gh-auth"] == "fail"' 'gh-auth failed' || return 1
	h5_json_has "$h5_work/out" '.reason | contains("auth")' 'reason names auth' || return 1
	h5_json_has "$h5_work/out" '(.checks | has("install-timer") | not)' 'install-timer was never reached' || return 1
	h5_units_empty
}
claim_leg "005: an unauthenticated gh stops before the handoff" h5_no_auth

# 3. a healthy dry run: ok, named checks, no files.
h5_dry_run() {
	h5_reset
	local rc=0
	h5_run "$h5_work/out" "$h5_work/err" --json --target "$h5_target" \
		--reviewer-team keepers --dry-run || rc=$?
	[ "$rc" = 0 ] || { h5_say "dry-run rc=$rc, want 0:"; sed 's/^/              /' "$h5_work/err" >&2; return 1; }
	h5_json_has "$h5_work/out" '.ok == true' 'ok' || return 1
	h5_json_has "$h5_work/out" '.checks["target-repo"] == "pass"' 'target named' || return 1
	h5_json_has "$h5_work/out" '.checks["repo-access"] == "pass"' 'repo readable' || return 1
	h5_json_has "$h5_work/out" '.checks["harness-current"] == "pass"' 'harness at trunk' || return 1
	h5_json_has "$h5_work/out" '.checks["install-timer"] == "pass"' 'dry handoff done' || return 1
	grep -q 'DRY-RUN' "$h5_work/err" || { h5_say 'install-timer did not run in dry mode'; return 1; }
	h5_units_empty
}
claim_leg "005: a healthy dry run says ok and writes nothing" h5_dry_run

# 4. both reviewer knobs empty: refused at install, per H-0116's rule.
h5_no_reviewer() {
	h5_reset
	local rc=0
	h5_run "$h5_work/out" "$h5_work/err" --json --target "$h5_target" \
		--reviewer-team '' --reviewer '' || rc=$?
	[ "$rc" = 1 ] || { h5_say "no-reviewer rc=$rc, want 1"; return 1; }
	h5_json_has "$h5_work/out" '.checks["reviewer-targets"] == "fail"' 'reviewer-targets failed' || return 1
	h5_units_empty
}
claim_leg "005: nobody to ask is a refusal, not a silent default" h5_no_reviewer

# 5. the install: files written, target and reviewer pinned, timer enabled, read back.
h5_install() {
	h5_reset
	local rc=0 unit
	h5_run "$h5_work/out" "$h5_work/err" --json --target "$h5_target" \
		--reviewer-team keepers --reviewer keeper --interval 15m H5_LINGER=yes || rc=$?
	[ "$rc" = 0 ] || { h5_say "install rc=$rc, want 0:"; sed 's/^/              /' "$h5_work/err" >&2; return 1; }
	h5_json_has "$h5_work/out" '.ok == true' 'ok' || return 1
	h5_json_has "$h5_work/out" '.checks["linger"] == "pass"' 'linger read from the machine' || return 1
	h5_json_has "$h5_work/out" '.checks["verify"] == "pass"' 'self-verify passed' || return 1
	# The elapse is armed inside the nested --verify (the outer envelope carries `verify`, not
	# its internals), so the direct read is the verify pass line in the captured prose -- and
	# the enable-file assertion below is the machine-state proof underneath it.
	grep -q '\[pass\] timer-scheduled' "$h5_work/err" || {
		h5_say 'the self-verify never reported an armed elapse'
		return 1
	}
	unit=$h5_units/newproject-factory.service
	[ -f "$unit" ] || { h5_say "no $unit"; return 1; }
	[ -f "$h5_units/newproject-factory.timer" ] || { h5_say 'no timer file'; return 1; }
	grep -q "^Environment=FACTORY_ROOT=$h5_target\$" "$unit" || {
		h5_say 'the unit does not pin the target it was given'
		grep '^Environment=' "$unit" | sed 's/^/              /' >&2
		return 1
	}
	grep -q '^Environment=FACTORY_REVIEWER_TEAM=keepers$' "$unit" || { h5_say 'the team did not reach the unit'; return 1; }
	grep -q '^Environment=FACTORY_REVIEWER=keeper$' "$unit" || { h5_say 'the reviewer did not reach the unit'; return 1; }
	grep -q '15m' "$h5_units/newproject-factory.timer" || { h5_say 'the interval did not reach the timer'; return 1; }
	[ "$(cat "$h5_work/sysd/newproject-factory.timer.enable" 2>/dev/null)" = enabled ] || {
		h5_say 'the timer was never enabled on (fake) systemd'
		return 1
	}
}
claim_leg "005: install writes, pins, enables -- and reads it all back" h5_install

# 6. --verify on a name with nothing behind it.
h5_verify_missing() {
	h5_reset
	local rc=0
	h5_run "$h5_work/out" "$h5_work/err" --json --verify --name ghost-factory || rc=$?
	[ "$rc" = 1 ] || { h5_say "verify-missing rc=$rc, want 1"; return 1; }
	h5_json_has "$h5_work/out" '.checks["unit-files"] == "fail"' 'unit-files failed' || return 1
	h5_json_has "$h5_work/out" '.checks["timer-scheduled"] == "fail"' 'nothing armed' || return 1
}
claim_leg "005: verify fails loudly when the machine holds nothing" h5_verify_missing

# 7. the trunk moved past the harness tree: the front door warns first, install-timer refuses,
#    and the refusal is what the envelope carries (#249's rule, front-displayed for agents).
h5_stale_harness_refusal() {
	h5_reset
	local ahead=$h5_work/ahead rc=0
	git clone -q "$h5_up" "$ahead"
	git -C "$ahead" config user.email ahead@example.invalid
	printf 'a commit the installed tree has not taken\n' >"$ahead/new.md"
	git -C "$ahead" add -A
	git -C "$ahead" commit -q -m 'fixture: trunk moves'
	git -C "$ahead" push -q origin main
	git -C "$h5_harness" fetch -q origin
	h5_run "$h5_work/out" "$h5_work/err" --json --target "$h5_target" --reviewer-team keepers || rc=$?
	[ "$rc" = 1 ] || { h5_say "stale-harness rc=$rc, want 1:"; sed 's/^/              /' "$h5_work/err" >&2; return 1; }
	h5_json_has "$h5_work/out" '.checks["harness-current"] == "warn"' 'warned before the refusal' || return 1
	h5_json_has "$h5_work/out" '.checks["install-timer"] == "fail"' 'the writer refused' || return 1
	grep -qi '1 commit' "$h5_work/err" || { h5_say 'the warning did not name the count'; return 1; }
	h5_units_empty
	git -C "$h5_harness" merge -q --ff-only origin/main
}
claim_leg "005: a trunk the tree has not taken is warned, then refused" h5_stale_harness_refusal
