(import stdlib.comptime)

(defmacro (emit-payload) : Decls
  `(define payload : (__tl_dyn-array u8)
    ,(comptime.expr-binary-data "owned-payload")))

(emit-payload)

(define (main) : i64
  (if (= (cast (array-ref payload 0) : i64) 111)
    42
    1))