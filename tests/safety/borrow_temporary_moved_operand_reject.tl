;: The operand of a borrowed temporary is a by-value position: a non-Copy
;: place it names moves into the temporary.
(import stdlib.string)

(defstruct Named
  (name String)
  (n i64))

(define (score [n : (& Named)]) : i64
  n.n)

(define (main) : i64
  (let
    [name : String (string.concat "a" "b")]
    (+ (score (& (Named name 1))) (string.string-length name))))