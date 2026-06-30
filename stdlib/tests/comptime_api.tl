(import stdlib.string)
(import stdlib.comptime)

(defmacro (stdlib-comptime-id [x : comptime.Expr]) : i64
  x)

(defmacro (stdlib-comptime-first-or-zero [args : comptime.Expr ...]) : i64
  (if (comptime.expr-list-empty? args)
    (comptime.expr-int 0)
    (comptime.expr-list-head args)))

(defmacro (stdlib-comptime-match-int-or-zero [x : comptime.Expr]) : i64
  (match x
    [(comptime.ExprInt _) x]
    [_ (comptime.expr-int 0)]))

(defmacro (stdlib-comptime-arg-count [args : comptime.Expr ...]) : i64
  (comptime.expr-int (comptime.expr-list-length args)))

(cfg
  feature-comptime-public-fields
  (defmacro (stdlib-comptime-public-field-count [args : comptime.Expr ...]) : i64
    (comptime.expr-int (struct-get args len))))

(cfg
  feature-comptime-public-fields
  (defmacro (stdlib-comptime-public-field-second [args : comptime.Expr ...]) : i64
    (if (> (struct-get args len) 1)
      (__tl_array-ref (struct-get args items) 1)
      (comptime.expr-int 0))))

(defmacro (stdlib-comptime-clause-count [arms : comptime.ExprClause ...]) : i64
  (comptime.expr-int
    (comptime.expr-list-length (comptime.expr-clause-list->expr-list arms))))

(cfg
  feature-comptime-public-fields
  (defmacro (stdlib-comptime-public-clause-count
    [arms : comptime.ExprClause ...]) : i64
    (comptime.expr-int (struct-get arms len))))

(cfg
  feature-comptime-public-fields
  (defmacro (stdlib-comptime-public-clause-first-result
    [arms : comptime.ExprClause ...]) : i64
    (if (> (struct-get arms len) 0)
      (match (__tl_array-ref (struct-get arms items) 0)
        [(ExprClause _ result) result])
      (comptime.expr-int 0))))

(defmacro (stdlib-comptime-clause-else-value [arm : comptime.ExprClause]) : i64
  (match arm
    [(ExprClause test result)
      (match test
        [(ExprVar name)
          (if (string.string-eq name "else")
            result
            (comptime.expr-int 0))]
        [_ (comptime.expr-int 0)])]))

(defmacro (stdlib-comptime-quoted-dense-second) : i64
  (match (quote (stdlib-comptime-quoted-dense-source 5 37))
    [(comptime.ExprCall _ args)
      (if (= (struct-get args len) 2)
        (__tl_array-ref (struct-get args items) 1)
        (comptime.expr-int 0))]
    [_ (comptime.expr-int 0)]))

