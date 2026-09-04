;; FORCING TEST for INL-9: the arms of a DISPATCH. `da-dispatch` is a `cond`
;; over a tag whose every arm calls the same helper, and whose spine -- the
;; entry block and the else-blocks below it -- only compares and branches.
;;
;; The chain mirrors sccp_lattice's `sccp-value` / `sccp-immediate`, where the
;; same shape is the row's largest set of refused depth-0 sites:
;;
;;   da-walk (a loop) -> da-dispatch -> da-fold   <- four arm sites, one per case
;;                    -> da-probe    -> da-fold   (the cold second reference)
;;
;; Only the FIRST arm of a dispatch is a successor of the entry block's branch,
;; so INL-4's `arm` reading sees one of the four and the other three read `none`
;; -- not because a caller clause refused them, but because no reading covered
;; their shape. The census could not say so either: every refusal printed
;; `pos=none`, which is why the trace now carries `rawpos` beside it.
;;
;; INL-9 reads the SPINE. A spine block holds no call and ends in a branch, so
;; reaching an arm costs the caller nothing and decides only which arm runs;
;; the arms hanging off it are one case each of a selector that runs exactly one
;; of them per invocation. That is the two-arm reading's guarantee stated for n
;; arms, and the caller clause the two-arm reading carries -- "the caller holds
;; no call this site does not account for" -- is unavailable here by
;; construction, since a dispatch holds one call per arm. What replaces it is a
;; clause on the CALLEE: `da-fold` is acyclic, and a loop imported into an arm
;; would be paid at every entry while the arm runs on a fraction of them.
;;
;; The exit code proves the values; the shape is pinned in
;; scripts/verify-asm-shape-gates.sh, and the abort twin
;; (checked_dispatch_arm_abort.tl) proves the body spliced into an arm keeps
;; its own abort site.
;; The helper. Acyclic and call-free, two bounds-checked table reads, and far
;; past every predictive band's size class -- the shared-accessor band's 28 and
;; the bounds-leaf band's 48 -- so only a real re-plan can price it.
(define (da-fold
  [tab : (& t (__tl_dyn-array i64))]
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]) : i64
  (let
    [x : i64 (+ (* a 3) (bit-xor b c))]
    [y : i64 (- (* d 5) (bit-and x 255))]
    [p : i64 (bit-or (shl (bit-and x 7) 3) (bit-and y 7))]
    [q : i64 (bit-xor (* p 31) (+ x y))]
    [v : i64 (array-ref tab (bit-and q 15))]
    [z : i64 (bit-or (shl v 3) (shr (bit-and y 4095) 2))]
    [w : i64 (+ (bit-xor x z) (* y 7))]
    [u : i64 (array-ref tab (bit-and w 15))]
    [s : i64 (+ (* u 11) (bit-and z 63))]
    [t2 : i64 (- (* w 13) (bit-or u 31))]
    (if (> (bit-and s 1) 0)
      (+ s (bit-xor t2 q))
      (- t2 (bit-and s q)))))

;; THE DISPATCH. Five cases, four of which call the helper. The entry block
;; computes nothing and branches on the first case; each else-block below it
;; compares and branches and nothing more. Every one of the four call blocks is
;; an arm of that spine, and only `if_then.0` is a successor of the entry
;; branch.
(define (da-dispatch
  [tab : (& t (__tl_dyn-array i64))]
  [tag : i64]
  [p : i64]
  [q : i64]) : i64
  (cond
    [(= tag 0) (da-fold tab p q 1 2)]
    [(= tag 1) (da-fold tab q p 3 4)]
    [(= tag 2) (da-fold tab p p 5 6)]
    [(= tag 3) (da-fold tab q q 7 8)]
    [else (+ (* p 2) q)]))

;; The cold second reference to the helper, so it is not a single-site callee
;; and no band can claim it before the measured tier is asked -- and so an
;; out-of-line body survives for the asm-shape gate to read. `main` holds a cold
;; second reference to the DISPATCH itself for the same reason: with one
;; reference the sole-call band would move it whole into `da-walk` and there
;; would be no `da-dispatch` in the assembly to read the arms out of.
(define (da-probe [tab : (& t (__tl_dyn-array i64))] [seed : i64]) : i64
  (da-fold tab seed (+ seed 1) (+ seed 2) (+ seed 3)))

;; The loop the dispatch hangs from, so its depth-0 arms carry the composite
;; frequency the depth floor's own rung asks for.
(define (da-walk [tab : (& t (__tl_dyn-array i64))] [rows : i64]) : i64
  (let
    [acc : i64 0]
    [r : i64 0]
    (begin
      (while (< r rows)
        (begin
          (set!
            acc
            (bit-xor acc (da-dispatch tab (bit-and r 7) (+ r 1) (+ r 5))))
          (set! r (+ r 1))))
      acc)))

(define (main) : i64
  (let
    [tab : (__tl_dyn-array i64) (__tl_make-array i64 16)]
    [i : i64 0]
    [total : i64 0]
    [cold : i64 0]
    (begin
      (while (< i 16)
        (begin
          (set! (array-ref tab i) (+ (* i 7) 3))
          (set! i (+ i 1))))
      (set! total (da-walk (& tab) 64))
      (set! cold (+ (da-probe (& tab) 2) (da-dispatch (& tab) 1 3 4)))
      (unless (= total 2944) (return 1))
      (unless (= cold 15475) (return 2))
      42)))