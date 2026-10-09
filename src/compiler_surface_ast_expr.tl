;; compiler_surface_ast_expr.tl - exhaustive expression surface codec.
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import compiler_surface_ast_codec_core as codec)

;; Embedded surface hydration remaps expression/type identities before later
;; compiler modules import byte_buf_core. Keep that nominal dependency present
;; for the routed bootstrap; without it, stage2 faults while loading the prelude
;; surface produced by stage1.
(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (import stdlib.byte_buf_core))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
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
  [reader : (&mut reader codec.SurfaceAstReader)]) : i64
  (if (codec.surface-ast-read-bool! reader)
    (codec.surface-ast-read-name! reader)
    -1))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-expr-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [items : ast.AstExprList]) : unit
    (let
      [index : i64 0]
      [count : i64 items.len]
      (codec.surface-ast-write-i64! out count)
      (while (< index count)
        (codec.surface-ast-write-i64! out (array-ref items.slots index))
        (set! index (+ index 1))))))

(define (surface-ast-read-expr-list!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstExprList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array i64) (__tl_make-array i64 count)]
    [index : i64 0]
    (while (< index count)
      (set! (array-ref slots index) (codec.surface-ast-read-i64! reader))
      (set! index (+ index 1)))
    (ast.AstExprList slots count)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-param!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [param : ast.AstParam]) : unit
    (match param
      [(Param name ty is-comptime)
        (codec.surface-ast-write-name! out context name)
        (codec.surface-ast-write-type! out context ty)
        (codec.surface-ast-write-bool! out is-comptime)])))

(define (surface-ast-read-param!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstParam
  (Param
    (codec.surface-ast-read-name! reader)
    (codec.surface-ast-read-type! reader)
    (codec.surface-ast-read-bool! reader)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-param-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [params : ast.AstParamList]) : unit
    (let
      [index : i64 0]
      [count : i64 params.len]
      (codec.surface-ast-write-i64! out count)
      (while (< index count)
        (surface-ast-write-param!
          out
          context
          (ast.ast-array-shared-view params.slots index))
        (set! index (+ index 1))))))

(define (surface-ast-read-param-list!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstParamList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstParam) (__tl_make-array ast.AstParam count)]
    [index : i64 0]
    (while (< index count)
      (set! (array-ref slots index) (surface-ast-read-param! reader))
      (set! index (+ index 1)))
    (ast.AstParamList slots count)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-pattern-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [patterns : ast.AstPatternList]) : unit
    (let
      [index : i64 0]
      [count : i64 patterns.len]
      (codec.surface-ast-write-i64! out count)
      (while (< index count)
        (surface-ast-write-pattern!
          out
          context
          (ast.ast-array-shared-view patterns.slots index))
        (set! index (+ index 1))))))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-pattern!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [pattern : ast.AstPattern]) : unit
    (match pattern
      [(Var name maybe-ty)
        (codec.surface-ast-write-i64! out 0)
        (codec.surface-ast-write-name! out context name)
        (codec.surface-ast-write-maybe-type! out context maybe-ty)]
      [(Tuple items)
        (codec.surface-ast-write-i64! out 1)
        (surface-ast-write-pattern-list! out context (deref items))]
      [(Array items)
        (codec.surface-ast-write-i64! out 6)
        (surface-ast-write-pattern-list! out context (deref items))]
      [(Slice items has-rest)
        (codec.surface-ast-write-i64! out 7)
        (codec.surface-ast-write-bool! out has-rest)
        (surface-ast-write-pattern-list! out context (deref items))]
      [(Wildcard) (codec.surface-ast-write-i64! out 2)]
      [(Binding name)
        (codec.surface-ast-write-i64! out 3)
        (codec.surface-ast-write-name! out context name)]
      [(Variant name items)
        (codec.surface-ast-write-i64! out 4)
        (codec.surface-ast-write-name! out context name)
        (surface-ast-write-pattern-list! out context (deref items))]
      [(Literal literal)
        (codec.surface-ast-write-i64! out 5)
        (codec.surface-ast-write-literal! out context literal)]
      [(Or items)
        (codec.surface-ast-write-i64! out 8)
        (surface-ast-write-pattern-list! out context (deref items))]
      [(Fields items)
        (codec.surface-ast-write-i64! out 9)
        (surface-ast-write-pattern-list! out context (deref items))]
      [(Field name items)
        (codec.surface-ast-write-i64! out 10)
        (codec.surface-ast-write-name! out context name)
        (surface-ast-write-pattern-list! out context (deref items))])))

