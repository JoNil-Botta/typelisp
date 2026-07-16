(import stdlib.comptime)
(import "include_str_comptime_owner.tl" module include.str.comptime.owner as owner)

(include-str-comptime source-bytes "include_str_comptime_payload.txt")

(defmacro (emit-payload [source : comptime.Expr]) : Decls
  `(define payload : (Array u8)
    ,(comptime.expr-binary-data (comptime.expr-string-value source))))

(emit-payload (source-bytes))

(defmacro (emit-binary-payload [source : comptime.Expr]) : Decls
  `(define binary-payload : (Array u8)
    ,(comptime.expr-binary-data (comptime.expr-string-value source))))

(emit-binary-payload (owner.binary-source-bytes))

(defmacro (emit-empty-payload) : Decls
  `(define empty-payload : (Array u8)
    ,(comptime.expr-binary-data "")))

(emit-empty-payload)

(define (main) : i64
  (if (and
    (= (array-length payload) 19)
    (= (cast (array-ref payload 0) : i64) 109)
    (= (cast (array-ref payload 17) : i64) 100)
    (= (cast (array-ref payload 18) : i64) 10)
    (= (array-length binary-payload) 6)
    (= (cast (array-ref binary-payload 0) : i64) 0)
    (= (cast (array-ref binary-payload 1) : i64) 65)
    (= (cast (array-ref binary-payload 2) : i64) 127)
    (= (cast (array-ref binary-payload 3) : i64) 128)
    (= (cast (array-ref binary-payload 4) : i64) 255)
    (= (cast (array-ref binary-payload 5) : i64) 10)
    (= (array-length empty-payload) 0))
    42
    1))