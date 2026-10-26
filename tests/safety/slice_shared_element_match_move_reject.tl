;; Matching a Slice element by value moves it out of the slice, as matching a
;; fixed array element read through a reference does (#8449, #8695).
(import stdlib.string)

(defenum MaybeText
  (Some String)
  (No))

(define (first-len [s : (& s (Slice MaybeText))]) : i64
  (match (array-ref s 0)
    [(MaybeText.Some text) (string.string-length (& text))]
    [(MaybeText.No) 0]))

(define (main) : i64
  42)