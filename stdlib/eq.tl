;# Owner-side nominal equality and generated equality adapter modules.
;#
;# A nominal type's equality lives beside the type. Its exact canonical owner
;# module either calls `(eq.gen T)`, which emits one ordinary function
;# `eq-<kebab-name>` comparing fields in declaration order (variant tag, then
;# payloads, for an enum), or defines that function itself for a semantic
;# equality:
;#
;# ```typelisp
;# (module geometry)
;# (import stdlib.eq)
;# (defstruct Point (x i64) (y i64))
;# (eq.gen Point) ; (define (eq-point [left : (& left Point)] [right : (& right Point)]) : bool ...)
;# ```
;#
;# The hook name is the lowercase kebab form of the nominal name, as for
;# `clone-<kebab-name>`. `(eq.eq T)` is the capability-module adapter used by
;# collections: its `eq` and `eq?` take shared borrows of two `T` values. For a
;# nominal `T` it validates and calls the owner hook and never reflects the
;# fields, so it also works for an `(:opaque)` type outside its module family.
;# Scalars, `String`, tuples, and fixed arrays compare structurally, and nested
;# nominal members always dispatch through their own owner hooks. A type's
;# nominal dependencies must have their hooks before `(eq.gen T)` expands.
(import stdlib.comptime)
(import stdlib.clone)

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
    ["struct" `(stdlib.eq.owner-eq ,T ,left ,right)]
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
    ["enum" `(stdlib.eq.owner-eq ,T ,left ,right)]
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

