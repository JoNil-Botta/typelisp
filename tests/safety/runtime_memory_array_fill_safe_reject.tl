;; The former array-slot fill helper has been removed.
(import stdlib.runtime)

(define (main) : i64
  (begin
    (runtime.array-fill8 (ptr-null : (MutPtr u8)) 1 (cast 0 : u64))
    0))