;; The optimizer's dense copy environment retains immutable snapshots until
;; an explicit truncate declares every longer snapshot of that lineage dead.
(import compiler_optimize as opt)
(import compiler_ir_types as ir)
(import compiler_owned_view as owned_view)
(import stdlib.test)

(define (copy-test-push [s : opt.OptCopyEnv] [value : i64]) : opt.OptCopyEnv
  (opt.opt-copy-env-push s (opt.OptCopyEntry.Copy value (I64 value))))

(define (copy-test-view [s : (& s opt.OptCopyEnv)]) : opt.OptCopyEnv
  (owned_view.compiler-owned-reference-shared-view s))

(define (copy-test-prefix [s : (& s opt.OptCopyEnv)] [count : i64]) : opt.OptCopyEnv
  (let
    [out (copy-test-view s)]
    (set!
      out.len
      (if (< count 0)
        0
        (if (> count s.len)
          s.len
          count)))
    out))

(define (copy-test-at [s : (& s opt.OptCopyEnv)] [index : i64]) : i64
  (match (& (array-ref s.slots index))
    [(Copy id _) (deref id)]
    [_ -999]))

(define (copy-test-digits [s : (& s opt.OptCopyEnv)]) : i64
  (let
    [index : i64 0]
    [out : i64 0]
    (while (< index s.len)
      (set! out (+ (* out 10) (copy-test-at s index)))
      (set! index (+ index 1)))
    out))

(define (copy-test-lookup [s : (& s opt.OptCopyEnv)] [key : i64]) : i64
  (match (opt.opt-copy-lookup s key)
    [(Some value)
      (match value
        [(I64 n) n]
        [(Var n) n]
        [_ -999])]
    [(No) -999]))

(test
  copy-stack-snapshots-keep-their-entries
  (let
    [base (copy-test-push (copy-test-push (opt.opt-copy-env-empty) 1) 2)]
    [a (copy-test-push (copy-test-view (& base)) 3)]
    [b (copy-test-push (copy-test-view (& base)) 4)]
    [prefix (copy-test-prefix (& a) 1)]
    [c (copy-test-push prefix 9)]
    (test.assert-i64-eq (copy-test-digits (& base)) 12 "base")
    (test.assert-i64-eq (copy-test-digits (& a)) 123 "in-place push")
    (test.assert-i64-eq (copy-test-digits (& b)) 124 "forked push")
    (test.assert-i64-eq (copy-test-digits (& c)) 19 "prefix push")
    (test.assert-i64-eq (copy-test-digits (& a)) 123 "retained newer snapshot")))

(test
  copy-stack-truncate-reuses-dead-slots
  (let
    [base (copy-test-push (opt.opt-copy-env-with-capacity 8) 1)]
    [child (copy-test-push (copy-test-view (& base)) 2)]
    (test.assert-i64-eq
      (copy-test-digits (& child))
      12
      "child before scope exit")
    (let
      [back (opt.opt-copy-env-truncate child 1)]
      [sibling (copy-test-push (copy-test-view (& back)) 3)]
      (test.assert-i64-eq (copy-test-digits (& back)) 1 "truncated")
      (test.assert-i64-eq (copy-test-digits (& sibling)) 13 "sibling")
      (test.assert-i64-eq (array-length sibling.slots) 8 "capacity reused")
      (test.assert-true
        (unsafe
          (=
            (ptr->int (__tl_array-data base.slots))
            (ptr->int (__tl_array-data sibling.slots))))
        "backing storage reused"))))

(test
  copy-stack-zeroed-snapshot-is-empty
  (let
    [cells (__tl_make-array opt.OptCopyEnv 1)]
    [zeroed (copy-test-view (& (array-ref cells 0)))]
    [one (copy-test-push (copy-test-view (& zeroed)) 7)]
    (test.assert-true (opt.opt-copy-env-empty? (& zeroed)) "zeroed is empty")
    (test.assert-i64-eq (copy-test-digits (& one)) 7 "push onto null top")))

