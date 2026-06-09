;; #2386 regression guard: `try` over a 16-byte register-resident result enum.
;; The try tag/payload reads addressed the operand as memory while the operand
;; lowered to its packed register-group value (SIGSEGV), and the err return
;; path returned a heap pointer where callers expect the enum in registers.
;; Exercises both the ok path (35) and the propagated err path (7).
(defenum ResI
  (OkI i64)
  (ErrI i64))

(define (half [n : i64]) : ResI
  (if (= n 0)
    (ErrI 7)
    (OkI (/ n 2))))

(define (run [n : i64]) : ResI
  (let
    [v : i64 (try (half n))]
    (OkI (+ v 1))))

(define (main) : i64
  (+
    (match (run 68)
      [(OkI v) v]
      [(ErrI _) 100])
    (match (run 0)
      [(OkI _) 100]
      [(ErrI e) e])))