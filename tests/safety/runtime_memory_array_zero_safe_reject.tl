;; The virgin-arena zero helper additionally requires fresh allocator storage.
(import stdlib.runtime)

(define (main) : i64
  (begin
    (runtime.array-zero (ptr-null : (MutPtr u8)) 64)
    0))