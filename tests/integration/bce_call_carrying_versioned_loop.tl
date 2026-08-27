;; bce_call_carrying_versioned_loop.tl - runtime parity for the multi-block
;; bounds check versioner's CALL-CARRYING clone.
;;
;; `walk` is a counted do-while loop whose body branches, indexes three
;; descriptor-backed arrays, and CALLS a helper on one of its arms. Two things
;; had to be true for it to version at all:
;;
;;   * the clone whitelist has to admit a direct call, and the clone has to
;;     rebase that call's dst and substitute its arguments like any other
;;     instruction (opt-bce-mb-body-instr-ok?, opt-bce-mb-clone-instr) -- so
;;     the fast clone holds its OWN copy of the call;
;;   * the guard has to be allowed to read the descriptor LENGTHS once, which
;;     needs a per-callee proof that nothing the call does can move a
;;     descriptor word. `bump` writes only the element storage of the array it
;;     is handed -- a different allocation from the descriptor naming it -- so
;;     its call-memory summary carries the element bit alone and it earns
;;     opt-direct-call-clean-unconditional-global-bit.
;;
;; The guard decides at run time and both windows below satisfy it, so the
;; fast clone runs at two different trip counts. Each result is checked twice:
;; against a hand-fused `twin` that inlines the helper's effect by hand, and
;; against the closed form the arithmetic has -- `items` and `other` are
;; constant, every `marks` slot is bumped exactly once, and `extra` selects the
;; arm.
;;
;; `len` comes from the process argument count so no size folds and the guard
;; is a real run-time decision.
(import stdlib.io)

;; Element-clean: every write lands in the element storage the parameter's
;; descriptor points at, never in a descriptor word and never in a global cell.
;; Large enough (its own counted loop) that the inliner leaves the call site
;; alone, which is the point -- the versioner has to clone the call.
(define (bump
  [marks : (&mut marks (__tl_dyn-array i64))]
  [start : i64]
  [count : i64]
  [v : i64]) : i64
  (let
    [i : i64 start]
    [stop : i64 (+ start count)]
    [last : i64 0]
    [spin : i64 0]
    [guard : i64 0]
    (begin
      (while (< i stop)
        (begin
          (set! (array-ref marks i) (+ (array-ref marks i) v))
          (set! last (array-ref marks i))
          (set! i (+ i 1))))
      ;; Two more passes over the same window, each a no-op on the values but
      ;; not on the SIZE: three counted loops keep this body above every static
      ;; inline band, so the call site below survives to be cloned. They stay
      ;; element-only writes, so the callee's summary is unchanged.
      (set! i start)
      (while (< i stop)
        (begin
          (set! spin (+ spin (array-ref marks i)))
          (set! (array-ref marks i) (array-ref marks i))
          (set! i (+ i 1))))
      (set! i start)
      (while (< i stop)
        (begin
          (set! guard (+ guard (- (array-ref marks i) (array-ref marks i))))
          (set! (array-ref marks i) (+ (array-ref marks i) guard))
          (set! i (+ i 1))))
      (+ last guard))))

(define (walk
  [items : (& items (__tl_dyn-array i64))]
  [other : (& other (__tl_dyn-array i64))]
  [extra : (& extra (__tl_dyn-array i64))]
  [marks : (&mut marks (__tl_dyn-array i64))]
  [n : i64]
  [seed : i64]) : i64
  (let
    [acc : i64 seed]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref items i)))
          (set! acc (+ acc (array-ref other i)))
          (if (> (array-ref extra i) 0)
            (set! acc (+ acc (bump (&mut marks) i 1 1)))
            (set! acc (- acc 1)))
          (set! i (+ i 1))))
      acc)))

;; The same arithmetic with the helper's effect fused in by hand.
(define (twin
  [items : (& items (__tl_dyn-array i64))]
  [other : (& other (__tl_dyn-array i64))]
  [extra : (& extra (__tl_dyn-array i64))]
  [marks : (&mut marks (__tl_dyn-array i64))]
  [n : i64]
  [seed : i64]) : i64
  (let
    [acc : i64 seed]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (array-ref items i)))
          (set! acc (+ acc (array-ref other i)))
          (if (> (array-ref extra i) 0)
            (begin
              (set! (array-ref marks i) (+ (array-ref marks i) 1))
              (set! acc (+ acc (array-ref marks i))))
            (set! acc (- acc 1)))
          (set! i (+ i 1))))
      acc)))

(define (fill [a : (&mut a (__tl_dyn-array i64))] [n : i64] [v : i64]) : unit
  (let
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref a i) v)
          (set! i (+ i 1))))
      unit)))

;; seed + sum over i < n of (items + other + (marks bump | -1)).
(define (expected
  [extra : (& extra (__tl_dyn-array i64))]
  [n : i64]
  [seed : i64]) : i64
  (let
    [acc : i64 seed]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (if (> (array-ref extra i) 0)
            (set! acc (+ acc 6))
            (set! acc (+ acc 4)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [len : i64 (+ 8 (io.arg-count))]
    [items (__tl_make-array i64 len)]
    [other (__tl_make-array i64 len)]
    [extra (__tl_make-array i64 len)]
    [marks-a (__tl_make-array i64 len)]
    [marks-b (__tl_make-array i64 len)]
    [marks-c (__tl_make-array i64 len)]
    [marks-d (__tl_make-array i64 len)]
    [wa : i64 0]
    [tb : i64 0]
    [wc : i64 0]
    [td : i64 0]
    (begin
      (fill (&mut items) len 2)
      (fill (&mut other) len 3)
      (fill (&mut extra) len 1)
      ;; Both arms of the branch run.
      (set! (array-ref extra 1) 0)
      (set! (array-ref extra 4) 0)
      ;; Each window gets its own `marks`, so every slot is bumped at most once
      ;; and the closed form below holds.
      (set! wa (walk (& items) (& other) (& extra) (&mut marks-a) len 7))
      (set! tb (twin (& items) (& other) (& extra) (&mut marks-b) len 7))
      (set! wc (walk (& items) (& other) (& extra) (&mut marks-c) (- len 3) 7))
      (set! td (twin (& items) (& other) (& extra) (&mut marks-d) (- len 3) 7))
      (if (and
        (= wa tb)
        (= wc td)
        (= wa (expected (& extra) len 7))
        (= wc (expected (& extra) (- len 3) 7)))
        42
        1))))