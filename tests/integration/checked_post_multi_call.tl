;; FORCING TEST for INL-8: the accessor's site is a block that POST-DOMINATES
;; the caller's entry, in a caller that is straight-line but carries calls of
;; its own.
;;
;; The chain mirrors callgraph_scc's hash map, where the same site is the
;; largest single gap against C:
;;
;;   pm-walk (a doubly nested loop) -> pm-lookup -> pm-crowded?
;;                                               -> pm-penalty
;;                                               -> pm-probe   <- the site
;;                                  -> pm-get-or -> pm-probe
;;                                  -> pm-contains? -> pm-probe
;;
;; `pm-lookup` computes a bias through a guard and then probes, so the probe's
;; call sits in the merge below that guard. The merge post-dominates the entry
;; -- every invocation that returns runs it -- so INL-4's `post` reading applies
;; and the boundary is credited once per invocation, exactly as it is at the
;; entry block. What refused it before INL-8 was the CALLER clause, which asked
;; how many calls the caller carries and allowed one: `pm-lookup` carries three,
;; so `pos` read `none`, the depth floor stood, and the census line ended
;; `site-depth` with no verdict priced for the site at all.
;;
;; INL-8 asks the caller's LOOPS instead. A depth-0 boundary is credited once
;; per invocation and the plan prices one allocation per invocation, so the two
;; are commensurate exactly while the caller is straight-line; a loop is what
;; makes the plan's number something a single allocation decision inside the
;; nest moves by an order of magnitude more. `pm-lookup` holds no loop, so the
;; site is measured, and the verdict keeps it.
;;
;; `pm-get-or` is the same accessor at a small caller's ENTRY block, which is
;; the admission that never moved: the pair is the packet's shape, a callee
;; taken at one caller while another caller of it kept the site out of line.
;;
;; The exit code proves the values; the shape is pinned in
;; scripts/verify-asm-shape-gates.sh, and the abort twin
;; (checked_post_multi_call_abort.tl) proves the body spliced at a
;; post-dominating site keeps its own abort site.
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
      (set! total (pm-walk (& keys) (& marks) cap 16 16))
      ;; The cold second references: one apiece for the accessor and for the
      ;; wrapper that takes it at its entry block, so no single-site band can
      ;; claim either and both keep an out-of-line body for the asm-shape gate
      ;; to read.
      (set!
        cold
        (+
          (pm-contains? (& keys) (& marks) cap 5)
          (pm-get-or (& keys) (& marks) (& vals) cap 9 777)))
      (unless (= total 5083) (return 1))
      (unless (= cold 28) (return 2))
      42)))