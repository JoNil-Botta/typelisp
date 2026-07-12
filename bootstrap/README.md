# Bootstrap compatibility prelude

`bootstrap/stdlib/core_macros.tl` is a frozen legacy prelude used only when a
published seed cannot evaluate the current CTFE macro builders, including
CTFE `while` and generic sequence folds. `scripts/lib-bootstrap-ctfe.sh`
probes those capabilities, runs the seed from a scratch directory so this
prelude takes precedence, and uses it only for seed-to-stage1 compilation.

Normal compilers always use `stdlib/core_macros.tl`; do not add ordinary source
or package dependencies on this directory.
