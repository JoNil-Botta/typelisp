(define (main) : i64
  (let
    [pair : (Tuple (Box i64) i64) (tuple (box 1) 41)]
    [taken : (Box i64) (tuple-ref pair 0)]
    [whole : (Tuple (Box i64) i64) pair]
    (+ (deref taken) (tuple-ref whole 1))))