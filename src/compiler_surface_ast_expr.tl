;; compiler_surface_ast_expr.tl - exhaustive expression surface codec.
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import compiler_surface_ast_codec_core as codec)

;; Embedded surface hydration remaps expression/type identities before later
;; compiler modules import byte_buf_core. Keep that nominal dependency present
;; for the routed bootstrap; without it, stage2 faults while loading the prelude
;; surface produced by stage1.
(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (import stdlib.byte_buf_core))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-optional-name!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [name : i64]) : unit
    (if (< name 0)
      (codec.surface-ast-write-bool! out false)
      (begin
        (codec.surface-ast-write-bool! out true)
        (codec.surface-ast-write-name! out context name)))))

(define (surface-ast-read-optional-name!
  [reader : (& reader codec.SurfaceAstReader)]) : i64
  (if (codec.surface-ast-read-bool! reader)
    (codec.surface-ast-read-name! reader)
    -1))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-expr-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [items : ast.AstExprList]) : unit
    (let
      [index : i64 0]
      [count : i64 items.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (begin
            (codec.surface-ast-write-i64! out (array-ref items.slots index))
            (set! index (+ index 1))))))))

(define (surface-ast-read-expr-list!
  [reader : (& reader codec.SurfaceAstReader)]) : ast.AstExprList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref slots index) (codec.surface-ast-read-i64! reader))
          (set! index (+ index 1))))
      (ast.AstExprList slots count))))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-param!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [param : ast.AstParam]) : unit
    (match param
      [(ast.AstParam.Param name ty is-comptime)
        (begin
          (codec.surface-ast-write-name! out context name)
          (codec.surface-ast-write-type! out context ty)
          (codec.surface-ast-write-bool! out is-comptime))])))

(define (surface-ast-read-param! [reader : (& reader codec.SurfaceAstReader)]) : ast.AstParam
  (ast.AstParam.Param
    (codec.surface-ast-read-name! reader)
    (codec.surface-ast-read-type! reader)
    (codec.surface-ast-read-bool! reader)))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-param-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [params : ast.AstParamList]) : unit
    (let
      [index : i64 0]
      [count : i64 params.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (begin
            (surface-ast-write-param!
              out
              context
              (ast.ast-array-shared-view params.slots index))
            (set! index (+ index 1))))))))

(define (surface-ast-read-param-list!
  [reader : (& reader codec.SurfaceAstReader)]) : ast.AstParamList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstParam) (__tl_make-array ast.AstParam count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref slots index) (surface-ast-read-param! reader))
          (set! index (+ index 1))))
      (ast.AstParamList slots count))))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-pattern-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [patterns : ast.AstPatternList]) : unit
    (let
      [index : i64 0]
      [count : i64 patterns.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (begin
            (surface-ast-write-pattern!
              out
              context
              (ast.ast-array-shared-view patterns.slots index))
            (set! index (+ index 1))))))))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-pattern!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [pattern : ast.AstPattern]) : unit
    (match pattern
      [(ast.AstPattern.Var name maybe-ty)
        (begin
          (codec.surface-ast-write-i64! out 0)
          (codec.surface-ast-write-name! out context name)
          (codec.surface-ast-write-maybe-type! out context maybe-ty))]
      [(ast.AstPattern.Tuple items)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (surface-ast-write-pattern-list!
            out
            context
            (ast.ast-pattern-list-box-shared-view items)))]
      [(ast.AstPattern.Array items)
        (begin
          (codec.surface-ast-write-i64! out 6)
          (surface-ast-write-pattern-list!
            out
            context
            (ast.ast-pattern-list-box-shared-view items)))]
      [(ast.AstPattern.Wildcard) (codec.surface-ast-write-i64! out 2)]
      [(ast.AstPattern.Binding name)
        (begin
          (codec.surface-ast-write-i64! out 3)
          (codec.surface-ast-write-name! out context name))]
      [(ast.AstPattern.Variant name items)
        (begin
          (codec.surface-ast-write-i64! out 4)
          (codec.surface-ast-write-name! out context name)
          (surface-ast-write-pattern-list!
            out
            context
            (ast.ast-pattern-list-box-shared-view items)))]
      [(ast.AstPattern.Literal literal)
        (begin
          (codec.surface-ast-write-i64! out 5)
          (codec.surface-ast-write-literal! out context literal))])))

(define (surface-ast-read-pattern-list!
  [reader : (& reader codec.SurfaceAstReader)]) : ast.AstPatternList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstPattern)
      (__tl_make-array ast.AstPattern count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! (array-ref slots index) (surface-ast-read-pattern! reader))
          (set! index (+ index 1))))
      (ast.AstPatternList slots count))))

