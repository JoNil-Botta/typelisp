(import stdlib.runtime)

(define (forward-exit [code : i64]) : never
  (runtime.os-exit code))

(define (main) : i64
  (let
    [code : i64 0]
    (forward-exit
      (begin
        (set! code 42)
        code))
    1))