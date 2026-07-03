(import "stdlib/io.tl")
(import stdlib.array)

;; FORCING TEST for GAP4: alias-granular load CSE + store-to-load forwarding.
;;
;; `poke-sum` interleaves bounds-checked element STORES and element READS on
;; one array in straight-line code (no calls). Pre-GAP4 the load-CSE table was
;; wiped by EVERY store and every access re-emitted a fresh descriptor gep the
;; CSE could not match (gep-var-identity keys), so each of the 7 accesses paid
;; its own len load (bounds check) and data-pointer load: ~14 descriptor
;; loads. Post-GAP4:
;;   * canonical (base, byte-offset, type) keys unify the descriptor geps,
;;   * element stores provably cannot touch descriptor fields (the ported
;;     #1801 element-only-store proof), so the entries SURVIVE the stores,
;; leaving exactly ONE len load and ONE data load in the function
;; (target/loadcse-gate.sh asserts the asm shape), and the reads of just-
;; written elements forward the stored values.
;;
;; The runtime check guards value correctness: a stale forwarded value or a
;; wrongly kept entry produces a wrong sum -> not 42. Self-recursive (never
;; taken) so the opt2 inliner cannot inline it into main.
(define (poke-sum [xs : (Array i64)] [n : i64]) : i64
  (if (< n 0)
    (poke-sum xs (+ n 1))
    (begin
      (array-set! xs 0 (+ n 40))
      (array-set! xs 1 (* n 3))
      (array-set! xs 2 (- (array.ref xs 0) (array.ref xs 1)))
      (+ (array.ref xs 2) (array.ref xs 1)))))

(define (main) : i64
  (let
    [n : i64 (+ (arg-count) 1)]
    [xs : (Array i64) (array.make-array i64 3)]
    [r : i64 (poke-sum xs n)]
    ;; n = 2 (arg-count is 1 with no args): xs[0]=42, xs[1]=6,
    ;; xs[2]=42-6=36; r = 36+6 = 42.
    (if (= r 42)
      42
      1)))