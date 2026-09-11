;; An unsafe raw atomic helper cannot be erased into an ordinary function value.
(import stdlib.runtime)

(define (main) : i64
  (let
    [_cas : (-> (MutPtr i32) i32 i32 i32)
      (unsafe
        runtime.atomic-i32-cas-ptr!)]
    0))