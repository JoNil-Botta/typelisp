;; The negative twin of checked_dispatch_arm: the SAME dispatch, with a table
;; shorter than the index the helper masks to.
;;
;; `da-fold`'s two reads mask their index to four bits, so a table of eight
;; slots is walked one past the end on the first case the dispatch takes. The
;; abort therefore fires INSIDE the body the measured tier copied into an arm of
;; `da-dispatch`, which is the point: a dispatch arm's import retires the call
;; boundary and nothing else -- every load the helper makes is still checked in
;; the merged body, and the check that fails still reports the helper's own
;; source location.
;;
;; The length and the row count are runtime arguments, so nothing can be
;; constant folded and the abort is reached at every optimization level.
(import stdlib.io)
(import stdlib.string)

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
    [len : i64 (string.>int (io.arg 1))]
    [rows : i64 (string.>int (io.arg 2))]
    [tab : (__tl_dyn-array i64) (__tl_make-array i64 len)]
    [i : i64 0]
    [total : i64 0]
    [cold : i64 0]
    (begin
      (while (< i len)
        (begin
          (set! (array-ref tab i) (+ (* i 7) 3))
          (set! i (+ i 1))))
      ;; `len` is 8 and the helper masks its index to fifteen, so the first case
      ;; the dispatch takes reads one past the end -- inside the body the
      ;; measured tier copied into that arm.
      (set! total (da-walk (& tab) rows))
      ;; Never reached, and there for the same reason as in the positive twin.
      (set! cold (+ (da-probe (& tab) 2) (da-dispatch (& tab) 1 3 4)))
      (unless (= total 0) (return 1))
      (unless (= cold 0) (return 2))
      42)))