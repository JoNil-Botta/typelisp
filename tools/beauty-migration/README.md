# Beauty-effort migration tools (preserved, not maintained)

The scripts the beauty effort's agents used to remove `*-shared-view` uses and the
`-seq-ref` residue. They are kept on this branch so the p1 follow-up issues can point to
them. They are research scripts: they assume the agent worktree layout (`target/exp/...`)
and a built compiler, and some hard-code local paths. Read a script before running it.
Every compiler run they start should go under `scripts/run-memory-bounded.sh`.

## views-zero/ (read-only parameter flip and match borrows, waves W1/W2)

- `census.py`, `census_lib.py`: classify each view use by what the copy feeds (an argument to a
  user function, an argument to a macro or builtin, let, match, store, return, borrow).
  `census-aec7e7321.out` is the table for main `aec7e7321`.
- `readonly.py`: by-value parameters that are read-only, as a greatest fixed point over the call
  graph, plus the flip yield against the census sites.
- `convCallee2.py`, `consLoop2.py`, `siteLoop.py`, `w1*.py`, `w1loop.sh`: apply the flips or deletions,
  typecheck, and revert per function on errors (`siteLoop.py` also has a match-borrow mode).
- `copytypes.py`: which types are Copy (a fixed point over the struct and enum definitions), used for W1.
- `tempargs.py`: call sites that need a `(& (expr))` wrapper after a flip.
- Guards, run before gating a flip PR:
  - `tcoguard.py`, `selftail.py`: no tail jump lost (#9044, #9137, #9183).
  - `nestedpat.py`: no borrowed match with a nested variant pattern (#8905).
  - `stalerb.py` / `reborrow.py`: no redundant `(& r)` of a value that is already a reference (#9137).
- `cgdiff.py`, `cgtop.py`: compare cachegrind function profiles.
- `overlap*.sh`, `fnoverlap.py`, `conflictlines.py`: check a branch against open PRs.

## views-residue/ (typecheck move pass and consumer flips, B7a/B7b)

- An s-expression reader plus move-pass and consumer-flip scripts used for #9131 and #9155.

## seqref/ (`compiler_optimize.tl` `-seq-ref` flip and revert, batches 3 and 4)

- `candidates.py`, `callers.py` and the flip and revert loop used for #9129 and #9141.
- `asm*.sh`, `cg*.sh`: asm identity and cachegrind helpers.

Results and the plans built on them are recorded in the p1 issues that link here.