;: Emit a call of nominal `T`'s canonical `eq-<kebab-name>` owner hook.
(defmacro (owner-eq
  [T : type (:kind struct enum)]
  [left : comptime.Expr]
  [right : comptime.Expr]) : comptime.Expr
  `(stdlib.eq.owner-hook-call
    ,T
    (stdlib.eq.owner-hook-name
      ,T
      (stdlib.clone.nominal-hook-name ,T "eq-" "eq: " "nominal name is empty")
      "eq")
    "eq"
    ,left
    ,right))

;: Return HOOK-NAME after checking that nominal `T`'s canonical owner module
;: defines it as a function with the owner-hook shape of FAMILY-EXPR: "eq"
;: expects `(-> (& T) (& T) bool)` and "hash" expects `(-> (& T) i64)`.
(defmacro (owner-hook-name
  [T : type (:kind struct enum)]
  [hook-name : String]
  [family-expr : comptime.Expr]) : comptime.Expr
  (let
    [family : String (comptime.expr-string-value family-expr)]
    [eq-family? : bool (string-eq family "eq")]
    [owner : String (type-nominal-module T)]
    [owner-display : String
      (if (string-eq owner "")
        "<root>"
        owner)]
    [type-name : String (type-nominal-name T)]
    [function-name : String (comptime.expr-string-value hook-name)]
    [arity : i64
      (if eq-family?
        2
        1)]
    [result-kind : String
      (if eq-family?
        "bool"
        "i64")]
    [signature : String
      (if eq-family?
        (comptime.string-append
          "(-> (& "
          (comptime.string-append
            type-name
            (comptime.string-append
              ") (& "
              (comptime.string-append type-name ") bool)"))))
        (comptime.string-append
          "(-> (& "
          (comptime.string-append type-name ") i64)")))]
    [manual : String
      (if eq-family?
        (comptime.string-append
          " [left : (& left "
          (comptime.string-append
            type-name
            (comptime.string-append
              ")] [right : (& right "
              (comptime.string-append type-name ")]) : bool"))))
        (comptime.string-append
          " [value : (& value "
          (comptime.string-append type-name ")]) : i64")))]
    [context : String
      (comptime.string-append
        family
        (comptime.string-append
          ": nominal type "
          (comptime.string-append
            type-name
            (comptime.string-append
              " needs its canonical owner hook "
              (comptime.string-append
                function-name
                (comptime.string-append " in module " owner-display))))))]
    (if (comptime.module-value? owner function-name)
      unit
      (comptime.comptime-error
        (comptime.string-append
          context
          (comptime.string-append
            "; add ("
            (comptime.string-append
              family
              (comptime.string-append
                ".gen "
                (comptime.string-append
                  type-name
                  (comptime.string-append
                    ") there or define ("
                    (comptime.string-append
                      function-name
                      (comptime.string-append manual ")"))))))))))
    ;; The arity and result kind are checked here; the shared-borrow
    ;; parameter types are checked by the typechecker at every hook call.
    (let
      [hook-type : comptime.Expr
        (comptime.module-value-type owner function-name)]
      [valid : bool (string-eq (type-kind hook-type) "function")]
      (if valid
        (set! valid (= (function-param-count hook-type) arity))
        unit)
      (if valid
        (set!
          valid
          (string-eq (type-kind (function-return-type hook-type)) result-kind))
        unit)
      (if valid
        unit
        (comptime.comptime-error
          (comptime.string-append
            context
            (comptime.string-append
              " with signature "
              (comptime.string-append
                signature
                (comptime.string-append ", got " (type-key hook-type)))))))
      (comptime.expr-string function-name))))

;: Call the validated owner hook HOOK-NAME of nominal `T` on shared borrows of
;: its operands. An "eq" hook takes LEFT and RIGHT; a "hash" hook takes LEFT.
(defmacro (owner-hook-call
  [T : type (:kind struct enum)]
  [hook-name : String]
  [family-expr : comptime.Expr]
  [left : comptime.Expr]
  [right : comptime.Expr]) : comptime.Expr
  (let
    [hook : comptime.Expr
      (comptime.module-value-expr
        (type-nominal-module T)
        (comptime.expr-string-value hook-name))]
    [left-arg : comptime.Expr `(stdlib.eq.eq-ref ,left)]
    (if (string-eq (comptime.expr-string-value family-expr) "eq")
      (comptime.expr-call
        hook
        (comptime.expr-list-cons
          left-arg
          (comptime.expr-list-cons
            `(stdlib.eq.eq-ref ,right)
            (comptime.expr-list-empty))))
      (comptime.expr-call
        hook
        (comptime.expr-list-cons left-arg (comptime.expr-list-empty))))))

;: Generate nominal `T`'s canonical `eq-<kebab-name>` owner hook.
;:
;: Call it from `T`'s exact canonical owner module, after the hooks of the
;: nominal types `T` holds. The emitted function compares two shared borrows
;: field by field, or by variant tag and then payload, short-circuiting at the
;: first difference. Repeating the identical call is idempotent; a same-name
;: value already in the owner module is a collision.
(defmacro (gen [T : type (:kind struct enum)]) : Decls
  (let
    [owner : String (type-nominal-module T)]
    [caller : String (comptime.current-module)]
    (if (string-eq owner caller)
      unit
      (let
        [owner-display : String
          (if (string-eq owner "")
            "<root>"
            owner)]
        [caller-display : String
          (if (string-eq caller "")
            "<root>"
            caller)]
        (comptime.comptime-error
          (comptime.string-append
            "eq.gen: "
            (comptime.string-append
              (type-nominal-name T)
              (comptime.string-append
                " must be generated in its canonical owner module "
                (comptime.string-append
                  owner-display
                  (comptime.string-append
                    " (current module "
                    (comptime.string-append caller-display ")")))))))))
    `(stdlib.eq.gen-named
      ,T
      (stdlib.clone.nominal-hook-name
        ,T
        "eq-"
        "eq.gen: "
        "nominal root name is empty"))))

;: Emit the equality hook after its nominal name has been computed.
(defmacro (gen-named [T : type (:kind struct enum)] [hook-name : String]) : Decls
  (let
    [owner : String (type-nominal-module T)]
    [owner-display : String
      (if (string-eq owner "")
        "<root>"
        owner)]
    [function-name-text : String (comptime.expr-string-value hook-name)]
    (if (comptime.module-value? owner function-name-text)
      (comptime.comptime-error
        (comptime.string-append
          "eq.gen: generated name collision for "
          (comptime.string-append
            function-name-text
            (comptime.string-append " in canonical owner module " owner-display))))
      unit)
    (let
      [function-name : comptime.Expr (comptime.expr-var function-name-text)]
      [body : comptime.Expr
        (match (type-kind T)
          ["struct" `(stdlib.eq.struct-eq-fields ,T 0 left right)]
          [_ `(stdlib.eq.enum-eq-dispatch ,T left right 0)])]
      `(define (,function-name [left : (& left ,T)] [right : (& right ,T)]) : bool
        ,body))))

;: Generate an equality adapter module for `T`.
;:
;: Its `eq` and `eq?` compare two shared borrows of `T` values without moving
;: or copying them (`unit` operands, which have no reference form, are passed
;: by value). A nominal `T` delegates to its canonical owner hook.
(defmacro (eq [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var (comptime.string-append "stdlib.eq.generated." (type-key T)))]
    (match (type-kind T)
      ["array"
        (if (array-dynamic? T)
          (comptime.comptime-error
            (comptime.string-append "eq: unsupported type " (type-key T)))
          unit)]
      [_ unit])
    (match (type-kind T)
      ;; A unit reference has no runtime representation, so unit operands are
      ;; passed by value; every unit value is equal.
      ["unit"
        `(begin
          (module ,module-name)
          (define (eq [left : unit] [right : unit]) : bool
            true)
          (define (eq? [left : unit] [right : unit]) : bool
            true))]
      [_
        (let
          ;; A borrowed `String` place is a `str` view.
          [operand-type : comptime.Expr
            (if (string-eq (type-kind T) "string")
              (comptime.expr-var "str")
              T)]
          `(begin
            (module ,module-name)
            (import stdlib.eq)
            (define (eq
              [left : (& left ,operand-type)]
              [right : (& right ,operand-type)]) : bool
              (stdlib.eq.inline-eq ,T left right))
            (define (eq?
              [left : (& left ,operand-type)]
              [right : (& right ,operand-type)]) : bool
              (stdlib.eq.inline-eq ,T left right))))])))