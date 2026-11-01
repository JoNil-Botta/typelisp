;# Generated structural equality modules.
;: Generate an equality module for concrete scalar and aggregate type `T`.
(import stdlib.comptime)

;; Generated equality reads its operands through shared borrows, as Rust's
;; derived `PartialEq` does: nothing is copied out or moved, so a compared
;; value keeps its owner and its cleanup. An operand is a place of the
;; compared type, a shared reference to one, or the value a match through a
;; reference binds for a Copy payload.
;: Return a shared reference to an equality operand.
(defmacro (eq-ref [operand : comptime.Expr]) : comptime.Expr
  (match (type-kind (comptime.expr-type operand))
    ["ref" operand]
    ["mut-ref" `(& (deref ,operand))]
    [_ `(& ,operand)]))

;: Return the value an equality operand of a Copy scalar type holds.
(defmacro (eq-value [operand : comptime.Expr]) : comptime.Expr
  (match (type-kind (comptime.expr-type operand))
    ["ref" `(deref ,operand)]
    ["mut-ref" `(deref ,operand)]
    [_ operand]))

;: Emit short-circuiting equality for all fields of a struct; LEFT and RIGHT
;: are shared references to the compared structs.
(defmacro (struct-eq-fields
  [T : type]
  [index-expr : comptime.Expr]
  [left : comptime.Expr]
  [right : comptime.Expr]) : comptime.Expr
  (match index-expr
    [(comptime.Expr.Int index)
      (if (>= index (struct-field-count T))
        `true
        (let
          [field-name : String (struct-field-name T index)]
          [next-index : comptime.Expr (comptime.expr-int (+ index 1))]
          [field-type : comptime.Expr (struct-field-type T index)]
          [field-kind : String (type-kind field-type)]
          [left-field : comptime.Expr
            (comptime.expr-struct-get left field-name)]
          [right-field : comptime.Expr
            (comptime.expr-struct-get right field-name)]
          (if (if (string-eq field-kind "ref")
            true
            (string-eq field-kind "mut-ref"))
            (comptime.comptime-error
              (comptime.string-append
                "eq: unsupported type "
                (type-key field-type)))
            `(if (stdlib.eq.inline-eq ,field-type ,left-field ,right-field)
              (stdlib.eq.struct-eq-fields ,T ,next-index ,left ,right)
              false))))]
    [_
      (comptime.comptime-error
        "eq: struct field index must be an integer literal")]))

;: Emit short-circuiting equality for all tuple elements; LEFT and RIGHT are
;: shared references to the compared tuples.
(defmacro (tuple-eq-elements
  [T : type]
  [index-expr : comptime.Expr]
  [left : comptime.Expr]
  [right : comptime.Expr]) : comptime.Expr
  (match index-expr
    [(comptime.Expr.Int index)
      (if (>= index (tuple-element-count T))
        `true
        (let
          [next-index : comptime.Expr (comptime.expr-int (+ index 1))]
          [element-type : comptime.Expr (tuple-element-type T index)]
          [left-item : comptime.Expr
            (comptime.expr-tuple-ref `(deref ,left) index)]
          [right-item : comptime.Expr
            (comptime.expr-tuple-ref `(deref ,right) index)]
          `(if (stdlib.eq.inline-eq ,element-type ,left-item ,right-item)
            (stdlib.eq.tuple-eq-elements ,T ,next-index ,left ,right)
            false)))]
    [_
      (comptime.comptime-error
        "eq: tuple element index must be an integer literal")]))

