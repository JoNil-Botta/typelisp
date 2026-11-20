;; #8985: a fixed array of arena Strings cannot be stored into an outer local.
(import stdlib.arena)
(import stdlib.string)

(define (main) : i64
  (let
    [k : (Array String 2) (array "" "")]
    (begin
      (with-arena
        r
        (let
          [s (string.int->string 1)]
          [u (string.int->string 2)]
          (set! k (array s u))))
      (+ 40 (string.string-length (& (array-ref k 0)))))))