(define (surface-ast-read-pattern! [reader : (& reader codec.SurfaceAstReader)]) : ast.AstPattern
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0)
        (ast.AstPattern.Var
          (codec.surface-ast-read-name! reader)
          (codec.surface-ast-read-maybe-type! reader))]
      [(= tag 1)
        (ast.AstPattern.Tuple (box (surface-ast-read-pattern-list! reader)))]
      [(= tag 2) ast.AstPattern.Wildcard]
      [(= tag 3) (ast.AstPattern.Binding (codec.surface-ast-read-name! reader))]
      [(= tag 4)
        (ast.AstPattern.Variant
          (codec.surface-ast-read-name! reader)
          (box (surface-ast-read-pattern-list! reader)))]
      [(= tag 5)
        (ast.AstPattern.Literal (codec.surface-ast-read-literal! reader))]
      [(= tag 6)
        (ast.AstPattern.Array (box (surface-ast-read-pattern-list! reader)))]
      [else
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid pattern tag")
          ast.AstPattern.Wildcard)])))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-let-binding-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [bindings : ast.AstLetBindingList]) : unit
    (let
      [index : i64 0]
      [count : i64 bindings.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (match (ast.ast-array-shared-view bindings.slots index)
            [(ast.AstLetBinding.Binding name maybe-ty value)
              (begin
                (codec.surface-ast-write-name! out context name)
                (codec.surface-ast-write-maybe-type! out context maybe-ty)
                (codec.surface-ast-write-i64! out value))])
          (set! index (+ index 1)))))))

(define (surface-ast-read-let-binding-list!
  [reader : (& reader codec.SurfaceAstReader)]) : ast.AstLetBindingList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstLetBinding)
      (__tl_make-array ast.AstLetBinding count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref slots index)
            (ast.AstLetBinding.Binding
              (codec.surface-ast-read-name! reader)
              (codec.surface-ast-read-maybe-type! reader)
              (codec.surface-ast-read-i64! reader)))
          (set! index (+ index 1))))
      (ast.AstLetBindingList slots count))))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-resource-binding-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [bindings : ast.AstResourceBindingList]) : unit
    (let
      [index : i64 0]
      [count : i64 bindings.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (match (ast.ast-array-shared-view bindings.slots index)
            [(ast.AstResourceBinding.Binding name init cleanup fallible)
              (begin
                (codec.surface-ast-write-name! out context name)
                (codec.surface-ast-write-i64! out init)
                (codec.surface-ast-write-i64! out cleanup)
                (codec.surface-ast-write-bool! out fallible))])
          (set! index (+ index 1)))))))

(define (surface-ast-read-resource-binding-list!
  [reader : (& reader codec.SurfaceAstReader)]) : ast.AstResourceBindingList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstResourceBinding)
      (__tl_make-array ast.AstResourceBinding count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref slots index)
            (ast.AstResourceBinding.Binding
              (codec.surface-ast-read-name! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-bool! reader)))
          (set! index (+ index 1))))
      (ast.AstResourceBindingList slots count))))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-match-arm-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [arms : ast.AstMatchArmList]) : unit
    (let
      [index : i64 0]
      [count : i64 arms.len]
      (begin
        (codec.surface-ast-write-i64! out count)
        (while (< index count)
          (match (ast.ast-array-shared-view arms.slots index)
            [(ast.AstMatchArm.Arm pattern body)
              (begin
                (surface-ast-write-pattern! out context pattern)
                (codec.surface-ast-write-i64! out body))])
          (set! index (+ index 1)))))))

(define (surface-ast-read-match-arm-list!
  [reader : (& reader codec.SurfaceAstReader)]) : ast.AstMatchArmList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstMatchArm)
      (__tl_make-array ast.AstMatchArm count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (set!
            (array-ref slots index)
            (ast.AstMatchArm.Arm
              (surface-ast-read-pattern! reader)
              (codec.surface-ast-read-i64! reader)))
          (set! index (+ index 1))))
      (ast.AstMatchArmList slots count))))

