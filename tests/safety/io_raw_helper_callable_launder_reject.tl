;; Unsafe I/O helpers cannot be erased into ordinary function values.
(import stdlib.io)

(define (main) : i64
  (let
    [_scan : (-> (Ptr u8) i64)
      (unsafe
        io.c-string-length)]
    0))