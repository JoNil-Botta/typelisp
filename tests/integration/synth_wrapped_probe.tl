;; FORCING TEST for INL-1: an accessor reached through TWO straight-line
;; wrappers from a nested loop is inlined into the wrapper that calls it.
;;
;; The shape is callgraph_scc's, which is the shape every hashmap-backed program
;; in the corpus has: one open-addressing `sp-probe` -- multi-block, loop
;; bearing, bounds carrying, call-free, past every unmeasured band's size
;; ceiling -- reached as
;;
;;   sp-walk (a doubly nested loop) -> sp-bump -> sp-get-or -> sp-probe
;;
;; where both wrappers call from their own ENTRY block. The census's own
;; reference count answers "how hot are the sites that NAME sp-get-or", and
;; those sites are straight-line, so on that count the probe's site reads as
;; composite frequency ONE -- below the tier's floor of one census weight -- and
;; the measured tier refuses it as cold. The counts propagated over the call
;; graph carry the nested loop's weight down the chain instead, and the site
;; reaches the verdict that keeps it.
;;
;; Both accessors keep a second, cold reference so no single-site or duplicating
;; band can claim either before the measured tier is asked.
;;
;; The exit code proves the values; the shape is pinned in
;; scripts/verify-asm-shape-gates.sh, and the abort twin
;; (synth_wrapped_probe_abort.tl) proves the inlined body keeps its own abort
;; site.
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
          (begin
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
                  (set! step (+ step 1))))))))
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

;; Wrapper two: the first wrapper at ITS entry block.
(define (sp-bump
  [keys : (& k (__tl_dyn-array i64))]
  [marks : (& m (__tl_dyn-array i64))]
  [vals : (& v (__tl_dyn-array i64))]
  [cap : i64]
  [key : i64]) : i64
  (let
    [seen : i64 (sp-get-or keys marks vals cap key 0)]
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
    [cap : i64 64]
    [keys : (__tl_dyn-array i64) (__tl_make-array i64 64)]
    [marks : (__tl_dyn-array i64) (__tl_make-array i64 64)]
    [vals : (__tl_dyn-array i64) (__tl_make-array i64 64)]
    [i : i64 0]
    [total : i64 0]
    [cold : i64 0]
    (begin
      (while (< i cap)
        (begin
          (set! (array-ref keys i) i)
          (set! (array-ref marks i) 1)
          (set! (array-ref vals i) (* i 3))
          (set! i (+ i 1))))
      (set! total (sp-walk (& keys) (& marks) (& vals) cap 16 16))
      (set!
        cold
        (+
          (sp-contains? (& keys) (& marks) cap 5)
          (sp-get-or (& keys) (& marks) (& vals) cap 9 777)))
      (unless (= total 13969) (return 1))
      (unless (= cold 28) (return 2))
      42)))