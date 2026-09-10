;; Unsafe declaration effects cannot be erased into an ordinary function value.
(import stdlib.fs)

(define (main) : i64
  (let
    [read-field : (-> (MutPtr u8) i64 i64)
      (unsafe
        fs.metadata-read-i64-at)]
    (read-field (ptr-null : (MutPtr u8)) 0)))