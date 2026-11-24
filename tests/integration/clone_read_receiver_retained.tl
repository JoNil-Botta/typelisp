;; A shared-reference formal borrows an array projection's receiver for the
;; read without moving it, unless the index evaluated after the receiver can
;; write a variable the receiver may select: then the receiver is retained by
;; value, as any operand a later operand can write is, and the callee reads
;; the element selected before the write. Here the index reassigns `a`; the
;; copy is the old element ("seven77", 7 bytes) and `a` holds the new one.
(import stdlib.string)

(define (copy-before-write
  [a : (Array String 1)]
  [b : (Array String 1)]
  [flag : bool]) : i64
  (let
    [copy : String
      (string.copy
        (array-ref
          (if flag
            a
            b)
          (begin
            (set! a (array "99"))
            0)))]
    (if (string.eq (array-ref a 0) "99")
      (string-length copy)
      1)))

(define (main) : i64
  (copy-before-write (array "seven77") (array "eight888") true))