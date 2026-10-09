;; #8776: a with-escape body allocation stored into an outer local would dangle
;; once the scratch arena rewinds.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [scratch (arena.make)]
    [s : String ""]
    (with-escape scratch (set! s (string.int->string 1234567)) 0)
    (with-escape scratch (string.string-length (string.int->string 7777777)))
    (if (string.eq (& s) "1234567")
      100
      7)))