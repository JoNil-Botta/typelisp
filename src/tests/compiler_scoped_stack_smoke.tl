;; compiler_scoped_stack_smoke.tl - The scoped-stack generator's snapshot,
;; copy-on-write and truncation rules, on a family of i64 entries.
(import stdlib.test)
(import compiler_scoped_stack as scoped_stack)

(defstruct ScopedStackTestStack
  (slots (__tl_dyn-array i64))
  (len i64)
  (top (__tl_dyn-array i64)))

(scoped_stack.compiler-scoped-stack-operations
  i64
  ScopedStackTestStack
  scoped-stack-test
  empty
  with-capacity
  len
  empty?
  last
  last-ref
  prefix
  push
  mark
  truncate
  release)

;; The entries oldest first as one number, a decimal digit each.
(define (scoped-stack-test-digits [s : (& s ScopedStackTestStack)]) : i64
  (let
    [index : i64 0]
    [out : i64 0]
    (begin
      (while (< index s.len)
        (begin
          (set! out (+ (* out 10) (array-ref s.slots index)))
          (set! index (+ index 1))))
      out)))

(define (scoped-stack-test-view [s : (& s ScopedStackTestStack)]) : ScopedStackTestStack
  (scoped-stack-test-prefix s s.len))

(test
  scoped-stack-snapshots-keep-their-entries
  (let
    [base : ScopedStackTestStack
      (scoped-stack-test-push
        (scoped-stack-test-push (scoped-stack-test-empty) 1)
        2)]
    ;; base is its lineage's top: this push lands in place
    [a : ScopedStackTestStack
      (scoped-stack-test-push (scoped-stack-test-view (& base)) 3)]
    ;; base is no longer the top: this push copies
    [b : ScopedStackTestStack
      (scoped-stack-test-push (scoped-stack-test-view (& base)) 4)]
    [rest : ScopedStackTestStack (scoped-stack-test-prefix (& a) 1)]
    [c : ScopedStackTestStack
      (scoped-stack-test-push (scoped-stack-test-view (& rest)) 9)]
    (begin
      (test.assert-i64-eq (scoped-stack-test-digits (& base)) 12 "base")
      (test.assert-i64-eq (scoped-stack-test-digits (& a)) 123 "in-place push")
      (test.assert-i64-eq (scoped-stack-test-digits (& b)) 124 "copied push")
      (test.assert-i64-eq (scoped-stack-test-digits (& rest)) 1 "prefix")
      (test.assert-i64-eq
        (scoped-stack-test-digits (& c))
        19
        "push onto a prefix")
      (test.assert-i64-eq (scoped-stack-test-digits (& a)) 123 "a after c")
      (test.assert-i64-eq (scoped-stack-test-last (& a)) 3 "last"))))

(test
  scoped-stack-truncate-reuses-dead-slots
  (let
    [base : ScopedStackTestStack
      (scoped-stack-test-push (scoped-stack-test-with-capacity 8) 1)]
    [mark : i64 (scoped-stack-test-mark (& base))]
    [child : ScopedStackTestStack
      (scoped-stack-test-push (scoped-stack-test-view (& base)) 2)]
    [_child-digits : unit
      (test.assert-i64-eq (scoped-stack-test-digits (& child)) 12 "child")]
    ;; the child's scope ends: its slots are free again
    [back : ScopedStackTestStack (scoped-stack-test-truncate child mark)]
    [sibling : ScopedStackTestStack
      (scoped-stack-test-push (scoped-stack-test-view (& back)) 3)]
    (begin
      (test.assert-i64-eq (scoped-stack-test-digits (& back)) 1 "truncated")
      (test.assert-i64-eq (scoped-stack-test-digits (& sibling)) 13 "sibling")
      (test.assert-true
        (= (array-length sibling.slots) 8)
        "the sibling reused the lineage instead of copying"))))

(test
  scoped-stack-zeroed-snapshot-is-empty
  (let
    [cells : (__tl_dyn-array ScopedStackTestStack)
      (__tl_make-array ScopedStackTestStack 1)]
    [zeroed : ScopedStackTestStack
      (scoped-stack-test-prefix (& (array-ref cells 0)) 0)]
    [one : ScopedStackTestStack
      (scoped-stack-test-push (scoped-stack-test-view (& zeroed)) 7)]
    (begin
      (test.assert-true (scoped-stack-test-empty? (& zeroed)) "zeroed is empty")
      (test.assert-i64-eq
        (scoped-stack-test-digits (& one))
        7
        "push onto zeroed"))))

(test
  scoped-stack-prefix-and-truncate-clamp-marks
  (let
    [s (scoped-stack-test-push (scoped-stack-test-with-capacity 0) 7)]
    [below (scoped-stack-test-prefix (& s) -1)]
    [above (scoped-stack-test-prefix (& s) 99)]
    (test.assert-i64-eq (scoped-stack-test-len (& below)) 0 "negative prefix")
    (test.assert-i64-eq (scoped-stack-test-len (& above)) 1 "oversized prefix")
    (test.assert-i64-eq
      (deref (scoped-stack-test-last-ref (& above)))
      7
      "borrowed last")
    (set! s (scoped-stack-test-truncate s 99))
    (test.assert-i64-eq (scoped-stack-test-len (& s)) 1 "oversized truncate")
    (set! s (scoped-stack-test-truncate s -1))
    (test.assert-true (scoped-stack-test-empty? (& s)) "negative truncate")))

(test
  scoped-stack-release-guards-and-reuses-dead-slots
  (let
    [base (scoped-stack-test-push (scoped-stack-test-with-capacity 4) 1)]
    [child (scoped-stack-test-push (scoped-stack-test-view (& base)) 2)]
    [newer (scoped-stack-test-push (scoped-stack-test-view (& child)) 3)]
    (scoped-stack-test-release (& child) 1)
    (scoped-stack-test-release (& newer) -1)
    (scoped-stack-test-release (& newer) 4)
    (set! newer (scoped-stack-test-push newer 4))
    (test.assert-i64-eq
      (array-length newer.slots)
      4
      "invalid releases leave top intact")
    (test.assert-i64-eq
      (scoped-stack-test-digits (& newer))
      1234
      "newer snapshot survives")
    ;; Child and newer die here; only base remains live beneath the mark.
    (scoped-stack-test-release (& newer) 1)
    (let
      [sibling (scoped-stack-test-push (scoped-stack-test-view (& base)) 9)]
      (test.assert-i64-eq
        (array-length sibling.slots)
        4
        "released slots reused")
      (test.assert-i64-eq (scoped-stack-test-digits (& sibling)) 19 "sibling")
      (test.assert-i64-eq
        (scoped-stack-test-digits (& base))
        1
        "base unchanged"))))

(defstruct ScopedPushOnly
  (slots (__tl_dyn-array i64))
  (len i64)
  (top (__tl_dyn-array i64)))

(scoped_stack.compiler-scoped-stack-operations
  i64
  ScopedPushOnly
  scoped-push-only
  push)

(test
  scoped-stack-push-selects-its-storage-dependencies
  (let
    [s (ScopedPushOnly (__tl_make-array i64 0) 0 (__tl_make-array i64 1))]
    (set! s (scoped-push-only-push s 7))
    (set! s (scoped-push-only-push s 8))
    (test.assert-i64-eq s.len 2 "push alone includes copy and growth helpers")
    (test.assert-i64-eq (array-ref s.slots 0) 7 "old entry")
    (test.assert-i64-eq (array-ref s.slots 1) 8 "new entry")))