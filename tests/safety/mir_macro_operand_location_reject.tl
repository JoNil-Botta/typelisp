;; An ownership error inside a macro's rest operand (`when`'s body) is located
;; in the caller's file, not the macro's.
(import stdlib.string as string)

(define (consume [s : String]) : i64
  (string.string-length (& s)))

(define (main) : i64
  (let
    [s : String (string.copy "abc")]
    [flag : bool true]
    (begin
      (consume s)
      (when flag (return (consume s)))
      42)))