(cfg
  (any
    compiler-surface-producer
    compiler-surface-selftest
    compiler-build-identity
    embedded-stdlib-tlci)
  (define (surface-ast-write-expr!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [expr : ast.AstExpr]) : unit
    (match expr
      [(ast.AstExpr.Spanned inner span)
        (begin
          (codec.surface-ast-write-i64! out 0)
          (codec.surface-ast-write-i64! out inner)
          (codec.surface-ast-write-span! out span))]
      [(ast.AstExpr.Literal literal)
        (begin
          (codec.surface-ast-write-i64! out 1)
          (codec.surface-ast-write-literal! out context literal))]
      [(ast.AstExpr.Var name)
        (begin
          (codec.surface-ast-write-i64! out 2)
          (codec.surface-ast-write-name! out context name))]
      [(ast.AstExpr.Binary op left right)
        (begin
          (codec.surface-ast-write-i64! out 3)
          (codec.surface-ast-write-bin-op! out op)
          (codec.surface-ast-write-i64! out left)
          (codec.surface-ast-write-i64! out right))]
      [(ast.AstExpr.Unary op inner)
        (begin
          (codec.surface-ast-write-i64! out 4)
          (codec.surface-ast-write-un-op! out op)
          (codec.surface-ast-write-i64! out inner))]
      [(ast.AstExpr.Call callee args)
        (begin
          (codec.surface-ast-write-i64! out 5)
          (codec.surface-ast-write-i64! out callee)
          (surface-ast-write-expr-list! out args))]
      [(ast.AstExpr.If condition then-expr else-expr)
        (begin
          (codec.surface-ast-write-i64! out 6)
          (codec.surface-ast-write-i64! out condition)
          (codec.surface-ast-write-i64! out then-expr)
          (codec.surface-ast-write-i64! out else-expr))]
      [(ast.AstExpr.Let payload)
        (match (ast.ast-let-box-shared-view payload)
          [(ast.AstLet.Let bindings body)
            (begin
              (codec.surface-ast-write-i64! out 7)
              (surface-ast-write-let-binding-list! out context bindings)
              (codec.surface-ast-write-i64! out body))])]
      [(ast.AstExpr.Lambda payload)
        (match (ast.ast-lambda-box-shared-view payload)
          [(ast.AstLambda.Lambda params ret body)
            (begin
              (codec.surface-ast-write-i64! out 8)
              (surface-ast-write-param-list! out context params)
              (codec.surface-ast-write-maybe-type! out context ret)
              (codec.surface-ast-write-i64! out body))])]
      [(ast.AstExpr.Tuple items)
        (begin
          (codec.surface-ast-write-i64! out 9)
          (surface-ast-write-expr-list! out items))]
      [(ast.AstExpr.TupleRef target index)
        (begin
          (codec.surface-ast-write-i64! out 10)
          (codec.surface-ast-write-i64! out target)
          (codec.surface-ast-write-i64! out index))]
      [(ast.AstExpr.Array items)
        (begin
          (codec.surface-ast-write-i64! out 11)
          (surface-ast-write-expr-list! out items))]
      [(ast.AstExpr.DynArray items)
        (begin
          (codec.surface-ast-write-i64! out 12)
          (surface-ast-write-expr-list! out items))]
      [(ast.AstExpr.FixedMakeArray ty-id size)
        (begin
          (codec.surface-ast-write-i64! out 85)
          (codec.surface-ast-write-i64! out ty-id)
          (codec.surface-ast-write-i64! out size))]
      [(ast.AstExpr.MakeArray ty-id size)
        (begin
          (codec.surface-ast-write-i64! out 13)
          (codec.surface-ast-write-i64! out ty-id)
          (codec.surface-ast-write-i64! out size))]
      [(ast.AstExpr.ArrayRef target index)
        (begin
          (codec.surface-ast-write-i64! out 14)
          (codec.surface-ast-write-i64! out target)
          (codec.surface-ast-write-i64! out index))]
      [(ast.AstExpr.ArraySet target index value)
        (begin
          (codec.surface-ast-write-i64! out 15)
          (codec.surface-ast-write-i64! out target)
          (codec.surface-ast-write-i64! out index)
          (codec.surface-ast-write-i64! out value))]
      [(ast.AstExpr.ArrayTake target live index)
        (begin
          (codec.surface-ast-write-i64! out 16)
          (codec.surface-ast-write-i64! out target)
          (codec.surface-ast-write-i64! out live)
          (codec.surface-ast-write-i64! out index))]
      [(ast.AstExpr.FixedArrayTake target index)
        (begin
          (codec.surface-ast-write-i64! out 79)
          (codec.surface-ast-write-i64! out target)
          (codec.surface-ast-write-i64! out index))]
      [(ast.AstExpr.Replace place replacement)
        (begin
          (codec.surface-ast-write-i64! out 84)
          (codec.surface-ast-write-i64! out place)
          (codec.surface-ast-write-i64! out replacement))]
      [(ast.AstExpr.ArrayPush target value)
        (begin
          (codec.surface-ast-write-i64! out 17)
          (codec.surface-ast-write-i64! out target)
          (codec.surface-ast-write-i64! out value))]
      [(ast.AstExpr.StringRef target index)
        (begin
          (codec.surface-ast-write-i64! out 18)
          (codec.surface-ast-write-i64! out target)
          (codec.surface-ast-write-i64! out index))]
      [(ast.AstExpr.While condition body)
        (begin
          (codec.surface-ast-write-i64! out 19)
          (codec.surface-ast-write-i64! out condition)
          (codec.surface-ast-write-i64! out body))]
      [(ast.AstExpr.Begin items)
        (begin
          (codec.surface-ast-write-i64! out 20)
          (surface-ast-write-expr-list! out items))]
      [(ast.AstExpr.Unsafe items)
        (begin
          (codec.surface-ast-write-i64! out 21)
          (surface-ast-write-expr-list! out items))]
      [(ast.AstExpr.Set name value)
        (begin
          (codec.surface-ast-write-i64! out 22)
          (codec.surface-ast-write-name! out context name)
          (codec.surface-ast-write-i64! out value))]
      [(ast.AstExpr.Ann inner ty-id)
        (begin
          (codec.surface-ast-write-i64! out 23)
          (codec.surface-ast-write-i64! out inner)
          (codec.surface-ast-write-i64! out ty-id))]
      [(ast.AstExpr.Cast inner ty-id)
        (begin
          (codec.surface-ast-write-i64! out 24)
          (codec.surface-ast-write-i64! out inner)
          (codec.surface-ast-write-i64! out ty-id))]
      [(ast.AstExpr.Borrow mutable lifetime-id inner)
        (begin
          (codec.surface-ast-write-i64! out 25)
          (codec.surface-ast-write-bool! out mutable)
          (codec.surface-ast-write-borrow-lifetime!
            out
            context
            (ast.ast-borrow-lifetime-from-id lifetime-id))
          (codec.surface-ast-write-i64! out inner))]
      [(ast.AstExpr.Match payload)
        (match (ast.ast-match-box-shared-view payload)
          [(ast.AstMatch.Match scrutinee arms)
            (begin
              (codec.surface-ast-write-i64! out 26)
              (codec.surface-ast-write-i64! out scrutinee)
              (surface-ast-write-match-arm-list! out context arms))])]
      [(ast.AstExpr.Foreach payload)
        (match (ast.ast-foreach-box-shared-view payload)
          [(ast.AstForeach.Foreach name index-ty start end body)
            (begin
              (codec.surface-ast-write-i64! out 27)
              (codec.surface-ast-write-name! out context name)
              (codec.surface-ast-write-type! out context index-ty)
              (codec.surface-ast-write-i64! out start)
              (codec.surface-ast-write-i64! out end)
              (codec.surface-ast-write-i64! out body))])]
      [(ast.AstExpr.SpmdReduce payload)
        (match (ast.ast-spmd-reduce-box-shared-view payload)
          [(ast.AstSpmdReduce.Reduce op index index-ty start end init value)
            (begin
              (codec.surface-ast-write-i64! out 28)
              (codec.surface-ast-write-reduce-op! out op)
              (codec.surface-ast-write-name! out context index)
              (codec.surface-ast-write-type! out context index-ty)
              (codec.surface-ast-write-i64! out start)
              (codec.surface-ast-write-i64! out end)
              (codec.surface-ast-write-i64! out init)
              (codec.surface-ast-write-i64! out value))])]
      [(ast.AstExpr.SpmdScan payload)
        (match (ast.ast-spmd-scan-box-shared-view payload)
          [(ast.AstSpmdScan.Scan
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
              (codec.surface-ast-write-i64! out 29)
              (codec.surface-ast-write-reduce-op! out op)
              (codec.surface-ast-write-name! out context index)
              (codec.surface-ast-write-type! out context index-ty)
              (codec.surface-ast-write-i64! out start)
              (codec.surface-ast-write-i64! out end)
              (codec.surface-ast-write-name! out context prefix)
              (codec.surface-ast-write-type! out context prefix-ty)
              (codec.surface-ast-write-i64! out init)
              (codec.surface-ast-write-i64! out value)
              (codec.surface-ast-write-i64! out body))])]
      [(ast.AstExpr.SpmdCompact payload)
        (match (ast.ast-spmd-compact-box-shared-view payload)
          [(ast.AstSpmdCompact.Compact
              index
              index-ty
              start
              end
              slot
              slot-ty
              init
              keep
              body)
            (begin
              (codec.surface-ast-write-i64! out 86)
              (codec.surface-ast-write-name! out context index)
              (codec.surface-ast-write-type! out context index-ty)
              (codec.surface-ast-write-i64! out start)
              (codec.surface-ast-write-i64! out end)
              (codec.surface-ast-write-name! out context slot)
              (codec.surface-ast-write-type! out context slot-ty)
              (codec.surface-ast-write-i64! out init)
              (codec.surface-ast-write-i64! out keep)
              (codec.surface-ast-write-i64! out body))])]
      [(ast.AstExpr.SpmdBroadcast value lane)
        (begin
          (codec.surface-ast-write-i64! out 30)
          (codec.surface-ast-write-i64! out value)
          (codec.surface-ast-write-i64! out lane))]
      [(ast.AstExpr.SpmdShuffle value lane)
        (begin
          (codec.surface-ast-write-i64! out 31)
          (codec.surface-ast-write-i64! out value)
          (codec.surface-ast-write-i64! out lane))]
      [(ast.AstExpr.SpmdProgramIndex) (codec.surface-ast-write-i64! out 32)]
      [(ast.AstExpr.SpmdProgramCount) (codec.surface-ast-write-i64! out 33)]
      [(ast.AstExpr.StructGet target field)
        (begin
          (codec.surface-ast-write-i64! out 34)
          (codec.surface-ast-write-i64! out target)
          (codec.surface-ast-write-name! out context field))]
      [(ast.AstExpr.StructSet target field value)
        (if (ast.ast-tuple-set-field-id? field)
          (begin
            ;; Append-only surface tag for the private tuple-place encoding.
            ;; Tag 35 remains the portable struct-field form and therefore
            ;; continues to carry a relocatable identity instead of a raw ID.
            (codec.surface-ast-write-i64! out 83)
            (codec.surface-ast-write-i64! out target)
            (codec.surface-ast-write-i64!
              out
              (ast.ast-tuple-set-index-from-field-id field))
            (codec.surface-ast-write-i64! out value))
          (begin
            (codec.surface-ast-write-i64! out 35)
            (codec.surface-ast-write-i64! out target)
            (codec.surface-ast-write-name! out context field)
            (codec.surface-ast-write-i64! out value)))]
      [(ast.AstExpr.WithRegion region body)
        (begin
          (codec.surface-ast-write-i64! out 36)
          (codec.surface-ast-write-name! out context region)
          (surface-ast-write-expr-list! out body))]
      [(ast.AstExpr.WithEscape escape body)
        (begin
          (codec.surface-ast-write-i64! out 37)
          (codec.surface-ast-write-i64! out escape)
          (surface-ast-write-expr-list! out body))]
      [(ast.AstExpr.WithScratch body)
        (begin
          (codec.surface-ast-write-i64! out 38)
          (surface-ast-write-expr-list! out body))]
      [(ast.AstExpr.InArena arena body)
        (begin
          (codec.surface-ast-write-i64! out 39)
          (codec.surface-ast-write-i64! out arena)
          (surface-ast-write-expr-list! out body))]
      [(ast.AstExpr.WithResource payload)
        (match (ast.ast-with-resource-box-shared-view payload)
          [(ast.AstWithResource.WithResource bindings body)
            (begin
              (codec.surface-ast-write-i64! out 40)
              (surface-ast-write-resource-binding-list! out context bindings)
              (surface-ast-write-expr-list! out body))])]
      [(ast.AstExpr.Box value)
        (begin
          (codec.surface-ast-write-i64! out 41)
          (codec.surface-ast-write-i64! out value))]
      [(ast.AstExpr.BoxGet value)
        (begin
          (codec.surface-ast-write-i64! out 42)
          (codec.surface-ast-write-i64! out value))]
      [(ast.AstExpr.BoxTake value)
        (begin
          (codec.surface-ast-write-i64! out 43)
          (codec.surface-ast-write-i64! out value))]
      [(ast.AstExpr.BoxSet target value)
        (begin
          (codec.surface-ast-write-i64! out 44)
          (codec.surface-ast-write-i64! out target)
          (codec.surface-ast-write-i64! out value))]
      [(ast.AstExpr.TypeLiteral ty-id)
        (begin
          (codec.surface-ast-write-i64! out 45)
          (codec.surface-ast-write-i64! out ty-id))]
      [(ast.AstExpr.Init maybe-ty-id)
        (begin
          (codec.surface-ast-write-i64! out 46)
          (codec.surface-ast-write-i64! out maybe-ty-id))]
      [(ast.AstExpr.Comptime inner)
        (begin
          (codec.surface-ast-write-i64! out 47)
          (codec.surface-ast-write-i64! out inner))]
      [(ast.AstExpr.Quote inner)
        (begin
          (codec.surface-ast-write-i64! out 48)
          (codec.surface-ast-write-i64! out inner))]
      [(ast.AstExpr.Quasiquote inner)
        (begin
          (codec.surface-ast-write-i64! out 49)
          (codec.surface-ast-write-i64! out inner))]
      [(ast.AstExpr.Unquote inner)
        (begin
          (codec.surface-ast-write-i64! out 50)
          (codec.surface-ast-write-i64! out inner))]
      [(ast.AstExpr.UnquoteSplicing inner)
        (begin
          (codec.surface-ast-write-i64! out 51)
          (codec.surface-ast-write-i64! out inner))]
      [(ast.AstExpr.BracketClause items)
        (begin
          (codec.surface-ast-write-i64! out 52)
          (surface-ast-write-expr-list! out items))]
      [(ast.AstExpr.Try inner)
        (begin
          (codec.surface-ast-write-i64! out 53)
          (codec.surface-ast-write-i64! out inner))]
      [(ast.AstExpr.Return inner)
        (begin
          (codec.surface-ast-write-i64! out 54)
          (codec.surface-ast-write-i64! out inner))]
      [(ast.AstExpr.Break) (codec.surface-ast-write-i64! out 55)]
      [(ast.AstExpr.Continue) (codec.surface-ast-write-i64! out 56)]
      [(ast.AstExpr.PtrNull ty-id)
        (begin
          (codec.surface-ast-write-i64! out 57)
          (codec.surface-ast-write-i64! out ty-id))]
      [(ast.AstExpr.PtrNullCheck ptr)
        (begin
          (codec.surface-ast-write-i64! out 58)
          (codec.surface-ast-write-i64! out ptr))]
      [(ast.AstExpr.PtrAddrOf place)
        (begin
          (codec.surface-ast-write-i64! out 59)
          (codec.surface-ast-write-i64! out place))]
      [(ast.AstExpr.PtrRead ptr)
        (begin
          (codec.surface-ast-write-i64! out 60)
          (codec.surface-ast-write-i64! out ptr))]
      [(ast.AstExpr.PtrWrite ptr value)
        (begin
          (codec.surface-ast-write-i64! out 61)
          (codec.surface-ast-write-i64! out ptr)
          (codec.surface-ast-write-i64! out value))]
      [(ast.AstExpr.PtrOffset ptr offset)
        (begin
          (codec.surface-ast-write-i64! out 62)
          (codec.surface-ast-write-i64! out ptr)
          (codec.surface-ast-write-i64! out offset))]
      [(ast.AstExpr.PtrCast ptr ty-id)
        (begin
          (codec.surface-ast-write-i64! out 63)
          (codec.surface-ast-write-i64! out ptr)
          (codec.surface-ast-write-i64! out ty-id))]
      [(ast.AstExpr.PtrToInt ptr)
        (begin
          (codec.surface-ast-write-i64! out 64)
          (codec.surface-ast-write-i64! out ptr))]
      [(ast.AstExpr.IntToPtr value ty-id)
        (begin
          (codec.surface-ast-write-i64! out 65)
          (codec.surface-ast-write-i64! out value)
          (codec.surface-ast-write-i64! out ty-id))]
      [(ast.AstExpr.StringData value)
        (begin
          (codec.surface-ast-write-i64! out 66)
          (codec.surface-ast-write-i64! out value))]
      [(ast.AstExpr.StringFromBytes data len)
        (begin
          (codec.surface-ast-write-i64! out 67)
          (codec.surface-ast-write-i64! out data)
          (codec.surface-ast-write-i64! out len))]
      [(ast.AstExpr.ArrayData value)
        (begin
          (codec.surface-ast-write-i64! out 68)
          (codec.surface-ast-write-i64! out value))]
      [(ast.AstExpr.BinaryData data)
        (begin
          (codec.surface-ast-write-i64! out 69)
          (codec.surface-ast-write-string! out data))]
      [(ast.AstExpr.ProgramArgc) (codec.surface-ast-write-i64! out 70)]
      [(ast.AstExpr.ProgramArgv) (codec.surface-ast-write-i64! out 71)]
      [(ast.AstExpr.ProgramEnvp) (codec.surface-ast-write-i64! out 72)]
      [(ast.AstExpr.CpuIdEax leaf subleaf)
        (begin
          (codec.surface-ast-write-i64! out 73)
          (codec.surface-ast-write-i64! out leaf)
          (codec.surface-ast-write-i64! out subleaf))]
      [(ast.AstExpr.CpuIdEbx leaf subleaf)
        (begin
          (codec.surface-ast-write-i64! out 74)
          (codec.surface-ast-write-i64! out leaf)
          (codec.surface-ast-write-i64! out subleaf))]
      [(ast.AstExpr.CpuIdEcx leaf subleaf)
        (begin
          (codec.surface-ast-write-i64! out 75)
          (codec.surface-ast-write-i64! out leaf)
          (codec.surface-ast-write-i64! out subleaf))]
      [(ast.AstExpr.CpuIdEdx leaf subleaf)
        (begin
          (codec.surface-ast-write-i64! out 76)
          (codec.surface-ast-write-i64! out leaf)
          (codec.surface-ast-write-i64! out subleaf))]
      [(ast.AstExpr.Xgetbv index)
        (begin
          (codec.surface-ast-write-i64! out 77)
          (codec.surface-ast-write-i64! out index))]
      [(ast.AstExpr.Syscall args)
        (begin
          (codec.surface-ast-write-i64! out 78)
          (surface-ast-write-expr-list! out args))]
      [(ast.AstExpr.ForOwnedState payload)
        (begin
          (codec.surface-ast-write-i64! out 80)
          (codec.surface-ast-write-i64!
            out
            (ast.ast-for-owned-state-source-name (& payload)))
          (codec.surface-ast-write-i64!
            out
            (ast.ast-for-owned-state-index-name (& payload)))
          (codec.surface-ast-write-i64!
            out
            (ast.ast-for-owned-state-source (& payload)))
          (codec.surface-ast-write-i64!
            out
            (ast.ast-for-owned-state-body (& payload))))]
      [(ast.AstExpr.ForOwnedStep payload)
        (begin
          (codec.surface-ast-write-i64! out 81)
          (codec.surface-ast-write-i64!
            out
            (ast.ast-for-owned-step-source-name (& payload)))
          (codec.surface-ast-write-i64!
            out
            (ast.ast-for-owned-step-index-name (& payload)))
          (codec.surface-ast-write-i64!
            out
            (ast.ast-for-owned-step-binding-name (& payload)))
          (codec.surface-ast-write-i64!
            out
            (ast.ast-for-owned-step-expected-type (& payload)))
          (codec.surface-ast-write-i64!
            out
            (ast.ast-for-owned-step-done-name (& payload)))
          (codec.surface-ast-write-i64!
            out
            (ast.ast-for-owned-step-body (& payload))))]
      [(ast.AstExpr.MacroExpansion inner provenance-id macro-name-id)
        (begin
          (codec.surface-ast-write-i64! out 82)
          (codec.surface-ast-write-i64! out inner)
          (surface-ast-write-optional-name!
            out
            context
            (ci.intern-composite-left-id-unchecked provenance-id))
          (surface-ast-write-optional-name!
            out
            context
            (ci.intern-composite-right-id-unchecked provenance-id))
          (surface-ast-write-optional-name! out context macro-name-id))])))

