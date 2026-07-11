# Bootstrap compatibility prelude

`bootstrap/stdlib/core_macros.tl` is a frozen legacy prelude used only when a
published seed cannot evaluate CTFE `while`. `scripts/lib-bootstrap-ctfe.sh`
probes that capability, runs the seed from a scratch directory so this prelude
takes precedence, and uses it only for seed-to-stage1 compilation.

Normal compilers always use `stdlib/core_macros.tl`; do not add ordinary source
or package dependencies on this directory.
