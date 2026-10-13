;: A literal placed with `in-arena` into an outer arena from inside a scratch
;: body takes that arena's region and outlives the scratch rewind (#8449: the
;: tag-only difference between body and result left the form unrepresented).
(import stdlib.arena)
(import stdlib.string)

(define (label) : String
  (let
    [home : arena.Arena (arena.current)]
    (with-scratch
      (let
        [message : String (in-arena home "forty-two")]
        message))))

(define (main) : i64
  (let
    [s : String (label)]
    [churn : i64
      (with-scratch (string.string-length (string.int->string 1111111)))]
    (if (and (string.eq (& s) "forty-two") (= churn 7))
      42
      1)))