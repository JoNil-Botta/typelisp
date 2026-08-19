;: Behavioral fixture for the multiblock inliner's CALL-CARRYING clone path.
;:
;: #6307 reported a silent wrong answer from a large inlined liveness kernel and
;: was read for a long time as "the multiblock clone path miscompiles
;: call-carrying clones". Re-triage closed it against the inliner and
;: re-attributed the failure to Linux opt2 scalar register allocation (#6288),
;: but no end-to-end fixture ever pinned the clone path itself, so the claim
;: could not be retired from the admission gates that cited it. This is that
;: fixture.
;:
;: The shape is the reported one, reduced: three parallel integer lists, a
;: per-element classifier with three arms of which two make a call, and a
;: loop-bearing scanner that the classifier is absorbed into. `ccc-mix` is
;: self-recursive, so it is never inlined and the classifier the scanner
;: absorbs really does still carry two calls when it is cloned.
;:
;: The check needs no golden constant: the same arithmetic is written a second
;: time as one fused, call-free loop that nothing inlines into anything, and the
;: two results must agree. A clone that rebased a call's destination wrongly,
;: dropped an argument remap, or mis-chained the continuation phi moves the
;: inlined result and not the fused one. Run at opt0/opt1 by the manifest (where
;: the multiblock inliner does not run at all) and at opt2 by
;: verify-integration.sh (where it does), so the two levels must also agree.
(import stdlib.array)

;; Never inlined: it calls itself, so it is in its own SCC. The recursive arm is
;; unreachable for every value this fixture produces, which is what lets the
;; fused loop below spell out the base case.
(define (ccc-mix [h : i64] [v : i64]) : i64
  (if (> v 1000)
    (ccc-mix h (- v 1000))
    (let
      [x : i64 (+ (* h 31) v)]
      (- x (* (/ x 1000003) 1000003)))))

;; Multiblock and CALL-CARRYING: three arms, two of which call `ccc-mix`. The
;; calls are NOT in tail position -- a tail call lowers to a jump and the
;; multiblock body gate refuses those, so the arms add to the result to keep a
;; real call instruction in the cloned body. One static reference, so the
;; scanner below absorbs it.
(define (ccc-classify [v : i64] [acc : i64]) : i64
  (if (= (- v (* (/ v 2) 2)) 0)
    (+ (ccc-mix acc v) 1)
    (if (> v 100)
      (+ (ccc-mix acc (- v 100)) 2)
      (+ acc v))))

(define (ccc-scan [a : (& a (__tl_dyn-array i64))] [n : i64] [seed : i64]) : i64
  (let
    [acc : i64 seed]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (ccc-classify (array-ref a i) acc))
          (set! i (+ i 1))))
      acc)))

;; The same arithmetic with no call in it, so nothing is cloned into it.
(define (ccc-scan-fused [a : (& a (__tl_dyn-array i64))] [n : i64] [seed : i64]) : i64
  (let
    [acc : i64 seed]
    [i : i64 0]
    [v : i64 0]
    [x : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! v (array-ref a i))
          (if (= (- v (* (/ v 2) 2)) 0)
            (begin
              (set! x (+ (* acc 31) v))
              (set! acc (+ (- x (* (/ x 1000003) 1000003)) 1)))
            (if (> v 100)
              (begin
                (set! x (+ (* acc 31) (- v 100)))
                (set! acc (+ (- x (* (/ x 1000003) 1000003)) 2)))
              (set! acc (+ acc v))))
          (set! i (+ i 1))))
      acc)))

;; A runtime-filled list: the optimizer does not constant-fold loads out of a
;; dynamically allocated array, so both scanners really run.
(define (ccc-fill [a : (&mut a (__tl_dyn-array i64))] [n : i64] [step : i64]) : unit
  (let
    [i : i64 0]
    [x : i64 step]
    (while (< i n)
      (begin
        (set! (array-ref a i) x)
        (set! x (+ (* x 7) 13))
        (set! x (- x (* (/ x 251) 251)))
        (set! i (+ i 1))))))

(define (main) : i64
  (let
    [n : i64 96]
    [uses : (__tl_dyn-array i64) (array.make-array i64 n)]
    [nophi : (__tl_dyn-array i64) (array.make-array i64 n)]
    [defs : (__tl_dyn-array i64) (array.make-array i64 n)]
    [inlined : i64 1]
    [fused : i64 1]
    (begin
      (ccc-fill (&mut uses) n 3)
      (ccc-fill (&mut nophi) n 11)
      (ccc-fill (&mut defs) n 29)
      (set! inlined (ccc-scan (& uses) n inlined))
      (set! inlined (ccc-scan (& nophi) n inlined))
      (set! inlined (ccc-scan (& defs) n inlined))
      (set! fused (ccc-scan-fused (& uses) n fused))
      (set! fused (ccc-scan-fused (& nophi) n fused))
      (set! fused (ccc-scan-fused (& defs) n fused))
      (if (= inlined fused)
        42
        1))))