;# Read-only preflight for the finite native-link schema. This visitor checks
;# caller-owned arrays and strings before the owned stdlib.serialize traversal
;# clones them. Its conservative retained/work charges include codec scratch,
;# nested value copies and canonical record-key lookup, not just wire length.
(import stdlib.comptime)
(import stdlib.string)
(import native_link_manifest_binary as binary)

(defstruct Budget
  (ok bool)
  (nodes i64)
  (strings i64)
  (work i64)
  (retained i64)
  (limits binary.Limits))

(define (new [limits : (& l binary.Limits)]) : Budget
  (Budget (binary.valid-limits? limits) 0 0 0 0 (clone (deref limits))))

(define (charge! [b : (&mut b Budget)] [nodes : i64] [strings : i64]) : unit
  (when
    b.ok
    (if (or
      (< nodes 0)
      (< strings 0)
      (> nodes (- b.limits.max-nodes b.nodes))
      (> strings (- b.limits.max-string-bytes b.strings))
      (> nodes (/ (- b.limits.max-work b.work) 4096))
      (> strings (/ (- b.limits.max-work b.work) 256))
      (> nodes (/ (- b.limits.max-retained-bytes b.retained) 4096))
      (> strings (/ (- b.limits.max-retained-bytes b.retained) 256)))
      (set! b.ok false)
      (let
        [cost : i64 (+ (* nodes 4096) (* strings 256))]
        (if (or
          (> cost (- b.limits.max-work b.work))
          (> cost (- b.limits.max-retained-bytes b.retained)))
          (set! b.ok false)
          (begin
            (set! b.nodes (+ b.nodes nodes))
            (set! b.strings (+ b.strings strings))
            (set! b.work (+ b.work cost))
            (set! b.retained (+ b.retained cost))))))))

(defmacro (observe-struct
  [T : type]
  [value : comptime.Expr]
  [budget : comptime.Expr]) : comptime.Expr
  (let
    [items : comptime.ExprList (comptime.expr-list-empty)]
    [i : i64 (- (struct-field-count T) 1)]
    (while (>= i 0)
      (let
        [ty : comptime.Expr (struct-field-type T i)]
        [field : comptime.Expr
          (comptime.expr-struct-get value (struct-field-name T i))]
        (set!
          items
          (comptime.expr-list-cons
            `(native_link_manifest_budget.observe-body ,ty (& ,field) ,budget)
            items)))
      (set! i (- i 1)))
    (comptime.expr-begin-unit items)))

(defmacro (observe-enum
  [T : type]
  [value : comptime.Expr]
  [budget : comptime.Expr]) : comptime.Expr
  (let
    [arms : comptime.MatchArmList (comptime.match-arm-list-empty)]
    [i : i64 (- (enum-variant-count T) 1)]
    [owner : String
      (comptime.string-append
        (type-nominal-module T)
        (comptime.string-append "." (type-nominal-name T)))]
    (while (>= i 0)
      (let
        [prefix : String
          (comptime.string-append
            "__native_budget_payload_"
            (comptime.string-append (comptime.int->string i) "_"))]
        [count : i64 (enum-variant-payload-count T i)]
        [j : i64 (- count 1)]
        [items : comptime.ExprList (comptime.expr-list-empty)]
        (while (>= j 0)
          (let
            [ty : comptime.Expr (enum-variant-payload-type T i j)]
            [binding : comptime.Expr
              (comptime.expr-var
                (comptime.string-append prefix (comptime.int->string j)))]
            (set!
              items
              (comptime.expr-list-cons
                `(native_link_manifest_budget.observe-body
                  ,ty
                  (& ,binding)
                  ,budget)
                items)))
          (set! j (- j 1)))
        (set!
          arms
          (comptime.match-arm-list-cons
            (comptime.match-arm
              (comptime.pattern-variant
                (comptime.string-append
                  owner
                  (comptime.string-append "." (enum-variant-name T i)))
                (comptime.pattern-list-bindings prefix count))
              (comptime.expr-begin-unit items))
            arms)))
      (set! i (- i 1)))
    (comptime.expr-match value arms)))

(defmacro (observe-body
  [T : type]
  [value : comptime.Expr]
  [budget : comptime.Expr]) : comptime.Expr
  (let
    [kind : String (type-kind T)]
    `(let
      [__native_budget_value ,value]
      (when
        ,(comptime.expr-struct-get budget "ok")
        (native_link_manifest_budget.charge! ,budget 1 0)
        ,(match kind
          ["string"
            `(native_link_manifest_budget.charge!
              ,budget
              0
              (stdlib.string.string-length __native_budget_value))]
          ["struct"
            `(native_link_manifest_budget.observe-struct
              ,T
              (deref __native_budget_value)
              ,budget)]
          ["enum"
            `(native_link_manifest_budget.observe-enum
              ,T
              __native_budget_value
              ,budget)]
          [(or "array" "dyn-array")
            (let
              [element : comptime.Expr (array-element-type T)]
              `(let
                [__native_count : i64 (array-length __native_budget_value)]
                [__native_index : i64 0]
                (when
                  (>
                    __native_count
                    (-
                      ,(comptime.expr-struct-get
                        (comptime.expr-struct-get budget "limits")
                        "max-nodes")
                      ,(comptime.expr-struct-get budget "nodes")))
                  (set! ,(comptime.expr-struct-get budget "ok") false))
                (while (and
                  ,(comptime.expr-struct-get budget "ok")
                  (< __native_index __native_count))
                  (native_link_manifest_budget.observe-body
                    ,element
                    (& (array-ref __native_budget_value __native_index))
                    ,budget)
                  (set! __native_index (+ __native_index 1)))))]
          [(or "u8" "u16" "u32" "u64" "i8" "i16" "i32" "i64" "bool") `unit]
          [_
            (comptime.comptime-error
              "native link preflight: unsupported schema type")])))))

(defmacro (observe [T : type] [value : comptime.Expr] [budget : comptime.Expr]) : comptime.Expr
  `(let
    [__native_budget_state ,budget]
    (native_link_manifest_budget.observe-body ,T ,value __native_budget_state)))