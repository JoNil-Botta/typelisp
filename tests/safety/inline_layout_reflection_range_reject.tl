(defstruct TooLarge
  (first (Array u8 9223372036854775800))
  (last (Array u8 16)))

(define (main) : i64
  (length (make-array u8 (comptime (size-of (type TooLarge))))))