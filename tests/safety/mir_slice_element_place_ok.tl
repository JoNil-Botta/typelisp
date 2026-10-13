;; An element of a shared slice is a place of the slice's referent: it is
;; borrowed for `clone` and read in a loop without moving it.
(import stdlib.string)

(define (total-length [texts : (& texts (Slice String))]) : i64
  (let
    [index : i64 0]
    [total : i64 0]
    (begin
      (while (< index (array-length texts))
        (let
          [copy : String (clone (array-ref texts index))]
          (begin
            (set! total (+ total (string.string-length copy)))
            (set! index (+ index 1)))))
      total)))

(define (main) : i64
  (let
    [texts : (Array String 2)
      (array "forty-" "two-characters-long-text-here!!")]
    (+ (total-length (slice-view texts 0 2)) 5)))