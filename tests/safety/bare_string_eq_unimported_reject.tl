;; Without `(import stdlib.string)` the bare `string-eq` spelling is unbound
;; (#7957).
(define (main) : i64
  (if (string-eq "ab" "ab")
    42
    1))