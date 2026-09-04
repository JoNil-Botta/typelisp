;; The negative twin of checked_post_multi_call: the SAME chain, with the walk
;; asking for a capacity one power of two past the family's length.
;;
;; INL-8 changes nothing about that run. The body spliced at the post-dominating
;; site retires no bounds check: the accessor's `keys[slot]` load is checked
;; exactly as it is when the accessor stays out of line, and the check that
;; fires is the one inside the body the measured tier copied into `pm-lookup`.
;; So the abort SITE -- the line and column of the load in `pm-probe`, not of
;; the call in the caller's merge block -- the message, and the exit status must
;; be byte-identical to the base compiler's at every optimization level, which
;; is what a body spliced at an entry-equivalent site keeping its own
;; diagnostics means.
;;
;; `cap` comes in as an argument so nothing can fold the run away.
(import stdlib.io)
(import stdlib.string)

(define pm-empty : i64
  -1)

;; The accessor. Linear probing with a tombstone lane and a wrap-around: a
;; cyclic, call-free body of about a hundred and fifty instructions that every
;; predictive band refuses, so only a real re-plan can price it.
(define (pm-probe
  [keys : (& k (__tl_dyn-array i64))]
  [marks : (& m (__tl_dyn-array i64))]
  [cap : i64]
  [key : i64]) : i64
  (let
    [mask : i64 (- cap 1)]
    [slot : i64 (bit-and (* key 2654435761) mask)]
    [step : i64 0]
    [found : i64 -1]
    [free : i64 -1]
    (begin
      (while (< step cap)
        (let
          [k : i64 (array-ref keys slot)]
          [m : i64 (array-ref marks slot)]
          (if (= m 0)
            (begin
              (if (< free 0)
                (set! free slot)
                unit)
              (set! found (- 0 (+ slot 2)))
              (set! step cap))
            (if (and (= m 1) (= k key))
              (begin
                (set! found slot)
                (set! step cap))
              (begin
                (if (and (= m 2) (< free 0))
                  (set! free slot)
                  unit)
                (set! slot (bit-and (+ slot 1) mask))
                (set! step (+ step 1)))))))
      (if (>= found 0)
        found
        (if (>= free 0)
          (- 0 (+ free 2))
          pm-empty)))))

;; The two calls the caller carries that the site does not account for. Neither
;; is on the site's own path: `pm-crowded?` runs in the entry block and
;; `pm-penalty` in one arm of the guard above the site. Between them they are
;; what makes `pm-lookup` carry three calls where the caller clause allows one.
(define (pm-crowded? [marks : (& m (__tl_dyn-array i64))] [cap : i64]) : bool
  (let
    [len : i64 (array-length marks)]
    [used : i64 0]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (if (= (array-ref marks i) 1)
            (set! used (+ used 1))
            unit)
          (set! i (+ i 1))))
      (> (* used 4) (* cap 3)))))

(define (pm-penalty [bias : i64]) : i64
  (- bias 3))

;; THE SITE. `pm-lookup` is straight-line -- it holds no loop of its own -- and
;; the accessor call sits in the merge below the guard, which POST-DOMINATES the
;; entry: every invocation that returns at all runs it, so the boundary the
;; inline retires is one the caller pays exactly once. The caller nonetheless
;; carries `pm-crowded?` and `pm-penalty`, so before INL-8 the caller clause
;; refused the reading on the call COUNT, `pos` read `none` and the census
;; reported `site-depth` with no verdict ever priced. INL-8 asks the loop
;; instead -- a loop-free caller's plan cost is the per-invocation number the
;; boundary is credited against -- and the verdict keeps the site.
(define (pm-lookup
  [keys : (& k (__tl_dyn-array i64))]
  [marks : (& m (__tl_dyn-array i64))]
  [cap : i64]
  [key : i64]
  [bias : i64]) : i64
  (let
    [adj : i64
      (if (pm-crowded? marks cap)
        (pm-penalty bias)
        bias)]
    [slot : i64 (pm-probe keys marks cap key)]
    (if (>= slot 0)
      (+ (array-ref keys slot) adj)
      adj)))

;; The small caller of the same accessor, which keeps the admission it always
;; had: its only call is the site's own and the site is its ENTRY block. The
;; pair is the shape the packet is about -- a callee taken at a wrapper while
;; another caller of it kept the site out of line.
(define (pm-get-or
  [keys : (& k (__tl_dyn-array i64))]
  [marks : (& m (__tl_dyn-array i64))]
  [vals : (& v (__tl_dyn-array i64))]
  [cap : i64]
  [key : i64]
  [fallback : i64]) : i64
  (let
    [slot : i64 (pm-probe keys marks cap key)]
    (if (>= slot 0)
      (array-ref vals slot)
      fallback)))

;; The cold second reference to the accessor, so it is not a single-site callee
;; and no band can claim it before the measured tier is asked.
(define (pm-contains?
  [keys : (& k (__tl_dyn-array i64))]
  [marks : (& m (__tl_dyn-array i64))]
  [cap : i64]
  [key : i64]) : i64
  (if (>= (pm-probe keys marks cap key) 0)
    1
    0))

;; The nested loop the chain hangs from: two levels, so the site below it
;; carries the composite frequency the depth floor's own rung asks for.
(define (pm-walk
  [keys : (& k (__tl_dyn-array i64))]
  [marks : (& m (__tl_dyn-array i64))]
  [cap : i64]
  [rows : i64]
  [cols : i64]) : i64
  (let
    [acc : i64 0]
    [r : i64 0]
    (begin
      (while (< r rows)
        (let
          [c : i64 0]
          (begin
            (while (< c cols)
              (begin
                (set! acc (+ acc (pm-lookup keys marks cap (+ (* r 7) c) 5)))
                (set! c (+ c 1))))
            (set! r (+ r 1)))))
      acc)))

(define (main) : i64
  (let
    [cap : i64 (string.>int (io.arg 1))]
    [rows : i64 (string.>int (io.arg 2))]
    [keys : (__tl_dyn-array i64) (__tl_make-array i64 64)]
    [marks : (__tl_dyn-array i64) (__tl_make-array i64 64)]
    [vals : (__tl_dyn-array i64) (__tl_make-array i64 64)]
    [i : i64 0]
    [total : i64 0]
    [cold : i64 0]
    (begin
      (while (< i 64)
        (begin
          (set! (array-ref keys i) i)
          (set! (array-ref marks i) 1)
          (set! (array-ref vals i) (* i 3))
          (set! i (+ i 1))))
      ;; `cap` is 128 and the arrays hold 64, so the probe's wrap-around mask
      ;; walks one past the end on its first pass through the loop -- inside the
      ;; body the measured tier copied into `pm-lookup` at its post-dominating
      ;; site.
      (set! total (pm-walk (& keys) (& marks) cap rows 4))
      ;; Never reached, and there for the same reason as in the positive twin.
      (set!
        cold
        (+
          (pm-contains? (& keys) (& marks) 64 5)
          (pm-get-or (& keys) (& marks) (& vals) 64 9 777)))
      (unless (= total 0) (return 1))
      (unless (= cold 0) (return 2))
      42)))