;: Emit equality for a nested fixed array; each operand is borrowed once.
(defmacro (inline-fixed-array-eq
  [element-type : type]
  [length-expr : comptime.Expr]
  [left : comptime.Expr]
  [right : comptime.Expr]) : comptime.Expr
  `(let
    [__eq_left (stdlib.eq.eq-ref ,left)]
    [__eq_right (stdlib.eq.eq-ref ,right)]
    [__eq_i : i64 0]
    [__eq_same : bool true]
    (while (and (< __eq_i ,length-expr) __eq_same)
      (if (stdlib.eq.inline-eq
        ,element-type
        (__tl_array-ref (deref __eq_left) __eq_i)
        (__tl_array-ref (deref __eq_right) __eq_i))
        unit
        (set! __eq_same false))
      (set! __eq_i (+ __eq_i 1)))
    __eq_same))

;: Emit finite structural equality for two operands of type `T`.
(defmacro (inline-eq [T : type] [left : comptime.Expr] [right : comptime.Expr]) : comptime.Expr
  (match (type-kind T)
    ["string"
      `(__tl_string_eq (stdlib.eq.eq-ref ,left) (stdlib.eq.eq-ref ,right))]
    ["unit" `true]
    ["bool" `(= (stdlib.eq.eq-value ,left) (stdlib.eq.eq-value ,right))]
    ["char" `(= (stdlib.eq.eq-value ,left) (stdlib.eq.eq-value ,right))]
    ["i64" `(= (stdlib.eq.eq-value ,left) (stdlib.eq.eq-value ,right))]
    ["i32" `(= (stdlib.eq.eq-value ,left) (stdlib.eq.eq-value ,right))]
    ["i16" `(= (stdlib.eq.eq-value ,left) (stdlib.eq.eq-value ,right))]
    ["i8" `(= (stdlib.eq.eq-value ,left) (stdlib.eq.eq-value ,right))]
    ["u64" `(= (stdlib.eq.eq-value ,left) (stdlib.eq.eq-value ,right))]
    ["u32" `(= (stdlib.eq.eq-value ,left) (stdlib.eq.eq-value ,right))]
    ["u16" `(= (stdlib.eq.eq-value ,left) (stdlib.eq.eq-value ,right))]
    ["u8" `(= (stdlib.eq.eq-value ,left) (stdlib.eq.eq-value ,right))]
    ["f64" `(= (stdlib.eq.eq-value ,left) (stdlib.eq.eq-value ,right))]
    ["f32" `(= (stdlib.eq.eq-value ,left) (stdlib.eq.eq-value ,right))]
    ["struct"
      `(let
        [__eq_left (stdlib.eq.eq-ref ,left)]
        [__eq_right (stdlib.eq.eq-ref ,right)]
        (stdlib.eq.struct-eq-fields ,T 0 __eq_left __eq_right))]
    ["tuple"
      `(let
        [__eq_left (stdlib.eq.eq-ref ,left)]
        [__eq_right (stdlib.eq.eq-ref ,right)]
        (stdlib.eq.tuple-eq-elements ,T 0 __eq_left __eq_right))]
    ["array"
      (if (array-dynamic? T)
        (comptime.comptime-error
          (comptime.string-append "eq: unsupported type " (type-key T)))
        (let
          [element-type : comptime.Expr (array-element-type T)]
          [length-expr : comptime.Expr (comptime.expr-int (array-length T))]
          `(stdlib.eq.inline-fixed-array-eq
            ,element-type
            ,length-expr
            ,left
            ,right)))]
    ["enum"
      `(let
        [__eq_left (stdlib.eq.eq-ref ,left)]
        [__eq_right (stdlib.eq.eq-ref ,right)]
        (stdlib.eq.enum-eq-dispatch ,T __eq_left __eq_right 0))]
    [_
      (comptime.comptime-error
        (comptime.string-append "eq: unsupported type " (type-key T)))]))

;: Emit short-circuiting equality for one enum variant's payload bindings.
(defmacro (enum-eq-payloads
  [T : type]
  [variant-index-expr : comptime.Expr]
  [payload-index-expr : comptime.Expr]) : comptime.Expr
  (match variant-index-expr
    [(comptime.Expr.Int variant-index)
      (match payload-index-expr
        [(comptime.Expr.Int payload-index)
          (if (>= payload-index (enum-variant-payload-count T variant-index))
            `true
            (let
              [next-index : comptime.Expr
                (comptime.expr-int (+ payload-index 1))]
              [left-value : comptime.Expr
                (comptime.expr-var
                  (comptime.string-append
                    (comptime.string-append
                      (comptime.string-append
                        "__eq_l_v"
                        (comptime.int->string variant-index))
                      "_p")
                    (comptime.int->string payload-index)))]
              [right-value : comptime.Expr
                (comptime.expr-var
                  (comptime.string-append
                    (comptime.string-append
                      (comptime.string-append
                        "__eq_r_v"
                        (comptime.int->string variant-index))
                      "_p")
                    (comptime.int->string payload-index)))]
              [payload-type : comptime.Expr
                (enum-variant-payload-type T variant-index payload-index)]
              `(if (stdlib.eq.inline-eq ,payload-type ,left-value ,right-value)
                (stdlib.eq.enum-eq-payloads ,T ,variant-index-expr ,next-index)
                false)))]
        [_
          (comptime.comptime-error
            "eq: enum payload index must be an integer literal")])]
    [_
      (comptime.comptime-error
        "eq: enum variant index must be an integer literal")]))

;: Emit a staged nested match through LEFT and RIGHT, shared references to the
;: compared enums, that compares their tags and payloads.
(defmacro (enum-eq-dispatch
  [T : type]
  [left : comptime.Expr]
  [right : comptime.Expr]
  [variant-index-expr : comptime.Expr]) : comptime.Expr
  (match variant-index-expr
    [(comptime.Expr.Int variant-index)
      (if (>= variant-index (enum-variant-count T))
        `false
        (let
          [variant-name : String (enum-variant-name T variant-index)]
          [payload-count : i64 (enum-variant-payload-count T variant-index)]
          [left-prefix : String
            (comptime.string-append
              (comptime.string-append
                "__eq_l_v"
                (comptime.int->string variant-index))
              "_p")]
          [right-prefix : String
            (comptime.string-append
              (comptime.string-append
                "__eq_r_v"
                (comptime.int->string variant-index))
              "_p")]
          [left-pattern : comptime.Pattern
            (comptime.pattern-variant
              variant-name
              (comptime.pattern-list-bindings left-prefix payload-count))]
          [right-pattern : comptime.Pattern
            (comptime.pattern-variant
              variant-name
              (comptime.pattern-list-bindings right-prefix payload-count))]
          [payload-body : comptime.Expr
            `(stdlib.eq.enum-eq-payloads ,T ,variant-index-expr 0)]
          [right-match : comptime.Expr
            (comptime.expr-match
              right
              (comptime.match-arm-list-cons
                (comptime.match-arm right-pattern payload-body)
                (comptime.match-arm-list-cons
                  (comptime.match-arm (comptime.pattern-wildcard) `false)
                  (comptime.match-arm-list-empty))))]
          [next-index : comptime.Expr (comptime.expr-int (+ variant-index 1))]
          [fallback : comptime.Expr
            `(stdlib.eq.enum-eq-dispatch ,T ,left ,right ,next-index)]
          (comptime.expr-match
            left
            (comptime.match-arm-list-cons
              (comptime.match-arm left-pattern right-match)
              (comptime.match-arm-list-cons
                (comptime.match-arm (comptime.pattern-wildcard) fallback)
                (comptime.match-arm-list-empty))))))]
    [_
      (comptime.comptime-error
        "eq: enum variant index must be an integer literal")]))

;: Generate a concrete equality module for `T`.
(defmacro (eq [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var (comptime.string-append "stdlib.eq.generated." (type-key T)))]
    [kind : String (type-kind T)]
    (match kind
      ["string"
        `(begin
          (module ,module-name)
          (define (eq [left : ,T] [right : ,T]) : bool
            (__tl_string_eq left right))
          (define (eq? [left : ,T] [right : ,T]) : bool
            (__tl_string_eq left right)))]
      ["unit"
        `(begin
          (module ,module-name)
          (define (eq [left : ,T] [right : ,T]) : bool
            true)
          (define (eq? [left : ,T] [right : ,T]) : bool
            true))]
      ["struct"
        `(begin
          (module ,module-name)
          (import stdlib.eq)
          (define (eq [left : ,T] [right : ,T]) : bool
            (stdlib.eq.inline-eq ,T left right))
          (define (eq? [left : ,T] [right : ,T]) : bool
            (stdlib.eq.inline-eq ,T left right)))]
      ["tuple"
        `(begin
          (module ,module-name)
          (import stdlib.eq)
          (define (eq [left : ,T] [right : ,T]) : bool
            (stdlib.eq.inline-eq ,T left right))
          (define (eq? [left : ,T] [right : ,T]) : bool
            (stdlib.eq.inline-eq ,T left right)))]
      ["array"
        (if (array-dynamic? T)
          (comptime.comptime-error
            (comptime.string-append "eq: unsupported type " (type-key T)))
          `(begin
            (module ,module-name)
            (import stdlib.eq)
            (define (eq [left : ,T] [right : ,T]) : bool
              (stdlib.eq.inline-eq ,T left right))
            (define (eq? [left : ,T] [right : ,T]) : bool
              (stdlib.eq.inline-eq ,T left right))))]
      ["enum"
        `(begin
          (module ,module-name)
          (import stdlib.eq)
          (define (eq [left : ,T] [right : ,T]) : bool
            (stdlib.eq.inline-eq ,T left right))
          (define (eq? [left : ,T] [right : ,T]) : bool
            (stdlib.eq.inline-eq ,T left right)))]
      ["bool"
        `(begin
          (module ,module-name)
          (define (eq [left : ,T] [right : ,T]) : bool
            (= left right))
          (define (eq? [left : ,T] [right : ,T]) : bool
            (= left right)))]
      ["char"
        `(begin
          (module ,module-name)
          (define (eq [left : ,T] [right : ,T]) : bool
            (= left right))
          (define (eq? [left : ,T] [right : ,T]) : bool
            (= left right)))]
      ["i64"
        `(begin
          (module ,module-name)
          (define (eq [left : ,T] [right : ,T]) : bool
            (= left right))
          (define (eq? [left : ,T] [right : ,T]) : bool
            (= left right)))]
      ["i32"
        `(begin
          (module ,module-name)
          (define (eq [left : ,T] [right : ,T]) : bool
            (= left right))
          (define (eq? [left : ,T] [right : ,T]) : bool
            (= left right)))]
      ["i16"
        `(begin
          (module ,module-name)
          (define (eq [left : ,T] [right : ,T]) : bool
            (= left right))
          (define (eq? [left : ,T] [right : ,T]) : bool
            (= left right)))]
      ["i8"
        `(begin
          (module ,module-name)
          (define (eq [left : ,T] [right : ,T]) : bool
            (= left right))
          (define (eq? [left : ,T] [right : ,T]) : bool
            (= left right)))]
      ["u64"
        `(begin
          (module ,module-name)
          (define (eq [left : ,T] [right : ,T]) : bool
            (= left right))
          (define (eq? [left : ,T] [right : ,T]) : bool
            (= left right)))]
      ["u32"
        `(begin
          (module ,module-name)
          (define (eq [left : ,T] [right : ,T]) : bool
            (= left right))
          (define (eq? [left : ,T] [right : ,T]) : bool
            (= left right)))]
      ["u16"
        `(begin
          (module ,module-name)
          (define (eq [left : ,T] [right : ,T]) : bool
            (= left right))
          (define (eq? [left : ,T] [right : ,T]) : bool
            (= left right)))]
      ["u8"
        `(begin
          (module ,module-name)
          (define (eq [left : ,T] [right : ,T]) : bool
            (= left right))
          (define (eq? [left : ,T] [right : ,T]) : bool
            (= left right)))]
      ["f64"
        `(begin
          (module ,module-name)
          (define (eq [left : ,T] [right : ,T]) : bool
            (= left right))
          (define (eq? [left : ,T] [right : ,T]) : bool
            (= left right)))]
      ["f32"
        `(begin
          (module ,module-name)
          (define (eq [left : ,T] [right : ,T]) : bool
            (= left right))
          (define (eq? [left : ,T] [right : ,T]) : bool
            (= left right)))]
      [_
        (comptime.comptime-error
          (comptime.string-append "eq: unsupported type " (type-key T)))])))