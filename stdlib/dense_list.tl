;; dense_list.tl - Declaration generator for compiler-private dense lists.
;;
;; The generated containers remain ordinary concrete `{slots, len}` structs
;; declared by their owning compiler module. This macro only centralizes their
;; repeated append-oriented mechanics; family-specific operations stay beside
;; each invocation.
(import stdlib.comptime)

;: Emit the common operations for a concrete compiler-private `{slots, len}`
;: list. `fallback-policy` is currently the explicit
;: `caller-provided-fallback` contract used by checked `get`. Capacity policy is
;: `zero-capacity`, `minimum-one`, or
;: `(shared-zero-capacity <generated-global-name>)`. Optional capabilities are
;: the unique bare names `len`, `empty?`, and `append-from`.
(defmacro (compiler-dense-list-operations
  [T
    : type
    (:kind i64 i32 i16 i8 u64 u32 u16 u8 f64 f32 bool char string unit array dyn-array box function tuple struct enum str ptr mut-ptr ref mut-ref)]
  [list-type : type]
  [prefix : Expr]
  [fallback-policy : Expr]
  [capacity-policy : Expr]
  [capabilities : Expr ...]) : Decls
  (let
    [prefix-text : String
      (match prefix
        [(Expr.Var value) value]
        [_
          (comptime-error
            "compiler-dense-list-operations: prefix must be a bare name")])]
    [caller-provided-fallback : bool
      (match fallback-policy
        [(Expr.Var value)
          (match value
            ["caller-provided-fallback" true]
            [_ false])]
        [_
          (comptime-error
            "compiler-dense-list-operations: fallback policy must be a bare name")])]
    [zero-capacity : bool
      (match capacity-policy
        [(Expr.Var value)
          (match value
            ["zero-capacity" true]
            ["minimum-one" false]
            [_
              (comptime-error
                "compiler-dense-list-operations: capacity policy must be `zero-capacity` or `minimum-one`")])]
        [(Expr.Call callee items)
          (match callee
            [(Expr.Var value)
              (match value
                ["shared-zero-capacity"
                  (if (= (expr-list-length items) 1)
                    true
                    (comptime-error
                      "compiler-dense-list-operations: shared-zero-capacity expects one storage expression"))]
                [_
                  (comptime-error
                    "compiler-dense-list-operations: capacity policy call must name `shared-zero-capacity`")])]
            [_
              (comptime-error
                "compiler-dense-list-operations: capacity policy call must name `shared-zero-capacity`")])]
        [_
          (comptime-error
            "compiler-dense-list-operations: capacity policy must be a named policy")])]
    [shared-zero-capacity : bool
      (match capacity-policy
        [(Expr.Call _ _) true]
        [_ false])]
    [shared-zero-slots : Expr
      (match capacity-policy
        [(Expr.Call _ items)
          (match (expr-list-nth items 0)
            [(Expr.Var value) (comptime.expr-var value)]
            [_
              (comptime-error
                "compiler-dense-list-operations: shared zero storage must be a bare name")])]
        [_ (comptime.expr-var "compiler-dense-list-unused-empty-slots")])]
    [capability-count : i64 (expr-list-length capabilities)]
    [capability0 : String
      (if (> capability-count 0)
        (match (expr-list-nth capabilities 0)
          [(Expr.Var value) value]
          [_
            (comptime-error
              "compiler-dense-list-operations: capabilities must be bare names")])
        "")]
    [capability1 : String
      (if (> capability-count 1)
        (match (expr-list-nth capabilities 1)
          [(Expr.Var value) value]
          [_
            (comptime-error
              "compiler-dense-list-operations: capabilities must be bare names")])
        "")]
    [capability2 : String
      (if (> capability-count 2)
        (match (expr-list-nth capabilities 2)
          [(Expr.Var value) value]
          [_
            (comptime-error
              "compiler-dense-list-operations: capabilities must be bare names")])
        "")]
    [has-len : bool
      (match capability0
        ["len" true]
        [_
          (match capability1
            ["len" true]
            [_
              (match capability2
                ["len" true]
                [_ false])])])]
    [has-empty : bool
      (match capability0
        ["empty?" true]
        [_
          (match capability1
            ["empty?" true]
            [_
              (match capability2
                ["empty?" true]
                [_ false])])])]
    [has-append : bool
      (match capability0
        ["append-from" true]
        [_
          (match capability1
            ["append-from" true]
            [_
              (match capability2
                ["append-from" true]
                [_ false])])])]
    [recognized-count : i64
      (+
        (if has-len
          1
          0)
        (+
          (if has-empty
            1
            0)
          (if has-append
            1
            0)))]
    [with-capacity-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-with-capacity"))]
    [new-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-new"))]
    [len-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-len"))]
    [empty-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-empty?"))]
    [get-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-get"))]
    [copy-range-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-copy-range"))]
    [grow-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-grow"))]
    [push-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-push"))]
    [append-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-append-from"))]
    [list-constructor : Expr (comptime.expr-var (type-nominal-name list-type))]
    [capacity-expr : Expr
      (if zero-capacity
        `(if (< capacity 0)
          0
          capacity)
        `(if (< capacity 1)
          1
          capacity))]
    [new-capacity : Expr
      (comptime.expr-int
        (if zero-capacity
          0
          4))]
    [constructor-body : Expr
      (if shared-zero-capacity
        `(if (<= capacity 0)
          (,list-constructor
            (cfg
              stage0-seed-bootstrap
              ,shared-zero-slots
              (unsafe
                (ptr-read (ptr-addr-of ,shared-zero-slots))))
            0)
          (,list-constructor (__tl_make-array ,T capacity) 0))
        `(let
          [cap : i64 ,capacity-expr]
          (,list-constructor (__tl_make-array ,T cap) 0)))]
    [len-decls : ExprList
      (if has-len
        (match `(begin
          (define (,len-name [v : (& v ,list-type)]) : i64
            v.len))
          [(Expr.Begin decls) decls]
          [_ (expr-list-empty)])
        (expr-list-empty))]
    [empty-decls : ExprList
      (if has-empty
        (match `(begin
          (define (,empty-name [v : (& v ,list-type)]) : bool
            (= v.len 0)))
          [(Expr.Begin decls) decls]
          [_ (expr-list-empty)])
        (expr-list-empty))]
    [append-decls : ExprList
      (if has-append
        (match `(begin
          (define (,append-name
            [out : (&mut out ,list-type)]
            [items : (& items ,list-type)]
            [index : i64]) : unit
            (if (>= index items.len)
              unit
              (begin
                ;; The range check proves this slot exists. This is the same
                ;; shallow value read that the checked getter exposes across
                ;; its function boundary, without constructing an unreachable
                ;; family-specific fallback.
                (,push-name
                  out
                  (unsafe
                    (ptr-read (ptr-offset (__tl_array-data items.slots) index))))
                (,append-name out items (+ index 1))))))
          [(Expr.Begin decls) decls]
          [_ (expr-list-empty)])
        (expr-list-empty))]
    [shared-zero-decls : ExprList
      (if shared-zero-capacity
        (match `(begin
          (define ,shared-zero-slots : (__tl_dyn-array ,T)
            (__tl_make-array ,T 0)))
          [(Expr.Begin decls) decls]
          [_ (expr-list-empty)])
        (expr-list-empty))]
    (if (if (not caller-provided-fallback)
      true
      (if (> capability-count 3)
        true
        (not (= capability-count recognized-count))))
      (comptime-error
        "compiler-dense-list-operations: expected caller-provided fallback and unique `len`, `empty?`, or `append-from` capabilities")
      `(begin
        ,@shared-zero-decls
        (define (,with-capacity-name [capacity : i64]) : ,list-type
          ,constructor-body)
        (define (,new-name) : ,list-type
          (,with-capacity-name ,new-capacity))
        ,@len-decls
        ,@empty-decls
        (define (,get-name
          [v : (& v ,list-type)]
          [index : i64]
          [fallback-value : ,T]) : ,T
          (if (and (>= index 0) (< index v.len))
            (array-ref v.slots index)
            fallback-value))
        (define (,copy-range-name
          [dst : (&mut dst (__tl_dyn-array ,T))]
          [src : (& src (__tl_dyn-array ,T))]
          [index : i64]
          [count : i64]) : unit
          (if (>= index count)
            unit
            (begin
              (set! (array-ref dst index) (array-ref src index))
              (,copy-range-name dst src (+ index 1) count))))
        (define (,grow-name [v : (&mut v ,list-type)]) : unit
          (let
            [n : i64 v.len]
            [old-cap : i64 (array-length v.slots)]
            [new-cap : i64
              (if (< old-cap 1)
                1
                (* old-cap 2))]
            [bigger : (__tl_dyn-array ,T) (__tl_make-array ,T new-cap)]
            (begin
              (,copy-range-name (&mut bigger) (& v.slots) 0 n)
              (set! v.slots bigger))))
        (define (,push-name [v : (&mut v ,list-type)] [value : ,T]) : unit
          (begin
            (if (< v.len (array-length v.slots))
              unit
              (,grow-name v))
            (let
              [index : i64 v.len]
              (begin
                (set! (array-ref v.slots index) value)
                (set! v.len (+ index 1))))))
        ,@append-decls))))