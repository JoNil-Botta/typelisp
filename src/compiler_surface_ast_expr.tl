;; compiler_surface_ast_expr.tl - exhaustive expression surface codec.
(import "compiler_ast_types.tl")
(import "compiler_surface_ast_codec_core.tl")

;; Embedded surface hydration remaps expression/type identities before later
;; compiler modules import byte_buf_core. Keep that nominal dependency present
;; for the routed bootstrap; without it, stage2 faults while loading the prelude
;; surface produced by stage1.
(cfg
  (any compiler-surface-producer compiler-surface-selftest embedded-stdlib-tlci)
  (import stdlib.byte_buf_core))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-expr-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [items : AstExprList]) : unit
    (let
      [index : i64 0]
      [count : i64 (struct-get items len)]
      (begin
        (surface-ast-write-i64! out count)
        (while (< index count)
          (begin
            (surface-ast-write-i64!
              out
              (array-ref (struct-get items slots) index))
            (set! index (+ index 1))))))))

(define (surface-ast-read-expr-list! [reader : SurfaceAstReader]) : AstExprList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array i64) (make-array i64 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set! slots index (surface-ast-read-i64! reader))
          (set! index (+ index 1))))
      (AstExprList slots count))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-param!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [param : AstParam]) : unit
    (match param
      [(AstParam.Param name ty is-comptime consume)
        (begin
          (surface-ast-write-name! out context name)
          (surface-ast-write-type! out context ty)
          (surface-ast-write-bool! out is-comptime)
          (surface-ast-write-bool! out consume))])))

(define (surface-ast-read-param! [reader : SurfaceAstReader]) : AstParam
  (AstParam.Param
    (surface-ast-read-name! reader)
    (surface-ast-read-type! reader)
    (surface-ast-read-bool! reader)
    (surface-ast-read-bool! reader)))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-param-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [params : AstParamList]) : unit
    (let
      [index : i64 0]
      [count : i64 (struct-get params len)]
      (begin
        (surface-ast-write-i64! out count)
        (while (< index count)
          (begin
            (surface-ast-write-param!
              out
              context
              (array-ref (struct-get params slots) index))
            (set! index (+ index 1))))))))

(define (surface-ast-read-param-list! [reader : SurfaceAstReader]) : AstParamList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array AstParam) (make-array AstParam count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set! slots index (surface-ast-read-param! reader))
          (set! index (+ index 1))))
      (AstParamList slots count))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-pattern-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [patterns : AstPatternList]) : unit
    (let
      [index : i64 0]
      [count : i64 (struct-get patterns len)]
      (begin
        (surface-ast-write-i64! out count)
        (while (< index count)
          (begin
            (surface-ast-write-pattern!
              out
              context
              (array-ref (struct-get patterns slots) index))
            (set! index (+ index 1))))))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-pattern!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [pattern : AstPattern]) : unit
    (match pattern
      [(AstPattern.Var name maybe-ty)
        (begin
          (surface-ast-write-i64! out 0)
          (surface-ast-write-name! out context name)
          (surface-ast-write-maybe-type! out context maybe-ty))]
      [(AstPattern.Tuple items)
        (begin
          (surface-ast-write-i64! out 1)
          (surface-ast-write-pattern-list! out context (box-get items)))]
      [(AstPattern.Wildcard) (surface-ast-write-i64! out 2)]
      [(AstPattern.Binding name)
        (begin
          (surface-ast-write-i64! out 3)
          (surface-ast-write-name! out context name))]
      [(AstPattern.Variant name items)
        (begin
          (surface-ast-write-i64! out 4)
          (surface-ast-write-name! out context name)
          (surface-ast-write-pattern-list! out context (box-get items)))]
      [(AstPattern.Literal literal)
        (begin
          (surface-ast-write-i64! out 5)
          (surface-ast-write-literal! out context literal))])))

(define (surface-ast-read-pattern-list! [reader : SurfaceAstReader]) : AstPatternList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array AstPattern) (make-array AstPattern count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set! slots index (surface-ast-read-pattern! reader))
          (set! index (+ index 1))))
      (AstPatternList slots count))))

