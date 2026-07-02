(import "stdlib/io.tl")
(import stdlib.array)

;; MUST-INVALIDATE stress for GAP4 (alias-granular load CSE / store-to-load
;; forwarding). Two handles that name the SAME array reach a function as
;; distinct parameters; a store through one MUST invalidate element load
;; entries cached through the other (different base vars may alias: the
;; conservative path has to reload). Both checks are runtime-verified: a
;; wrongly surviving entry returns the stale pre-store value and the checksum
;; misses 42. Fixpoint/SELFCHECK can pass over aliasing bugs (both stages
;; equally wrong) -- this fixture is the net.
;;
;; `alias-poke`: read xs[0], store through ys[0] (same buffer!), re-read
;; xs[0] -- the re-read must see the store.
;; `mirror-sum`: the licm_alias_stress rotate shape split across two aliased
;; handles: reads through xs must observe earlier-iteration writes through ys.
;; Never-taken self-recursions block inlining, keeping xs/ys distinct params.
(define (alias-poke
  [xs : (Array i64)]
  [ys : (Array i64)]
  [n : i64]) : i64
  (if (< n 0)
    (alias-poke xs ys (+ n 1))
    (let
      [a : i64 (array.array-ref xs 0)]
      (begin
        (array.array-set! ys 0 (+ a n))
        (+ (array.array-ref xs 0) (array.array-ref ys 1))))))

(define (mirror-sum
  [xs : (Array i64)]
  [ys : (Array i64)]
  [n : i64]) : i64
  (if (< n 0)
    (mirror-sum xs ys (+ n 1))
    (let
      [i : i64 0]
      [acc : i64 0]
      (begin
        (while (< i n)
          (begin
            (set! acc (+ acc (array.array-ref xs i)))
            (array.array-set! ys (- (- n 1) i) (+ i 1))
            (set! i (+ i 1))))
        acc))))

(define (main) : i64
  (let
    [n : i64 (+ (arg-count) 5)]
    [xs : (Array i64) (array.make-array i64 2)]
    [zs : (Array i64) (array.make-array i64 (+ n 1))]
    (begin
      (array.array-set! xs 0 10)
      (array.array-set! xs 1 20)
      (let
        ;; n = 6 (arg-count is 1 with no args): a=10; xs[0] := 10+6 = 16;
        ;; r1 = xs[0] + xs[1] = 16 + 20 = 36. A stale cached xs[0] gives 30.
        [r1 : i64 (alias-poke xs xs n)]
        ;; zs len 7, zero-init; reads i=0..6 see writes from earlier
        ;; iterations only for i>3: acc = 0+0+0+0+3+2+1 = 6. Stale reads
        ;; (a wrongly surviving element entry) give 0.
        [r2 : i64 (mirror-sum zs zs (+ n 1))]
        (if (and (= r1 36) (= r2 6)) 42 1)))))
