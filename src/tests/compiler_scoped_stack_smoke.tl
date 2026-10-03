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
  scoped-stack-test)

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