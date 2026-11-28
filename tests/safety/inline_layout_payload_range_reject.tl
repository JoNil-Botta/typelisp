(defenum TooLarge
  (Large (Array u8 9223372036854775800)))

(define (main) : i64
  (length (make-array TooLarge 1)))