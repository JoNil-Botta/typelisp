(import "stdlib/io.tl")

;; CORRECTNESS TEST for M-G2b's write-back path. w loses the CSR competition
;; (6 refs/iteration vs 7+ for acc/i/a/b/c) and its call-free region right
;; after probe(i) READS the old value twice (`acc += w`, `acc += w*i` --
;; unmergeable, so copy-prop cannot collapse them) and then REDEFINES it
;; (`w += i`), so the region needs BOTH the entry reload and the exit store.
;; The new value is read after the second call and -- decisively -- by the
;; NEXT iteration's region entry reload across the back edge. Every M-G2b
;; boundary bug corrupts the checksum:
;;   * a missing exit store leaves the home slot stale for the next
;;     iteration's entry reload (and the post-call read);
;;   * a wrong entry reload feeds a stale w into acc twice per iteration;
;;   * a mis-remapped class member desynchronizes w's register and slot.
;; Deep verification: acc accumulates every intermediate value (including
;; w*i products), so a stale value at ANY iteration changes the closed-form
;; total. Correct both before (w fully spilled) and after (w region-homed)
;; M-G2b -- a reconstruction regression guard, exit code 42 only on the
;; exact total.
;; Recursive on purpose so the leaf inliner cannot delete the calls: probe(x) = x.
(define (probe [x : i64]) : i64
  (if (<= x 0)
    0
    (+ 1 (probe (- x 1)))))

;; NON-TAIL self-recursion (never taken at rounds = 1) keeps wb out of the
;; inliner AND out of opt-tailrec, so the intended CSR-saturated shape occurs
;; in the named function rather than dissolving into main.
(define (wb [w0 : i64] [rounds : i64]) : i64
  (let
    [a : i64 1]
    [b : i64 2]
    [c : i64 3]
    [w : i64 w0]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i 60)
        (begin
          (set! acc (+ acc (probe i)))
          ; call A
          (set! acc (+ acc w))
          ; w's region: use, use, use+def
          (set! acc (+ acc (* w i)))
          (set! w (+ w i))
          (set! acc (+ acc (+ a i)))
          ; a,b,c hot: 7 refs each
          (set! acc (+ acc (+ a 1)))
          (set! acc (+ acc (+ a 2)))
          (set! acc (+ acc (+ a 3)))
          (set! acc (+ acc (* 2 a)))
          (set! a (+ a 1))
          (set! acc (+ acc (+ b i)))
          (set! acc (+ acc (+ b 1)))
          (set! acc (+ acc (+ b 2)))
          (set! acc (+ acc (+ b 3)))
          (set! acc (+ acc (* 2 b)))
          (set! b (+ b 1))
          (set! acc (+ acc (+ c i)))
          (set! acc (+ acc (+ c 1)))
          (set! acc (+ acc (+ c 2)))
          (set! acc (+ acc (+ c 3)))
          (set! acc (+ acc (* 2 c)))
          (set! c (+ c 1))
          (set! acc (+ acc (probe 7)))
          ; call B -- exit store must precede
          (set! acc (+ acc w))
          ; post-call read of the new value
          (set! i (+ i 1))))
      (let
        [r : i64 (+ acc (+ a (+ b (+ c w))))]
        (if (> rounds 1)
          (+ r (wb w0 (- rounds 1)))
          r)))))

(define (main) : i64
  (let
    ;; w0 = 5 when run without args (arg-count = 1); (arg-count) blocks
    ;; constant folding.
    [w0 : i64 (+ 4 (arg-count))]
    [r : i64 (wb w0 1)]
    ;; per iteration t (0..59): a_t = 1+t, b_t = 2+t, c_t = 3+t;
    ;; w_{t+1} = w_t + t, w_0 = 5 -> w_t = 5 + t(t-1)/2;
    ;; sum(w_t) = 300 + 34220 = 34520; sum(w_t * t) = 5*1770
    ;;   + (sum(t^3) - sum(t^2))/2 = 8850 + (3132900 - 70210)/2 = 1540195;
    ;; acc = 1770 + 34520 + 1540195 + sum(12+7t) + sum(18+7t) + sum(24+7t)
    ;;       + 420 + sum(w_t + t)
    ;;     = 1770+34520+1540195+13110+13470+13830+420+36290 = 1653605;
    ;; finals a=61 b=62 c=63 w=1775 -> r = 1655566.
    (if (= r 1655566)
      42
      1)))