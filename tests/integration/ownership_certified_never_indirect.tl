(import stdlib.runtime)

(define (wrong-exit [_code : i64]) : never
  (runtime.os-exit 1))

(define (invoke [func : (-> i64 never)] [other : (-> i64 never)]) : never
  (func
    (begin
      (set! func other)
      42)))

(define (main) : i64
  (invoke runtime.os-exit wrong-exit))