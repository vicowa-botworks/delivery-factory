# delivery-factory — the delivery harness. There is no application to build
# here; the product of this repository is the factory itself, so `verify` is
# the whole gate. Extracted from parental-lockout at 2adea1bab529 (H-0406);
# the product's build, package and install targets stayed with the product.

.PHONY: verify selftest check-close-verb check-decisions check-shell

.PHONY: verify
verify:
	bash -n factory/*.sh
	python3 scripts/check-close-verb.py --self-test
	python3 scripts/check-decisions.py
	python3 scripts/check-decisions.py --self-test
	python3 scripts/merge-decisions.py --self-test
	bash scripts/check-shell.sh
	bash scripts/check-commit-verbs.sh
	bash factory/selftest.sh

# The pieces individually, for a fast loop before the full gate.
selftest:
	bash factory/selftest.sh

check-close-verb:
	python3 scripts/check-close-verb.py --self-test

check-decisions:
	python3 scripts/check-decisions.py
	python3 scripts/check-decisions.py --self-test
	python3 scripts/merge-decisions.py --self-test

check-shell:
	bash scripts/check-shell.sh