(test
  copy-stack-truncate-clamps-marks
  (let
    [s (copy-test-push (opt.opt-copy-env-with-capacity 0) 7)]
    (set! s (opt.opt-copy-env-truncate s 99))
    (test.assert-i64-eq (copy-test-digits (& s)) 7 "oversized mark")
    (set! s (opt.opt-copy-env-truncate s -1))
    (test.assert-true (opt.opt-copy-env-empty? (& s)) "negative mark")
    (set! s (copy-test-push s 8))
    (test.assert-i64-eq (copy-test-digits (& s)) 8 "reuse after clear")))

(test
  copy-stack-invalidation-keeps-retained-snapshots
  (let
    [env
      (opt.opt-copy-env-push
        (opt.opt-copy-env-push
          (opt.opt-copy-env-empty)
          (opt.OptCopyEntry.Copy 1 (I64 11)))
        (opt.OptCopyEntry.Copy 2 (Var 65)))]
    [removed (opt.opt-copy-invalidate-var (copy-test-view (& env)) 65)]
    [unchanged (opt.opt-copy-invalidate-var (copy-test-view (& env)) 99)]
    (test.assert-i64-eq (copy-test-lookup (& env) 2) 65 "original source")
    (test.assert-i64-eq
      (copy-test-lookup (& removed) 2)
      -999
      "source invalidated")
    (test.assert-i64-eq
      (copy-test-lookup (& removed) 1)
      11
      "other fact retained")
    (test.assert-i64-eq
      (copy-test-lookup (& unchanged) 2)
      65
      "absent definition")
    (test.assert-i64-eq
      (copy-test-lookup (& env) 1)
      11
      "original snapshot retained")))

(test
  copy-stack-growth-and-negative-global-keys
  (let
    [env (opt.opt-copy-env-empty)]
    [index : i64 0]
    (while (< index 17)
      (set! env (copy-test-push env index))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index 17)
      (test.assert-i64-eq
        (copy-test-at (& env) index)
        index
        "growth keeps every entry")
      (set! index (+ index 1)))
    (set! env (opt.opt-copy-env-push env (opt.OptCopyEntry.Copy -1 (I64 42))))
    (set! env (opt.opt-copy-env-push env (opt.OptCopyEntry.Copy -65 (I64 99))))
    (set! env (opt.opt-copy-invalidate-var env -1))
    (test.assert-i64-eq
      (copy-test-lookup (& env) -1)
      -999
      "negative key removed")
    (test.assert-i64-eq
      (copy-test-lookup (& env) -65)
      99
      "other negative key retained")))

(define (copy-test-wide-entry
  [s : (& s opt.OptCopyEnv)]
  [index : i64]
  [group : i64]
  [word : i64]
  [text : (& text str)]) : unit
  (match (& (array-ref s.slots index))
    [(PackWord g w value)
      (test.assert-i64-eq (deref g) group "wide group")
      (test.assert-i64-eq (deref w) word "wide index")
      (match value
        [(String actual) (test.assert-string-eq actual text "wide descriptor")]
        [_ (test.assert-true false "expected string descriptor")])]
    [_ (test.assert-true false "expected pack-word entry")]))

(test
  copy-stack-wide-entries-survive-growth-and-forks
  (let
    [s (opt.opt-copy-env-empty)]
    [index : i64 0]
    (while (< index 9)
      (set!
        s
        (opt.opt-copy-env-push
          s
          (opt.OptCopyEntry.PackWord index (+ index 1) (String "arena"))))
      (set! index (+ index 1)))
    (let
      [fork
        (opt.opt-copy-env-push
          (copy-test-prefix (& s) 2)
          (opt.OptCopyEntry.PackWord 90 91 (String "fork")))]
      (test.assert-i64-eq s.len 9 "original length")
      (test.assert-i64-eq fork.len 3 "fork length")
      (copy-test-wide-entry (& s) 8 8 9 "arena")
      (copy-test-wide-entry (& fork) 0 0 1 "arena")
      (copy-test-wide-entry (& fork) 2 90 91 "fork"))))