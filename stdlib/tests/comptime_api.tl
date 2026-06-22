(import "stdlib/comptime.tl" module stdlib.comptime as comptime)

(defmacro (stdlib-comptime-id [x : comptime.Expr]) : i64
  x)

(defmacro (stdlib-comptime-first-or-zero [args : comptime.Expr ...]) : i64
  (if (comptime.expr-list-empty? args)
    (comptime.expr-int 0)
    (comptime.expr-list-head args)))

(defmacro (stdlib-comptime-match-int-or-zero [x : comptime.Expr]) : i64
  (match x
    [(ExprInt _) x]
    [_ (comptime.expr-int 0)]))

(defmacro (stdlib-comptime-arg-count [args : comptime.Expr ...]) : i64
  (comptime.expr-int (comptime.expr-list-length args)))

(defmacro (stdlib-comptime-clause-count [arms : comptime.ExprClause ...]) : i64
  (comptime.expr-int
    (comptime.expr-list-length (comptime.expr-clause-list->expr-list arms))))

(defmacro (stdlib-comptime-clause-else-value [arm : comptime.ExprClause]) : i64
  (match arm
    [(ExprClause test result)
      (match test
        [(ExprVar name)
          (if (string-eq name "else")
            result
            (comptime.expr-int 0))]
        [_ (comptime.expr-int 0)])]))

(defmacro (stdlib-comptime-derived-name [prefix : comptime.Expr]) : i64
  (match prefix
    [(ExprVar base)
      (comptime.expr-var
        (comptime.string-concat
          (comptime.string-append base (comptime.int->string 0))
          "-value"))]
    [_ (comptime.expr-int 0)]))

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
              (if (string-eq base "stdlib-comptime-derived")
                (if (string=? base "stdlib-comptime-derived")
                  (if (=
                    (cast (string-ref base 0) : i64)
                    (cast (char-at base 0) : i64))
                    1
                    0)
                  0)
                0)))))]
    [_ (comptime.expr-int 0)]))

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

(define (stdlib-comptime-clause-match-shape) : i64
  (+ (stdlib-comptime-clause-else-value [else 6]) 36))

(define (stdlib-comptime-qualified-string-helper-shape) : i64
  (let
    [stdlib-comptime-derived0-value : i64 42]
    (+
      stdlib-comptime-derived0-value
      (stdlib-comptime-derived-name stdlib-comptime-derived))))

(define (stdlib-comptime-legacy-string-helper-shape) : i64
  (stdlib-comptime-string-helper-total stdlib-comptime-derived))

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

(test
  comptime-clause-match-shape
  (if (= (stdlib-comptime-clause-match-shape) 42)
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
  comptime-legacy-string-helper-shape
  (if (= (stdlib-comptime-legacy-string-helper-shape) 54)
    unit
    (begin
      (/ 1 0)
      unit)))