(define (surface-ast-read-pattern! [reader : SurfaceAstReader]) : AstPattern
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0)
        (AstPattern.Var
          (surface-ast-read-name! reader)
          (surface-ast-read-maybe-type! reader))]
      [(= tag 1)
        (AstPattern.Tuple (box (surface-ast-read-pattern-list! reader)))]
      [(= tag 2) AstPattern.Wildcard]
      [(= tag 3) (AstPattern.Binding (surface-ast-read-name! reader))]
      [(= tag 4)
        (AstPattern.Variant
          (surface-ast-read-name! reader)
          (box (surface-ast-read-pattern-list! reader)))]
      [(= tag 5) (AstPattern.Literal (surface-ast-read-literal! reader))]
      [else
        (begin
          (surface-ast-reader-fail! reader "surface ast: invalid pattern tag")
          AstPattern.Wildcard)])))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-let-binding-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [bindings : AstLetBindingList]) : unit
    (let
      [index : i64 0]
      [count : i64 (struct-get bindings len)]
      (begin
        (surface-ast-write-i64! out count)
        (while (< index count)
          (match (array-ref (struct-get bindings slots) index)
            [(AstLetBinding.Binding name maybe-ty value)
              (begin
                (surface-ast-write-name! out context name)
                (surface-ast-write-maybe-type! out context maybe-ty)
                (surface-ast-write-i64! out value))])
          (set! index (+ index 1)))))))

(define (surface-ast-read-let-binding-list! [reader : SurfaceAstReader]) : AstLetBindingList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array AstLetBinding) (make-array AstLetBinding count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set!
            slots
            index
            (AstLetBinding.Binding
              (surface-ast-read-name! reader)
              (surface-ast-read-maybe-type! reader)
              (surface-ast-read-i64! reader)))
          (set! index (+ index 1))))
      (AstLetBindingList slots count))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-resource-binding-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [bindings : AstResourceBindingList]) : unit
    (let
      [index : i64 0]
      [count : i64 (struct-get bindings len)]
      (begin
        (surface-ast-write-i64! out count)
        (while (< index count)
          (match (array-ref (struct-get bindings slots) index)
            [(AstResourceBinding.Binding name init cleanup fallible)
              (begin
                (surface-ast-write-name! out context name)
                (surface-ast-write-i64! out init)
                (surface-ast-write-i64! out cleanup)
                (surface-ast-write-bool! out fallible))])
          (set! index (+ index 1)))))))

(define (surface-ast-read-resource-binding-list! [reader : SurfaceAstReader]) : AstResourceBindingList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array AstResourceBinding)
      (make-array AstResourceBinding count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set!
            slots
            index
            (AstResourceBinding.Binding
              (surface-ast-read-name! reader)
              (surface-ast-read-i64! reader)
              (surface-ast-read-i64! reader)
              (surface-ast-read-bool! reader)))
          (set! index (+ index 1))))
      (AstResourceBindingList slots count))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-match-arm-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [arms : AstMatchArmList]) : unit
    (let
      [index : i64 0]
      [count : i64 (struct-get arms len)]
      (begin
        (surface-ast-write-i64! out count)
        (while (< index count)
          (match (array-ref (struct-get arms slots) index)
            [(AstMatchArm.Arm pattern body)
              (begin
                (surface-ast-write-pattern! out context pattern)
                (surface-ast-write-i64! out body))])
          (set! index (+ index 1)))))))

(define (surface-ast-read-match-arm-list! [reader : SurfaceAstReader]) : AstMatchArmList
  (let
    [count : i64 (surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array AstMatchArm) (make-array AstMatchArm count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (array-set!
            slots
            index
            (AstMatchArm.Arm
              (surface-ast-read-pattern! reader)
              (surface-ast-read-i64! reader)))
          (set! index (+ index 1))))
      (AstMatchArmList slots count))))

