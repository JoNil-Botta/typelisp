;; A raw pointer value does not prove live, aligned, initialized i64 storage.
(import stdlib.runtime)

(define (main) : i64
  (runtime.atomic-i64-load-ptr (ptr-null : (Ptr i64))))