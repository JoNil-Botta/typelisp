;; Unsafe raw-copy effects cannot be erased into an ordinary function value.
(import stdlib.runtime)

(define (main) : i64
  (let
    [_copy : (-> (MutPtr u8) (Ptr u8) i64 unit)
      (unsafe
        runtime.mem-copy-fwd)]
    0))