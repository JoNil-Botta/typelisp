;; Without `(import stdlib.string)` the bare `string-concat` spelling is
;; unbound (#7957), although the runtime prelude defines a private helper of
;; that name.
(define (joined) : String
  (string-concat "ab" "cd"))

(define (main) : i64
  42)