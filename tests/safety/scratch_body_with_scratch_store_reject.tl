;; #8776: a with-scratch body allocation stored into an outer local would dangle
;; once the scratch arena is destroyed.
(import stdlib.string)

(define (main) : i64
  (let
    [s : String ""]
    (with-scratch (set! s (string.int->string 1234567)) 0)
    (with-scratch (string.string-length (string.int->string 7777777)))
    (if (string.eq (& s) "1234567")
      100
      7)))