(defmacro (stdlib-comptime-spliced-dense-second [args : comptime.Expr ...]) : i64
  (match `(stdlib-comptime-spliced-dense-source ,@args)
    [(comptime.ExprCall _ operands)
      (if (= (struct-get operands len) 2)
        (__tl_array-ref (struct-get operands items) 1)
        (comptime.expr-int 0))]
    [_ (comptime.expr-int 0)]))

(cfg
  feature-comptime-public-fields
  (defmacro (stdlib-comptime-public-binding-init
    [bindings : comptime.ExprBindingClause ...]) : i64
    (if (> (struct-get bindings len) 0)
      (let
        [first : comptime.ExprBindingClause
          (__tl_array-ref (struct-get bindings items) 0)]
        (if (string.string-eq (struct-get first name) "value")
          (struct-get first init)
          (comptime.expr-int 0)))
      (comptime.expr-int 0))))

(defmacro (stdlib-comptime-derived-name [prefix : comptime.Expr]) : i64
  (match prefix
    [(comptime.ExprVar base)
      (comptime.expr-var
        (comptime.string-concat
          (comptime.string-append base (comptime.int->string 0))
          "-value"))]
    [_ (comptime.expr-int 0)]))

(defmacro (stdlib-comptime-derived-string [prefix : comptime.Expr]) : String
  (match prefix
    [(comptime.ExprVar base)
      (comptime.expr-string (comptime.string-append base "-literal"))]
    [_ (comptime.expr-string "")]))

(defmacro (stdlib-comptime-string-helper-total [prefix : comptime.Expr]) : i64
  (match prefix
    [(ExprVar base)
      (comptime.expr-int
        (+
          (string-length base)
          (+
            (length base)
            (+
              (string->int "7")
              (if (string.string-eq base "stdlib-comptime-derived")
                (if (string=? base "stdlib-comptime-derived")
                  (if (=
                    (cast (string-ref base 0) : i64)
                    (cast (char-at base 0) : i64))
                    1
                    0)
                  0)
                0)))))]
    [_ (comptime.expr-int 0)]))

(defmacro (stdlib-comptime-error-unreached [x : comptime.Expr]) : i64
  (if false
    (comptime.comptime-error "unreached stdlib comptime error")
    x))

(define (stdlib-comptime-qualified-import-shape) : i64
  (+
    (stdlib-comptime-id 14)
    (+
      (stdlib-comptime-first-or-zero 14 100)
      (stdlib-comptime-match-int-or-zero 14))))

(define (stdlib-comptime-qualified-helper-shape) : i64
  (+
    (stdlib-comptime-arg-count 1 2 3)
    (+ (stdlib-comptime-clause-count [false 0] [true 0] [false 0]) 36)))

(cfg
  feature-comptime-public-fields
  (define (stdlib-comptime-public-field-shape) : i64
    (+
      (stdlib-comptime-public-field-count 1 2 3)
      (+ (stdlib-comptime-public-field-second 1 20) 19))))

(cfg
  feature-comptime-public-fields
  (define (stdlib-comptime-public-clause-field-shape) : i64
    (+
      (stdlib-comptime-public-clause-count [false 40] [true 0])
      (stdlib-comptime-public-clause-first-result [false 40] [true 0]))))

(cfg
  feature-comptime-public-fields
  (define (stdlib-comptime-public-binding-field-shape) : i64
    (stdlib-comptime-public-binding-init [value 42])))

(define (stdlib-comptime-clause-match-shape) : i64
  (+ (stdlib-comptime-clause-else-value [else 6]) 36))

(define (stdlib-comptime-quote-dense-shape) : i64
  (+ (stdlib-comptime-quoted-dense-second) 5))

(define (stdlib-comptime-splice-dense-shape) : i64
  (+ (stdlib-comptime-spliced-dense-second 10 32) 10))

(define (stdlib-comptime-qualified-string-helper-shape) : i64
  (let
    [stdlib-comptime-derived0-value : i64 42]
    (+
      stdlib-comptime-derived0-value
      (stdlib-comptime-derived-name stdlib-comptime-derived))))

(define (stdlib-comptime-derived-string-shape) : bool
  (string.string-eq
    (stdlib-comptime-derived-string stdlib-comptime-derived)
    "stdlib-comptime-derived-literal"))

(define (stdlib-comptime-legacy-string-helper-shape) : i64
  (stdlib-comptime-string-helper-total stdlib-comptime-derived))

(define (stdlib-comptime-error-branch-shape) : i64
  (stdlib-comptime-error-unreached 42))

(test
  comptime-qualified-import-shape
  (if (= (stdlib-comptime-qualified-import-shape) 42)
    unit
    (begin
      (/ 1 0)
      unit)))

(test
  comptime-qualified-helper-shape
  (if (= (stdlib-comptime-qualified-helper-shape) 42)
    unit
    (begin
      (/ 1 0)
      unit)))

(cfg
  feature-comptime-public-fields
  (test
    comptime-public-field-shape
    (if (= (stdlib-comptime-public-field-shape) 42)
      unit
      (begin
        (/ 1 0)
        unit))))

(cfg
  feature-comptime-public-fields
  (test
    comptime-public-clause-field-shape
    (if (= (stdlib-comptime-public-clause-field-shape) 42)
      unit
      (begin
        (/ 1 0)
        unit))))

(cfg
  feature-comptime-public-fields
  (test
    comptime-public-binding-field-shape
    (if (= (stdlib-comptime-public-binding-field-shape) 42)
      unit
      (begin
        (/ 1 0)
        unit))))

(test
  comptime-clause-match-shape
  (if (= (stdlib-comptime-clause-match-shape) 42)
    unit
    (begin
      (/ 1 0)
      unit)))

(test
  comptime-quote-dense-shape
  (if (= (stdlib-comptime-quote-dense-shape) 42)
    unit
    (begin
      (/ 1 0)
      unit)))

(test
  comptime-splice-dense-shape
  (if (= (stdlib-comptime-splice-dense-shape) 42)
    unit
    (begin
      (/ 1 0)
      unit)))

(test
  comptime-qualified-string-helper-shape
  (if (= (stdlib-comptime-qualified-string-helper-shape) 84)
    unit
    (begin
      (/ 1 0)
      unit)))

(test
  comptime-derived-string-shape
  (if (stdlib-comptime-derived-string-shape)
    unit
    (begin
      (/ 1 0)
      unit)))

(test
  comptime-legacy-string-helper-shape
  (if (= (stdlib-comptime-legacy-string-helper-shape) 54)
    unit
    (begin
      (/ 1 0)
      unit)))

(test
  comptime-error-branch-shape
  (if (= (stdlib-comptime-error-branch-shape) 42)
    unit
    (begin
      (/ 1 0)
      unit)))