;: The clone-out itself allocates in the arena active around the form, so a
;: with-scratch of an outer String inside `with-arena r` yields an r-tagged
;: String that cannot leave the region (red-team find f04).
(import stdlib.string)

(define (bad [seed : String]) : String
  (with-arena r (with-scratch seed)))

(define (main) : i64
  (let
    [s (bad "ab")]
    (if (string.eq (& s) "ab")
      42
      7)))