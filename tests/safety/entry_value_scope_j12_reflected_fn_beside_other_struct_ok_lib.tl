;; Helper for entry_value_scope_j12_reflected_fn_beside_other_struct_ok (#9687).
(import stdlib.comptime)

(defmacro (rv [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) (type-nominal-name U))
    (comptime.expr-list-cons (comptime.expr-int 42) (comptime.expr-list-empty))))

(defmacro (rv2 [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) (type-nominal-name U))
    (comptime.expr-list-cons
      (comptime.expr-int 40)
      (comptime.expr-list-cons (comptime.expr-int 2) (comptime.expr-list-empty)))))

(defmacro (rn-make [U : type]) : Expr
  (comptime.module-value-expr (type-nominal-module U) "make"))

(defmacro (rc0-make [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "make")
    (comptime.expr-list-empty)))

(defmacro (rc1-make [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "make")
    (comptime.expr-list-cons (comptime.expr-int 41) (comptime.expr-list-empty))))

(defmacro (rn-Red [U : type]) : Expr
  (comptime.module-value-expr (type-nominal-module U) "Red"))

(defmacro (rc0-Red [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "Red")
    (comptime.expr-list-empty)))

(defmacro (rc1-Red [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "Red")
    (comptime.expr-list-cons (comptime.expr-int 41) (comptime.expr-list-empty))))

(defmacro (rn-Green [U : type]) : Expr
  (comptime.module-value-expr (type-nominal-module U) "Green"))

(defmacro (rc0-Green [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "Green")
    (comptime.expr-list-empty)))

(defmacro (rc1-Green [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "Green")
    (comptime.expr-list-cons (comptime.expr-int 41) (comptime.expr-list-empty))))

(defmacro (rn-show [U : type]) : Expr
  (comptime.module-value-expr (type-nominal-module U) "show"))

(defmacro (rc0-show [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "show")
    (comptime.expr-list-empty)))

(defmacro (rc1-show [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "show")
    (comptime.expr-list-cons (comptime.expr-int 41) (comptime.expr-list-empty))))

(defmacro (rn-limit [U : type]) : Expr
  (comptime.module-value-expr (type-nominal-module U) "limit"))

(defmacro (rc0-limit [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "limit")
    (comptime.expr-list-empty)))

(defmacro (rc1-limit [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "limit")
    (comptime.expr-list-cons (comptime.expr-int 41) (comptime.expr-list-empty))))

(defmacro (rn-inc [U : type]) : Expr
  (comptime.module-value-expr (type-nominal-module U) "inc"))

(defmacro (rc0-inc [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "inc")
    (comptime.expr-list-empty)))

(defmacro (rc1-inc [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "inc")
    (comptime.expr-list-cons (comptime.expr-int 41) (comptime.expr-list-empty))))

(defmacro (rn-getpid [U : type]) : Expr
  (comptime.module-value-expr (type-nominal-module U) "getpid"))

(defmacro (rc0-getpid [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "getpid")
    (comptime.expr-list-empty)))

(defmacro (rc1-getpid [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "getpid")
    (comptime.expr-list-cons (comptime.expr-int 41) (comptime.expr-list-empty))))

(defmacro (rn-helper [U : type]) : Expr
  (comptime.module-value-expr (type-nominal-module U) "helper"))

(defmacro (rc0-helper [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "helper")
    (comptime.expr-list-empty)))

(defmacro (rc1-helper [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "helper")
    (comptime.expr-list-cons (comptime.expr-int 41) (comptime.expr-list-empty))))

(defmacro (rn-ret42 [U : type]) : Expr
  (comptime.module-value-expr (type-nominal-module U) "ret42"))

(defmacro (rc0-ret42 [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "ret42")
    (comptime.expr-list-empty)))

(defmacro (rc1-ret42 [U : type]) : Expr
  (comptime.expr-call
    (comptime.module-value-expr (type-nominal-module U) "ret42")
    (comptime.expr-list-cons (comptime.expr-int 41) (comptime.expr-list-empty))))