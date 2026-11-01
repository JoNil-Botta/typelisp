;: Binding a move-only field in a struct pattern moves it out of the place, so
;: the field cannot be used again (the rest of the struct stays usable).
(import stdlib.string)

(defstruct Pair
  (name String)
  (count i64))

(define (take [s : String]) : i64
  (string.string-length (& s)))

(define (main) : i64
  (let
    [pair : Pair (Pair (string.copy "ab") 40)]
    (begin
      (match pair
        [(Pair name _) (take name)])
      (take pair.name))))