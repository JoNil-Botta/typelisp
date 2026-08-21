(import stdlib.array)

;; FORCING TEST for M6-H (the scavenged M6-D staging register) and for the
;; fusion pin that keeps a fused LOAD destination's identity through slot
;; coloring.
;;
;; `changed?` is liveness_scan's change-detection kernel in miniature: four
;; buffers plus a base offset, an inner loop that compares two elements per
;; word, and a copy-back afterwards that keeps every buffer and the base live
;; ACROSS that loop. The pressure that creates is the point -- it spills both
;; loop-invariant `base`-relative addresses LICM hoists into the preheader, and
;; it spills the two compared elements.
;;
;; Before this packet the inner loop emitted, per compare:
;;     movq (%rA,%rI,8), %rL      ; the other operand
;;     movq %rL, EM0(%rsp)        ; emergency-save the base scratch
;;     movq %rO, EM1(%rsp)        ; emergency-save the value scratch
;;     movq SPILL(%rsp), %rL      ; stage the hoisted base
;;     movq (%rL,%rI,8), %rO      ; load the element
;;     movq %rO, SLOT(%rsp)       ; store it to its home
;;     movq EM1(%rsp), %rO        ; emergency-restore
;;     movq EM0(%rsp), %rL        ; emergency-restore
;;     cmpq SLOT(%rsp), %rL       ; compare against the slot just written
;; nine instructions where three suffice, and the give-away is the last line:
;; a compare reading back the slot the line four above it had just written.
;;
;; Two independent refusals produced that. Slot coloring merged the two
;; compares' loaded values onto one representative id, so the use count the
;; emitter recomputes on the remapped blocks was 2 and every M6 probe declined
;; on `single-use?`; and even single-use, M6-D took its one staging register
;; from the load destination's own register home, which a SPILLED destination
;; does not have. With the loaded value pinned out of slot sharing and the
;; staging register peeked from the scavenger, the compare folds:
;;     movq SPILL(%rsp), %rT
;;     cmpq (%rT,%rI,8), %rL
;; and the loaded element never materialises at all.
;;
;; `refused` is the nearest neighbour the fold must NOT take: it reads the
;; loaded element a second time (folding it into the sum), so the value is
;; genuinely needed after the compare, is not single-use, and must keep its own
;; home. Its assembly still contains the store-then-compare-the-slot shape, and
;; that is correct there.
;;
;; The never-taken self-recursion keeps both functions out of the opt2 inliner
;; so each shape stays in its own frame. `main` runs the two over the same data
;; and returns 42 only when they agree on every case, so a fold that dropped,
;; reordered or mis-addressed a load fails the runtime test as well as the
;; assembly-shape gate in scripts/verify-asm-shape-gates.sh.
(define (changed?
  [a : (__tl_dyn-array i64)]
  [b : (__tl_dyn-array i64)]
  [c : (__tl_dyn-array i64)]
  [d : (__tl_dyn-array i64)]
  [base : i64]
  [n : i64]
  [poke : i64]) : i64
  (if (< poke 0)
    (changed? a b c d base n (+ poke 1))
    (let
      [i : i64 0]
      [hit : i64 0]
      (begin
        (while (and (< i n) (= hit 0))
          (begin
            (when
              (or
                (!= (array-ref a i) (array-ref b (+ base i)))
                (!= (array-ref c i) (array-ref d (+ base i))))
              (set! hit 1))
            (set! i (+ i 1))))
        (when
          (= hit 1)
          (let
            [k : i64 0]
            (while (< k n)
              (begin
                (set! (array-ref b (+ base k)) (array-ref a k))
                (set! (array-ref d (+ base k)) (array-ref c k))
                (set! k (+ k 1))))))
        hit))))

;; Nearest refused neighbour: the loaded element is read twice, so it is not
;; single-use, the fold cannot retire it, and it keeps a home of its own.
(define (refused
  [a : (__tl_dyn-array i64)]
  [b : (__tl_dyn-array i64)]
  [c : (__tl_dyn-array i64)]
  [d : (__tl_dyn-array i64)]
  [base : i64]
  [n : i64]
  [poke : i64]) : i64
  (if (< poke 0)
    (refused a b c d base n (+ poke 1))
    (let
      [i : i64 0]
      [hit : i64 0]
      [sum : i64 0]
      (begin
        (while (and (< i n) (= hit 0))
          (begin
            (when
              (or
                (!= (array-ref a i) (array-ref b (+ base i)))
                (!= (array-ref c i) (array-ref d (+ base i))))
              (set! hit 1))
            (set! sum (+ sum (array-ref b (+ base i))))
            (set! sum (+ sum (array-ref d (+ base i))))
            (set! i (+ i 1))))
        (when
          (= hit 1)
          (let
            [k : i64 0]
            (while (< k n)
              (begin
                (set! (array-ref b (+ base k)) (array-ref a k))
                (set! (array-ref d (+ base k)) (array-ref c k))
                (set! k (+ k 1))))))
        (if (< sum 0)
          (- 0 hit)
          hit)))))

(define (main) : i64
  (let
    [a : (__tl_dyn-array i64) (array.make-array i64 8)]
    [b : (__tl_dyn-array i64) (array.make-array i64 16)]
    [c : (__tl_dyn-array i64) (array.make-array i64 8)]
    [d : (__tl_dyn-array i64) (array.make-array i64 16)]
    [ok : i64 0]
    [trial : i64 0]
    (begin
      (while (< trial 4)
        (let
          [i : i64 0]
          [left : i64 0]
          [right : i64 0]
          (begin
            (while (< i 8)
              (begin
                (set! (array-ref a i) i)
                (set! (array-ref c i) (* i 3))
                (set! i (+ i 1))))
            (set! i 0)
            (while (< i 16)
              (begin
                (set! (array-ref b i) 0)
                (set! (array-ref d i) 0)
                (set! i (+ i 1))))
            (when
              (> trial 0)
              (let
                [k : i64 0]
                (while (< k 8)
                  (begin
                    (set! (array-ref b (+ 8 k)) (array-ref a k))
                    (set! (array-ref d (+ 8 k)) (array-ref c k))
                    (set! k (+ k 1))))))
            (set! left (changed? a b c d 8 (* trial 2) 0))
            (set! i 0)
            (while (< i 16)
              (begin
                (set! (array-ref b i) 0)
                (set! (array-ref d i) 0)
                (set! i (+ i 1))))
            (when
              (> trial 0)
              (let
                [k : i64 0]
                (while (< k 8)
                  (begin
                    (set! (array-ref b (+ 8 k)) (array-ref a k))
                    (set! (array-ref d (+ 8 k)) (array-ref c k))
                    (set! k (+ k 1))))))
            (set! right (refused a b c d 8 (* trial 2) 0))
            (when (= left right) (set! ok (+ ok 1)))
            (set! trial (+ trial 1)))))
      (if (= ok 4)
        42
        1))))