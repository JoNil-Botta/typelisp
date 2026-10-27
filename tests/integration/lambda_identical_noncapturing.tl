;; Non-capturing descriptors already use fn@; retain that identity rule too.
(define (main) : i64
  (let
    [f
      (lambda () : i64
        42)]
    [g
      (lambda () : i64
        42)]
    (if (and (= (f) 42) (= (g) 42))
      42
      1)))