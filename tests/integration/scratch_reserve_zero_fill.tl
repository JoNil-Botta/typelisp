;; FORCING TEST for SCR-1: a loop whose hoisted residents fill the whole
;; register file leaves the backend no free scratch for the memory operations
;; it must stage, and the allocator answers by RESERVING one.
;;
;; `reset-arrays!` writes sixteen global vectors at the same index in one loop.
;; LICM hoists every vector's data pointer into the preheader, the greedy homes
;; as many as the pool holds and spills the rest, and each store through a
;; spilled pointer must reload it into a scratch register. Before SCR-1 every
;; pool register was live across the loop, so the scavenger borrowed one for
;; each such store and bracketed it with a save and a restore (the XMM park of
;; compiler-backend-emergency-wrap), and the staged store copied the resident
;; index into a second borrowed register besides: seven instructions per store
;; against the two a free scratch needs. The scratch-reserve round
;; (compiler-reg-scratch-reserve-rewrite-function) prices those parks off the
;; plan, replans with %r11 out of the greedy pool and keeps the plan when it is
;; cheaper, and the staged store reads the register-homed index in place. The
;; gate asserts the shape: no park in the loop, and the spilled pointers
;; reloaded through %r11 straight into a store.
;;
;; NON-TAIL self-recursion (never taken at rounds = 1) keeps `reset-arrays!`
;; out of the inliner and out of opt-tailrec, so the gate can assert on the
;; named body (divmagic_hoist pattern).
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

(define (zero-vec [n : i64]) : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 n) n))

(define (vec-set! [items : (&mut items i64vec.Vec)] [index : i64] [value : i64]) : unit
  (set! (array-ref (i64vec.slots-mut items) index) value))

(define (vec-ref [items : (& items i64vec.Vec)] [index : i64]) : i64
  (array-ref (i64vec.slots items) index))

(define g-seg-lo : i64vec.Vec
  (zero-vec 0))
(define g-seg-hi : i64vec.Vec
  (zero-vec 0))
(define g-raw : i64vec.Vec
  (zero-vec 0))
(define g-key : i64vec.Vec
  (zero-vec 0))
(define g-hint : i64vec.Vec
  (zero-vec 0))
(define g-argpref : i64vec.Vec
  (zero-vec 0))
(define g-param : i64vec.Vec
  (zero-vec 0))
(define g-group : i64vec.Vec
  (zero-vec 0))
(define g-present : i64vec.Vec
  (zero-vec 0))
(define g-kind : i64vec.Vec
  (zero-vec 0))
(define g-reg : i64vec.Vec
  (zero-vec 0))
(define g-primary : i64vec.Vec
  (zero-vec 0))
(define g-secondary : i64vec.Vec
  (zero-vec 0))
(define g-pending : i64vec.Vec
  (zero-vec 0))
(define g-evict : i64vec.Vec
  (zero-vec 0))
(define g-stage : i64vec.Vec
  (zero-vec 0))

(define (reset-arrays! [count : i64] [rounds : i64]) : i64
  (let
    [v : i64 0]
    (begin
      (while (< v count)
        (begin
          (vec-set! (&mut g-seg-lo) v 0)
          (vec-set! (&mut g-seg-hi) v 0)
          (vec-set! (&mut g-raw) v 0)
          (vec-set! (&mut g-key) v 0)
          (vec-set! (&mut g-hint) v -1)
          (vec-set! (&mut g-argpref) v -1)
          (vec-set! (&mut g-param) v 0)
          (vec-set! (&mut g-group) v 0)
          (vec-set! (&mut g-present) v 0)
          (vec-set! (&mut g-kind) v 0)
          (vec-set! (&mut g-reg) v -1)
          (vec-set! (&mut g-primary) v -1)
          (vec-set! (&mut g-secondary) v -1)
          (vec-set! (&mut g-pending) v 0)
          (vec-set! (&mut g-evict) v 0)
          (vec-set! (&mut g-stage) v 0)
          (set! v (+ v 1))))
      (if (> rounds 1)
        (+ count (reset-arrays! count (- rounds 1)))
        count))))

(define (main) : i64
  (let
    ;; count = 64 when run without args (io.arg-count = 1); the runtime value
    ;; blocks constant folding of the loop.
    [count : i64 (+ 63 (io.arg-count))]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (set! g-seg-lo (zero-vec count))
      (set! g-seg-hi (zero-vec count))
      (set! g-raw (zero-vec count))
      (set! g-key (zero-vec count))
      (set! g-hint (zero-vec count))
      (set! g-argpref (zero-vec count))
      (set! g-param (zero-vec count))
      (set! g-group (zero-vec count))
      (set! g-present (zero-vec count))
      (set! g-kind (zero-vec count))
      (set! g-reg (zero-vec count))
      (set! g-primary (zero-vec count))
      (set! g-secondary (zero-vec count))
      (set! g-pending (zero-vec count))
      (set! g-evict (zero-vec count))
      (set! g-stage (zero-vec count))
      (while (< i 100)
        (begin
          (set! acc (+ acc (reset-arrays! count 1)))
          (set! acc (+ acc (vec-ref (& g-hint) 3)))
          (set! acc (+ acc (vec-ref (& g-key) 5)))
          (set! i (+ i 1))))
      ;; 100 x (64 + (-1) + 0)
      (if (= acc 6300)
        42
        1))))