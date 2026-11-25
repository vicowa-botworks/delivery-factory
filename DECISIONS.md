# Decision log — delivery-factory, repository scope (`D-` ids)

Harness-mechanics decisions live in `factory/DECISIONS.md` and `factory/DECISIONS/` under `H-`
ids; this log holds `D-` ids for decisions about the repository itself — what it is, what it
contains, where its boundaries are. The split is the one the parent repository
(`vicowa-botworks/parental-lockout`) enforced when the harness lived inside it, kept unchanged so
every carried entry keeps an id that is already published.

## D-0001 · Which decision log governs a decision in the extracted harness repository?

- Question: the extraction of `factory/` out of `vicowa-botworks/parental-lockout` (H-0406) made
  the harness its own repository, and the parent's split — root `DECISIONS.md` for product
  decisions, `factory/DECISIONS.md` for harness decisions — arrives here with no product left to
  own the root half. A new decision has no rule naming which log it belongs to, and an entry in
  the wrong log is invisible to the allocator that guards the other one.
- Options: fold everything into `factory/DECISIONS.md` (one log; repository-level decisions have
  no home and the pair's continuation rule loses its second file) | start the root log with `D-`
  ids for repository-scope decisions and leave `H-` ids to harness mechanics | renumber the
  harness log into `D-` ids (published ids are immutable; refused on sight).
- Chose: start the root log with `D-` ids for repository-scope decisions and leave `H-` ids to harness mechanics
- Why: `check-decisions.py` already enforces the `D`/`H` id split across the pair and
  `factory/next-decision-id.sh` allocates each log's next id independently, so the split needs no
  new machinery and every carried entry keeps its published id; `D-` ids stayed unused by the
  harness for the whole parent history, so this log starts clean and cannot collide.
- Checkpoint: 2033ff1
