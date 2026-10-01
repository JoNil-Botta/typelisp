;; compile_profile_macro_pool_prepare.tl - Fixture for preparing a declaration
;; macro transformer's pools (#7937). One declaration macro fires many times,
;; with arguments whose normalisation expands other macros first, through a
;; nested declaration macro and through a splice of several declarations.
;; `main` returns 42 only if every generated function is present and correct.
(import stdlib.str_cat as sc)
(import stdlib.string)

;; One function returning the value of an arbitrary argument expression. Its
;; body expands expression macros too, so each fire prepares several
;; transformers.
(defmacro (define-value-fn [name : Expr] [value : Expr]) : Decls
  `(begin
    (define (,name) : i64
      (cond
        [(and true (or false true) (not (and false true))) ,value]
        [else (string.string-length (sc.str-cat "un" "reached"))]))))

;; A nested expansion: one declaration macro whose output fires another.
(defmacro (define-twin-fns [left : Expr] [right : Expr] [value : Expr]) : Decls
  `(begin
    (define-value-fn ,left ,value)
    (define-value-fn ,right (+ ,value 1))))

;; A splice: one declaration macro producing several declarations at once.
(defmacro (define-string-fns [name : Expr] [len-name : Expr]) : Decls
  `(begin
    (define (,name) : String
      (sc.str-cat "po" "ol"))
    (define (,len-name) : i64
      (string.string-length (,name)))))

(define-value-fn v00 0)

(define-value-fn v01 (+ 0 1))

(define-value-fn
  v02
  (if (and true (or false true))
    2
    0))

(define-value-fn v03 (cond [false 0] [else 3]))

(define-value-fn v04 (string.string-length (sc.str-cat "ab" "cd")))

(define-value-fn v05 (+ 2 3))

(define-value-fn
  v06
  (if (or false (and true true))
    6
    0))

(define-value-fn v07 (cond [(and true false) 0] [else 7]))

(define-value-fn v08 (string.string-length (sc.str-cat "ab" "cd" "ef" "gh")))

(define-value-fn v09 9)

(define-value-fn v10 (+ 5 5))

(define-value-fn
  v11
  (if (and true true)
    11
    0))

(define-value-fn v12 (cond [false 0] [(or false true) 12] [else 0]))

(define-value-fn v13 (+ (string.string-length (sc.str-cat "a" "b")) 11))

(define-value-fn v14 14)

(define-value-fn v15 (+ 7 8))

(define-twin-fns
  t0
  t1
  (if (or false true)
    20
    0))

(define-twin-fns t2 t3 (cond [false 0] [else 30]))

(define-string-fns pool-text pool-text-length)

(define (value-sum) : i64
  (+
    (+ (v00) (v01) (v02) (v03) (v04) (v05) (v06) (v07))
    (+ (v08) (v09) (v10) (v11) (v12) (v13) (v14) (v15))))

(define (main) : i64
  (if (and
    (= (value-sum) 120)
    (= (t0) 20)
    (= (t1) 21)
    (= (t2) 30)
    (= (t3) 31)
    (string.eq (pool-text) "pool")
    (= (pool-text-length) 4))
    42
    1))