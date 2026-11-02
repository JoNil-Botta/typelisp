;; Elided signatures retain the same call-result lifetime (#8897).
(define (forward [value : (&mut i64)]) : (&mut i64)
  value)

(define (main) : i64
  (let
    [value : i64 0]
    [reference : (&mut value i64) (forward (&mut value))]
    (set! (deref reference) 42)
    value))