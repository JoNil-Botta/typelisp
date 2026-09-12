;; The raw adapter's effect must survive aliases, even within unsafe.
(import stdlib.sync)

(define (main) : i64
  (let
    [_load : (-> i64 i64 i64)
      (unsafe
        sync.atomic-i64-load)]
    0))