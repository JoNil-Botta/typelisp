;; Raw C-string scans require the caller to prove a live NUL-terminated range.
(import stdlib.io)

(define (main) : i64
  (io.c-string-length (ptr-null : (Ptr u8))))