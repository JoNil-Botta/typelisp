;; Raw array-slot fill alignment and writable-range obligations are not safe defaults.
(import stdlib.runtime)

(define (main) : i64
  (begin
    (runtime.array-fill8 (ptr-null : (MutPtr u8)) 1 (cast 0 : u64))
    0))