(cfg
  (any compiler-surface-producer compiler-surface-selftest)
  (define (surface-ast-write-expr!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : SurfaceAstWriteContext]
    [expr : AstExpr]) : unit
    (match expr
      [(AstExpr.Spanned inner span)
        (begin
          (surface-ast-write-i64! out 0)
          (surface-ast-write-i64! out inner)
          (surface-ast-write-span! out span))]
      [(AstExpr.Literal literal)
        (begin
          (surface-ast-write-i64! out 1)
          (surface-ast-write-literal! out context literal))]
      [(AstExpr.Var name)
        (begin
          (surface-ast-write-i64! out 2)
          (surface-ast-write-name! out context name))]
      [(AstExpr.Binary op left right)
        (begin
          (surface-ast-write-i64! out 3)
          (surface-ast-write-bin-op! out op)
          (surface-ast-write-i64! out left)
          (surface-ast-write-i64! out right))]
      [(AstExpr.Unary op inner)
        (begin
          (surface-ast-write-i64! out 4)
          (surface-ast-write-un-op! out op)
          (surface-ast-write-i64! out inner))]
      [(AstExpr.Call callee args)
        (begin
          (surface-ast-write-i64! out 5)
          (surface-ast-write-i64! out callee)
          (surface-ast-write-expr-list! out args))]
      [(AstExpr.If condition then-expr else-expr)
        (begin
          (surface-ast-write-i64! out 6)
          (surface-ast-write-i64! out condition)
          (surface-ast-write-i64! out then-expr)
          (surface-ast-write-i64! out else-expr))]
      [(AstExpr.Let payload)
        (match (box-get payload)
          [(AstLet.Let bindings body)
            (begin
              (surface-ast-write-i64! out 7)
              (surface-ast-write-let-binding-list! out context bindings)
              (surface-ast-write-i64! out body))])]
      [(AstExpr.Lambda payload)
        (match (box-get payload)
          [(AstLambda.Lambda params ret body)
            (begin
              (surface-ast-write-i64! out 8)
              (surface-ast-write-param-list! out context params)
              (surface-ast-write-maybe-type! out context ret)
              (surface-ast-write-i64! out body))])]
      [(AstExpr.Tuple items)
        (begin
          (surface-ast-write-i64! out 9)
          (surface-ast-write-expr-list! out items))]
      [(AstExpr.TupleRef target index)
        (begin
          (surface-ast-write-i64! out 10)
          (surface-ast-write-i64! out target)
          (surface-ast-write-i64! out index))]
      [(AstExpr.Array items)
        (begin
          (surface-ast-write-i64! out 11)
          (surface-ast-write-expr-list! out items))]
      [(AstExpr.DynArray items)
        (begin
          (surface-ast-write-i64! out 12)
          (surface-ast-write-expr-list! out items))]
      [(AstExpr.MakeArray ty-id size)
        (begin
          (surface-ast-write-i64! out 13)
          (surface-ast-write-i64! out ty-id)
          (surface-ast-write-i64! out size))]
      [(AstExpr.ArrayRef target index)
        (begin
          (surface-ast-write-i64! out 14)
          (surface-ast-write-i64! out target)
          (surface-ast-write-i64! out index))]
      [(AstExpr.ArraySet target index value)
        (begin
          (surface-ast-write-i64! out 15)
          (surface-ast-write-i64! out target)
          (surface-ast-write-i64! out index)
          (surface-ast-write-i64! out value))]
      [(AstExpr.ArrayTake target live index)
        (begin
          (surface-ast-write-i64! out 16)
          (surface-ast-write-i64! out target)
          (surface-ast-write-i64! out live)
          (surface-ast-write-i64! out index))]
      [(AstExpr.ArrayPush target value)
        (begin
          (surface-ast-write-i64! out 17)
          (surface-ast-write-i64! out target)
          (surface-ast-write-i64! out value))]
      [(AstExpr.StringRef target index)
        (begin
          (surface-ast-write-i64! out 18)
          (surface-ast-write-i64! out target)
          (surface-ast-write-i64! out index))]
      [(AstExpr.While condition body)
        (begin
          (surface-ast-write-i64! out 19)
          (surface-ast-write-i64! out condition)
          (surface-ast-write-i64! out body))]
      [(AstExpr.Begin items)
        (begin
          (surface-ast-write-i64! out 20)
          (surface-ast-write-expr-list! out items))]
      [(AstExpr.Unsafe items)
        (begin
          (surface-ast-write-i64! out 21)
          (surface-ast-write-expr-list! out items))]
      [(AstExpr.Set name value)
        (begin
          (surface-ast-write-i64! out 22)
          (surface-ast-write-name! out context name)
          (surface-ast-write-i64! out value))]
      [(AstExpr.Ann inner ty-id)
        (begin
          (surface-ast-write-i64! out 23)
          (surface-ast-write-i64! out inner)
          (surface-ast-write-i64! out ty-id))]
      [(AstExpr.Cast inner ty-id)
        (begin
          (surface-ast-write-i64! out 24)
          (surface-ast-write-i64! out inner)
          (surface-ast-write-i64! out ty-id))]
      [(AstExpr.Borrow mutable lifetime-id inner)
        (begin
          (surface-ast-write-i64! out 25)
          (surface-ast-write-bool! out mutable)
          (surface-ast-write-borrow-lifetime!
            out
            context
            (ast-borrow-lifetime-from-id lifetime-id))
          (surface-ast-write-i64! out inner))]
      [(AstExpr.Match payload)
        (match (box-get payload)
          [(AstMatch.Match scrutinee arms)
            (begin
              (surface-ast-write-i64! out 26)
              (surface-ast-write-i64! out scrutinee)
              (surface-ast-write-match-arm-list! out context arms))])]
      [(AstExpr.Foreach payload)
        (match (box-get payload)
          [(AstForeach.Foreach name index-ty start end body)
            (begin
              (surface-ast-write-i64! out 27)
              (surface-ast-write-name! out context name)
              (surface-ast-write-type! out context index-ty)
              (surface-ast-write-i64! out start)
              (surface-ast-write-i64! out end)
              (surface-ast-write-i64! out body))])]
      [(AstExpr.SpmdReduce payload)
        (match (box-get payload)
          [(AstSpmdReduce.Reduce op index index-ty start end init value)
            (begin
              (surface-ast-write-i64! out 28)
              (surface-ast-write-reduce-op! out op)
              (surface-ast-write-name! out context index)
              (surface-ast-write-type! out context index-ty)
              (surface-ast-write-i64! out start)
              (surface-ast-write-i64! out end)
              (surface-ast-write-i64! out init)
              (surface-ast-write-i64! out value))])]
      [(AstExpr.SpmdScan payload)
        (match (box-get payload)
          [(AstSpmdScan.Scan
              op
              index
              index-ty
              start
              end
              prefix
              prefix-ty
              init
              value
              body)
            (begin
              (surface-ast-write-i64! out 29)
              (surface-ast-write-reduce-op! out op)
              (surface-ast-write-name! out context index)
              (surface-ast-write-type! out context index-ty)
              (surface-ast-write-i64! out start)
              (surface-ast-write-i64! out end)
              (surface-ast-write-name! out context prefix)
              (surface-ast-write-type! out context prefix-ty)
              (surface-ast-write-i64! out init)
              (surface-ast-write-i64! out value)
              (surface-ast-write-i64! out body))])]
      [(AstExpr.SpmdBroadcast value lane)
        (begin
          (surface-ast-write-i64! out 30)
          (surface-ast-write-i64! out value)
          (surface-ast-write-i64! out lane))]
      [(AstExpr.SpmdShuffle value lane)
        (begin
          (surface-ast-write-i64! out 31)
          (surface-ast-write-i64! out value)
          (surface-ast-write-i64! out lane))]
      [(AstExpr.SpmdProgramIndex) (surface-ast-write-i64! out 32)]
      [(AstExpr.SpmdProgramCount) (surface-ast-write-i64! out 33)]
      [(AstExpr.StructGet target field)
        (begin
          (surface-ast-write-i64! out 34)
          (surface-ast-write-i64! out target)
          (surface-ast-write-name! out context field))]
      [(AstExpr.StructSet target field value)
        (begin
          (surface-ast-write-i64! out 35)
          (surface-ast-write-i64! out target)
          (surface-ast-write-name! out context field)
          (surface-ast-write-i64! out value))]
      [(AstExpr.WithRegion region body)
        (begin
          (surface-ast-write-i64! out 36)
          (surface-ast-write-name! out context region)
          (surface-ast-write-expr-list! out body))]
      [(AstExpr.WithEscape escape body)
        (begin
          (surface-ast-write-i64! out 37)
          (surface-ast-write-i64! out escape)
          (surface-ast-write-expr-list! out body))]
      [(AstExpr.WithScratch body)
        (begin
          (surface-ast-write-i64! out 38)
          (surface-ast-write-expr-list! out body))]
      [(AstExpr.InArena arena body)
        (begin
          (surface-ast-write-i64! out 39)
          (surface-ast-write-i64! out arena)
          (surface-ast-write-expr-list! out body))]
      [(AstExpr.WithResource payload)
        (match (box-get payload)
          [(AstWithResource.WithResource bindings body)
            (begin
              (surface-ast-write-i64! out 40)
              (surface-ast-write-resource-binding-list! out context bindings)
              (surface-ast-write-expr-list! out body))])]
      [(AstExpr.Box value)
        (begin
          (surface-ast-write-i64! out 41)
          (surface-ast-write-i64! out value))]
      [(AstExpr.BoxGet value)
        (begin
          (surface-ast-write-i64! out 42)
          (surface-ast-write-i64! out value))]
      [(AstExpr.BoxTake value)
        (begin
          (surface-ast-write-i64! out 43)
          (surface-ast-write-i64! out value))]
      [(AstExpr.BoxSet target value)
        (begin
          (surface-ast-write-i64! out 44)
          (surface-ast-write-i64! out target)
          (surface-ast-write-i64! out value))]
      [(AstExpr.TypeLiteral ty-id)
        (begin
          (surface-ast-write-i64! out 45)
          (surface-ast-write-i64! out ty-id))]
      [(AstExpr.Init maybe-ty-id)
        (begin
          (surface-ast-write-i64! out 46)
          (surface-ast-write-i64! out maybe-ty-id))]
      [(AstExpr.Comptime inner)
        (begin
          (surface-ast-write-i64! out 47)
          (surface-ast-write-i64! out inner))]
      [(AstExpr.Quote inner)
        (begin
          (surface-ast-write-i64! out 48)
          (surface-ast-write-i64! out inner))]
      [(AstExpr.Quasiquote inner)
        (begin
          (surface-ast-write-i64! out 49)
          (surface-ast-write-i64! out inner))]
      [(AstExpr.Unquote inner)
        (begin
          (surface-ast-write-i64! out 50)
          (surface-ast-write-i64! out inner))]
      [(AstExpr.UnquoteSplicing inner)
        (begin
          (surface-ast-write-i64! out 51)
          (surface-ast-write-i64! out inner))]
      [(AstExpr.BracketClause items)
        (begin
          (surface-ast-write-i64! out 52)
          (surface-ast-write-expr-list! out items))]
      [(AstExpr.Try inner)
        (begin
          (surface-ast-write-i64! out 53)
          (surface-ast-write-i64! out inner))]
      [(AstExpr.Return inner)
        (begin
          (surface-ast-write-i64! out 54)
          (surface-ast-write-i64! out inner))]
      [(AstExpr.Break) (surface-ast-write-i64! out 55)]
      [(AstExpr.Continue) (surface-ast-write-i64! out 56)]
      [(AstExpr.PtrNull ty-id)
        (begin
          (surface-ast-write-i64! out 57)
          (surface-ast-write-i64! out ty-id))]
      [(AstExpr.PtrNullCheck ptr)
        (begin
          (surface-ast-write-i64! out 58)
          (surface-ast-write-i64! out ptr))]
      [(AstExpr.PtrAddrOf place)
        (begin
          (surface-ast-write-i64! out 59)
          (surface-ast-write-i64! out place))]
      [(AstExpr.PtrRead ptr)
        (begin
          (surface-ast-write-i64! out 60)
          (surface-ast-write-i64! out ptr))]
      [(AstExpr.PtrWrite ptr value)
        (begin
          (surface-ast-write-i64! out 61)
          (surface-ast-write-i64! out ptr)
          (surface-ast-write-i64! out value))]
      [(AstExpr.PtrOffset ptr offset)
        (begin
          (surface-ast-write-i64! out 62)
          (surface-ast-write-i64! out ptr)
          (surface-ast-write-i64! out offset))]
      [(AstExpr.PtrCast ptr ty-id)
        (begin
          (surface-ast-write-i64! out 63)
          (surface-ast-write-i64! out ptr)
          (surface-ast-write-i64! out ty-id))]
      [(AstExpr.PtrToInt ptr)
        (begin
          (surface-ast-write-i64! out 64)
          (surface-ast-write-i64! out ptr))]
      [(AstExpr.IntToPtr value ty-id)
        (begin
          (surface-ast-write-i64! out 65)
          (surface-ast-write-i64! out value)
          (surface-ast-write-i64! out ty-id))]
      [(AstExpr.StringData value)
        (begin
          (surface-ast-write-i64! out 66)
          (surface-ast-write-i64! out value))]
      [(AstExpr.StringFromBytes data len)
        (begin
          (surface-ast-write-i64! out 67)
          (surface-ast-write-i64! out data)
          (surface-ast-write-i64! out len))]
      [(AstExpr.ArrayData value)
        (begin
          (surface-ast-write-i64! out 68)
          (surface-ast-write-i64! out value))]
      [(AstExpr.BinaryData data)
        (begin
          (surface-ast-write-i64! out 69)
          (surface-ast-write-string! out data))]
      [(AstExpr.ProgramArgc) (surface-ast-write-i64! out 70)]
      [(AstExpr.ProgramArgv) (surface-ast-write-i64! out 71)]
      [(AstExpr.ProgramEnvp) (surface-ast-write-i64! out 72)]
      [(AstExpr.CpuIdEax leaf subleaf)
        (begin
          (surface-ast-write-i64! out 73)
          (surface-ast-write-i64! out leaf)
          (surface-ast-write-i64! out subleaf))]
      [(AstExpr.CpuIdEbx leaf subleaf)
        (begin
          (surface-ast-write-i64! out 74)
          (surface-ast-write-i64! out leaf)
          (surface-ast-write-i64! out subleaf))]
      [(AstExpr.CpuIdEcx leaf subleaf)
        (begin
          (surface-ast-write-i64! out 75)
          (surface-ast-write-i64! out leaf)
          (surface-ast-write-i64! out subleaf))]
      [(AstExpr.CpuIdEdx leaf subleaf)
        (begin
          (surface-ast-write-i64! out 76)
          (surface-ast-write-i64! out leaf)
          (surface-ast-write-i64! out subleaf))]
      [(AstExpr.Xgetbv index)
        (begin
          (surface-ast-write-i64! out 77)
          (surface-ast-write-i64! out index))]
      [(AstExpr.Syscall args)
        (begin
          (surface-ast-write-i64! out 78)
          (surface-ast-write-expr-list! out args))])))

