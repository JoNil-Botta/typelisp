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
;; bytes and reports kibibytes, `live` reports the value in the live-delta field
;; of the six-field row instead of the value field, and `bare` writes the
;; three-field row `compile-profile|row|value`.
;;
;; `bump!`, `add!` and `max!` update a counter in compile-profile builds and
;; expand to `unit` in every other build, so counting sites need no cfg.
;;
;; Counters that live in a job's metric array instead of globals are a
;; `defslots` table: `(counters.defslots table first entry ...)` numbers the
;; entries' slots from `first` in table order and defines
;; `<table>-end`, the slot after the last. An entry is `(name "row" [kind])`,
;; or `(name)` for a slot no row reports; in compile-profile builds
;; `<table>-emit!` writes the rows from the metric array at a job's metrics
;; address.
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

(cfg
  compile-profile
  (define (profile-counter-bare-row! [row : String] [value : i64]) : unit
    (io.print-error
      (str_cat.str-cat "compile-profile|" row "|" (string.int->string value) "\n"))))

(cfg
  compile-profile
  (define (profile-slot-value [address : u64] [slot : i64]) : i64
    (unsafe
      (ptr-read (ptr-offset (int->ptr address : (Ptr i64)) slot)))))

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
                        ["bare" `(profile-counter-bare-row! ,row ,counter)]
                        [_
                          (comptime-error
                            "defcounters: a kind must be `us`, `kb`, `live` or `bare`")])
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

(defmacro (defslots [table : Expr] [first : Expr] [entries : Expr ...]) : Decls
  (let
    [table-name : String
      (match table
        [(Expr.Var value) value]
        [_ (comptime-error "defslots: the table name must be a bare name")])]
    [count : i64 (comptime.expr-list-length entries)]
    [decls : ExprList (comptime.expr-list-empty)]
    [rows : ExprList (comptime.expr-list-empty)]
    [index : i64 count]
    (begin
      (while (> index 0)
        (begin
          (set! index (- index 1))
          (match (comptime.expr-list-nth entries index)
            [(Expr.Call name fields)
              (let
                [slot : Expr name]
                [value : Expr `(profile-slot-value address ,slot)]
                [field-count : i64 (comptime.expr-list-length fields)]
                [kind : String
                  (if (> field-count 1)
                    (match (comptime.expr-list-nth fields 1)
                      [(Expr.Var kind-name) kind-name]
                      [_
                        (comptime-error "defslots: a kind must be a bare name")])
                    "count")]
                (begin
                  (set!
                    decls
                    (comptime.expr-list-cons
                      `(define ,slot : i64
                        (+ ,first ,(comptime.expr-int index)))
                      decls))
                  (if (> field-count 0)
                    (let
                      [row : Expr (comptime.expr-list-nth fields 0)]
                      (set!
                        rows
                        (comptime.expr-list-cons
                          (match kind
                            ["count" `(profile-counter-row! ,row ,value)]
                            ["live" `(profile-counter-live-row! ,row ,value)]
                            ["bare" `(profile-counter-bare-row! ,row ,value)]
                            [_
                              (comptime-error "defslots: a kind must be `live` or `bare`")])
                          rows)))
                    unit)))]
            [_
              (comptime-error
                "defslots: an entry must be `(name [\"row\" [kind]])`")])))
      (let
        [end : Expr
          `(define ,(comptime.expr-var
            (comptime.string-append table-name "-end")) : i64
            (+ ,first ,(comptime.expr-int count)))]
        (cfg
          compile-profile
          (if (> (comptime.expr-list-length rows) 0)
            `(begin
              ,@decls
              ,end
              (define (,(comptime.expr-var
                  (comptime.string-append table-name "-emit!"))
                [address : u64]) : unit
                (begin
                  ,@rows
                  unit)))
            `(begin
              ,@decls
              ,end))
          `(begin
            ,@decls
            ,end))))))