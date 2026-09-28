;; Helper and builtin spellings with signatures the builtins reject.
(define (eq [left : i64] [right : i64]) : bool
  (= left (+ right 1)))

(define (string-length [n : i64]) : i64
  (* n 2))

(define (array-length [text : String]) : i64
  66)