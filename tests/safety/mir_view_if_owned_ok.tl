;: Joining owned values in an `if` and reading through references stays valid.
(import stdlib.string as string)

(defstruct Names
  (first String)
  (count i64))

(define (pick [names : (& names Names)] [fallback : String] [use-first : bool]) : String
  (if use-first
    (string.copy (& names.first))
    fallback))

(define (main) : i64
  (let
    [names : Names (Names "abc" 1)]
    [picked : String (pick (& names) "fallback" true)]
    (+ 39 (string.string-length (& picked)))))