(define (surface-ast-read-pattern-list!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstPatternList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstPattern)
      (__tl_make-array ast.AstPattern count)]
    [index : i64 0]
    (while (< index count)
      (set! (array-ref slots index) (surface-ast-read-pattern! reader))
      (set! index (+ index 1)))
    (ast.AstPatternList slots count)))

(define (surface-ast-read-pattern!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstPattern
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0)
        (Var
          (codec.surface-ast-read-name! reader)
          (codec.surface-ast-read-maybe-type! reader))]
      [(= tag 1) (Tuple (box (surface-ast-read-pattern-list! reader)))]
      [(= tag 2) Wildcard]
      [(= tag 3) (Binding (codec.surface-ast-read-name! reader))]
      [(= tag 4)
        (Variant
          (codec.surface-ast-read-name! reader)
          (box (surface-ast-read-pattern-list! reader)))]
      [(= tag 5) (Literal (codec.surface-ast-read-literal! reader))]
      [(= tag 6) (Array (box (surface-ast-read-pattern-list! reader)))]
      [(= tag 7)
        (let
          [has-rest : bool (codec.surface-ast-read-bool! reader)]
          (Slice (box (surface-ast-read-pattern-list! reader)) has-rest))]
      [(= tag 8) (Or (box (surface-ast-read-pattern-list! reader)))]
      [(= tag 9) (Fields (box (surface-ast-read-pattern-list! reader)))]
      [(= tag 10)
        (Field
          (codec.surface-ast-read-name! reader)
          (box (surface-ast-read-pattern-list! reader)))]
      [else
        (codec.surface-ast-reader-fail!
          reader
          "surface ast: invalid pattern tag")
        Wildcard])))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-let-binding-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [bindings : ast.AstLetBindingList]) : unit
    (let
      [index : i64 0]
      [count : i64 bindings.len]
      (codec.surface-ast-write-i64! out count)
      (while (< index count)
        (match (ast.ast-array-shared-view bindings.slots index)
          [(Binding name maybe-ty value)
            (codec.surface-ast-write-name! out context name)
            (codec.surface-ast-write-maybe-type! out context maybe-ty)
            (codec.surface-ast-write-i64! out value)])
        (set! index (+ index 1))))))

(define (surface-ast-read-let-binding-list!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstLetBindingList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstLetBinding)
      (__tl_make-array ast.AstLetBinding count)]
    [index : i64 0]
    (while (< index count)
      (set!
        (array-ref slots index)
        (ast.AstLetBinding.Binding
          (codec.surface-ast-read-name! reader)
          (codec.surface-ast-read-maybe-type! reader)
          (codec.surface-ast-read-i64! reader)))
      (set! index (+ index 1)))
    (ast.AstLetBindingList slots count)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-resource-binding-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [bindings : ast.AstResourceBindingList]) : unit
    (let
      [index : i64 0]
      [count : i64 bindings.len]
      (codec.surface-ast-write-i64! out count)
      (while (< index count)
        (match (array-ref bindings.slots index)
          [(Binding name init cleanup fallible)
            (codec.surface-ast-write-name! out context name)
            (codec.surface-ast-write-i64! out init)
            (codec.surface-ast-write-i64! out cleanup)
            (codec.surface-ast-write-bool! out fallible)])
        (set! index (+ index 1))))))

(define (surface-ast-read-resource-binding-list!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstResourceBindingList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstResourceBinding)
      (__tl_make-array ast.AstResourceBinding count)]
    [index : i64 0]
    (while (< index count)
      (set!
        (array-ref slots index)
        (ast.AstResourceBinding.Binding
          (codec.surface-ast-read-name! reader)
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-bool! reader)))
      (set! index (+ index 1)))
    (ast.AstResourceBindingList slots count)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-match-arm-list!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [arms : ast.AstMatchArmList]) : unit
    (let
      [index : i64 0]
      [count : i64 arms.len]
      (codec.surface-ast-write-i64! out count)
      (while (< index count)
        (match (ast.ast-array-shared-view arms.slots index)
          [(Arm pattern body)
            (surface-ast-write-pattern! out context pattern)
            (codec.surface-ast-write-i64! out body)])
        (set! index (+ index 1))))))

