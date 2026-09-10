;; Import aliases preserve the unsafe effect on raw directory/C-string helpers.
(import stdlib.fs as disk)

(define (main) : i64
  (disk.c-string-byte (ptr-null : (Ptr u8)) 0))