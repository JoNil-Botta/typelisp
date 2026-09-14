;; C pointer kinds remain distinct from ordinary function kinds in macro proofs.
(defmacro (c-answer [T : type (:kind c-function)]) : Expr
  (if (= (type-kind T) "c-function")
    `42
    `1))

(defmacro (c-empty [T : type (:kind c-function)]) : Expr
  `(init : ,T))

(defmacro (c-null [T : type (:kind c-function)]) : Expr
  `(ptr-null : ,T))

(define (safe-empty) : (CFunc nullable (-> i64 i64))
  (c-empty (CFunc nullable (-> i64 i64))))

(define (unsafe-empty) : (CFunc unsafe-nullable (-> i64 i64))
  (c-empty (CFunc unsafe-nullable (-> i64 i64))))

(define (main) : i64
  (if (and
    (ptr-null? (c-null (CFunc nullable (-> i64 i64))))
    (ptr-null? (c-null (CFunc unsafe-nullable (-> i64 i64))))
    (ptr-null? (safe-empty))
    (ptr-null? (unsafe-empty))
    (=
      (+
        (+
          (c-answer (CFunc nullable (-> i64 i64)))
          (c-answer (CFunc non-null (-> i64 i64))))
        (+
          (c-answer (CFunc unsafe-nullable (-> i64 i64)))
          (c-answer (CFunc unsafe-non-null (-> i64 i64)))))
      168))
    42
    1))