(define (surface-ast-read-expr! [reader : SurfaceAstReader]) : AstExpr
  (let
    [tag : i64 (surface-ast-read-i64! reader)]
    (cond
      [(= tag 0)
        (AstExpr.Spanned
          (surface-ast-read-i64! reader)
          (surface-ast-read-span! reader))]
      [(= tag 1) (AstExpr.Literal (surface-ast-read-literal! reader))]
      [(= tag 2) (AstExpr.Var (surface-ast-read-name! reader))]
      [(= tag 3)
        (AstExpr.Binary
          (surface-ast-read-bin-op! reader)
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 4)
        (AstExpr.Unary
          (surface-ast-read-un-op! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 5)
        (AstExpr.Call
          (surface-ast-read-i64! reader)
          (surface-ast-read-expr-list! reader))]
      [(= tag 6)
        (AstExpr.If
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 7)
        (AstExpr.Let
          (box
            (AstLet.Let
              (surface-ast-read-let-binding-list! reader)
              (surface-ast-read-i64! reader))))]
      [(= tag 8)
        (AstExpr.Lambda
          (box
            (AstLambda.Lambda
              (surface-ast-read-param-list! reader)
              (surface-ast-read-maybe-type! reader)
              (surface-ast-read-i64! reader))))]
      [(= tag 9) (AstExpr.Tuple (surface-ast-read-expr-list! reader))]
      [(= tag 10)
        (AstExpr.TupleRef
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 11) (AstExpr.Array (surface-ast-read-expr-list! reader))]
      [(= tag 12) (AstExpr.DynArray (surface-ast-read-expr-list! reader))]
      [(= tag 13)
        (AstExpr.MakeArray
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 14)
        (AstExpr.ArrayRef
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 15)
        (AstExpr.ArraySet
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 16)
        (AstExpr.ArrayTake
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 17)
        (AstExpr.ArrayPush
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 18)
        (AstExpr.StringRef
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 19)
        (AstExpr.While
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 20) (AstExpr.Begin (surface-ast-read-expr-list! reader))]
      [(= tag 21) (AstExpr.Unsafe (surface-ast-read-expr-list! reader))]
      [(= tag 22)
        (AstExpr.Set
          (surface-ast-read-name! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 23)
        (AstExpr.Ann
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 24)
        (AstExpr.Cast
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 25)
        (AstExpr.Borrow
          (surface-ast-read-bool! reader)
          (ast-borrow-lifetime-to-id (surface-ast-read-borrow-lifetime! reader))
          (surface-ast-read-i64! reader))]
      [(= tag 26)
        (AstExpr.Match
          (box
            (AstMatch.Match
              (surface-ast-read-i64! reader)
              (surface-ast-read-match-arm-list! reader))))]
      [(= tag 27)
        (AstExpr.Foreach
          (box
            (AstForeach.Foreach
              (surface-ast-read-name! reader)
              (surface-ast-read-type! reader)
              (surface-ast-read-i64! reader)
              (surface-ast-read-i64! reader)
              (surface-ast-read-i64! reader))))]
      [(= tag 28)
        (AstExpr.SpmdReduce
          (box
            (AstSpmdReduce.Reduce
              (surface-ast-read-reduce-op! reader)
              (surface-ast-read-name! reader)
              (surface-ast-read-type! reader)
              (surface-ast-read-i64! reader)
              (surface-ast-read-i64! reader)
              (surface-ast-read-i64! reader)
              (surface-ast-read-i64! reader))))]
      [(= tag 29)
        (AstExpr.SpmdScan
          (box
            (AstSpmdScan.Scan
              (surface-ast-read-reduce-op! reader)
              (surface-ast-read-name! reader)
              (surface-ast-read-type! reader)
              (surface-ast-read-i64! reader)
              (surface-ast-read-i64! reader)
              (surface-ast-read-name! reader)
              (surface-ast-read-type! reader)
              (surface-ast-read-i64! reader)
              (surface-ast-read-i64! reader)
              (surface-ast-read-i64! reader))))]
      [(= tag 30)
        (AstExpr.SpmdBroadcast
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 31)
        (AstExpr.SpmdShuffle
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 32) AstExpr.SpmdProgramIndex]
      [(= tag 33) AstExpr.SpmdProgramCount]
      [(= tag 34)
        (AstExpr.StructGet
          (surface-ast-read-i64! reader)
          (surface-ast-read-name! reader))]
      [(= tag 35)
        (AstExpr.StructSet
          (surface-ast-read-i64! reader)
          (surface-ast-read-name! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 36)
        (AstExpr.WithRegion
          (surface-ast-read-name! reader)
          (surface-ast-read-expr-list! reader))]
      [(= tag 37)
        (AstExpr.WithEscape
          (surface-ast-read-i64! reader)
          (surface-ast-read-expr-list! reader))]
      [(= tag 38) (AstExpr.WithScratch (surface-ast-read-expr-list! reader))]
      [(= tag 39)
        (AstExpr.InArena
          (surface-ast-read-i64! reader)
          (surface-ast-read-expr-list! reader))]
      [(= tag 40)
        (AstExpr.WithResource
          (box
            (AstWithResource.WithResource
              (surface-ast-read-resource-binding-list! reader)
              (surface-ast-read-expr-list! reader))))]
      [(= tag 41) (AstExpr.Box (surface-ast-read-i64! reader))]
      [(= tag 42) (AstExpr.BoxGet (surface-ast-read-i64! reader))]
      [(= tag 43) (AstExpr.BoxTake (surface-ast-read-i64! reader))]
      [(= tag 44)
        (AstExpr.BoxSet
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 45) (AstExpr.TypeLiteral (surface-ast-read-i64! reader))]
      [(= tag 46) (AstExpr.Init (surface-ast-read-i64! reader))]
      [(= tag 47) (AstExpr.Comptime (surface-ast-read-i64! reader))]
      [(= tag 48) (AstExpr.Quote (surface-ast-read-i64! reader))]
      [(= tag 49) (AstExpr.Quasiquote (surface-ast-read-i64! reader))]
      [(= tag 50) (AstExpr.Unquote (surface-ast-read-i64! reader))]
      [(= tag 51) (AstExpr.UnquoteSplicing (surface-ast-read-i64! reader))]
      [(= tag 52) (AstExpr.BracketClause (surface-ast-read-expr-list! reader))]
      [(= tag 53) (AstExpr.Try (surface-ast-read-i64! reader))]
      [(= tag 54) (AstExpr.Return (surface-ast-read-i64! reader))]
      [(= tag 55) AstExpr.Break]
      [(= tag 56) AstExpr.Continue]
      [(= tag 57) (AstExpr.PtrNull (surface-ast-read-i64! reader))]
      [(= tag 58) (AstExpr.PtrNullCheck (surface-ast-read-i64! reader))]
      [(= tag 59) (AstExpr.PtrAddrOf (surface-ast-read-i64! reader))]
      [(= tag 60) (AstExpr.PtrRead (surface-ast-read-i64! reader))]
      [(= tag 61)
        (AstExpr.PtrWrite
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 62)
        (AstExpr.PtrOffset
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 63)
        (AstExpr.PtrCast
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 64) (AstExpr.PtrToInt (surface-ast-read-i64! reader))]
      [(= tag 65)
        (AstExpr.IntToPtr
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 66) (AstExpr.StringData (surface-ast-read-i64! reader))]
      [(= tag 67)
        (AstExpr.StringFromBytes
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 68) (AstExpr.ArrayData (surface-ast-read-i64! reader))]
      [(= tag 69) (AstExpr.BinaryData (surface-ast-read-string! reader))]
      [(= tag 70) AstExpr.ProgramArgc]
      [(= tag 71) AstExpr.ProgramArgv]
      [(= tag 72) AstExpr.ProgramEnvp]
      [(= tag 73)
        (AstExpr.CpuIdEax
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 74)
        (AstExpr.CpuIdEbx
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 75)
        (AstExpr.CpuIdEcx
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 76)
        (AstExpr.CpuIdEdx
          (surface-ast-read-i64! reader)
          (surface-ast-read-i64! reader))]
      [(= tag 77) (AstExpr.Xgetbv (surface-ast-read-i64! reader))]
      [(= tag 78) (AstExpr.Syscall (surface-ast-read-expr-list! reader))]
      [else
        (begin
          (surface-ast-reader-fail!
            reader
            "surface ast: invalid expression tag")
          AstExpr.ProgramArgc)])))