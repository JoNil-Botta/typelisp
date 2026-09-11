;; Raw read-modify-write operations require an explicit storage-validity proof.
(import stdlib.runtime)

(define (main) : i64
  (runtime.atomic-i64-fetch-add-ptr! (ptr-null : (MutPtr i64)) 1))