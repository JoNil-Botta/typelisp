;; The negative twin of synth_tail_wrapper: the SAME chain, with the walk
;; asking for a capacity one past the family's length.
;;
;; INL-2 changes nothing about that run. The body spliced at the tail-call site
;; retires no bounds check: the accessor's `keys[slot]` load is checked exactly
;; as it is when the accessor stays out of line, and the check that fires is the
;; one inside the body the measured tier copied into `sp-slot-id`. So the abort
;; SITE -- the line and column of the load in `sp-probe`, not of the tail call
;; in the wrapper -- the message, and the exit status must be byte-identical to
;; the base compiler's at every optimization level, which is what a body spliced
;; at a tail-call site keeping its own diagnostics means.
;;
;; `cap` comes in as an argument so nothing can fold the run away.
(import stdlib.io)
(import stdlib.string)

(define sp-empty : i64
  -1)

;; The accessor. Linear probing with a tombstone lane and a wrap-around, which
;; is a cyclic call-free body of about a hundred and fifty instructions: every
;; predictive band refuses it, and only a real re-plan can price it.
(define (sp-probe
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
          sp-empty)))))

;; Wrapper one: the probe at its ENTRY block, and nothing else in that block.
(define (sp-get-or
  [keys : (& k (__tl_dyn-array i64))]
  [marks : (& m (__tl_dyn-array i64))]
  [vals : (& v (__tl_dyn-array i64))]
  [cap : i64]
  [key : i64]
  [fallback : i64]) : i64
  (let
    [slot : i64 (sp-probe keys marks cap key)]
    (if (>= slot 0)
      (array-ref vals slot)
      fallback)))

;; Wrapper two, and the site this fixture exists for: the whole body is
;; `return sp-get-or(...)`, which the lowering fuses into a direct tail call.
(define (sp-slot-id
  [keys : (& k (__tl_dyn-array i64))]
  [marks : (& m (__tl_dyn-array i64))]
  [vals : (& v (__tl_dyn-array i64))]
  [cap : i64]
  [key : i64]) : i64
  (sp-get-or keys marks vals cap key 0))

;; Wrapper three: the tail wrapper at ITS entry block.
(define (sp-bump
  [keys : (& k (__tl_dyn-array i64))]
  [marks : (& m (__tl_dyn-array i64))]
  [vals : (& v (__tl_dyn-array i64))]
  [cap : i64]
  [key : i64]) : i64
  (let
    [seen : i64 (sp-slot-id keys marks vals cap key)]
    (+ seen 1)))

;; The cold second reference to the probe, so it is not a single-site callee.
(define (sp-contains?
  [keys : (& k (__tl_dyn-array i64))]
  [marks : (& m (__tl_dyn-array i64))]
  [cap : i64]
  [key : i64]) : i64
  (if (>= (sp-probe keys marks cap key) 0)
    1
    0))

;; The nested loop the whole chain hangs from: two levels, so the sites below it
;; carry a depth-2 census weight once the counts are propagated.
(define (sp-walk
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
                (set! acc (+ acc (sp-bump keys marks vals cap (+ (* r 7) c))))
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
      ;; body the measured tier copied into `sp-slot-id` at its tail-call site.
      (set! total (sp-walk (& keys) (& marks) (& vals) cap rows 4))
      ;; Never reached, and there for the same reason as in the positive twin:
      ;; the cold references keep all three off every single-site band, so the
      ;; chain the measured tier prices is the same one.
      (set!
        cold
        (+
          (sp-contains? (& keys) (& marks) 64 5)
          (+
            (sp-get-or (& keys) (& marks) (& vals) 64 9 777)
            (sp-slot-id (& keys) (& marks) (& vals) 64 11))))
      (unless (= total 0) (return 1))
      (unless (= cold 0) (return 2))
      42)))