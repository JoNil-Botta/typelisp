;; An ownership error inside an `and` operand is located in the caller's file.
(import stdlib.string as string)

(define (consume [s : String]) : i64
  (string.string-length (& s)))

(define (main) : i64
  (let
    [s : String (string.copy "abc")]
    [flag : bool true]
    (begin
      (consume s)
      (set! flag (and flag (= (consume s) 1)))
      42)))