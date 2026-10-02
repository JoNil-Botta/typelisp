(defenum Size
  (Small)
  (Large)
  (Huge))

(defenum Op
  (Move i64 Size)
  (Halt))

;; The nested alternatives cover Small and Large but not Huge, so the arm does
;; not cover Move.
(define (dst [op : Op]) : i64
  (match op
    [(Move n (or (Small) (Large))) n]
    [Halt 0]))

(define (main) : i64
  0)