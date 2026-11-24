;; The opaque type's module family keeps every reflection query (#8735).
(import opaque_dep.reflect)

(define (main) : i64
  (+ (reflect.connection-facts) 31))