;; Raw fill storage and extent obligations cannot be assumed by safe source.
(import stdlib.runtime)

(define (main) : i64
  (begin
    (runtime.mem-fill8 (ptr-null : (MutPtr u8)) 1 (cast 0 : u64))
    0))