# Pending address-taken programs

`scripts/verify-addr-taken-matrix.sh` skips this directory. Each program here
declares the exit its `--opt-level 0` oracle produces, and at least one of
opt1/opt2 disagrees with it today:

| program | opt0/opt1/opt2 |
| --- | --- |
| `00-load-after-set` | 42/38/38 |
| `101-load-cse-call-between` | 2/6/6 |
| `52-load-cse-cmp` | 40/7/7 |
| `53-load-cse-arith` | 6/2/2 |
| `55-load-cse-struct-holder` | 6/2/2 |
| `56-load-cse-id-fn` | 6/2/2 |
| `57-load-cse-offset-zero` | 6/6/2 |
| `58-load-cse-i32` | 6/2/2 |
| `59-load-cse-u8` | 6/2/2 |
| `60-load-cse-bool` | 40/7/7 |
| `64-load-cse-loop-pair` | 45/42/42 |
| `65-load-cse-nested-block` | 2/6/6 |
| `66-load-cse-two-sets` | 7/2/2 |
| `69-load-cse-index` | 26/22/22 |
| `70-load-cse-bound` | 40/37/37 |
| `78-load-cse-callee-read` | 6/2/2 |
| `80-load-cse-ptr-returned` | 6/2/2 |
| `84-call-arg-ptr-read` | 11/3/3 |
| `8514-fold-load-cse` | 42/38/38 |
| `8514-typed-store-f64` | 42/1/1 |
| `8785-cmp-dup` | 42/42/1 |
| `8785-guard-dedup` | 42/42/2 |
| `8785-gvn-compare` | 42/42/2 |

Shapes:

- `00`, `52-70`, `78`, `80`, `84`, `101`, `8514-*`, `8785-*` forward a load or
  compute a fact from an address-taken local across a `set!` of that local or a
  call that writes through its address.
- `57` folds a pointer displacement from the local reloaded after a store
  through its address (opt2 only).

A fix moves the files it repairs out of this directory and into
`tests/addr-taken-matrix/`, where the gate then runs them; delete the row
above in the same change.
