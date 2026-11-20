# Pending address-taken programs

`scripts/verify-addr-taken-matrix.sh` skips this directory. Each program here
declares the exit its `--opt-level 0` oracle produces, and at least one of
opt1/opt2 disagrees with it today. No program is pending today.

A program found to disagree is added here with its opt0/opt1/opt2 exits; the
fix moves it out of this directory and into `tests/addr-taken-matrix/`, where
the gate then runs it, and removes its entry here in the same change.
