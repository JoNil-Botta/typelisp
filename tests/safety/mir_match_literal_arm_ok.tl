;; A match without an expected type whose arms are a payload read and a bare
;; literal: the literal takes the other arm's type, as legacy typing retypes it.
(defenum Carrier
  (Wide (Tuple i64 i64))
  (None))

(define (main) : i64
  (let
    [c : Carrier (Carrier.Wide (tuple 1 4))]
    (if (=
      (match c
        [(Carrier.Wide w) (tuple-ref w 1)]
        [(Carrier.None) 0])
      4)
      42
      1)))