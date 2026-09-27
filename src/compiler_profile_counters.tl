;; compiler_profile_counters.tl - the compile-profile counter registry.
;;
;; Every counter row a compile-profile build reports is one entry of a
;; `defcounters` table:
;;
;;   (cfg
;;     compile-profile
;;     (counters.defcounters
;;       compiler-tc-env-profile
;;       (tc-env-binds "typecheck.env.binds")
;;       (tc-walk-marshal-ns "typecheck.macro.walk_direct_marshal_us" us)))
;;
;; An entry `(name "row")` declares the i64 global `name`. The table gets
;; `<table>-emit!`, which writes one row per entry in table order, and
;; `<table>-reset!`, which zeroes every entry. An optional kind changes the
;; reported value: `us` holds nanoseconds and reports microseconds, `kb` holds
;; bytes and reports kibibytes, and `live` reports the value in the live-delta
;; field of the six-field row instead of the value field.
;;
;; `bump!`, `add!` and `max!` update a counter in compile-profile builds and
;; expand to `unit` in every other build, so counting sites need no cfg.
(import stdlib.comptime)
(cfg compile-profile (import stdlib.io))
(cfg compile-profile (import stdlib.str_cat_runtime as str_cat))
(cfg compile-profile (import stdlib.string))

(cfg
  compile-profile
  (define (profile-counter-row! [row : String] [value : i64]) : unit
    (io.print-error
      (str_cat.str-cat
        "compile-profile|"
        row
        "|"
        (string.int->string value)
        "|0|0|0\n"))))

(cfg
  compile-profile
  (define (profile-counter-live-row! [row : String] [value : i64]) : unit
    (io.print-error
      (str_cat.str-cat
        "compile-profile|"
        row
        "|0|0|"
        (string.int->string value)
        "|0\n"))))

(defmacro (bump! [_counter : Expr]) : Expr
  (cfg compile-profile `(set! ,_counter (+ ,_counter 1)) `unit))

(defmacro (add! [_counter : Expr] [_value : Expr]) : Expr
  (cfg compile-profile `(set! ,_counter (+ ,_counter ,_value)) `unit))

(defmacro (max! [_counter : Expr] [_value : Expr]) : Expr
  (cfg
    compile-profile
    `(let
      [next : i64 ,_value]
      (if (> next ,_counter)
        (set! ,_counter next)
        unit))
    `unit))

(defmacro (defcounters [table : Expr] [entries : Expr ...]) : Decls
  (let
    [table-name : String
      (match table
        [(Expr.Var value) value]
        [_ (comptime-error "defcounters: the table name must be a bare name")])]
    [decls : ExprList (comptime.expr-list-empty)]
    [rows : ExprList (comptime.expr-list-empty)]
    [resets : ExprList (comptime.expr-list-empty)]
    [index : i64 (comptime.expr-list-length entries)]
    (begin
      (while (> index 0)
        (begin
          (set! index (- index 1))
          (match (comptime.expr-list-nth entries index)
            [(Expr.Call name fields)
              (let
                [counter : Expr name]
                [row : Expr (comptime.expr-list-nth fields 0)]
                [kind : String
                  (if (> (comptime.expr-list-length fields) 1)
                    (match (comptime.expr-list-nth fields 1)
                      [(Expr.Var value) value]
                      [_
                        (comptime-error
                          "defcounters: a kind must be a bare name")])
                    "count")]
                (begin
                  (set!
                    decls
                    (comptime.expr-list-cons
                      `(define ,counter : i64
                        0)
                      decls))
                  (set!
                    resets
                    (comptime.expr-list-cons `(set! ,counter 0) resets))
                  (set!
                    rows
                    (comptime.expr-list-cons
                      (match kind
                        ["count" `(profile-counter-row! ,row ,counter)]
                        ["us" `(profile-counter-row! ,row (/ ,counter 1000))]
                        ["kb" `(profile-counter-row! ,row (/ ,counter 1024))]
                        ["live" `(profile-counter-live-row! ,row ,counter)]
                        [_
                          (comptime-error
                            "defcounters: a kind must be `us`, `kb` or `live`")])
                      rows))))]
            [_
              (comptime-error
                "defcounters: an entry must be `(name \"row\" [kind])`")])))
      `(begin
        ,@decls
        (define (,(comptime.expr-var
            (comptime.string-append table-name "-emit!"))) : unit
          (begin
            ,@rows
            unit))
        (define (,(comptime.expr-var
            (comptime.string-append table-name "-reset!"))) : unit
          (begin
            ,@resets
            unit))))))