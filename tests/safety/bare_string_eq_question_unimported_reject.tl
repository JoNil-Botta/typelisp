;; Without `(import stdlib.string)` the bare `string=?` spelling is unbound
;; (#7957).
(define (main) : i64
  (if (string=? "ab" "ab")
    42
    1))