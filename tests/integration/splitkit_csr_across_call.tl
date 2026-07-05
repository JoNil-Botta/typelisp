(import stdlib.io)

;; FORCING / SOUNDNESS test for SplitKit M5 -- CSR-ACROSS-THE-CALL via occupant
;; liberation (design 3.2). A call-spanning value V is used AFTER a real
;; (non-inlinable) call. Without a callee-saved home, V is reloaded from its slot
;; after EVERY call crossing (the one reload the #153 reload-elision peephole cannot
;; elide -- the call clobbers the caller-saved reload). M5 keeps V in a CSR across
;; the call, so the post-call uses read the register, not the slot.
;;
;; `clobber` is self-recursive so the opt-2 leaf-inliner cannot inline it and delete
;; the call; it clobbers every caller-saved register (clobber(k) = k+1 for k >= 0).
;;
;; SHAPE (occupant liberation forcing):
;;   a,b,c,d  : used AFTER every call for the WHOLE function -> call-spanning across
;;              all phases -> they occupy 4 of the 5 CSRs the whole function.
;;   hot      : a value born BEFORE call2, used HEAVILY (many times) AFTER call2 in a
;;              straight-line region. It is call-spanning across call2 and, with only
;;              the 5th CSR available, wants it across the call.
;;   occ      : occupies the 5th CSR but is COLD across `hot`'s crossing region -- it
;;              is defined early, used once at the very end, and merely live-through
;;              (no uses) over hot's post-call2 region. To give `hot` a CSR across
;;              call2, M5 must LIBERATE occ's CSR: store occ before the region, keep
;;              hot in that CSR across call2, reload occ after. (In Phase-1-only
;;              builds where occ's CSR is not liberated, hot uses whatever CSR is
;;              free or reloads per use -- still CORRECT, just fewer reloads saved.)
;;
;; CORRECTNESS GUARD: closed form computed by hand and seeded from (io.arg-count) so the
;; optimizer cannot constant-fold the calls away. If the allocator mis-models the
;; occupant liberation (reloads a stale slot, clobbers hot across call2, or fails to
;; reload occ after the region), the sum is wrong -> exit 1.
(define (clobber [x : i64]) : i64
  (if (<= x 0)
    1
    (+ 1 (clobber (- x 1)))))

(define (csr [n : i64]) : i64
  (let
    [a : i64 (+ n 1)]
    [b : i64 (+ n 2)]
    [c : i64 (+ n 3)]
    [d : i64 (+ n 4)]
    [occ : i64 (+ n 5)]
    [hot : i64 0]
    [acc : i64 0]
    (begin
      ;; phase 1: call1; a,b,c,d,occ all live across it (5 CSRs).
      (set! acc (+ acc (clobber n)))
      (set! acc (+ acc (+ a (+ b (+ c (+ d occ))))))
      ;; phase 2: hot born; call2; hot used MANY times after call2. occ is NOT used
      ;; here -> cold/live-through across hot's post-call2 region (its CSR is the
      ;; liberation candidate). a,b,c,d still live across call2.
      (set! hot (+ n 100))
      (set! acc (+ acc (clobber n)))
      (set! acc (+ acc (+ a (+ b (+ c d)))))
      (set! acc (+ acc hot))
      (set! acc (+ acc hot))
      (set! acc (+ acc hot))
      (set! acc (+ acc hot))
      ;; phase 3: occ used once at the very end (its only late use).
      (set! acc (+ acc (clobber n)))
      (set! acc (+ acc occ))
      acc)))

(define (main) : i64
  (let
    [n : i64 (io.arg-count)]
    [r : i64 (csr n)]
    ;; a+b+c+d+occ = 5n+15 ; (clobber n)=n+1 each of 3 calls = 3n+3
    ;; a+b+c+d = 4n+10 ; 4*hot = 4n+400 ; occ = n+5
    ;; total = (5n+15)+(3n+3)+(4n+10)+(4n+400)+(n+5) = 17n+433
    [expected : i64 (+ (* 17 n) 433)]
    (if (= r expected)
      42
      1)))