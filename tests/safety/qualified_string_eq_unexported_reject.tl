;; stdlib.string exports `eq` and `string=?`, not `string-eq` (#7883).
(import stdlib.string)

(define (main) : i64
  (if (string.string-eq "ab" "ab")
    0
    1))