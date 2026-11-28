;; The last byte of this layout is tail padding. Checking the program
;; computes the extent without reserving any storage.
(defstruct Edge
  (first i64)
  (last (Array u8 9223372036854775791)))

(define (main) : i64
  (+
    (length (make-array Edge 1))
    (length (make-array unit 9223372036854775807))))