(define (surface-ast-read-expr! [reader : (& reader codec.SurfaceAstReader)]) : ast.AstExpr
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0)
        (ast.AstExpr.Spanned
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-span! reader))]
      [(= tag 1) (ast.AstExpr.Literal (codec.surface-ast-read-literal! reader))]
      [(= tag 2) (ast.AstExpr.Var (codec.surface-ast-read-name! reader))]
      [(= tag 3)
        (ast.AstExpr.Binary
          (codec.surface-ast-read-bin-op! reader)
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 4)
        (ast.AstExpr.Unary
          (codec.surface-ast-read-un-op! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 5)
        (ast.AstExpr.Call
          (codec.surface-ast-read-i64! reader)
          (surface-ast-read-expr-list! reader))]
      [(= tag 6)
        (ast.AstExpr.If
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 7)
        (ast.AstExpr.Let
          (box
            (ast.AstLet.Let
              (surface-ast-read-let-binding-list! reader)
              (codec.surface-ast-read-i64! reader))))]
      [(= tag 8)
        (ast.AstExpr.Lambda
          (box
            (ast.AstLambda.Lambda
              (surface-ast-read-param-list! reader)
              (codec.surface-ast-read-maybe-type! reader)
              (codec.surface-ast-read-i64! reader))))]
      [(= tag 9) (ast.AstExpr.Tuple (surface-ast-read-expr-list! reader))]
      [(= tag 10)
        (ast.AstExpr.TupleRef
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 11) (ast.AstExpr.Array (surface-ast-read-expr-list! reader))]
      [(= tag 12) (ast.AstExpr.DynArray (surface-ast-read-expr-list! reader))]
      [(= tag 85)
        (ast.AstExpr.FixedMakeArray
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 86)
        (ast.AstExpr.SpmdCompact
          (box
            (ast.AstSpmdCompact.Compact
              (codec.surface-ast-read-name! reader)
              (codec.surface-ast-read-type! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-name! reader)
              (codec.surface-ast-read-type! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-i64! reader))))]
      [(= tag 13)
        (ast.AstExpr.MakeArray
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 14)
        (ast.AstExpr.ArrayRef
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 15)
        (ast.AstExpr.ArraySet
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 16)
        (ast.AstExpr.ArrayTake
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 17)
        (ast.AstExpr.ArrayPush
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 18)
        (ast.AstExpr.StringRef
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 19)
        (ast.AstExpr.While
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 20) (ast.AstExpr.Begin (surface-ast-read-expr-list! reader))]
      [(= tag 21) (ast.AstExpr.Unsafe (surface-ast-read-expr-list! reader))]
      [(= tag 22)
        (ast.AstExpr.Set
          (codec.surface-ast-read-name! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 23)
        (ast.AstExpr.Ann
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 24)
        (ast.AstExpr.Cast
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 25)
        (ast.AstExpr.Borrow
          (codec.surface-ast-read-bool! reader)
          (ast.ast-borrow-lifetime-to-id
            (codec.surface-ast-read-borrow-lifetime! reader))
          (codec.surface-ast-read-i64! reader))]
      [(= tag 26)
        (ast.AstExpr.Match
          (box
            (ast.AstMatch.Match
              (codec.surface-ast-read-i64! reader)
              (surface-ast-read-match-arm-list! reader))))]
      [(= tag 27)
        (ast.AstExpr.Foreach
          (box
            (ast.AstForeach.Foreach
              (codec.surface-ast-read-name! reader)
              (codec.surface-ast-read-type! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-i64! reader))))]
      [(= tag 28)
        (ast.AstExpr.SpmdReduce
          (box
            (ast.AstSpmdReduce.Reduce
              (codec.surface-ast-read-reduce-op! reader)
              (codec.surface-ast-read-name! reader)
              (codec.surface-ast-read-type! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-i64! reader))))]
      [(= tag 29)
        (ast.AstExpr.SpmdScan
          (box
            (ast.AstSpmdScan.Scan
              (codec.surface-ast-read-reduce-op! reader)
              (codec.surface-ast-read-name! reader)
              (codec.surface-ast-read-type! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-name! reader)
              (codec.surface-ast-read-type! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-i64! reader))))]
      [(= tag 30)
        (ast.AstExpr.SpmdBroadcast
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 31)
        (ast.AstExpr.SpmdShuffle
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 32) ast.AstExpr.SpmdProgramIndex]
      [(= tag 33) ast.AstExpr.SpmdProgramCount]
      [(= tag 34)
        (ast.AstExpr.StructGet
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-name! reader))]
      [(= tag 35)
        (ast.AstExpr.StructSet
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-name! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 36)
        (ast.AstExpr.WithRegion
          (codec.surface-ast-read-name! reader)
          (surface-ast-read-expr-list! reader))]
      [(= tag 37)
        (ast.AstExpr.WithEscape
          (codec.surface-ast-read-i64! reader)
          (surface-ast-read-expr-list! reader))]
      [(= tag 38)
        (ast.AstExpr.WithScratch (surface-ast-read-expr-list! reader))]
      [(= tag 39)
        (ast.AstExpr.InArena
          (codec.surface-ast-read-i64! reader)
          (surface-ast-read-expr-list! reader))]
      [(= tag 40)
        (ast.AstExpr.WithResource
          (box
            (ast.AstWithResource.WithResource
              (surface-ast-read-resource-binding-list! reader)
              (surface-ast-read-expr-list! reader))))]
      [(= tag 41) (ast.AstExpr.Box (codec.surface-ast-read-i64! reader))]
      [(= tag 42) (ast.AstExpr.BoxGet (codec.surface-ast-read-i64! reader))]
      [(= tag 43) (ast.AstExpr.BoxTake (codec.surface-ast-read-i64! reader))]
      [(= tag 44)
        (ast.AstExpr.BoxSet
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 45)
        (ast.AstExpr.TypeLiteral (codec.surface-ast-read-i64! reader))]
      [(= tag 46) (ast.AstExpr.Init (codec.surface-ast-read-i64! reader))]
      [(= tag 47) (ast.AstExpr.Comptime (codec.surface-ast-read-i64! reader))]
      [(= tag 48) (ast.AstExpr.Quote (codec.surface-ast-read-i64! reader))]
      [(= tag 49) (ast.AstExpr.Quasiquote (codec.surface-ast-read-i64! reader))]
      [(= tag 50) (ast.AstExpr.Unquote (codec.surface-ast-read-i64! reader))]
      [(= tag 51)
        (ast.AstExpr.UnquoteSplicing (codec.surface-ast-read-i64! reader))]
      [(= tag 52)
        (ast.AstExpr.BracketClause (surface-ast-read-expr-list! reader))]
      [(= tag 53) (ast.AstExpr.Try (codec.surface-ast-read-i64! reader))]
      [(= tag 54) (ast.AstExpr.Return (codec.surface-ast-read-i64! reader))]
      [(= tag 55) ast.AstExpr.Break]
      [(= tag 56) ast.AstExpr.Continue]
      [(= tag 57) (ast.AstExpr.PtrNull (codec.surface-ast-read-i64! reader))]
      [(= tag 58)
        (ast.AstExpr.PtrNullCheck (codec.surface-ast-read-i64! reader))]
      [(= tag 59) (ast.AstExpr.PtrAddrOf (codec.surface-ast-read-i64! reader))]
      [(= tag 60) (ast.AstExpr.PtrRead (codec.surface-ast-read-i64! reader))]
      [(= tag 61)
        (ast.AstExpr.PtrWrite
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 62)
        (ast.AstExpr.PtrOffset
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 63)
        (ast.AstExpr.PtrCast
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 64) (ast.AstExpr.PtrToInt (codec.surface-ast-read-i64! reader))]
      [(= tag 65)
        (ast.AstExpr.IntToPtr
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 66) (ast.AstExpr.StringData (codec.surface-ast-read-i64! reader))]
      [(= tag 67)
        (ast.AstExpr.StringFromBytes
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 68) (ast.AstExpr.ArrayData (codec.surface-ast-read-i64! reader))]
      [(= tag 69)
        (ast.AstExpr.BinaryData (codec.surface-ast-read-string! reader))]
      [(= tag 70) ast.AstExpr.ProgramArgc]
      [(= tag 71) ast.AstExpr.ProgramArgv]
      [(= tag 72) ast.AstExpr.ProgramEnvp]
      [(= tag 73)
        (ast.AstExpr.CpuIdEax
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 74)
        (ast.AstExpr.CpuIdEbx
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 75)
        (ast.AstExpr.CpuIdEcx
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 76)
        (ast.AstExpr.CpuIdEdx
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 77) (ast.AstExpr.Xgetbv (codec.surface-ast-read-i64! reader))]
      [(= tag 78) (ast.AstExpr.Syscall (surface-ast-read-expr-list! reader))]
      [(= tag 79)
        (ast.AstExpr.FixedArrayTake
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 80)
        (ast.AstExpr.ForOwnedState
          (ast.ast-for-owned-state-payload
            (codec.surface-ast-read-i64! reader)
            (codec.surface-ast-read-i64! reader)
            (codec.surface-ast-read-i64! reader)
            (codec.surface-ast-read-i64! reader)))]
      [(= tag 81)
        (ast.AstExpr.ForOwnedStep
          (ast.ast-for-owned-step-payload
            (codec.surface-ast-read-i64! reader)
            (codec.surface-ast-read-i64! reader)
            (codec.surface-ast-read-i64! reader)
            (codec.surface-ast-read-i64! reader)
            (codec.surface-ast-read-i64! reader)
            (codec.surface-ast-read-i64! reader)))]
      [(= tag 82)
        (ast.AstExpr.MacroExpansion
          (codec.surface-ast-read-i64! reader)
          (ci.intern-composite-pair-id
            (surface-ast-read-optional-name! reader)
            (surface-ast-read-optional-name! reader))
          (surface-ast-read-optional-name! reader))]
      [(= tag 83)
        (ast.AstExpr.StructSet
          (codec.surface-ast-read-i64! reader)
          (ast.ast-tuple-set-field-id-from-index
            (codec.surface-ast-read-i64! reader))
          (codec.surface-ast-read-i64! reader))]
      [(= tag 84)
        (ast.AstExpr.Replace
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [else
        (begin
          (codec.surface-ast-reader-fail!
            reader
            "surface ast: invalid expression tag")
          ast.AstExpr.ProgramArgc)])))