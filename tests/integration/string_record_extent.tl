; Multiple object String records exercise empty, unaligned, and alignment-boundary
; payload extents.  The globals add addressable data relocations after the
; string backing records; direct-object and assembly routes must both return 42.
(define empty-text : String
  "")
(define short-text : String
  "abc")
(define aligned-text : String
  "wxyz")
(define base : i64
  35)

(define (main) : i64
  (+
    base
    (+
      (__tl_string_length empty-text)
      (+ (__tl_string_length short-text) (__tl_string_length aligned-text)))))