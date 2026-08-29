;; Refs #6930: constructor lowering must evaluate every operand before it
;; writes a directly reused destination. The opt0/opt2 runner rows cover both
;; the lowerer's two-phase order and ctor_fwd's guarded store retargeting.
;; lint-allow: unused-import
(import stdlib.string)

(defstruct CopyState
  (left i64)
  (right i64)
  (sum i64))

;; Returning this nested shape through hidden sret materializes the inner value
;; in a fresh temporary first, which gives ctor_fwd a real candidate.
(defstruct NestedState
  (prefix i64)
  (inner CopyState))

;; String makes this memory-class aggregate non-Copy. Passing it by value moves
;; the source, while `set!` below legally reinitializes that same local from the
;; returned value.
(defstruct OwnedState
  (left i64)
  (right i64)
  (label String))

(define (swap-owned [state : OwnedState]) : OwnedState
  (OwnedState state.right state.left state.label))

(define (rebuild-nested [state : CopyState] [prefix : i64]) : NestedState
  (NestedState
    prefix
    (CopyState state.right state.left (+ state.left state.right))))

;; This direct tail call forwards the caller's hidden sret slot. The callee must
;; still observe the complete private snapshot of its consumed argument before
;; any result bytes become visible in that slot.
(define (tail-swap-owned [state : OwnedState]) : OwnedState
  (swap-owned state))

;; Each recursive tail step constructs the next consumed accumulator before it
;; forwards the unchanged hidden sret slot. This keeps the evaluate-before-write
;; boundary live across the loop form of destination forwarding.
(define (tail-rotate-owned [state : OwnedState] [remaining : i64]) : OwnedState
  (if (> remaining 0)
    (tail-rotate-owned
      (OwnedState state.right state.left state.label)
      (- remaining 1))
    state))

(define (main) : i64
  (let
    [copy : CopyState (CopyState 11 22 33)]
    [nested : NestedState (NestedState 5 (CopyState 3 4 7))]
    [owned : OwnedState (OwnedState 7 35 "kept")]
    [round : i64 0]
    (begin
      ;; Each accumulator update reuses `copy` as its own destination. The
      ;; first store would overwrite `copy.left`; the second and third operands
      ;; must already have read the old value by then.
      (while (< round 5)
        (begin
          (set! copy (CopyState copy.right copy.left (+ copy.left copy.right)))
          (set! round (+ round 1))))
      (unless
        (and (= copy.left 22) (= copy.right 11) (= copy.sum 33))
        (return 1))
      ;; The nested destination must remain untouched until all reads from the
      ;; old nested value have been materialized.
      (set!
        nested
        (NestedState
          (+ nested.prefix 1)
          (CopyState
            nested.inner.right
            nested.inner.left
            (+ nested.inner.left nested.inner.right))))
      (unless
        (and
          (= nested.prefix 6)
          (= nested.inner.left 4)
          (= nested.inner.right 3)
          (= nested.inner.sum 7))
        (return 2))
      ;; The returned outer value goes through hidden sret; ctor_fwd may remove
      ;; its inner temp/copy while preserving the same materialization order.
      (set! nested (rebuild-nested nested.inner (+ nested.prefix 1)))
      (unless
        (and
          (= nested.prefix 7)
          (= nested.inner.left 3)
          (= nested.inner.right 4)
          (= nested.inner.sum 7))
        (return 3))
      ;; The source binding is consumed and immediately reinitialized from the
      ;; hidden-sret result. Ownership alone must not be treated as noalias if
      ;; later lowering or optimization reuses its backing storage.
      (set! owned (swap-owned owned))
      (unless
        (and (= owned.left 35) (= owned.right 7) (string.eq owned.label "kept"))
        (return 4))
      ;; Cross the same ownership/reinitialization pattern through a forwarded
      ;; hidden sret and swap back.
      (set! owned (tail-swap-owned owned))
      (unless
        (and (= owned.left 7) (= owned.right 35) (string.eq owned.label "kept"))
        (return 5))
      ;; Three recursive accumulator steps leave the pair swapped once more.
      (set! owned (tail-rotate-owned owned 3))
      (unless
        (and (= owned.left 35) (= owned.right 7) (string.eq owned.label "kept"))
        (return 6))
      42)))