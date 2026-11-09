;; #9687: a macro-generated define used by the entry module itself.
(defmacro (gen-def) : Decls
  `(define (gen-helper) : i64
    42))

(gen-def)

(define (main) : i64
  (gen-helper))