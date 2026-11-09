(define (claim [state : (MutPtr i64)] [generation : i64])
  (:export-symbol "tl_rz_claim") : bool
  (if (ptr-null? state)
    false
    (=
      (unsafe
        (atomic-cas! state generation (+ generation 1)))
      generation)))

(define (empty [value : i64])
  (:export-symbol "tl_rz_empty") : i64
  (if (= value 0)
    0
    (+ value 1)))

(define (main) : i64
  (let
    [cell : i64 10]
    (if (and
      (not (claim (ptr-null : (MutPtr i64)) 10))
      (claim
        (unsafe
          (ptr-addr-of cell))
        10)
      (= cell 11)
      (not
        (claim
          (unsafe
            (ptr-addr-of cell))
          10))
      (= (empty 0) 0)
      (= (empty 41) 42))
      42
      1)))