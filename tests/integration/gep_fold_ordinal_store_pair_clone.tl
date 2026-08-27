;: Behavioral fixture for the GAP9 gep-fold ORDINAL ACCOUNTING across a
;: call-carrying multiblock clone.
;:
;: GAP9 folds a constant offset add into a gep's addressing displacement and
;: hands emission a per-function table keyed by the gep's ORDINAL in walk order
;: (see the ordinal-table comment in compiler_backend.tl). The invariant that
;: keying rests on is that emission consumes exactly one ordinal per Gep --
;: including the geps a peephole ABSORBS, where the walk resumes past a gep the
;: peephole folded into its own operand.
;:
;: The `StorePtr;Gep;StorePtr` store-pair peephole -- the shape a two-word enum
;: or descriptor store produces -- absorbed its gep without consuming the
;: ordinal, so every later gep in that function read the previous entry's
;: displacement. That is silent whenever the shifted entries happen to agree in
;: shape, which is why it survived: it is the real backend defect behind #6307
;: ("call-carrying multiblock clones miscompile"), whose re-triage against
;: regalloc #6288 closed the regalloc half and left this one live.
;:
;: The shape here is calc.tl's lexer reduced to the three ingredients that make
;: the accounting observable in one function: parallel byte indices `i`, `i+1`,
;: `i+2`, `i+3` over one base (the gep folds that install the table), a
;: two-word token store per iteration (the absorbed store-pair gep), and a
;: multiblock CALL-CARRYING classifier absorbed into the scanner by the opt2
;: multiblock inliner (the clone that puts them in one body). Pre-fix this file
;: does not compile at opt2 at all: the shifted ordinals land on a differently
;: shaped entry and the audit refuses the function.
;:
;: The check needs no golden constant. The same scan is written a second time
;: as one call-free loop that nothing is cloned into, and both the accumulator
;: and the whole emitted token array must agree -- so a displacement that is
;: merely wrong (rather than shape-detectable) fails here too. Run at opt0/opt1
;: by the manifest and at opt2 by verify-integration.sh, where the multiblock
;: inliner and the gep fold both actually run.
;; Two words: tag then payload. Storing one writes base+0 and base+8 through a
;; single address computation -- the store-pair peephole's admitted shape.
(defenum GfoTok
  (Int i64)
  (Punct i64))

;; Never inlined: it calls itself, so it is in its own SCC. The recursive arm
;; is unreachable for every value this fixture produces.
(define (gfo-mix [h : i64] [v : i64]) : i64
  (if (> v 1000)
    (gfo-mix h (- v 1000))
    (let
      [x : i64 (+ (* h 31) v)]
      (- x (* (/ x 1000003) 1000003)))))

;; Multiblock and CALL-CARRYING: three arms, two of which call `gfo-mix` out of
;; tail position. One static reference, so the scanner absorbs it at opt2.
(define (gfo-classify [c : i64] [acc : i64]) : i64
  (if (= (- c (* (/ c 2) 2)) 0)
    (+ (gfo-mix acc c) 1)
    (if (> c 100)
      (+ (gfo-mix acc (- c 100)) 2)
      (+ acc c))))

;; The clone site: four parallel byte indices off one base (foldable gep
;; candidates) and a two-word token store, in a body that carries the cloned
;; calls.
(define (gfo-scan
  [src : (__tl_dyn-array u8)]
  [out : (__tl_dyn-array GfoTok)]
  [n : i64]
  [seed : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 seed]
    (begin
      (while (< i (- n 3))
        (begin
          (set!
            acc
            (gfo-classify
              (+
                (+
                  (cast (array-ref src i) : i64)
                  (cast (array-ref src (+ i 1)) : i64))
                (+
                  (cast (array-ref src (+ i 2)) : i64)
                  (cast (array-ref src (+ i 3)) : i64)))
              acc))
          (set! (array-ref out i) (GfoTok.Int acc))
          (set! i (+ i 1))))
      acc)))

;; The same arithmetic with no call in it, so nothing is cloned into it.
(define (gfo-scan-fused
  [src : (__tl_dyn-array u8)]
  [out : (__tl_dyn-array GfoTok)]
  [n : i64]
  [seed : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 seed]
    [c : i64 0]
    [x : i64 0]
    (begin
      (while (< i (- n 3))
        (begin
          (set!
            c
            (+
              (+
                (cast (array-ref src i) : i64)
                (cast (array-ref src (+ i 1)) : i64))
              (+
                (cast (array-ref src (+ i 2)) : i64)
                (cast (array-ref src (+ i 3)) : i64))))
          (if (= (- c (* (/ c 2) 2)) 0)
            (begin
              (set! x (+ (* acc 31) c))
              (set! acc (+ (- x (* (/ x 1000003) 1000003)) 1)))
            (if (> c 100)
              (begin
                (set! x (+ (* acc 31) (- c 100)))
                (set! acc (+ (- x (* (/ x 1000003) 1000003)) 2)))
              (set! acc (+ acc c))))
          (set! (array-ref out i) (GfoTok.Int acc))
          (set! i (+ i 1))))
      acc)))

(define (gfo-tok-value [t : GfoTok]) : i64
  (match t
    [(GfoTok.Int v) v]
    [(GfoTok.Punct v) (- 0 v)]))

;; A runtime-filled source: the optimizer does not constant-fold loads out of a
;; dynamically allocated array, so both scanners really run.
(define (gfo-fill [src : (__tl_dyn-array u8)] [n : i64] [step : i64]) : unit
  (let
    [i : i64 0]
    [x : i64 step]
    (while (< i n)
      (begin
        (set! (array-ref src i) (cast (- x (* (/ x 251) 251)) : u8))
        (set! x (+ (* x 7) 13))
        (set! i (+ i 1))))))

(define (gfo-tokens-agree?
  [a : (__tl_dyn-array GfoTok)]
  [b : (__tl_dyn-array GfoTok)]
  [n : i64]) : bool
  (let
    [i : i64 0]
    [same : bool true]
    (begin
      (while (< i n)
        (begin
          (if (=
            (gfo-tok-value (array-ref a i))
            (gfo-tok-value (array-ref b i)))
            unit
            (set! same false))
          (set! i (+ i 1))))
      same)))

(define (main) : i64
  (let
    [n : i64 96]
    [src : (__tl_dyn-array u8) (__tl_make-array u8 n)]
    [cloned-toks : (__tl_dyn-array GfoTok) (__tl_make-array GfoTok n)]
    [fused-toks : (__tl_dyn-array GfoTok) (__tl_make-array GfoTok n)]
    [cloned : i64 0]
    [fused : i64 0]
    (begin
      (gfo-fill src n 3)
      (set! cloned (gfo-scan src cloned-toks n 1))
      (set! fused (gfo-scan-fused src fused-toks n 1))
      (if (and
        (= cloned fused)
        (gfo-tokens-agree? cloned-toks fused-toks (- n 3)))
        42
        1))))