(define (surface-ast-read-match-arm-list!
  [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstMatchArmList
  (let
    [count : i64 (codec.surface-ast-read-count! reader)]
    [slots : (__tl_dyn-array ast.AstMatchArm)
      (__tl_make-array ast.AstMatchArm count)]
    [index : i64 0]
    (while (< index count)
      (set!
        (array-ref slots index)
        (ast.AstMatchArm.Arm
          (surface-ast-read-pattern! reader)
          (codec.surface-ast-read-i64! reader)))
      (set! index (+ index 1)))
    (ast.AstMatchArmList slots count)))

(cfg
  (any compiler-surface-producer compiler-build-identity embedded-stdlib-tlci)
  (define (surface-ast-write-expr!
    [out : (&mut out byte_buf_core.ByteBufBuilder)]
    [context : (&mut context codec.SurfaceAstWriteContext)]
    [expr : ast.AstExpr]) : unit
    (match expr
      [(Spanned inner span)
        (codec.surface-ast-write-i64! out 0)
        (codec.surface-ast-write-i64! out inner)
        (codec.surface-ast-write-span! out span)]
      [(Literal literal)
        (codec.surface-ast-write-i64! out 1)
        (codec.surface-ast-write-literal! out context literal)]
      [(Var name)
        (codec.surface-ast-write-i64! out 2)
        (codec.surface-ast-write-name! out context name)]
      [(Binary op left right)
        (codec.surface-ast-write-i64! out 3)
        (codec.surface-ast-write-bin-op! out op)
        (codec.surface-ast-write-i64! out left)
        (codec.surface-ast-write-i64! out right)]
      [(Unary op inner)
        (codec.surface-ast-write-i64! out 4)
        (codec.surface-ast-write-un-op! out op)
        (codec.surface-ast-write-i64! out inner)]
      [(Call callee args)
        (codec.surface-ast-write-i64! out 5)
        (codec.surface-ast-write-i64! out callee)
        (surface-ast-write-expr-list! out args)]
      [(If condition then-expr else-expr)
        (codec.surface-ast-write-i64! out 6)
        (codec.surface-ast-write-i64! out condition)
        (codec.surface-ast-write-i64! out then-expr)
        (codec.surface-ast-write-i64! out else-expr)]
      [(Let payload)
        (match (deref payload)
          [(Let bindings body)
            (codec.surface-ast-write-i64! out 7)
            (surface-ast-write-let-binding-list! out context bindings)
            (codec.surface-ast-write-i64! out body)])]
      [(Lambda payload)
        (match (deref payload)
          [(Lambda params ret body)
            (codec.surface-ast-write-i64! out 8)
            (surface-ast-write-param-list! out context params)
            (codec.surface-ast-write-maybe-type! out context ret)
            (codec.surface-ast-write-i64! out body)])]
      [(Tuple items)
        (codec.surface-ast-write-i64! out 9)
        (surface-ast-write-expr-list! out items)]
      [(TupleRef target index)
        (codec.surface-ast-write-i64! out 10)
        (codec.surface-ast-write-i64! out target)
        (codec.surface-ast-write-i64! out index)]
      [(Array items)
        (codec.surface-ast-write-i64! out 11)
        (surface-ast-write-expr-list! out items)]
      [(DynArray items)
        (codec.surface-ast-write-i64! out 12)
        (surface-ast-write-expr-list! out items)]
      [(FixedMakeArray ty-id size)
        (codec.surface-ast-write-i64! out 85)
        (codec.surface-ast-write-i64! out ty-id)
        (codec.surface-ast-write-i64! out size)]
      [(MakeArray ty-id size)
        (codec.surface-ast-write-i64! out 13)
        (codec.surface-ast-write-i64! out ty-id)
        (codec.surface-ast-write-i64! out size)]
      [(ArrayRef target index)
        (codec.surface-ast-write-i64! out 14)
        (codec.surface-ast-write-i64! out target)
        (codec.surface-ast-write-i64! out index)]
      [(ArraySet target index value)
        (codec.surface-ast-write-i64! out 15)
        (codec.surface-ast-write-i64! out target)
        (codec.surface-ast-write-i64! out index)
        (codec.surface-ast-write-i64! out value)]
      [(ArrayTake target live index)
        (codec.surface-ast-write-i64! out 16)
        (codec.surface-ast-write-i64! out target)
        (codec.surface-ast-write-i64! out live)
        (codec.surface-ast-write-i64! out index)]
      [(Replace place replacement)
        (codec.surface-ast-write-i64! out 84)
        (codec.surface-ast-write-i64! out place)
        (codec.surface-ast-write-i64! out replacement)]
      [(ArrayPush target value)
        (codec.surface-ast-write-i64! out 17)
        (codec.surface-ast-write-i64! out target)
        (codec.surface-ast-write-i64! out value)]
      [(StringRef target index)
        (codec.surface-ast-write-i64! out 18)
        (codec.surface-ast-write-i64! out target)
        (codec.surface-ast-write-i64! out index)]
      [(While condition body)
        (codec.surface-ast-write-i64! out 19)
        (codec.surface-ast-write-i64! out condition)
        (surface-ast-write-expr-list! out body)]
      [(Begin items)
        (codec.surface-ast-write-i64! out 20)
        (surface-ast-write-expr-list! out items)]
      [(Unsafe items)
        (codec.surface-ast-write-i64! out 21)
        (surface-ast-write-expr-list! out items)]
      [(Set name value)
        (codec.surface-ast-write-i64! out 22)
        (codec.surface-ast-write-name! out context name)
        (codec.surface-ast-write-i64! out value)]
      [(Ann inner ty-id)
        (codec.surface-ast-write-i64! out 23)
        (codec.surface-ast-write-i64! out inner)
        (codec.surface-ast-write-i64! out ty-id)]
      [(Cast inner ty-id)
        (codec.surface-ast-write-i64! out 24)
        (codec.surface-ast-write-i64! out inner)
        (codec.surface-ast-write-i64! out ty-id)]
      [(Borrow mutable lifetime-id inner)
        (codec.surface-ast-write-i64! out 25)
        (codec.surface-ast-write-bool! out mutable)
        (codec.surface-ast-write-borrow-lifetime!
          out
          context
          (ast.ast-borrow-lifetime-from-id lifetime-id))
        (codec.surface-ast-write-i64! out inner)]
      [(Match payload)
        (match (deref payload)
          [(Match scrutinee arms)
            (codec.surface-ast-write-i64! out 26)
            (codec.surface-ast-write-i64! out scrutinee)
            (surface-ast-write-match-arm-list! out context arms)])]
      [(Foreach payload)
        (match (deref payload)
          [(Foreach name index-ty start end body)
            (codec.surface-ast-write-i64! out 27)
            (codec.surface-ast-write-name! out context name)
            (codec.surface-ast-write-type! out context index-ty)
            (codec.surface-ast-write-i64! out start)
            (codec.surface-ast-write-i64! out end)
            (codec.surface-ast-write-i64! out body)]
          [(Foreach2
            outer
            outer-ty
            outer-start
            outer-end
            inner
            inner-ty
            inner-start
            inner-end
            body)
            (codec.surface-ast-write-i64! out 89)
            (codec.surface-ast-write-name! out context outer)
            (codec.surface-ast-write-type! out context outer-ty)
            (codec.surface-ast-write-i64! out outer-start)
            (codec.surface-ast-write-i64! out outer-end)
            (codec.surface-ast-write-name! out context inner)
            (codec.surface-ast-write-type! out context inner-ty)
            (codec.surface-ast-write-i64! out inner-start)
            (codec.surface-ast-write-i64! out inner-end)
            (codec.surface-ast-write-i64! out body)])]
      [(SpmdReduce payload)
        (match (deref payload)
          [(Reduce op index index-ty start end init value)
            (codec.surface-ast-write-i64! out 28)
            (codec.surface-ast-write-reduce-op! out op)
            (codec.surface-ast-write-name! out context index)
            (codec.surface-ast-write-type! out context index-ty)
            (codec.surface-ast-write-i64! out start)
            (codec.surface-ast-write-i64! out end)
            (codec.surface-ast-write-i64! out init)
            (codec.surface-ast-write-i64! out value)])]
      [(SpmdScan payload)
        (match (deref payload)
          [(Scan op index index-ty start end prefix prefix-ty init value body)
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
            (codec.surface-ast-write-i64! out body)])]
      [(SpmdCompact payload)
        (match (deref payload)
          [(Compact index index-ty start end slot slot-ty init keep body)
            (codec.surface-ast-write-i64! out 86)
            (codec.surface-ast-write-name! out context index)
            (codec.surface-ast-write-type! out context index-ty)
            (codec.surface-ast-write-i64! out start)
            (codec.surface-ast-write-i64! out end)
            (codec.surface-ast-write-name! out context slot)
            (codec.surface-ast-write-type! out context slot-ty)
            (codec.surface-ast-write-i64! out init)
            (codec.surface-ast-write-i64! out keep)
            (codec.surface-ast-write-i64! out body)])]
      [(SpmdBroadcast value lane)
        (codec.surface-ast-write-i64! out 30)
        (codec.surface-ast-write-i64! out value)
        (codec.surface-ast-write-i64! out lane)]
      [(SpmdShuffle value lane)
        (codec.surface-ast-write-i64! out 31)
        (codec.surface-ast-write-i64! out value)
        (codec.surface-ast-write-i64! out lane)]
      [(SpmdProgramIndex) (codec.surface-ast-write-i64! out 32)]
      [(SpmdProgramCount) (codec.surface-ast-write-i64! out 33)]
      [(ForeachActive lane body)
        (codec.surface-ast-write-i64! out 87)
        (codec.surface-ast-write-name! out context lane)
        (codec.surface-ast-write-i64! out body)]
      [(LaneValue value)
        (codec.surface-ast-write-i64! out 88)
        (codec.surface-ast-write-i64! out value)]
      [(StructGet target field)
        (codec.surface-ast-write-i64! out 34)
        (codec.surface-ast-write-i64! out target)
        (codec.surface-ast-write-name! out context field)]
      [(StructSet target field value)
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
      [(WithRegion region body)
        (codec.surface-ast-write-i64! out 36)
        (codec.surface-ast-write-name! out context region)
        (surface-ast-write-expr-list! out body)]
      [(WithEscape escape body)
        (codec.surface-ast-write-i64! out 37)
        (codec.surface-ast-write-i64! out escape)
        (surface-ast-write-expr-list! out body)]
      [(WithScratch body)
        (codec.surface-ast-write-i64! out 38)
        (surface-ast-write-expr-list! out body)]
      [(InArena arena body)
        (codec.surface-ast-write-i64! out 39)
        (codec.surface-ast-write-i64! out arena)
        (surface-ast-write-expr-list! out body)]
      [(WithResource payload)
        (match (deref payload)
          [(WithResource bindings body)
            (codec.surface-ast-write-i64! out 40)
            (surface-ast-write-resource-binding-list! out context bindings)
            (surface-ast-write-expr-list! out body)])]
      [(Box value)
        (codec.surface-ast-write-i64! out 41)
        (codec.surface-ast-write-i64! out value)]
      [(BoxGet value)
        (codec.surface-ast-write-i64! out 42)
        (codec.surface-ast-write-i64! out value)]
      [(BoxTake value)
        (codec.surface-ast-write-i64! out 43)
        (codec.surface-ast-write-i64! out value)]
      [(BoxSet target value)
        (codec.surface-ast-write-i64! out 44)
        (codec.surface-ast-write-i64! out target)
        (codec.surface-ast-write-i64! out value)]
      [(TypeLiteral ty-id)
        (codec.surface-ast-write-i64! out 45)
        (codec.surface-ast-write-i64! out ty-id)]
      [(Init maybe-ty-id)
        (codec.surface-ast-write-i64! out 46)
        (codec.surface-ast-write-i64! out maybe-ty-id)]
      [(Comptime inner)
        (codec.surface-ast-write-i64! out 47)
        (codec.surface-ast-write-i64! out inner)]
      [(Quote inner)
        (codec.surface-ast-write-i64! out 48)
        (codec.surface-ast-write-i64! out inner)]
      [(Quasiquote inner)
        (codec.surface-ast-write-i64! out 49)
        (codec.surface-ast-write-i64! out inner)]
      [(Unquote inner)
        (codec.surface-ast-write-i64! out 50)
        (codec.surface-ast-write-i64! out inner)]
      [(UnquoteSplicing inner)
        (codec.surface-ast-write-i64! out 51)
        (codec.surface-ast-write-i64! out inner)]
      [(BracketClause items)
        (codec.surface-ast-write-i64! out 52)
        (surface-ast-write-expr-list! out items)]
      [(Try inner)
        (codec.surface-ast-write-i64! out 53)
        (codec.surface-ast-write-i64! out inner)]
      [(Return inner)
        (codec.surface-ast-write-i64! out 54)
        (codec.surface-ast-write-i64! out inner)]
      [(Break) (codec.surface-ast-write-i64! out 55)]
      [(Continue) (codec.surface-ast-write-i64! out 56)]
      [(PtrNull ty-id)
        (codec.surface-ast-write-i64! out 57)
        (codec.surface-ast-write-i64! out ty-id)]
      [(PtrNullCheck ptr)
        (codec.surface-ast-write-i64! out 58)
        (codec.surface-ast-write-i64! out ptr)]
      [(PtrAddrOf place)
        (codec.surface-ast-write-i64! out 59)
        (codec.surface-ast-write-i64! out place)]
      [(PtrRead ptr)
        (codec.surface-ast-write-i64! out 60)
        (codec.surface-ast-write-i64! out ptr)]
      [(PtrWrite ptr value)
        (codec.surface-ast-write-i64! out 61)
        (codec.surface-ast-write-i64! out ptr)
        (codec.surface-ast-write-i64! out value)]
      [(PtrOffset ptr offset)
        (codec.surface-ast-write-i64! out 62)
        (codec.surface-ast-write-i64! out ptr)
        (codec.surface-ast-write-i64! out offset)]
      [(PtrCast ptr ty-id)
        (codec.surface-ast-write-i64! out 63)
        (codec.surface-ast-write-i64! out ptr)
        (codec.surface-ast-write-i64! out ty-id)]
      [(PtrToInt ptr)
        (codec.surface-ast-write-i64! out 64)
        (codec.surface-ast-write-i64! out ptr)]
      [(IntToPtr value ty-id)
        (codec.surface-ast-write-i64! out 65)
        (codec.surface-ast-write-i64! out value)
        (codec.surface-ast-write-i64! out ty-id)]
      [(StringData value)
        (codec.surface-ast-write-i64! out 66)
        (codec.surface-ast-write-i64! out value)]
      [(StringFromBytes data len)
        (codec.surface-ast-write-i64! out 67)
        (codec.surface-ast-write-i64! out data)
        (codec.surface-ast-write-i64! out len)]
      [(ArrayData value)
        (codec.surface-ast-write-i64! out 68)
        (codec.surface-ast-write-i64! out value)]
      [(BinaryData data)
        (codec.surface-ast-write-i64! out 69)
        (codec.surface-ast-write-string! out data)]
      [(ProgramArgc) (codec.surface-ast-write-i64! out 70)]
      [(ProgramArgv) (codec.surface-ast-write-i64! out 71)]
      [(ProgramEnvp) (codec.surface-ast-write-i64! out 72)]
      [(CpuIdEax leaf subleaf)
        (codec.surface-ast-write-i64! out 73)
        (codec.surface-ast-write-i64! out leaf)
        (codec.surface-ast-write-i64! out subleaf)]
      [(CpuIdEbx leaf subleaf)
        (codec.surface-ast-write-i64! out 74)
        (codec.surface-ast-write-i64! out leaf)
        (codec.surface-ast-write-i64! out subleaf)]
      [(CpuIdEcx leaf subleaf)
        (codec.surface-ast-write-i64! out 75)
        (codec.surface-ast-write-i64! out leaf)
        (codec.surface-ast-write-i64! out subleaf)]
      [(CpuIdEdx leaf subleaf)
        (codec.surface-ast-write-i64! out 76)
        (codec.surface-ast-write-i64! out leaf)
        (codec.surface-ast-write-i64! out subleaf)]
      [(Xgetbv index)
        (codec.surface-ast-write-i64! out 77)
        (codec.surface-ast-write-i64! out index)]
      [(Syscall args)
        (codec.surface-ast-write-i64! out 78)
        (surface-ast-write-expr-list! out args)]
      [(ForOwnedState payload)
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
          (ast.ast-for-owned-state-body (& payload)))]
      [(ForOwnedStep payload)
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
          (ast.ast-for-owned-step-body (& payload)))]
      [(MacroExpansion inner provenance-id macro-name-id)
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
        (surface-ast-write-optional-name! out context macro-name-id)])))

(define (surface-ast-read-expr! [reader : (&mut reader codec.SurfaceAstReader)]) : ast.AstExpr
  (let
    [tag : i64 (codec.surface-ast-read-i64! reader)]
    (cond
      [(= tag 0)
        (Spanned
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-span! reader))]
      [(= tag 1) (Literal (codec.surface-ast-read-literal! reader))]
      [(= tag 2) (Var (codec.surface-ast-read-name! reader))]
      [(= tag 3)
        (Binary
          (codec.surface-ast-read-bin-op! reader)
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 4)
        (Unary
          (codec.surface-ast-read-un-op! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 5)
        (Call
          (codec.surface-ast-read-i64! reader)
          (surface-ast-read-expr-list! reader))]
      [(= tag 6)
        (If
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 7)
        (Let
          (box
            (ast.AstLet.Let
              (surface-ast-read-let-binding-list! reader)
              (codec.surface-ast-read-i64! reader))))]
      [(= tag 8)
        (Lambda
          (box
            (ast.AstLambda.Lambda
              (surface-ast-read-param-list! reader)
              (codec.surface-ast-read-maybe-type! reader)
              (codec.surface-ast-read-i64! reader))))]
      [(= tag 9) (Tuple (surface-ast-read-expr-list! reader))]
      [(= tag 10)
        (TupleRef
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 11) (Array (surface-ast-read-expr-list! reader))]
      [(= tag 12) (DynArray (surface-ast-read-expr-list! reader))]
      [(= tag 85)
        (FixedMakeArray
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 86)
        (SpmdCompact
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
      [(= tag 87)
        (ForeachActive
          (codec.surface-ast-read-name! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 88) (LaneValue (codec.surface-ast-read-i64! reader))]
      [(= tag 89)
        (Foreach
          (box
            (ast.AstForeach.Foreach2
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
        (MakeArray
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 14)
        (ArrayRef
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 15)
        (ArraySet
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 16)
        (ArrayTake
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 17)
        (ArrayPush
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 18)
        (StringRef
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 19)
        (While
          (codec.surface-ast-read-i64! reader)
          (surface-ast-read-expr-list! reader))]
      [(= tag 20) (Begin (surface-ast-read-expr-list! reader))]
      [(= tag 21) (Unsafe (surface-ast-read-expr-list! reader))]
      [(= tag 22)
        (Set
          (codec.surface-ast-read-name! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 23)
        (Ann
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 24)
        (Cast
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 25)
        (Borrow
          (codec.surface-ast-read-bool! reader)
          (ast.ast-borrow-lifetime-to-id
            (codec.surface-ast-read-borrow-lifetime! reader))
          (codec.surface-ast-read-i64! reader))]
      [(= tag 26)
        (Match
          (box
            (ast.AstMatch.Match
              (codec.surface-ast-read-i64! reader)
              (surface-ast-read-match-arm-list! reader))))]
      [(= tag 27)
        (Foreach
          (box
            (ast.AstForeach.Foreach
              (codec.surface-ast-read-name! reader)
              (codec.surface-ast-read-type! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-i64! reader)
              (codec.surface-ast-read-i64! reader))))]
      [(= tag 28)
        (SpmdReduce
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
        (SpmdScan
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
        (SpmdBroadcast
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 31)
        (SpmdShuffle
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 32) SpmdProgramIndex]
      [(= tag 33) SpmdProgramCount]
      [(= tag 34)
        (StructGet
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-name! reader))]
      [(= tag 35)
        (StructSet
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-name! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 36)
        (WithRegion
          (codec.surface-ast-read-name! reader)
          (surface-ast-read-expr-list! reader))]
      [(= tag 37)
        (WithEscape
          (codec.surface-ast-read-i64! reader)
          (surface-ast-read-expr-list! reader))]
      [(= tag 38) (WithScratch (surface-ast-read-expr-list! reader))]
      [(= tag 39)
        (InArena
          (codec.surface-ast-read-i64! reader)
          (surface-ast-read-expr-list! reader))]
      [(= tag 40)
        (WithResource
          (box
            (ast.AstWithResource.WithResource
              (surface-ast-read-resource-binding-list! reader)
              (surface-ast-read-expr-list! reader))))]
      [(= tag 41) (Box (codec.surface-ast-read-i64! reader))]
      [(= tag 42) (BoxGet (codec.surface-ast-read-i64! reader))]
      [(= tag 43) (BoxTake (codec.surface-ast-read-i64! reader))]
      [(= tag 44)
        (BoxSet
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 45) (TypeLiteral (codec.surface-ast-read-i64! reader))]
      [(= tag 46) (Init (codec.surface-ast-read-i64! reader))]
      [(= tag 47) (Comptime (codec.surface-ast-read-i64! reader))]
      [(= tag 48) (Quote (codec.surface-ast-read-i64! reader))]
      [(= tag 49) (Quasiquote (codec.surface-ast-read-i64! reader))]
      [(= tag 50) (Unquote (codec.surface-ast-read-i64! reader))]
      [(= tag 51) (UnquoteSplicing (codec.surface-ast-read-i64! reader))]
      [(= tag 52) (BracketClause (surface-ast-read-expr-list! reader))]
      [(= tag 53) (Try (codec.surface-ast-read-i64! reader))]
      [(= tag 54) (Return (codec.surface-ast-read-i64! reader))]
      [(= tag 55) Break]
      [(= tag 56) Continue]
      [(= tag 57) (PtrNull (codec.surface-ast-read-i64! reader))]
      [(= tag 58) (PtrNullCheck (codec.surface-ast-read-i64! reader))]
      [(= tag 59) (PtrAddrOf (codec.surface-ast-read-i64! reader))]
      [(= tag 60) (PtrRead (codec.surface-ast-read-i64! reader))]
      [(= tag 61)
        (PtrWrite
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 62)
        (PtrOffset
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 63)
        (PtrCast
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 64) (PtrToInt (codec.surface-ast-read-i64! reader))]
      [(= tag 65)
        (IntToPtr
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 66) (StringData (codec.surface-ast-read-i64! reader))]
      [(= tag 67)
        (StringFromBytes
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 68) (ArrayData (codec.surface-ast-read-i64! reader))]
      [(= tag 69) (BinaryData (codec.surface-ast-read-string! reader))]
      [(= tag 70) ProgramArgc]
      [(= tag 71) ProgramArgv]
      [(= tag 72) ProgramEnvp]
      [(= tag 73)
        (CpuIdEax
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 74)
        (CpuIdEbx
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 75)
        (CpuIdEcx
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 76)
        (CpuIdEdx
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [(= tag 77) (Xgetbv (codec.surface-ast-read-i64! reader))]
      [(= tag 78) (Syscall (surface-ast-read-expr-list! reader))]
      [(= tag 80)
        (ForOwnedState
          (ast.ast-for-owned-state-payload
            (codec.surface-ast-read-i64! reader)
            (codec.surface-ast-read-i64! reader)
            (codec.surface-ast-read-i64! reader)
            (codec.surface-ast-read-i64! reader)))]
      [(= tag 81)
        (ForOwnedStep
          (ast.ast-for-owned-step-payload
            (codec.surface-ast-read-i64! reader)
            (codec.surface-ast-read-i64! reader)
            (codec.surface-ast-read-i64! reader)
            (codec.surface-ast-read-i64! reader)
            (codec.surface-ast-read-i64! reader)
            (codec.surface-ast-read-i64! reader)))]
      [(= tag 82)
        (MacroExpansion
          (codec.surface-ast-read-i64! reader)
          (ci.intern-composite-pair-id
            (surface-ast-read-optional-name! reader)
            (surface-ast-read-optional-name! reader))
          (surface-ast-read-optional-name! reader))]
      [(= tag 83)
        (StructSet
          (codec.surface-ast-read-i64! reader)
          (ast.ast-tuple-set-field-id-from-index
            (codec.surface-ast-read-i64! reader))
          (codec.surface-ast-read-i64! reader))]
      [(= tag 84)
        (Replace
          (codec.surface-ast-read-i64! reader)
          (codec.surface-ast-read-i64! reader))]
      [else
        (codec.surface-ast-reader-fail!
          reader
          "surface ast: invalid expression tag")
        ProgramArgc])))