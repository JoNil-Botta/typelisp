;; The twin of `clone_read_receiver_retained.tl` where nothing after the
;; receiver writes what it selects: the receiver is lent for the read, not
;; moved or copied, so both arrays stay usable after the call, and the copy is
;; the element of the array the condition selected.
(import stdlib.string)

(define (take-first [texts : (Array String 1)]) : i64
  (string-length (array-ref texts 0)))

(define (copy-lent [a : (Array String 1)] [b : (Array String 1)] [flag : bool]) : i64
  (let
    [copy : String
      (string.copy
        (array-ref
          (if flag
            a
            b)
          0))]
    (+ (* 10 (string-length copy)) (take-first a) (take-first b))))

(define (main) : i64
  (copy-lent (array "abc") (array "ninechars") true))