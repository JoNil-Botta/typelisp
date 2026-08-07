(define (take-first [pair : (& source (Tuple (Box i64) i64))]) : i64
  (let
    [taken : (Box i64) (tuple-ref (deref pair) 0)]
    (deref taken)))

(define (main) : i64
  (let
    [pair : (Tuple (Box i64) i64) (tuple (box 1) 41)]
    (take-first (& pair))))