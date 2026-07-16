(import stdlib.comptime)

(include-str-comptime source-bytes "include_str_comptime_payload.txt")

(defmacro (emit-payload [source : comptime.Expr]) : Decls
  `(define payload : (Array u8)
    ,(comptime.expr-binary-data (comptime.expr-string-value source))))

(emit-payload (source-bytes))

(define (main) : i64
  (if (and
    (= (array-length payload) 19)
    (= (cast (array-ref payload 0) : i64) 109)
    (= (cast (array-ref payload 17) : i64) 100)
    (= (cast (array-ref payload 18) : i64) 10))
    42
    1))