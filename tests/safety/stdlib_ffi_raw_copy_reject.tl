;; A helper that writes through a caller's raw pointer is unsafe (#9783).
(import stdlib.ffi)

(define (main) : i64
  (match (ffi.c-string-copy! "abc" (ptr-null : (MutPtr u8)) 4)
    [(ffi.FfiCStringCopyOk _) 0]
    [_ 1]))