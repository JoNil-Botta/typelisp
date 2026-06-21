; A string literal is an immutable fat { ptr, len } value whose bytes live in
; .rodata. `string-length` reads the len field. "hello" is 5 bytes, so the
; program exits with status 5.
(import "stdlib/string.tl")

(define (main) : i64
  (string-length "hello"))
