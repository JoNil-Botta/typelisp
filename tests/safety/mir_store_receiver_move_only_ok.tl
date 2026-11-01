;; A receiver selecting an array of move-only elements writes that array in
;; place; nothing is moved out of it.
(import stdlib.string)

(define (pick [c : bool]) : i64
  (let
    [items : (Array String 1) (array "a")]
    [fixed : (Array String 1) (array "b")]
    (begin
      (set!
        (array-ref
          (if c
            items
            fixed)
          0)
        "cc")
      (+ 40 (string.string-length (& (array-ref items 0)))))))

(define (main) : i64
  (pick true))