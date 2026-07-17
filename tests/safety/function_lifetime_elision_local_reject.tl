(define (main) : i64
  (let
    [value : i64 42]
    [view : (& i64) (& value)]
    (read-ref view)))