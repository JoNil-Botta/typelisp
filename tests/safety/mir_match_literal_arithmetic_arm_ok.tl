;; Without an expected type, a match arm typed by literal defaulting alone
;; (`(- 0 1)`) takes the other arms' type, as legacy typing retypes it
;; (#8449 M5).
(defenum Lookup
  (Found i64)
  (Missing))

(define (found-42? [l : Lookup]) : bool
  (=
    (match l
      [(Lookup.Found n) n]
      [(Lookup.Missing) (- 0 1)])
    42))

(define (main) : i64
  (if (and (found-42? (Lookup.Found 42)) (not (found-42? (Lookup.Missing))))
    42
    1))