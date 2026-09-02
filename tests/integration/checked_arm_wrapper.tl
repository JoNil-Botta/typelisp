;; FORCING TEST for INL-4: the site is an ARM of the caller's entry branch whose
;; sibling arm returns a literal, and the accessor is folded into it.
;;
;; The chain is synth_tail_wrapper's with the forwarding wrapper given a guard:
;;
;;   aw-walk (a doubly nested loop) -> aw-bump -> aw-slot-id -> aw-get-or
;;                                                           -> aw-probe
;;
;; `aw-slot-id` is `(if (< id 0) -1 (aw-get-or ...))`, so its entry block ends
;; in a branch, the negative arm returns the literal -1, and the accessor call
;; sits in the other arm. That block is NOT the caller's entry block, so before
;; INL-4 the depth floor refused the site outright -- the trace line reported
;; `site-depth` and no verdict was ever priced -- even though the two arms
;; between them run the wrapper out on every invocation, exactly as the entry
;; block does.
;;
;; INL-4 reads the block as ENTRY-EQUIVALENT (`|pos=arm` on the clause line) and
;; the verdict keeps it. The caller clause is satisfied here for the reason it
;; exists: `aw-slot-id` carries no call but the site's own, so the boundary the
;; inline retires is one the wrapper pays once per invocation.
;;
;; Everything else is calibrated exactly as the INL-1 and INL-2 fixtures are.
;; The site is reached two straight-line levels below a nested loop, so its
;; composite frequency is the loop's weight once the call graph's counts are
;; propagated; and by the time the tier reaches `aw-slot-id` the bottom-up walk
;; has already folded `aw-probe` into `aw-get-or`, so the body the arm site
;; copies is call-free and the depth floor's call-free clause applies to it
;; unchanged.
;;
;; Both accessors keep a second, cold reference so no single-site or duplicating
;; band can claim either before the measured tier is asked.
;;
;; The exit code proves the values; the shape is pinned in
;; scripts/verify-asm-shape-gates.sh, and the abort twin
;; (checked_arm_wrapper_abort.tl) proves the body spliced at an arm site keeps
;; its own abort site.
(define aw-empty : i64
  -1)

;; The accessor. Linear probing with a tombstone lane and a wrap-around, which
;; is a cyclic call-free body of about a hundred and fifty instructions: every
;; predictive band refuses it, and only a real re-plan can price it.
(define (aw-probe
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
          aw-empty)))))

;; Wrapper one: the probe at its ENTRY block, and nothing else in that block.
(define (aw-get-or
  [keys : (& k (__tl_dyn-array i64))]
  [marks : (& m (__tl_dyn-array i64))]
  [vals : (& v (__tl_dyn-array i64))]
  [cap : i64]
  [key : i64]
  [fallback : i64]) : i64
  (let
    [slot : i64 (aw-probe keys marks cap key)]
    (if (>= slot 0)
      (array-ref vals slot)
      fallback)))

;; Wrapper two, and the site this fixture exists for: a guard whose negative arm
;; returns a literal and whose other arm holds the accessor call. The two arms
;; run the wrapper out between them, so the call's block is entry-equivalent.
(define (aw-slot-id
  [keys : (& k (__tl_dyn-array i64))]
  [marks : (& m (__tl_dyn-array i64))]
  [vals : (& v (__tl_dyn-array i64))]
  [cap : i64]
  [id : i64]) : i64
  (if (< id 0)
    -1
    (aw-get-or keys marks vals cap id 0)))

;; Wrapper three: the guarded wrapper at ITS entry block.
(define (aw-bump
  [keys : (& k (__tl_dyn-array i64))]
  [marks : (& m (__tl_dyn-array i64))]
  [vals : (& v (__tl_dyn-array i64))]
  [cap : i64]
  [key : i64]) : i64
  (let
    [seen : i64 (aw-slot-id keys marks vals cap key)]
    (+ seen 1)))

;; The cold second reference to the probe, so it is not a single-site callee.
(define (aw-contains?
  [keys : (& k (__tl_dyn-array i64))]
  [marks : (& m (__tl_dyn-array i64))]
  [cap : i64]
  [key : i64]) : i64
  (if (>= (aw-probe keys marks cap key) 0)
    1
    0))

;; The nested loop the whole chain hangs from: two levels, so the sites below it
;; carry a depth-2 census weight once the counts are propagated.
(define (aw-walk
  [keys : (& k (__tl_dyn-array i64))]
  [marks : (& m (__tl_dyn-array i64))]
  [vals : (& v (__tl_dyn-array i64))]
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
                (set! acc (+ acc (aw-bump keys marks vals cap (+ (* r 7) c))))
                (set! c (+ c 1))))
            (set! r (+ r 1)))))
      acc)))

(define (main) : i64
  (let
    [cap : i64 64]
    [keys : (__tl_dyn-array i64) (__tl_make-array i64 64)]
    [marks : (__tl_dyn-array i64) (__tl_make-array i64 64)]
    [vals : (__tl_dyn-array i64) (__tl_make-array i64 64)]
    [i : i64 0]
    [total : i64 0]
    [guarded : i64 0]
    [cold : i64 0]
    (begin
      (while (< i cap)
        (begin
          (set! (array-ref keys i) i)
          (set! (array-ref marks i) 1)
          (set! (array-ref vals i) (* i 3))
          (set! i (+ i 1))))
      (set! total (aw-walk (& keys) (& marks) (& vals) cap 16 16))
      ;; The guard's own arm, proving the sibling the widening reads is the one
      ;; that runs: a negative id never reaches the accessor at all.
      (set! guarded (aw-slot-id (& keys) (& marks) (& vals) cap -3))
      ;; The cold second references: one apiece for the accessor, the wrapper
      ;; the arm site copies, and the guarded wrapper itself, so no single-site
      ;; band can claim any of the three and every one of them keeps an
      ;; out-of-line body for the asm-shape gate to read.
      (set!
        cold
        (+
          (aw-contains? (& keys) (& marks) cap 5)
          (+
            (aw-get-or (& keys) (& marks) (& vals) cap 9 777)
            (aw-slot-id (& keys) (& marks) (& vals) cap 11))))
      (unless (= total 13969) (return 1))
      (unless (= guarded -1) (return 2))
      (unless (= cold 61) (return 3))
      42)))
