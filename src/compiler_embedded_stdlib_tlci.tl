;; Build-configured embedded stdlib comptime image and production loader path.
(cfg
  (any stage0-seed-bootstrap test)
  (import compiler_embedded_stdlib_tlci_payload_seed as payload))
(cfg
  (not (any stage0-seed-bootstrap test))
  (import compiler_embedded_stdlib_tlci_payload as payload))
(import "tlci_loader.tl")

;; compiler_ctfe instantiates (hashmap i64 i64); the generated-module import
;; needs stdlib.hashmap in this program graph even though full compiler
;; builds get it from other modules (small graphs like the embedded verifier
;; would otherwise fail the instantiation).
;; lint-allow: unused-import -- the generated-map instantiation needs it.
(import stdlib.hashmap)
(import "tlci_core.tl")
(import "compiler_ast_types.tl")
(import "compiler_ctfe.tl")
(import compiler_intern as ci)
(import stdlib.array)

(defenum CompilerEmbeddedStdlibTlciValidation
  (Ok i64)
  (Err String))

(defenum CompilerEmbeddedStdlibTlciLookup
  (Cataloged)
  (Missing)
  (Unavailable String))

(defenum CompilerEmbeddedStdlibTlciSurface
  (Ok String String (Array u8))
  (Unavailable String))

;; The compiler maps the image lazily on the first embedded-stdlib macro call
;; and keeps it mapped through that macro-expansion pass. State values are
;; 0 = closed, 1 = loaded, and -1 = load failed. The separate cells avoid
;; requiring an artificial zero-value TlciLoadedImage enum variant.
(define compiler-embedded-stdlib-tlci-session-state : (Array i64)
  (make-array 0))
(define compiler-embedded-stdlib-tlci-session-image : (Array TlciLoadedImage)
  (array.make-array TlciLoadedImage 1))
(define compiler-embedded-stdlib-tlci-session-error : (Array String)
  (make-array ""))

(define (compiler-embedded-stdlib-tlci-length) : i64
  (array-length payload.embedded-stdlib-tlci-bytes))

(define (compiler-embedded-stdlib-tlci-copy) : (Array u8)
  (let
    [length : i64 (compiler-embedded-stdlib-tlci-length)]
    [out : (Array u8) (array.make-array u8 length)]
    [index : i64 0]
    (begin
      (while (< index length)
        (begin
          (array-set!
            out
            index
            (array-ref payload.embedded-stdlib-tlci-bytes index))
          (set! index (+ index 1))))
      out)))

(define (compiler-embedded-stdlib-tlci-surface) : CompilerEmbeddedStdlibTlciSurface
  (if (= (compiler-embedded-stdlib-tlci-length) 0)
    (CompilerEmbeddedStdlibTlciSurface.Unavailable
      "embedded stdlib tlci is unavailable in the seed/test build")
    (match (tlci-parse-image (compiler-embedded-stdlib-tlci-copy))
      [(ResultTlciImage.Err message)
        (CompilerEmbeddedStdlibTlciSurface.Unavailable message)]
      [(ResultTlciImage.Ok image)
        (CompilerEmbeddedStdlibTlciSurface.Ok
          (struct-get image compiler-build-hash)
          payload.embedded-stdlib-tlci-source-hash
          (struct-get image rodata))])))

(define (compiler-embedded-stdlib-tlci-host-table) : TlciHostCallbackTable
  (TlciHostCallbackTable
    tlci-host-callback-table-magic
    tlci-host-abi-version
    tlci-host-callback-table-size
    0
    0
    0
    1
    1))

(define (compiler-embedded-stdlib-tlci-session-open!) : bool
  (let
    [state : i64 (array-ref compiler-embedded-stdlib-tlci-session-state 0)]
    (cond
      [(= state 1) true]
      [(= state -1) false]
      [else
        (if (= (compiler-embedded-stdlib-tlci-length) 0)
          (begin
            (array-set! compiler-embedded-stdlib-tlci-session-state 0 -1)
            (array-set!
              compiler-embedded-stdlib-tlci-session-error
              0
              "embedded stdlib tlci is unavailable in the seed/test build")
            false)
          (match (tlci-loader-load-from-bytes-with-host
            (compiler-embedded-stdlib-tlci-copy)
            (compiler-comptime-host-table))
            [(ResultTlciLoadedImage.Err message)
              (begin
                (array-set! compiler-embedded-stdlib-tlci-session-state 0 -1)
                (array-set!
                  compiler-embedded-stdlib-tlci-session-error
                  0
                  message)
                false)]
            [(ResultTlciLoadedImage.Ok loaded)
              (begin
                (array-set!
                  compiler-embedded-stdlib-tlci-session-image
                  0
                  loaded)
                (array-set! compiler-embedded-stdlib-tlci-session-state 0 1)
                true)]))])))

(define (compiler-embedded-stdlib-tlci-catalog-lookup [name : String]) : CompilerEmbeddedStdlibTlciLookup
  (if (compiler-embedded-stdlib-tlci-session-open!)
    (let
      [loaded : TlciLoadedImage
        (array-ref compiler-embedded-stdlib-tlci-session-image 0)]
      (match (tlci-loader-find-macro-entry (& loaded) name)
        [(ResultTlciMacroEntry.Ok _) CompilerEmbeddedStdlibTlciLookup.Cataloged]
        [(ResultTlciMacroEntry.Err _) CompilerEmbeddedStdlibTlciLookup.Missing]))
    (CompilerEmbeddedStdlibTlciLookup.Unavailable
      (array-ref compiler-embedded-stdlib-tlci-session-error 0))))

;; Dispatch a cataloged entry on the mapped pass session. The caller owns the
;; comptime host session (operands, fuel, cookie) around this call.
(define (compiler-embedded-stdlib-tlci-session-dispatch
  [name : String]
  [session-cookie : i64]) : ResultTlciMacroDispatch
  (if (= (array-ref compiler-embedded-stdlib-tlci-session-state 0) 1)
    (let
      [loaded : TlciLoadedImage
        (array-ref compiler-embedded-stdlib-tlci-session-image 0)]
      (tlci-loader-dispatch-macro
        (& loaded)
        name
        session-cookie
        (array.make-array i64 0)
        0))
    (ResultTlciMacroDispatch.Err "embedded stdlib tlci session is not loaded")))

(define (compiler-embedded-stdlib-tlci-session-close!) : unit
  (let
    [state : i64 (array-ref compiler-embedded-stdlib-tlci-session-state 0)]
    (begin
      (array-set! compiler-embedded-stdlib-tlci-session-state 0 0)
      (array-set! compiler-embedded-stdlib-tlci-session-error 0 "")
      (if (= state 1)
        (match (tlci-loader-release
          (array-ref compiler-embedded-stdlib-tlci-session-image 0))
          [(ResultTlciLoaderUnit.Ok) unit]
          [(ResultTlciLoaderUnit.Err _) unit])
        unit))))

;; Map the embedded image through the production W^X loader, execute its image
;; registration entry, validate every registered macro record, and release the
;; mapping. Callback addresses are nonzero sentinels because validation never
;; invokes a transformer; real dispatch installs compiler-owned callbacks.
(define (compiler-embedded-stdlib-tlci-validate) : CompilerEmbeddedStdlibTlciValidation
  (if (= (compiler-embedded-stdlib-tlci-length) 0)
    (CompilerEmbeddedStdlibTlciValidation.Err
      "embedded stdlib tlci is unavailable in the seed/test build")
    (match (tlci-loader-load-from-bytes-with-host
      (compiler-embedded-stdlib-tlci-copy)
      (compiler-embedded-stdlib-tlci-host-table))
      [(ResultTlciLoadedImage.Err message)
        (CompilerEmbeddedStdlibTlciValidation.Err message)]
      [(ResultTlciLoadedImage.Ok loaded)
        (let
          [count : i64 (struct-get loaded macro-entry-count)]
          [has-array-length : bool
            (match (tlci-loader-find-macro-entry
              (& loaded)
              "stdlib.array/length")
              [(ResultTlciMacroEntry.Ok _) true]
              [(ResultTlciMacroEntry.Err _) false])]
          (match (tlci-loader-release loaded)
            [(ResultTlciLoaderUnit.Err message)
              (CompilerEmbeddedStdlibTlciValidation.Err message)]
            [(ResultTlciLoaderUnit.Ok)
              (if (and (> count 0) has-array-length)
                (CompilerEmbeddedStdlibTlciValidation.Ok count)
                (CompilerEmbeddedStdlibTlciValidation.Err
                  "embedded stdlib tlci is missing its macro catalog"))]))])))

;; --- compiler-owned native-comptime host session (refs #5212) -----------------
;;
;; One session spans one native transformer invocation. Values under
;; construction live on this compiler-owned stack: the image drives it through
;; callback-invoke operations and never holds result handles, so the emitted
;; native code stays a pure operation sequence. Every operation validates the
;; session cookie and answers with the SPEC status contract; kind or arity
;; violations return bad-request without committing any state.
(define compiler-comptime-host-session-cookie : i64
  0)
(define compiler-comptime-host-session-fuel : i64
  0)
(define compiler-comptime-host-session-status : i64
  tlci-host-callback-status-ok)
(define compiler-comptime-host-pools : (Array AstNodePoolContext)
  (array.make-array AstNodePoolContext 1))
(define compiler-comptime-host-operands : (Array CompilerCtfeValue)
  (array.make-array CompilerCtfeValue 8))
(define compiler-comptime-host-operand-count : i64
  0)
(define compiler-comptime-host-reflections : (Array CtfeReflectInfoList)
  (array.make-array CtfeReflectInfoList 1))
(define compiler-comptime-host-stack : (Array CompilerCtfeValue)
  (array.make-array CompilerCtfeValue 64))
(define compiler-comptime-host-stack-len : i64
  0)
(define compiler-comptime-host-result : (Array CompilerCtfeValue)
  (array.make-array CompilerCtfeValue 1))
(define compiler-comptime-host-result-ready : bool
  false)
(define compiler-comptime-host-diagnostic : (Array String)
  (make-array ""))

;; Computed-body local slots for let-bound transformer bodies (refs #5603).
;; Slots are addressed by immediate operand and validated per session.
(define compiler-comptime-host-locals-cap : i64
  32)
(define compiler-comptime-host-locals : (Array CompilerCtfeValue)
  (array.make-array CompilerCtfeValue compiler-comptime-host-locals-cap))
(define compiler-comptime-host-locals-live : (Array bool)
  (array.make-array bool compiler-comptime-host-locals-cap))

;; Pop `count` patterns into a fresh list (last-pushed becomes the final
;; element), or report failure when any value is not a pattern.
(defenum CompilerCtfeMaybePatternList
  (Some AstPatternList)
  (None))

(define (compiler-comptime-host-pop-pattern-list [count : i64]) : CompilerCtfeMaybePatternList
  (let
    [out : AstPatternList (ast-pattern-list-new)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (let
          [value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len (- count index)))]
          (match value
            [(CompilerCtfeValue.Pattern pattern)
              (begin
                (ast-pattern-list-push (&mut out) pattern)
                (set! index (+ index 1)))]
            [_ (set! ok false)])))
      (if ok
        (begin
          (set!
            compiler-comptime-host-stack-len
            (- compiler-comptime-host-stack-len count))
          (CompilerCtfeMaybePatternList.Some out))
        (CompilerCtfeMaybePatternList.None)))))

(define (compiler-comptime-host-locals-clear!) : unit
  (compiler-comptime-host-locals-clear-from! 0))

(define (compiler-comptime-host-locals-clear-from! [index : i64]) : unit
  (if (>= index compiler-comptime-host-locals-cap)
    unit
    (begin
      (array-set! compiler-comptime-host-locals-live index false)
      (compiler-comptime-host-locals-clear-from! (+ index 1)))))

;; Runtime bridge: the image's callback-invoke pointer targets a backend
;; trampoline that reads the registered function value from a runtime cell,
;; installs its environment word, and tail-jumps its code word (discarding
;; the host-context argument, which is why the dispatcher takes five
;; parameters). The setter stores the dispatcher's function value; the
;; entry-ptr cell supplies the raw invoke address for the host table.
(extern (tl-comptime-host-invoke-set [fn-value : i64]) : i64 (:symbol "tl_comptime_host_invoke_set"))

(define (compiler-comptime-host-session-open!
  [pools : AstNodePoolContext]
  [operands : (Array CompilerCtfeValue)]
  [operand-count : i64]
  [fuel : i64]
  [cookie : i64]
  [reflections : CtfeReflectInfoList]) : unit
  (begin
    (array-set! compiler-comptime-host-pools 0 pools)
    (array-set! compiler-comptime-host-reflections 0 reflections)
    (let
      [index : i64 0]
      (while (and (< index operand-count) (< index 8))
        (begin
          (array-set!
            compiler-comptime-host-operands
            index
            (array-ref operands index))
          (set! index (+ index 1)))))
    (set! compiler-comptime-host-operand-count operand-count)
    (set! compiler-comptime-host-session-fuel fuel)
    (set! compiler-comptime-host-session-status tlci-host-callback-status-ok)
    (set! compiler-comptime-host-stack-len 0)
    (set! compiler-comptime-host-result-ready false)
    (compiler-comptime-host-locals-clear!)
    (array-set! compiler-comptime-host-diagnostic 0 "")
    (set! compiler-comptime-host-session-cookie cookie)))

(define (compiler-comptime-host-session-close!) : unit
  (begin
    (set! compiler-comptime-host-session-cookie 0)
    (set! compiler-comptime-host-session-status tlci-host-callback-status-ok)
    (set! compiler-comptime-host-stack-len 0)
    (set! compiler-comptime-host-operand-count 0)
    (set! compiler-comptime-host-result-ready false)))

(define (compiler-comptime-host-result-value) : CompilerCtfeValue
  (array-ref compiler-comptime-host-result 0))

(define (compiler-comptime-host-result-ready?) : bool
  compiler-comptime-host-result-ready)

(define (compiler-comptime-host-diagnostic-text) : String
  (array-ref compiler-comptime-host-diagnostic 0))

(define (compiler-comptime-host-push! [value : CompilerCtfeValue]) : i64
  (if (>=
    compiler-comptime-host-stack-len
    (array-length compiler-comptime-host-stack))
    tlci-host-callback-status-bad-request
    (begin
      (array-set!
        compiler-comptime-host-stack
        compiler-comptime-host-stack-len
        value)
      (set!
        compiler-comptime-host-stack-len
        (+ compiler-comptime-host-stack-len 1))
      tlci-host-callback-status-ok)))

;; Expression list of a variadic operand or stack value. Captured lists carry
;; the caller's pools; the session's pools are the caller's, so they project
;; the same way the interpreted quote accepts a storage-sharing capture.
;; Refs #5617.
(defenum CompilerCtfeMaybeExprList
  (Some AstExprList)
  (None))

(define (compiler-comptime-host-value-expr-list [value : CompilerCtfeValue]) : CompilerCtfeMaybeExprList
  (match value
    [(CompilerCtfeValue.ExprList items) (CompilerCtfeMaybeExprList.Some items)]
    [(CompilerCtfeValue.CapturedExprList items _)
      (CompilerCtfeMaybeExprList.Some items)]
    [_ (CompilerCtfeMaybeExprList.None)]))

;; Comptime String text held in a session local, for the scanner ops that read
;; a bound template or type key by slot. `live` is checked by the caller, which
;; distinguishes an out-of-range slot from a slot holding a non-String value.
;; Refs #5701.
(defenum CompilerCtfeMaybeString
  (Some String)
  (None))

(define (compiler-comptime-host-local-string [slot : i64]) : CompilerCtfeMaybeString
  (if (or
    (< slot 0)
    (>= slot compiler-comptime-host-locals-cap)
    (not (array-ref compiler-comptime-host-locals-live slot)))
    (CompilerCtfeMaybeString.None)
    (match (array-ref compiler-comptime-host-locals slot)
      [(CompilerCtfeValue.String text _) (CompilerCtfeMaybeString.Some text)]
      [_ (CompilerCtfeMaybeString.None)])))

;; The pools that own an operand's expression nodes: a captured operand keeps
;; its caller pools, every other value reads the session pools. Refs #5602.
(define (compiler-comptime-host-value-pools [value : CompilerCtfeValue]) : AstNodePoolContext
  (match value
    [(CompilerCtfeValue.CapturedExpr _ _ pools) pools]
    [(CompilerCtfeValue.CapturedExprList _ pools) pools]
    [_ (array-ref compiler-comptime-host-pools 0)]))

;; The `Spanned`-unwrapped expression an operand denotes, mirroring
;; `ctfe-match-expr-variant`'s `ctfe-expr-unspan` before it inspects a variant.
(define (compiler-comptime-host-unspanned-expr
  [pools : AstNodePoolContext]
  [expr : AstExpr]) : AstExpr
  (match expr
    [(AstExpr.Spanned inner _)
      (compiler-comptime-host-unspanned-expr
        pools
        (ast-node-pool-context-expr-get pools inner))]
    [_ expr]))

;; The unspanned expression of operand `index`, or a unit literal when the
;; operand is out of range or carries no expression node. Callers probe the
;; range separately, so the fallback is only a total-function placeholder.
(define (compiler-comptime-host-operand-expr [index : i64]) : AstExpr
  (let
    [value : CompilerCtfeValue
      (array-ref compiler-comptime-host-operands index)]
    [node : i64 (compiler-comptime-host-value-node value)]
    (if (< node 0)
      (AstExpr.Literal (AstLiteral.Unit))
      (compiler-comptime-host-unspanned-expr
        (compiler-comptime-host-value-pools value)
        (ast-node-pool-context-expr-get
          (compiler-comptime-host-value-pools value)
          node)))))

;; Expression node id of a stack value, or -1 when the value does not carry
;; one. Captured operands keep their caller-pool node id; the pool-context
;; bridging refinement is tracked with the real-body slice. A type operand
;; converts to its type-syntax expression, matching the interpreted
;; quasiquote's unquote substitution for `,T`.
(define (compiler-comptime-host-value-node [value : CompilerCtfeValue]) : i64
  (match value
    [(CompilerCtfeValue.Expr node _) node]
    [(CompilerCtfeValue.CapturedExpr node _ _) node]
    [(CompilerCtfeValue.Type ty)
      (ctfe-type-to-expr
        ty
        (ctfe-env-empty-with-pools (array-ref compiler-comptime-host-pools 0)))]
    [_ -1]))

;; Pop two operand expressions (second then target) and push a two-operand
;; intrinsic node: kind 0 is array-ref, kind 1 is array-push. Both take the
;; target and operand node ids the interpreted quasiquote builders receive.
(define (compiler-comptime-host-build-binary-intrinsic! [kind : i64]) : i64
  (if (< compiler-comptime-host-stack-len 2)
    tlci-host-callback-status-bad-request
    (let
      [operand : CompilerCtfeValue
        (array-ref
          compiler-comptime-host-stack
          (- compiler-comptime-host-stack-len 1))]
      [target : CompilerCtfeValue
        (array-ref
          compiler-comptime-host-stack
          (- compiler-comptime-host-stack-len 2))]
      [operand-node : i64 (compiler-comptime-host-value-node operand)]
      [target-node : i64 (compiler-comptime-host-value-node target)]
      (if (or (< operand-node 0) (< target-node 0))
        tlci-host-callback-status-bad-request
        (let
          [pools : AstNodePoolContext
            (array-ref compiler-comptime-host-pools 0)]
          [node : i64
            (if (= kind 0)
              (ast-expr-array-ref-with-pools pools target-node operand-node)
              (ast-expr-array-push-with-pools pools target-node operand-node))]
          (begin
            (set!
              compiler-comptime-host-stack-len
              (- compiler-comptime-host-stack-len 2))
            (compiler-comptime-host-push!
              (CompilerCtfeValue.Expr node (AstType.Expr)))))))))

;; Decode the scalar AstType ordinal a native image passes for type-scalar.
;; The producer and consumer are always the same source-bound binary, so the
;; ordinal contract stays in sync with the producer's encoder.
(define (compiler-comptime-host-scalar-type-for-ordinal [ordinal : i64]) : AstType
  (cond
    [(= ordinal 0) (AstType.I64)]
    [(= ordinal 1) (AstType.I32)]
    [(= ordinal 2) (AstType.I16)]
    [(= ordinal 3) (AstType.I8)]
    [(= ordinal 4) (AstType.U64)]
    [(= ordinal 5) (AstType.U32)]
    [(= ordinal 6) (AstType.U16)]
    [(= ordinal 7) (AstType.U8)]
    [(= ordinal 8) (AstType.F64)]
    [(= ordinal 9) (AstType.F32)]
    [(= ordinal 10) (AstType.Bool)]
    [(= ordinal 11) (AstType.Char)]
    [(= ordinal 12) (AstType.String)]
    [(= ordinal 13) (AstType.Str)]
    [(= ordinal 14) (AstType.Bytes)]
    [(= ordinal 15) (AstType.Expr)]
    [(= ordinal 16) (AstType.ExprList)]
    [(= ordinal 17) (AstType.Unit)]
    [(= ordinal 18) (AstType.Never)]
    [else (AstType.Unit)]))

;; Decode the AstBinOp ordinal a native image passes for expr-binary-op. The
;; producer and consumer are always the same source-bound binary, so the
;; ordinal contract stays in sync with the producer's encoder. Callers range
;; check the ordinal before decoding, so the fallback is unreachable.
(define (compiler-comptime-host-binop-for-ordinal [ordinal : i64]) : AstBinOp
  (cond
    [(= ordinal 0) (AstBinOp.Add)]
    [(= ordinal 1) (AstBinOp.Sub)]
    [(= ordinal 2) (AstBinOp.Mul)]
    [(= ordinal 3) (AstBinOp.Div)]
    [(= ordinal 4) (AstBinOp.Mod)]
    [(= ordinal 5) (AstBinOp.Eq)]
    [(= ordinal 6) (AstBinOp.Ne)]
    [(= ordinal 7) (AstBinOp.Lt)]
    [(= ordinal 8) (AstBinOp.Le)]
    [(= ordinal 9) (AstBinOp.Gt)]
    [(= ordinal 10) (AstBinOp.Ge)]
    [(= ordinal 11) (AstBinOp.And)]
    [(= ordinal 12) (AstBinOp.Or)]
    [(= ordinal 13) (AstBinOp.BitAnd)]
    [(= ordinal 14) (AstBinOp.BitOr)]
    [(= ordinal 15) (AstBinOp.BitXor)]
    [(= ordinal 16) (AstBinOp.Shl)]
    [(= ordinal 17) (AstBinOp.Shr)]
    [else (AstBinOp.Add)]))

;; Decode the AstUnOp ordinal a native image passes for expr-unary-op.
(define (compiler-comptime-host-unop-for-ordinal [ordinal : i64]) : AstUnOp
  (cond
    [(= ordinal 0) (AstUnOp.Neg)]
    [(= ordinal 1) (AstUnOp.Not)]
    [(= ordinal 2) (AstUnOp.BitNot)]
    [else (AstUnOp.Neg)]))

;; Pop one expression from the value stack and push the single-operand node
;; the parser produces for the shape named by `kind` (0 return, 1 box, 2
;; box-get), matching the interpreted quote's reconstruction. Returns the
;; callback status. Refs #5605.
(define (compiler-comptime-host-unary-node-step! [kind : i64]) : i64
  (if (< compiler-comptime-host-stack-len 1)
    tlci-host-callback-status-bad-request
    (let
      [inner-value : CompilerCtfeValue
        (array-ref
          compiler-comptime-host-stack
          (- compiler-comptime-host-stack-len 1))]
      [inner-node : i64 (compiler-comptime-host-value-node inner-value)]
      (if (< inner-node 0)
        tlci-host-callback-status-bad-request
        (let
          [pools : AstNodePoolContext
            (array-ref compiler-comptime-host-pools 0)]
          (begin
            (set!
              compiler-comptime-host-stack-len
              (- compiler-comptime-host-stack-len 1))
            (compiler-comptime-host-push!
              (CompilerCtfeValue.Expr
                (cond
                  [(= kind 0) (ast-expr-return-with-pools pools inner-node)]
                  [(= kind 1) (ast-expr-box-with-pools pools inner-node)]
                  [(= kind 2) (ast-expr-box-get-with-pools pools inner-node)]
                  [(= kind 3) (ast-expr-ptr-read-with-pools pools inner-node)]
                  [(= kind 4) (ast-expr-ptr-to-int-with-pools pools inner-node)]
                  [(= kind 5)
                    (ast-expr-string-data-with-pools pools inner-node)]
                  [else (ast-expr-array-data-with-pools pools inner-node)])
                (AstType.Expr)))))))))

;; The compiler-owned callback invoke installed into the tlci host callback
;; table. TypeLisp's native convention passes scalar arguments in the SysV
;; integer registers, so this function is directly callable from the mapped
;; image on Linux; the Windows adapter is tracked with the dispatch slice.
;; Pop the second then the first operand expression and push the two-operand
;; raw-pointer/data node the parser produces: kind 0 is `(ptr-write! p v)`,
;; kind 1 is `(ptr-offset p n)`, and kind 2 is `(string-from-bytes d n)`.
;; Refs #5605.
(define (compiler-comptime-host-ptr-binary-step! [kind : i64]) : i64
  (if (< compiler-comptime-host-stack-len 2)
    tlci-host-callback-status-bad-request
    (let
      [second-value : CompilerCtfeValue
        (array-ref
          compiler-comptime-host-stack
          (- compiler-comptime-host-stack-len 1))]
      [first-value : CompilerCtfeValue
        (array-ref
          compiler-comptime-host-stack
          (- compiler-comptime-host-stack-len 2))]
      [second-node : i64 (compiler-comptime-host-value-node second-value)]
      [first-node : i64 (compiler-comptime-host-value-node first-value)]
      (if (or (< second-node 0) (< first-node 0))
        tlci-host-callback-status-bad-request
        (let
          [pools : AstNodePoolContext
            (array-ref compiler-comptime-host-pools 0)]
          (begin
            (set!
              compiler-comptime-host-stack-len
              (- compiler-comptime-host-stack-len 2))
            (compiler-comptime-host-push!
              (CompilerCtfeValue.Expr
                (cond
                  [(= kind 0)
                    (ast-expr-ptr-write-with-pools pools first-node second-node)]
                  [(= kind 1)
                    (ast-expr-ptr-offset-with-pools
                      pools
                      first-node
                      second-node)]
                  [else
                    (ast-expr-string-from-bytes-with-pools
                      pools
                      first-node
                      second-node)])
                (AstType.Expr)))))))))

;; Pop a type value and push the composite that wraps it: kind 0 is
;; `(Ptr T)`/`(MutPtr T)` selected by `flag`, 1 is `(Box T)`, 2 is the unsized
;; `(Array T)`, 3 is `(Array T N)` with `flag` as the count, and 4 is
;; `(& r T)`/`(&mut r T)` with `flag` selecting mutability and the lifetime name
;; arriving as caller bytes. The lifetime name is interned through the same
;; source-slice path template variable names use. Refs #5605.
(define (compiler-comptime-host-type-wrap-step!
  [kind : i64]
  [flag : i64]
  [name-ptr : i64]
  [name-len : i64]) : i64
  (if (< compiler-comptime-host-stack-len 1)
    tlci-host-callback-status-bad-request
    (match (array-ref
      compiler-comptime-host-stack
      (- compiler-comptime-host-stack-len 1))
      [(CompilerCtfeValue.Type inner)
        (let
          [pools : AstNodePoolContext
            (array-ref compiler-comptime-host-pools 0)]
          (if (and (= kind 4) (or (<= name-ptr 0) (< name-len 0)))
            tlci-host-callback-status-bad-request
            (let
              [region : i64
                (if (= kind 4)
                  (let
                    [name : String
                      (unsafe
                        (string-from-bytes
                          (int->ptr name-ptr : (Ptr u8))
                          name-len))]
                    (ci.intern-source-slice name 0 (string.string-length name)))
                  0)]
              (begin
                (set!
                  compiler-comptime-host-stack-len
                  (- compiler-comptime-host-stack-len 1))
                (compiler-comptime-host-push!
                  (CompilerCtfeValue.Type
                    (cond
                      [(= kind 0)
                        (if (= flag 0)
                          (ast-ty-ptr-with-pools pools inner)
                          (ast-ty-mut-ptr-with-pools pools inner))]
                      [(= kind 1) (ast-ty-box-with-pools pools inner)]
                      [(= kind 2) (ast-ty-dyn-array-with-pools pools inner)]
                      [(= kind 3) (ast-ty-array-with-pools pools inner flag)]
                      [else
                        (if (= flag 0)
                          (ast-ty-ref-with-pools pools region inner)
                          (ast-ty-mut-ref-with-pools pools region inner))])))))))]
      [_ tlci-host-callback-status-bad-request])))

;; Replace the type value at the top of the session stack with one reflected
;; field/variant name. `kind` is 0 for a struct field and 1 for an enum
;; variant. The returned `Name` preserves the declaration's intern identity,
;; matching the interpreted reflection path rather than materializing a fresh
;; computed String. Refs #5626.
(define (compiler-comptime-host-reflection-name-step!
  [kind : i64]
  [index : i64]) : i64
  (if (< compiler-comptime-host-stack-len 1)
    tlci-host-callback-status-bad-request
    (match (array-ref
      compiler-comptime-host-stack
      (- compiler-comptime-host-stack-len 1))
      [(CompilerCtfeValue.Type ty)
        (match (ctfe-reflect-info-for-type-with-pools
          (array-ref compiler-comptime-host-pools 0)
          (array-ref compiler-comptime-host-reflections 0)
          ty)
          [(CtfeMaybeReflectInfo.Some info)
            (match info
              [(CtfeReflectInfo.Struct _ _ _ _ _ fields)
                (if (= kind 0)
                  (match (ctfe-reflect-field-name-at fields index)
                    [(ResultCtfeNameLookup.Ok name)
                      (begin
                        (set!
                          compiler-comptime-host-stack-len
                          (- compiler-comptime-host-stack-len 1))
                        (compiler-comptime-host-push! (ctfe-name-value name)))]
                    [(ResultCtfeNameLookup.Err _)
                      tlci-host-callback-status-bad-request])
                  tlci-host-callback-status-bad-request)]
              [(CtfeReflectInfo.Enum _ _ _ _ _ variants)
                (if (= kind 1)
                  (match (ctfe-reflect-variant-name-at variants index)
                    [(ResultCtfeNameLookup.Ok name)
                      (begin
                        (set!
                          compiler-comptime-host-stack-len
                          (- compiler-comptime-host-stack-len 1))
                        (compiler-comptime-host-push! (ctfe-name-value name)))]
                    [(ResultCtfeNameLookup.Err _)
                      tlci-host-callback-status-bad-request])
                  tlci-host-callback-status-bad-request)])]
          [(CtfeMaybeReflectInfo.None) tlci-host-callback-status-bad-request])]
      [_ tlci-host-callback-status-bad-request])))

;; Reflection counts return their value directly through the callback ABI, so
;; success consumes the type stack value and failure uses the negative data-op
;; sentinel. `kind` is struct fields, enum variants, enum variant payloads, or
;; tuple elements (0 through 3). Refs #5626.
(define (compiler-comptime-host-reflection-count-step!
  [kind : i64]
  [index : i64]) : i64
  (if (< compiler-comptime-host-stack-len 1)
    -3
    (match (array-ref
      compiler-comptime-host-stack
      (- compiler-comptime-host-stack-len 1))
      [(CompilerCtfeValue.Type ty)
        (let
          [pools : AstNodePoolContext
            (array-ref compiler-comptime-host-pools 0)]
          [infos : CtfeReflectInfoList
            (array-ref compiler-comptime-host-reflections 0)]
          [count : i64
            (cond
              [(= kind 0)
                (match (ctfe-reflect-info-for-type-with-pools pools infos ty)
                  [(CtfeMaybeReflectInfo.Some
                      (CtfeReflectInfo.Struct _ _ _ _ _ fields))
                    (ctfe-reflect-field-list-count fields)]
                  [_ -3])]
              [(= kind 1)
                (match (ctfe-reflect-info-for-type-with-pools pools infos ty)
                  [(CtfeMaybeReflectInfo.Some
                      (CtfeReflectInfo.Enum _ _ _ _ _ variants))
                    (ctfe-reflect-variant-list-count variants)]
                  [_ -3])]
              [(= kind 2)
                (match (ctfe-reflect-info-for-type-with-pools pools infos ty)
                  [(CtfeMaybeReflectInfo.Some
                      (CtfeReflectInfo.Enum _ _ _ _ _ variants))
                    (match (ctfe-reflect-variant-payloads-at variants index)
                      [(ResultCtfeTypeListLookup.Ok payloads)
                        (ctfe-type-list-count payloads)]
                      [(ResultCtfeTypeListLookup.Err _) -3])]
                  [_ -3])]
              [else
                (match (ctfe-reflect-resolve-type-with-pools pools infos ty)
                  [(AstType.Tuple elems) (ctfe-type-list-count (box-get elems))]
                  [_ -3])])]
          (if (< count 0)
            -3
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              count)))]
      [_ -3])))

;; Replace the type stack value with one indexed reflected type. `kind` is a
;; struct field, enum payload, or tuple element (0 through 2). Refs #5626.
(define (compiler-comptime-host-reflection-type-step!
  [kind : i64]
  [first-index : i64]
  [second-index : i64]) : i64
  (if (< compiler-comptime-host-stack-len 1)
    tlci-host-callback-status-bad-request
    (match (array-ref
      compiler-comptime-host-stack
      (- compiler-comptime-host-stack-len 1))
      [(CompilerCtfeValue.Type ty)
        (let
          [pools : AstNodePoolContext
            (array-ref compiler-comptime-host-pools 0)]
          [infos : CtfeReflectInfoList
            (array-ref compiler-comptime-host-reflections 0)]
          (cond
            [(= kind 0)
              (match (ctfe-reflect-info-for-type-with-pools pools infos ty)
                [(CtfeMaybeReflectInfo.Some
                    (CtfeReflectInfo.Struct _ _ _ _ _ fields))
                  (match (ctfe-reflect-field-type-at
                    fields
                    pools
                    infos
                    first-index)
                    [(ResultCtfeTypeLookup.Ok field-ty)
                      (begin
                        (set!
                          compiler-comptime-host-stack-len
                          (- compiler-comptime-host-stack-len 1))
                        (compiler-comptime-host-push!
                          (CompilerCtfeValue.Type field-ty)))]
                    [(ResultCtfeTypeLookup.Err _)
                      tlci-host-callback-status-bad-request])]
                [_ tlci-host-callback-status-bad-request])]
            [(= kind 1)
              (match (ctfe-reflect-info-for-type-with-pools pools infos ty)
                [(CtfeMaybeReflectInfo.Some
                    (CtfeReflectInfo.Enum _ _ _ _ _ variants))
                  (match (ctfe-reflect-variant-payloads-at variants first-index)
                    [(ResultCtfeTypeListLookup.Ok payloads)
                      (match (ctfe-type-list-ref-with-pools
                        payloads
                        pools
                        infos
                        second-index)
                        [(ResultCtfeTypeLookup.Ok payload-ty)
                          (begin
                            (set!
                              compiler-comptime-host-stack-len
                              (- compiler-comptime-host-stack-len 1))
                            (compiler-comptime-host-push!
                              (CompilerCtfeValue.Type payload-ty)))]
                        [(ResultCtfeTypeLookup.Err _)
                          tlci-host-callback-status-bad-request])]
                    [(ResultCtfeTypeListLookup.Err _)
                      tlci-host-callback-status-bad-request])]
                [_ tlci-host-callback-status-bad-request])]
            [else
              (match (ctfe-reflect-resolve-type-with-pools pools infos ty)
                [(AstType.Tuple elems)
                  (match (ctfe-type-list-ref-with-pools
                    (box-get elems)
                    pools
                    infos
                    first-index)
                    [(ResultCtfeTypeLookup.Ok element-ty)
                      (begin
                        (set!
                          compiler-comptime-host-stack-len
                          (- compiler-comptime-host-stack-len 1))
                        (compiler-comptime-host-push!
                          (CompilerCtfeValue.Type element-ty)))]
                    [(ResultCtfeTypeLookup.Err _)
                      tlci-host-callback-status-bad-request])]
                [_ tlci-host-callback-status-bad-request])]))]
      [_ tlci-host-callback-status-bad-request])))

(define (compiler-comptime-host-invoke-step
  [session : i64]
  [operation : i64]
  [arg-a : i64]
  [arg-b : i64]
  [_arg-c : i64]) : i64
  (cond
    [(or
        (= compiler-comptime-host-session-cookie 0)
        (not (= session compiler-comptime-host-session-cookie)))
      tlci-host-callback-status-bad-request]
    [(= operation tlci-host-callback-op-fuel-check)
      (if (> compiler-comptime-host-session-fuel 0)
        (begin
          (set!
            compiler-comptime-host-session-fuel
            (- compiler-comptime-host-session-fuel 1))
          tlci-host-callback-status-ok)
        tlci-host-callback-status-fuel-exhausted)]
    [(= operation tlci-host-callback-op-diagnostic)
      (begin
        (if (and (> arg-a 0) (>= arg-b 0))
          (array-set!
            compiler-comptime-host-diagnostic
            0
            (unsafe
              (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b)))
          unit)
        tlci-host-callback-status-diagnostic)]
    ;; Scratch lifecycle ops: the compiler-owned session builds results on its
    ;; value stack, not through host scratch, so these are no-ops. Registration
    ;; shells issue only scratch-reset, so accepting it lets a shell dispatch
    ;; run cleanly and commit no result -- the route then interprets it.
    [(= operation tlci-host-callback-op-scratch-alloc)
      tlci-host-callback-status-ok]
    [(= operation tlci-host-callback-op-scratch-reset)
      tlci-host-callback-status-ok]
    [(= operation tlci-host-callback-op-expr-var)
      (if (or (<= arg-a 0) (< arg-b 0))
        tlci-host-callback-status-bad-request
        (let
          [name : String
            (unsafe
              (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))]
          ;; Reproduce the interpreted quote's variable exactly: the lexer's
          ;; source-name id for the spelling, marked as template source so
          ;; dotted spellings resolve through the same hygiene path as an
          ;; interpreted expansion.
          [node : i64
            (ast-node-pool-context-expr-push
              (array-ref compiler-comptime-host-pools 0)
              (AstExpr.Var
                (ci.intern-template-source-id
                  (ci.intern-source-slice name 0 (string.string-length name)))))]
          (compiler-comptime-host-push!
            (CompilerCtfeValue.Expr node (AstType.Expr)))))]
    [(= operation tlci-host-callback-op-expr-list-empty)
      (compiler-comptime-host-push!
        (CompilerCtfeValue.ExprList (ast-expr-list-new)))]
    [(= operation tlci-host-callback-op-expr-list-append)
      (if (< compiler-comptime-host-stack-len 2)
        tlci-host-callback-status-bad-request
        (let
          [elem : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [list-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [node : i64 (compiler-comptime-host-value-node elem)]
          (if (< node 0)
            tlci-host-callback-status-bad-request
            (match list-value
              [(CompilerCtfeValue.ExprList items)
                (let
                  [next : AstExprList items]
                  (begin
                    (ast-expr-list-push (&mut next) node)
                    (set!
                      compiler-comptime-host-stack-len
                      (- compiler-comptime-host-stack-len 2))
                    (compiler-comptime-host-push!
                      (CompilerCtfeValue.ExprList next))))]
              [_ tlci-host-callback-status-bad-request]))))]
    [(= operation tlci-host-callback-op-push-operand)
      (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
        tlci-host-callback-status-bad-request
        (compiler-comptime-host-push!
          (array-ref compiler-comptime-host-operands arg-a)))]
    [(= operation tlci-host-callback-op-expr-call)
      (if (< compiler-comptime-host-stack-len 2)
        tlci-host-callback-status-bad-request
        (let
          [args-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [callee : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [callee-node : i64 (compiler-comptime-host-value-node callee)]
          (if (< callee-node 0)
            tlci-host-callback-status-bad-request
            (match args-value
              [(CompilerCtfeValue.ExprList items)
                (let
                  [node : i64
                    (ctfe-ast-expr-call-with-provenance
                      (array-ref compiler-comptime-host-pools 0)
                      callee-node
                      items)]
                  (begin
                    (set!
                      compiler-comptime-host-stack-len
                      (- compiler-comptime-host-stack-len 2))
                    (compiler-comptime-host-push!
                      (CompilerCtfeValue.Expr node (AstType.Expr)))))]
              [_ tlci-host-callback-status-bad-request]))))]
    ;; Intrinsic two-operand array nodes: pop the second operand then the
    ;; target and push the array-ref / array-push node the parser recognizes
    ;; for these forms, matching the interpreted quasiquote builders.
    [(= operation tlci-host-callback-op-expr-array-ref)
      (compiler-comptime-host-build-binary-intrinsic! 0)]
    [(= operation tlci-host-callback-op-expr-array-push)
      (compiler-comptime-host-build-binary-intrinsic! 1)]
    ;; make-array: pop the size expression and the element type value and push
    ;; the make-array node, matching the interpreted quote (the type passes
    ;; through by identity).
    [(= operation tlci-host-callback-op-expr-make-array)
      (if (< compiler-comptime-host-stack-len 2)
        tlci-host-callback-status-bad-request
        (let
          [size-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [type-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [size-node : i64 (compiler-comptime-host-value-node size-value)]
          (if (< size-node 0)
            tlci-host-callback-status-bad-request
            (match type-value
              [(CompilerCtfeValue.Type ty)
                (let
                  [node : i64
                    (ast-expr-make-array-with-pools
                      (array-ref compiler-comptime-host-pools 0)
                      ty
                      size-node)]
                  (begin
                    (set!
                      compiler-comptime-host-stack-len
                      (- compiler-comptime-host-stack-len 2))
                    (compiler-comptime-host-push!
                      (CompilerCtfeValue.Expr node (AstType.Expr)))))]
              [_ tlci-host-callback-status-bad-request]))))]
    ;; Reflection: 1/0 as data when the type operand's kind string matches
    ;; the caller bytes (the same ctfe mapping interpretation uses); negative
    ;; reports a bad request without touching session state.
    [(= operation tlci-host-callback-op-operand-type-kind-eq)
      (if (or
        (< arg-a 0)
        (>= arg-a compiler-comptime-host-operand-count)
        (<= arg-b 0)
        (< _arg-c 0))
        -3
        (match (array-ref compiler-comptime-host-operands arg-a)
          [(CompilerCtfeValue.Type ty)
            (if (string.eq
              (ctfe-type-kind-with-reflections-and-pools
                (array-ref compiler-comptime-host-pools 0)
                (array-ref compiler-comptime-host-reflections 0)
                ty)
              (unsafe
                (string-from-bytes (int->ptr arg-b : (Ptr u8)) _arg-c)))
              1
              0)]
          [_ -3]))]
    ;; operand-expr-type-kind-eq: the same probe over an Expr operand's
    ;; produced type, so `(match (type-kind (comptime.expr-type v)) ...)`
    ;; dispatches without materializing the type on the value stack. An
    ;; untyped Expr operand is a malformed request here; the value-position
    ;; expr-type op reports the interpreted diagnostic instead.
    [(= operation tlci-host-callback-op-operand-expr-type-kind-eq)
      (if (or
        (< arg-a 0)
        (>= arg-a compiler-comptime-host-operand-count)
        (<= arg-b 0)
        (< _arg-c 0))
        -3
        (match (array-ref compiler-comptime-host-operands arg-a)
          [(CompilerCtfeValue.Expr _ ty)
            (let
              [pools : AstNodePoolContext
                (array-ref compiler-comptime-host-pools 0)]
              [actual-ty : AstType
                (ctfe-captured-expr-type-inner-with-pools pools ty)]
              (if (ctfe-untyped-expr-type? actual-ty)
                -3
                (if (string.eq
                  (ctfe-type-kind-with-reflections-and-pools
                    pools
                    (array-ref compiler-comptime-host-reflections 0)
                    (ctfe-reflect-resolve-type-with-pools
                      pools
                      (array-ref compiler-comptime-host-reflections 0)
                      actual-ty))
                  (unsafe
                    (string-from-bytes (int->ptr arg-b : (Ptr u8)) _arg-c)))
                  1
                  0)))]
          [_ -3]))]
    ;; operand-type-key-eq: the canonical type-key of a type operand against
    ;; caller bytes, the `(match (type-key T) ...)` dispatch.
    [(= operation tlci-host-callback-op-operand-type-key-eq)
      (if (or
        (< arg-a 0)
        (>= arg-a compiler-comptime-host-operand-count)
        (<= arg-b 0)
        (< _arg-c 0))
        -3
        (match (array-ref compiler-comptime-host-operands arg-a)
          [(CompilerCtfeValue.Type ty)
            (if (string.eq
              (ctfe-type-key-with-reflections-and-pools
                (array-ref compiler-comptime-host-pools 0)
                (array-ref compiler-comptime-host-reflections 0)
                ty)
              (unsafe
                (string-from-bytes (int->ptr arg-b : (Ptr u8)) _arg-c)))
              1
              0)]
          [_ -3]))]
    ;; expr-type: pop an Expr value and push its resolved produced type, the
    ;; same mapping `ctfe-eval-expr-type-call` uses -- including its
    ;; "expr-type requires a typechecked Expr" diagnostic.
    [(= operation tlci-host-callback-op-expr-type)
      (if (< compiler-comptime-host-stack-len 1)
        tlci-host-callback-status-bad-request
        (match (array-ref
          compiler-comptime-host-stack
          (- compiler-comptime-host-stack-len 1))
          [(CompilerCtfeValue.Expr _ ty)
            (let
              [pools : AstNodePoolContext
                (array-ref compiler-comptime-host-pools 0)]
              [actual-ty : AstType
                (ctfe-captured-expr-type-inner-with-pools pools ty)]
              (if (ctfe-untyped-expr-type? actual-ty)
                (begin
                  (array-set!
                    compiler-comptime-host-diagnostic
                    0
                    "expr-type requires a typechecked Expr")
                  tlci-host-callback-status-diagnostic)
                (begin
                  (set!
                    compiler-comptime-host-stack-len
                    (- compiler-comptime-host-stack-len 1))
                  (compiler-comptime-host-push!
                    (CompilerCtfeValue.Type
                      (ctfe-reflect-resolve-type-with-pools
                        pools
                        (array-ref compiler-comptime-host-reflections 0)
                        actual-ty))))))]
          [_ tlci-host-callback-status-bad-request]))]
    ;; expr-cast: pop the type value then the operand expression and push the
    ;; cast node the parser produces for `(cast e : T)`. The producer emits the
    ;; operand template first and the type second.
    [(= operation tlci-host-callback-op-expr-cast)
      (if (< compiler-comptime-host-stack-len 2)
        tlci-host-callback-status-bad-request
        (let
          [type-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [value-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [value-node : i64 (compiler-comptime-host-value-node value-value)]
          (if (< value-node 0)
            tlci-host-callback-status-bad-request
            (match type-value
              [(CompilerCtfeValue.Type ty)
                (begin
                  (set!
                    compiler-comptime-host-stack-len
                    (- compiler-comptime-host-stack-len 2))
                  (compiler-comptime-host-push!
                    (CompilerCtfeValue.Expr
                      (ast-expr-cast-with-pools
                        (array-ref compiler-comptime-host-pools 0)
                        value-node
                        ty)
                      (AstType.Expr))))]
              [_ tlci-host-callback-status-bad-request]))))]
    [(= operation tlci-host-callback-op-expr-bool-literal)
      (compiler-comptime-host-push!
        (CompilerCtfeValue.Expr
          (ast-node-pool-context-expr-push
            (array-ref compiler-comptime-host-pools 0)
            (AstExpr.Literal (AstLiteral.Bool (not (= arg-a 0)))))
          (AstType.Expr)))]
    [(= operation tlci-host-callback-op-expr-int-literal)
      (compiler-comptime-host-push!
        (CompilerCtfeValue.Expr
          (ast-node-pool-context-expr-push
            (array-ref compiler-comptime-host-pools 0)
            (AstExpr.Literal (ast-lit-int arg-a)))
          (AstType.Expr)))]
    ;; Template string literal: the lexer interns literal text through the
    ;; source-name session, so the same spelling maps to the same id here.
    [(= operation tlci-host-callback-op-expr-string)
      (if (or (<= arg-a 0) (< arg-b 0))
        tlci-host-callback-status-bad-request
        (let
          [text : String
            (unsafe
              (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))]
          (compiler-comptime-host-push!
            (CompilerCtfeValue.Expr
              (ast-node-pool-context-expr-push
                (array-ref compiler-comptime-host-pools 0)
                (AstExpr.Literal
                  (AstLiteral.String
                    (ci.intern-source-slice text 0 (string.string-length text)))))
              (AstType.Expr)))))]
    ;; Pop a splice ExprList then the list under construction and push the
    ;; concatenation, matching the interpreted quote's unquote-splicing step.
    [(= operation tlci-host-callback-op-expr-splice)
      (if (< compiler-comptime-host-stack-len 2)
        tlci-host-callback-status-bad-request
        (let
          [splice-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [list-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          (match list-value
            [(CompilerCtfeValue.ExprList items)
              (match (compiler-comptime-host-value-expr-list splice-value)
                [(CompilerCtfeMaybeExprList.Some splice-items)
                  (let
                    [next : AstExprList
                      (ctfe-expr-list-append items splice-items)]
                    (begin
                      (set!
                        compiler-comptime-host-stack-len
                        (- compiler-comptime-host-stack-len 2))
                      (compiler-comptime-host-push!
                        (CompilerCtfeValue.ExprList next))))]
                [(CompilerCtfeMaybeExprList.None)
                  tlci-host-callback-status-bad-request])]
            [_ tlci-host-callback-status-bad-request])))]
    ;; Pop else, then, and cond expressions and push the if node the parser
    ;; produces, matching the interpreted quote.
    [(= operation tlci-host-callback-op-expr-if)
      (if (< compiler-comptime-host-stack-len 3)
        tlci-host-callback-status-bad-request
        (let
          [else-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [then-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [cond-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 3))]
          [else-node : i64 (compiler-comptime-host-value-node else-value)]
          [then-node : i64 (compiler-comptime-host-value-node then-value)]
          [cond-node : i64 (compiler-comptime-host-value-node cond-value)]
          (if (or (< else-node 0) (< then-node 0) (< cond-node 0))
            tlci-host-callback-status-bad-request
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 3))
              (compiler-comptime-host-push!
                (CompilerCtfeValue.Expr
                  (ast-expr-if-with-pools
                    (array-ref compiler-comptime-host-pools 0)
                    cond-node
                    then-node
                    else-node)
                  (AstType.Expr)))))))]
    ;; Item count of a variadic ExprList operand as data; negative reports a
    ;; bad request without touching session state (the generated entry
    ;; translates it to the public bad-request status before unwinding).
    [(= operation tlci-host-callback-op-expr-list-length)
      (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
        -3
        (match (compiler-comptime-host-value-expr-list
          (array-ref compiler-comptime-host-operands arg-a))
          [(CompilerCtfeMaybeExprList.Some items) (ctfe-expr-list-length items)]
          [(CompilerCtfeMaybeExprList.None) -3]))]
    ;; Index a variadic ExprList operand: `a` names the operand and `b` the
    ;; element, mirroring the interpreted `expr-list-nth` builtin (an
    ;; out-of-range index is a bad request, and a captured operand keeps its
    ;; caller pools on the pushed element). Refs #5617.
    [(= operation tlci-host-callback-op-expr-list-nth)
      (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
        tlci-host-callback-status-bad-request
        (let
          [operand : CompilerCtfeValue
            (array-ref compiler-comptime-host-operands arg-a)]
          (match (compiler-comptime-host-value-expr-list operand)
            [(CompilerCtfeMaybeExprList.Some items)
              (if (or (< arg-b 0) (>= arg-b (ctfe-expr-list-length items)))
                tlci-host-callback-status-bad-request
                (let
                  [node : i64 (ctfe-expr-list-nth items arg-b)]
                  (match operand
                    [(CompilerCtfeValue.CapturedExprList _ pools)
                      (compiler-comptime-host-push!
                        (CompilerCtfeValue.CapturedExpr
                          node
                          (ctfe-untyped-expr-type)
                          pools))]
                    [_
                      (compiler-comptime-host-push!
                        (CompilerCtfeValue.Expr node (ctfe-untyped-expr-type)))])))]
            [(CompilerCtfeMaybeExprList.None)
              tlci-host-callback-status-bad-request])))]
    ;; Pop an expression list and push the begin node the parser produces.
    [(= operation tlci-host-callback-op-expr-begin)
      (if (< compiler-comptime-host-stack-len 1)
        tlci-host-callback-status-bad-request
        (match (array-ref
          compiler-comptime-host-stack
          (- compiler-comptime-host-stack-len 1))
          [(CompilerCtfeValue.ExprList items)
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              (compiler-comptime-host-push!
                (CompilerCtfeValue.Expr
                  (ast-node-pool-context-expr-push
                    (array-ref compiler-comptime-host-pools 0)
                    (AstExpr.Begin items))
                  (AstType.Expr))))]
          [_ tlci-host-callback-status-bad-request]))]
    ;; Pop the right then the left operand expression and push a binary node
    ;; for the AstBinOp ordinal in `a`.
    [(= operation tlci-host-callback-op-expr-binary-op)
      (if (or (< compiler-comptime-host-stack-len 2) (< arg-a 0) (> arg-a 17))
        tlci-host-callback-status-bad-request
        (let
          [right-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [left-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [right-node : i64 (compiler-comptime-host-value-node right-value)]
          [left-node : i64 (compiler-comptime-host-value-node left-value)]
          (if (or (< right-node 0) (< left-node 0))
            tlci-host-callback-status-bad-request
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 2))
              (compiler-comptime-host-push!
                (CompilerCtfeValue.Expr
                  (ast-expr-binary-with-pools
                    (array-ref compiler-comptime-host-pools 0)
                    (compiler-comptime-host-binop-for-ordinal arg-a)
                    left-node
                    right-node)
                  (AstType.Expr)))))))]
    ;; Pop the operand expression and push a unary node for the AstUnOp
    ;; ordinal in `a`.
    [(= operation tlci-host-callback-op-expr-unary-op)
      (if (or (< compiler-comptime-host-stack-len 1) (< arg-a 0) (> arg-a 2))
        tlci-host-callback-status-bad-request
        (let
          [inner-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [inner-node : i64 (compiler-comptime-host-value-node inner-value)]
          (if (< inner-node 0)
            tlci-host-callback-status-bad-request
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              (compiler-comptime-host-push!
                (CompilerCtfeValue.Expr
                  (ast-expr-unary-with-pools
                    (array-ref compiler-comptime-host-pools 0)
                    (compiler-comptime-host-unop-for-ordinal arg-a)
                    inner-node)
                  (AstType.Expr)))))))]
    [(= operation tlci-host-callback-op-expr-char-literal)
      (compiler-comptime-host-push!
        (CompilerCtfeValue.Expr
          (ast-node-pool-context-expr-push
            (array-ref compiler-comptime-host-pools 0)
            (AstExpr.Literal (AstLiteral.Char (cast arg-a : char))))
          (AstType.Expr)))]
    [(= operation tlci-host-callback-op-expr-unit-literal)
      (compiler-comptime-host-push!
        (CompilerCtfeValue.Expr
          (ast-node-pool-context-expr-push
            (array-ref compiler-comptime-host-pools 0)
            (AstExpr.Literal (AstLiteral.Unit)))
          (AstType.Expr)))]
    ;; Computed-body locals: local-set pops one value into the named session
    ;; slot; local-get pushes the slot's value.
    [(= operation tlci-host-callback-op-local-set)
      (if (or
        (< arg-a 0)
        (>= arg-a compiler-comptime-host-locals-cap)
        (< compiler-comptime-host-stack-len 1))
        tlci-host-callback-status-bad-request
        (begin
          (array-set!
            compiler-comptime-host-locals
            arg-a
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1)))
          (array-set! compiler-comptime-host-locals-live arg-a true)
          (set!
            compiler-comptime-host-stack-len
            (- compiler-comptime-host-stack-len 1))
          tlci-host-callback-status-ok))]
    [(= operation tlci-host-callback-op-local-get)
      (if (or
        (< arg-a 0)
        (>= arg-a compiler-comptime-host-locals-cap)
        (not (array-ref compiler-comptime-host-locals-live arg-a)))
        tlci-host-callback-status-bad-request
        (compiler-comptime-host-push!
          (array-ref compiler-comptime-host-locals arg-a)))]
    ;; Pop a comptime String (or Name) value and push the variable node the
    ;; interpreted (comptime.)expr-var builtin produces.
    [(= operation tlci-host-callback-op-expr-var-from-value)
      (if (< compiler-comptime-host-stack-len 1)
        tlci-host-callback-status-bad-request
        (match (array-ref
          compiler-comptime-host-stack
          (- compiler-comptime-host-stack-len 1))
          [(CompilerCtfeValue.String text string-id)
            (let
              [env : CtfeEnv
                (ctfe-env-empty-with-pools
                  (array-ref compiler-comptime-host-pools 0))]
              (begin
                (set!
                  compiler-comptime-host-stack-len
                  (- compiler-comptime-host-stack-len 1))
                (compiler-comptime-host-push!
                  (ctfe-syntax-expr-push
                    env
                    (AstExpr.Var
                      (ctfe-string-syntax-name-id
                        (ctfe-env-source-names env)
                        text
                        string-id))
                    (ctfe-untyped-expr-type)))))]
          [(CompilerCtfeValue.Name _ name-id)
            (let
              [env : CtfeEnv
                (ctfe-env-empty-with-pools
                  (array-ref compiler-comptime-host-pools 0))]
              (begin
                (set!
                  compiler-comptime-host-stack-len
                  (- compiler-comptime-host-stack-len 1))
                (compiler-comptime-host-push!
                  (ctfe-syntax-expr-push
                    env
                    (AstExpr.Var name-id)
                    (ctfe-untyped-expr-type)))))]
          [_ tlci-host-callback-status-bad-request]))]
    ;; Pop an expression list and push the bracket-clause node.
    [(= operation tlci-host-callback-op-expr-bracket-clause)
      (if (< compiler-comptime-host-stack-len 1)
        tlci-host-callback-status-bad-request
        (match (array-ref
          compiler-comptime-host-stack
          (- compiler-comptime-host-stack-len 1))
          [(CompilerCtfeValue.ExprList items)
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              (compiler-comptime-host-push!
                (CompilerCtfeValue.Expr
                  (ast-expr-bracket-clause-with-pools
                    (array-ref compiler-comptime-host-pools 0)
                    items)
                  (AstType.Expr))))]
          [_ tlci-host-callback-status-bad-request]))]
    ;; Pop the place expression and push a borrow node; immediate `a` is 1
    ;; for &mut and 0 for &, and `b`/`c` are the optional named lifetime's
    ;; byte pointer and length (0/0 for an inferred lifetime).
    [(= operation tlci-host-callback-op-expr-borrow)
      (if (< compiler-comptime-host-stack-len 1)
        tlci-host-callback-status-bad-request
        (let
          [place-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [place-node : i64 (compiler-comptime-host-value-node place-value)]
          (if (< place-node 0)
            tlci-host-callback-status-bad-request
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              (compiler-comptime-host-push!
                (CompilerCtfeValue.Expr
                  (ast-expr-borrow-with-pools
                    (array-ref compiler-comptime-host-pools 0)
                    (not (= arg-a 0))
                    (if (> arg-b 0)
                      (AstBorrowLifetime.Named
                        (ci.intern-source-slice
                          (unsafe
                            (string-from-bytes
                              (int->ptr arg-b : (Ptr u8))
                              _arg-c))
                          0
                          _arg-c))
                      (AstBorrowLifetime.Inferred))
                    place-node)
                  (AstType.Expr)))))))]
    ;; type-key: pop a type value and push its canonical key string, the same
    ;; mapping the interpreted reflection uses.
    [(= operation tlci-host-callback-op-type-key)
      (if (< compiler-comptime-host-stack-len 1)
        tlci-host-callback-status-bad-request
        (match (array-ref
          compiler-comptime-host-stack
          (- compiler-comptime-host-stack-len 1))
          [(CompilerCtfeValue.Type ty)
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              (compiler-comptime-host-push!
                (ctfe-generated-string-value
                  (ctfe-type-key-with-reflections-and-pools
                    (array-ref compiler-comptime-host-pools 0)
                    (array-ref compiler-comptime-host-reflections 0)
                    ty))))]
          [_ tlci-host-callback-status-bad-request]))]
    ;; Indexed nominal-name reflection. The producer leaves the type value on
    ;; the stack and passes its generated i64 index in `a`.
    [(= operation tlci-host-callback-op-struct-field-name)
      (compiler-comptime-host-reflection-name-step! 0 arg-a)]
    [(= operation tlci-host-callback-op-enum-variant-name)
      (compiler-comptime-host-reflection-name-step! 1 arg-a)]
    [(= operation tlci-host-callback-op-struct-field-count)
      (compiler-comptime-host-reflection-count-step! 0 0)]
    [(= operation tlci-host-callback-op-enum-variant-count)
      (compiler-comptime-host-reflection-count-step! 1 0)]
    [(= operation tlci-host-callback-op-enum-variant-payload-count)
      (compiler-comptime-host-reflection-count-step! 2 arg-a)]
    [(= operation tlci-host-callback-op-tuple-element-count)
      (compiler-comptime-host-reflection-count-step! 3 0)]
    [(= operation tlci-host-callback-op-struct-field-type)
      (compiler-comptime-host-reflection-type-step! 0 arg-a 0)]
    [(= operation tlci-host-callback-op-enum-variant-payload-type)
      (compiler-comptime-host-reflection-type-step! 1 arg-a arg-b)]
    [(= operation tlci-host-callback-op-tuple-element-type)
      (compiler-comptime-host-reflection-type-step! 2 arg-a 0)]
    ;; string-append: pop the second then the first comptime String value and
    ;; push the concatenation, a generated string value like the interpreted
    ;; operation's.
    [(= operation tlci-host-callback-op-string-append)
      (if (< compiler-comptime-host-stack-len 2)
        tlci-host-callback-status-bad-request
        (let
          [right-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [left-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          (match left-value
            [(CompilerCtfeValue.String left-text _)
              (match right-value
                [(CompilerCtfeValue.String right-text _)
                  (begin
                    (set!
                      compiler-comptime-host-stack-len
                      (- compiler-comptime-host-stack-len 2))
                    (compiler-comptime-host-push!
                      (ctfe-generated-string-value
                        (string.append left-text right-text))))]
                [_ tlci-host-callback-status-bad-request])]
            [_ tlci-host-callback-status-bad-request])))]
    ;; Pattern construction, mirroring the interpreted quote's pattern rebuild:
    ;; variant names pass through unmarked while Var/Binding names carry the
    ;; template-source mark.
    [(= operation tlci-host-callback-op-pattern-wildcard)
      (compiler-comptime-host-push!
        (CompilerCtfeValue.Pattern (AstPattern.Wildcard)))]
    [(= operation tlci-host-callback-op-pattern-binding)
      (if (or (<= arg-a 0) (< arg-b 0))
        tlci-host-callback-status-bad-request
        (let
          [name : String
            (unsafe
              (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))]
          (compiler-comptime-host-push!
            (CompilerCtfeValue.Pattern
              (AstPattern.Binding
                (ci.intern-template-source-id
                  (ci.intern-source-slice name 0 (string.string-length name))))))))]
    [(= operation tlci-host-callback-op-pattern-variant)
      (if (or
        (<= arg-a 0)
        (< arg-b 0)
        (< _arg-c 0)
        (< compiler-comptime-host-stack-len (+ _arg-c 1)))
        tlci-host-callback-status-bad-request
        (let
          [name : String
            (unsafe
              (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))]
          (match (compiler-comptime-host-pop-pattern-list _arg-c)
            [(CompilerCtfeMaybePatternList.None)
              tlci-host-callback-status-bad-request]
            [(CompilerCtfeMaybePatternList.Some items)
              (compiler-comptime-host-push!
                (CompilerCtfeValue.Pattern
                  (ast-pat-variant-id
                    (ci.intern-source-slice name 0 (string.string-length name))
                    items)))])))]
    [(= operation tlci-host-callback-op-pattern-list-empty)
      (compiler-comptime-host-push!
        (CompilerCtfeValue.PatternList (ast-pattern-list-new)))]
    [(= operation tlci-host-callback-op-pattern-list-cons)
      (if (< compiler-comptime-host-stack-len 2)
        tlci-host-callback-status-bad-request
        (let
          [pattern-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [list-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          (match list-value
            [(CompilerCtfeValue.PatternList items)
              (match pattern-value
                [(CompilerCtfeValue.Pattern pattern)
                  (let
                    [next : AstPatternList items]
                    (begin
                      (ast-pattern-list-push (&mut next) pattern)
                      (set!
                        compiler-comptime-host-stack-len
                        (- compiler-comptime-host-stack-len 2))
                      (compiler-comptime-host-push!
                        (CompilerCtfeValue.PatternList next))))]
                [_ tlci-host-callback-status-bad-request])]
            [_ tlci-host-callback-status-bad-request])))]
    [(= operation tlci-host-callback-op-pattern-list-bindings)
      (cond
        [(or (< arg-a 0) (< compiler-comptime-host-stack-len 1))
          tlci-host-callback-status-bad-request]
        [(> arg-a compiler-comptime-host-session-fuel)
          tlci-host-callback-status-fuel-exhausted]
        [else
          (match (array-ref
            compiler-comptime-host-stack
            (- compiler-comptime-host-stack-len 1))
            [(CompilerCtfeValue.String prefix _)
              (let
                [patterns : AstPatternList
                  (ast-pattern-list-with-capacity arg-a)]
                [index : i64 0]
                (begin
                  (while (< index arg-a)
                    (let
                      [name : String
                        (string.append prefix (string.int->string index))]
                      (begin
                        (ast-pattern-list-push
                          (&mut patterns)
                          (ast-pat-binding-id
                            (ctfe-materialize-generated-name-id name)))
                        (set! index (+ index 1)))))
                  (set!
                    compiler-comptime-host-session-fuel
                    (- compiler-comptime-host-session-fuel arg-a))
                  (set!
                    compiler-comptime-host-stack-len
                    (- compiler-comptime-host-stack-len 1))
                  (compiler-comptime-host-push!
                    (CompilerCtfeValue.PatternList patterns))))]
            [_ tlci-host-callback-status-bad-request])])]
    [(= operation tlci-host-callback-op-pattern-variant-from-value)
      (if (< compiler-comptime-host-stack-len 2)
        tlci-host-callback-status-bad-request
        (let
          [payloads-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [name-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [name-id : i64
            (match name-value
              [(CompilerCtfeValue.Name _ id) id]
              [(CompilerCtfeValue.String _ id) id]
              [_ -1])]
          (if (< name-id 0)
            tlci-host-callback-status-bad-request
            (match payloads-value
              [(CompilerCtfeValue.PatternList payloads)
                (begin
                  (set!
                    compiler-comptime-host-stack-len
                    (- compiler-comptime-host-stack-len 2))
                  (compiler-comptime-host-push!
                    (CompilerCtfeValue.Pattern
                      (ast-pat-variant-id name-id payloads))))]
              [_ tlci-host-callback-status-bad-request]))))]
    [(= operation tlci-host-callback-op-match-arm-list-cons-from-values)
      (if (< compiler-comptime-host-stack-len 2)
        tlci-host-callback-status-bad-request
        (let
          [rest-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [head-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          (match head-value
            [(CompilerCtfeValue.MatchArm head)
              (match rest-value
                [(CompilerCtfeValue.MatchArmList rest)
                  (begin
                    (set!
                      compiler-comptime-host-stack-len
                      (- compiler-comptime-host-stack-len 2))
                    (compiler-comptime-host-push!
                      (CompilerCtfeValue.MatchArmList
                        (ast-match-arm-cons head rest))))]
                [_ tlci-host-callback-status-bad-request])]
            [_ tlci-host-callback-status-bad-request])))]
    [(= operation tlci-host-callback-op-match-arm)
      (if (< compiler-comptime-host-stack-len 2)
        tlci-host-callback-status-bad-request
        (let
          [body-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [pattern-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [body-node : i64 (compiler-comptime-host-value-node body-value)]
          (if (< body-node 0)
            tlci-host-callback-status-bad-request
            (match pattern-value
              [(CompilerCtfeValue.Pattern pattern)
                (begin
                  (set!
                    compiler-comptime-host-stack-len
                    (- compiler-comptime-host-stack-len 2))
                  (compiler-comptime-host-push!
                    (CompilerCtfeValue.MatchArm
                      (ast-match-arm pattern body-node))))]
              [_ tlci-host-callback-status-bad-request]))))]
    [(= operation tlci-host-callback-op-match-arm-list-empty)
      (compiler-comptime-host-push!
        (CompilerCtfeValue.MatchArmList (ast-match-arm-list-new)))]
    [(= operation tlci-host-callback-op-match-arm-list-cons)
      (if (< compiler-comptime-host-stack-len 2)
        tlci-host-callback-status-bad-request
        (let
          [arm-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [list-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          (match list-value
            [(CompilerCtfeValue.MatchArmList items)
              (match arm-value
                [(CompilerCtfeValue.MatchArm arm)
                  (let
                    [next : AstMatchArmList items]
                    (begin
                      (ast-match-arm-list-push (&mut next) arm)
                      (set!
                        compiler-comptime-host-stack-len
                        (- compiler-comptime-host-stack-len 2))
                      (compiler-comptime-host-push!
                        (CompilerCtfeValue.MatchArmList next))))]
                [_ tlci-host-callback-status-bad-request])]
            [_ tlci-host-callback-status-bad-request])))]
    [(= operation tlci-host-callback-op-expr-match)
      (if (< compiler-comptime-host-stack-len 2)
        tlci-host-callback-status-bad-request
        (let
          [arms-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [scrutinee-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [scrutinee-node : i64
            (compiler-comptime-host-value-node scrutinee-value)]
          (if (< scrutinee-node 0)
            tlci-host-callback-status-bad-request
            (match arms-value
              [(CompilerCtfeValue.MatchArmList arms)
                (begin
                  (set!
                    compiler-comptime-host-stack-len
                    (- compiler-comptime-host-stack-len 2))
                  (compiler-comptime-host-push!
                    (CompilerCtfeValue.Expr
                      (ast-expr-match-with-pools
                        (array-ref compiler-comptime-host-pools 0)
                        scrutinee-node
                        arms)
                      (AstType.Expr))))]
              [_ tlci-host-callback-status-bad-request]))))]
    ;; string-value: push the comptime String value for caller bytes, keeping
    ;; a parsed-source identity like the lexer's string tokens.
    [(= operation tlci-host-callback-op-string-value)
      (if (or (<= arg-a 0) (< arg-b 0))
        tlci-host-callback-status-bad-request
        (let
          [text : String
            (unsafe
              (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))]
          [string-id : i64
            (ci.intern-source-slice text 0 (string.string-length text))]
          (compiler-comptime-host-push!
            (CompilerCtfeValue.String (intern-str string-id) string-id))))]
    ;; diagnostic-from-value: pop a comptime String into the session
    ;; diagnostic and answer with the diagnostic status.
    [(= operation tlci-host-callback-op-diagnostic-from-value)
      (if (< compiler-comptime-host-stack-len 1)
        tlci-host-callback-status-bad-request
        (match (array-ref
          compiler-comptime-host-stack
          (- compiler-comptime-host-stack-len 1))
          [(CompilerCtfeValue.String text _)
            (begin
              (array-set! compiler-comptime-host-diagnostic 0 text)
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              tlci-host-callback-status-diagnostic)]
          [_ tlci-host-callback-status-bad-request]))]
    ;; pattern-var: a unit/variable pattern for caller bytes with the
    ;; template-source mark, matching the interpreted quote.
    [(= operation tlci-host-callback-op-pattern-var)
      (if (or (<= arg-a 0) (< arg-b 0))
        tlci-host-callback-status-bad-request
        (let
          [name : String
            (unsafe
              (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))]
          (compiler-comptime-host-push!
            (CompilerCtfeValue.Pattern
              (AstPattern.Var
                (ci.intern-template-source-id
                  (ci.intern-source-slice name 0 (string.string-length name)))
                (AstMaybeType.No))))))]
    ;; string-eq: pop two comptime String values and answer 1/0 as data (a
    ;; negative value reports a bad request without touching session state).
    [(= operation tlci-host-callback-op-string-eq)
      (if (< compiler-comptime-host-stack-len 2)
        -3
        (let
          [right-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [left-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          (match left-value
            [(CompilerCtfeValue.String left-text _)
              (match right-value
                [(CompilerCtfeValue.String right-text _)
                  (begin
                    (set!
                      compiler-comptime-host-stack-len
                      (- compiler-comptime-host-stack-len 2))
                    (if (string.eq left-text right-text)
                      1
                      0))]
                [_ -3])]
            [_ -3])))]
    ;; tuple-ref: pop the target expression and use the computed index in `a`.
    [(= operation tlci-host-callback-op-expr-tuple-ref)
      (if (< compiler-comptime-host-stack-len 1)
        tlci-host-callback-status-bad-request
        (let
          [target-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [target-node : i64 (compiler-comptime-host-value-node target-value)]
          (if (or (< target-node 0) (< arg-a 0))
            tlci-host-callback-status-bad-request
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              (compiler-comptime-host-push!
                (CompilerCtfeValue.Expr
                  (ast-expr-tuple-ref-with-pools
                    (array-ref compiler-comptime-host-pools 0)
                    target-node
                    arg-a)
                  (AstType.Expr)))))))]
    ;; struct-get: pop the target expression and push the field access node
    ;; for the field name in `a`/`b`.
    [(= operation tlci-host-callback-op-expr-struct-get)
      (if (or (<= arg-a 0) (< arg-b 0) (< compiler-comptime-host-stack-len 1))
        tlci-host-callback-status-bad-request
        (let
          [target-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [target-node : i64 (compiler-comptime-host-value-node target-value)]
          (if (< target-node 0)
            tlci-host-callback-status-bad-request
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              (compiler-comptime-host-push!
                (CompilerCtfeValue.Expr
                  (ast-expr-struct-get-id-with-pools
                    (array-ref compiler-comptime-host-pools 0)
                    target-node
                    (ci.intern-source-slice
                      (unsafe
                        (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))
                      0
                      arg-b))
                  (AstType.Expr)))))))]
    ;; Dynamic struct-get: pop the computed name after the target expression.
    [(= operation tlci-host-callback-op-expr-struct-get-from-value)
      (if (< compiler-comptime-host-stack-len 2)
        tlci-host-callback-status-bad-request
        (let
          [name-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [target-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [target-node : i64 (compiler-comptime-host-value-node target-value)]
          [name-id : i64
            (match name-value
              [(CompilerCtfeValue.Name _ id) id]
              [(CompilerCtfeValue.String _ id) id]
              [_ -1])]
          (if (or (< target-node 0) (< name-id 0))
            tlci-host-callback-status-bad-request
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 2))
              (compiler-comptime-host-push!
                (CompilerCtfeValue.Expr
                  (ast-expr-struct-get-id-with-pools
                    (array-ref compiler-comptime-host-pools 0)
                    target-node
                    name-id)
                  (AstType.Expr)))))))]
    ;; array-set!: pop the value, index, and target expressions and push the
    ;; node the parser produces.
    [(= operation tlci-host-callback-op-expr-array-set)
      (if (< compiler-comptime-host-stack-len 3)
        tlci-host-callback-status-bad-request
        (let
          [value-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [index-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [target-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 3))]
          [value-node : i64 (compiler-comptime-host-value-node value-value)]
          [index-node : i64 (compiler-comptime-host-value-node index-value)]
          [target-node : i64 (compiler-comptime-host-value-node target-value)]
          (if (or (< value-node 0) (< index-node 0) (< target-node 0))
            tlci-host-callback-status-bad-request
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 3))
              (compiler-comptime-host-push!
                (CompilerCtfeValue.Expr
                  (ast-expr-array-set-with-pools
                    (array-ref compiler-comptime-host-pools 0)
                    target-node
                    index-node
                    value-node)
                  (AstType.Expr)))))))]
    ;; expr-struct-set: pop the value then the target expression and push the
    ;; `(set! (struct-get target field) value)` node for the field name in
    ;; `a`/`b`, matching the interpreted quote's non-unquoted set! target path.
    [(= operation tlci-host-callback-op-expr-struct-set)
      (if (or (<= arg-a 0) (< arg-b 0) (< compiler-comptime-host-stack-len 2))
        tlci-host-callback-status-bad-request
        (let
          [value-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [target-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [value-node : i64 (compiler-comptime-host-value-node value-value)]
          [target-node : i64 (compiler-comptime-host-value-node target-value)]
          (if (or (< value-node 0) (< target-node 0))
            tlci-host-callback-status-bad-request
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 2))
              (compiler-comptime-host-push!
                (CompilerCtfeValue.Expr
                  (ast-expr-struct-set-id-with-pools
                    (array-ref compiler-comptime-host-pools 0)
                    target-node
                    (ci.intern-source-slice
                      (unsafe
                        (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))
                      0
                      arg-b)
                    value-node)
                  (AstType.Expr)))))))]
    ;; expr-return / expr-box / expr-box-get: pop one expression and push the
    ;; node the parser produces, matching the interpreted quote's unary
    ;; reconstruction of `(return e)`, `(box e)`, and `(box-get e)`.
    [(= operation tlci-host-callback-op-expr-return)
      (compiler-comptime-host-unary-node-step! 0)]
    [(= operation tlci-host-callback-op-expr-box)
      (compiler-comptime-host-unary-node-step! 1)]
    [(= operation tlci-host-callback-op-expr-box-get)
      (compiler-comptime-host-unary-node-step! 2)]
    ;; Raw-pointer and `unsafe` template nodes (refs #5605).
    [(= operation tlci-host-callback-op-expr-ptr-read)
      (compiler-comptime-host-unary-node-step! 3)]
    [(= operation tlci-host-callback-op-expr-ptr-to-int)
      (compiler-comptime-host-unary-node-step! 4)]
    [(= operation tlci-host-callback-op-expr-string-data)
      (compiler-comptime-host-unary-node-step! 5)]
    [(= operation tlci-host-callback-op-expr-array-data)
      (compiler-comptime-host-unary-node-step! 6)]
    [(= operation tlci-host-callback-op-expr-string-from-bytes)
      (compiler-comptime-host-ptr-binary-step! 2)]
    [(= operation tlci-host-callback-op-expr-ptr-write)
      (compiler-comptime-host-ptr-binary-step! 0)]
    [(= operation tlci-host-callback-op-expr-ptr-offset)
      (compiler-comptime-host-ptr-binary-step! 1)]
    ;; expr-unsafe pops an expression list and pushes the `(unsafe ...)` node
    ;; the parser produces, matching expr-begin's shape.
    [(= operation tlci-host-callback-op-expr-unsafe)
      (if (< compiler-comptime-host-stack-len 1)
        tlci-host-callback-status-bad-request
        (match (array-ref
          compiler-comptime-host-stack
          (- compiler-comptime-host-stack-len 1))
          [(CompilerCtfeValue.ExprList items)
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              (compiler-comptime-host-push!
                (CompilerCtfeValue.Expr
                  (ast-node-pool-context-expr-push
                    (array-ref compiler-comptime-host-pools 0)
                    (AstExpr.Unsafe items))
                  (AstType.Expr))))]
          [_ tlci-host-callback-status-bad-request]))]
    ;; expr-float-literal: push a float literal node carrying the caller bytes
    ;; verbatim, the same source text the interpreted quote preserves.
    [(= operation tlci-host-callback-op-expr-float-literal)
      (if (or (<= arg-a 0) (< arg-b 0))
        tlci-host-callback-status-bad-request
        (let
          [text : String
            (unsafe
              (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))]
          (compiler-comptime-host-push!
            (CompilerCtfeValue.Expr
              (ast-node-pool-context-expr-push
                (array-ref compiler-comptime-host-pools 0)
                (AstExpr.Literal
                  (AstLiteral.Float
                    (intern-str
                      (ci.intern-source-slice
                        text
                        0
                        (string.string-length text))))))
              (AstType.Expr)))))]
    ;; let-binding: pop the init expression and push a binding for the name in
    ;; `a`/`b` with the template-source mark and no type annotation.
    [(= operation tlci-host-callback-op-let-binding)
      (if (or (<= arg-a 0) (< arg-b 0) (< compiler-comptime-host-stack-len 1))
        tlci-host-callback-status-bad-request
        (let
          [init-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [init-node : i64 (compiler-comptime-host-value-node init-value)]
          (if (< init-node 0)
            tlci-host-callback-status-bad-request
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              (compiler-comptime-host-push!
                (CompilerCtfeValue.LetBinding
                  (ast-let-binding-id
                    (ci.intern-template-source-id
                      (ci.intern-source-slice
                        (unsafe
                          (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))
                        0
                        arg-b))
                    (AstMaybeType.No)
                    init-node)))))))]
    [(= operation tlci-host-callback-op-let-binding-list-empty)
      (compiler-comptime-host-push!
        (CompilerCtfeValue.LetBindingList (ast-let-binding-list-new)))]
    [(= operation tlci-host-callback-op-let-binding-list-cons)
      (if (< compiler-comptime-host-stack-len 2)
        tlci-host-callback-status-bad-request
        (let
          [binding-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [list-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          (match list-value
            [(CompilerCtfeValue.LetBindingList items)
              (match binding-value
                [(CompilerCtfeValue.LetBinding binding)
                  (let
                    [next : AstLetBindingList items]
                    (begin
                      (ast-let-binding-list-push (&mut next) binding)
                      (set!
                        compiler-comptime-host-stack-len
                        (- compiler-comptime-host-stack-len 2))
                      (compiler-comptime-host-push!
                        (CompilerCtfeValue.LetBindingList next))))]
                [_ tlci-host-callback-status-bad-request])]
            [_ tlci-host-callback-status-bad-request])))]
    ;; expr-let: pop the body then the binding list and push the let node.
    [(= operation tlci-host-callback-op-expr-let)
      (if (< compiler-comptime-host-stack-len 2)
        tlci-host-callback-status-bad-request
        (let
          [body-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [list-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [body-node : i64 (compiler-comptime-host-value-node body-value)]
          (if (< body-node 0)
            tlci-host-callback-status-bad-request
            (match list-value
              [(CompilerCtfeValue.LetBindingList items)
                (begin
                  (set!
                    compiler-comptime-host-stack-len
                    (- compiler-comptime-host-stack-len 2))
                  (compiler-comptime-host-push!
                    (CompilerCtfeValue.Expr
                      (ast-expr-let-with-pools
                        (array-ref compiler-comptime-host-pools 0)
                        items
                        body-node)
                      (AstType.Expr))))]
              [_ tlci-host-callback-status-bad-request]))))]
    ;; type-var: push the AstType.Var for caller bytes (unmarked, matching
    ;; the interpreted type quote for a plain name).
    [(= operation tlci-host-callback-op-type-var)
      (if (or (<= arg-a 0) (< arg-b 0))
        tlci-host-callback-status-bad-request
        (let
          [name : String
            (unsafe
              (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))]
          (compiler-comptime-host-push!
            (CompilerCtfeValue.Type
              (AstType.Var
                (ci.intern-source-slice name 0 (string.string-length name)))))))]
    ;; type-scalar: push the scalar AstType variant for immediate `a`.
    [(= operation tlci-host-callback-op-type-scalar)
      (compiler-comptime-host-push!
        (CompilerCtfeValue.Type
          (compiler-comptime-host-scalar-type-for-ordinal arg-a)))]
    ;; array-element-type: pop an array type value and push the element type,
    ;; matching the interpreted reflection.
    [(= operation tlci-host-callback-op-array-element-type)
      (if (< compiler-comptime-host-stack-len 1)
        tlci-host-callback-status-bad-request
        (let
          [env : CtfeEnv
            (ctfe-env-empty-with-pools
              (array-ref compiler-comptime-host-pools 0))]
          (match (array-ref
            compiler-comptime-host-stack
            (- compiler-comptime-host-stack-len 1))
            [(CompilerCtfeValue.Type (AstType.Array elem _))
              (begin
                (set!
                  compiler-comptime-host-stack-len
                  (- compiler-comptime-host-stack-len 1))
                (compiler-comptime-host-push!
                  (CompilerCtfeValue.Type (ctfe-ty-get env elem))))]
            [(CompilerCtfeValue.Type (AstType.DynArray elem))
              (begin
                (set!
                  compiler-comptime-host-stack-len
                  (- compiler-comptime-host-stack-len 1))
                (compiler-comptime-host-push!
                  (CompilerCtfeValue.Type (ctfe-ty-get env elem))))]
            [_ tlci-host-callback-status-bad-request])))]
    ;; array-length: the fixed element count of an array type as data; a
    ;; dynamic type or non-array reports the negative sentinel.
    [(= operation tlci-host-callback-op-array-length)
      (if (< compiler-comptime-host-stack-len 1)
        -3
        (match (array-ref
          compiler-comptime-host-stack
          (- compiler-comptime-host-stack-len 1))
          [(CompilerCtfeValue.Type (AstType.Array _ count))
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              count)]
          [_ -3]))]
    ;; array-dynamic?: 1 for a dynamic array type, 0 for a fixed one, and the
    ;; negative sentinel otherwise.
    [(= operation tlci-host-callback-op-array-dynamic?)
      (if (< compiler-comptime-host-stack-len 1)
        -3
        (match (array-ref
          compiler-comptime-host-stack
          (- compiler-comptime-host-stack-len 1))
          [(CompilerCtfeValue.Type (AstType.Array _ _))
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              0)]
          [(CompilerCtfeValue.Type (AstType.DynArray _))
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              1)]
          [_ -3]))]
    ;; expr-int-from-data: push an int literal node for the value in `a`.
    ;; Expression-shape probe and accessors for a computed body matching on
    ;; `(comptime.Expr.Call callee args)`. The probe answers as data and
    ;; bypasses the status latch; the accessors push exactly the two values
    ;; the interpreted pattern binds. Refs #5602.
    [(= operation tlci-host-callback-op-operand-expr-call?)
      (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
        -3
        (match (compiler-comptime-host-operand-expr arg-a)
          [(AstExpr.Call _ _) 1]
          [_ 0]))]
    [(= operation tlci-host-callback-op-operand-expr-call-callee)
      (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
        tlci-host-callback-status-bad-request
        (match (compiler-comptime-host-operand-expr arg-a)
          [(AstExpr.Call callee _)
            (compiler-comptime-host-push!
              (CompilerCtfeValue.Expr callee (ctfe-untyped-expr-type)))]
          [_ tlci-host-callback-status-bad-request]))]
    [(= operation tlci-host-callback-op-operand-expr-call-args)
      (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
        tlci-host-callback-status-bad-request
        (match (compiler-comptime-host-operand-expr arg-a)
          [(AstExpr.Call _ call-args)
            (compiler-comptime-host-push!
              (CompilerCtfeValue.ExprList call-args))]
          [_ tlci-host-callback-status-bad-request]))]
    ;; The `comptime.Expr.Int` half: a data probe plus a value read that the
    ;; generated entry only issues inside the probe's matching arm. Refs #5602.
    ;; expr-ptr-cast pops the type value then the pointer expression, the same
    ;; order expr-make-array uses. Refs #5605.
    [(= operation tlci-host-callback-op-expr-ptr-cast)
      (if (< compiler-comptime-host-stack-len 2)
        tlci-host-callback-status-bad-request
        (let
          [type-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [ptr-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [ptr-node : i64 (compiler-comptime-host-value-node ptr-value)]
          (if (< ptr-node 0)
            tlci-host-callback-status-bad-request
            (match type-value
              [(CompilerCtfeValue.Type ty)
                (begin
                  (set!
                    compiler-comptime-host-stack-len
                    (- compiler-comptime-host-stack-len 2))
                  (compiler-comptime-host-push!
                    (CompilerCtfeValue.Expr
                      (ast-expr-ptr-cast-with-pools
                        (array-ref compiler-comptime-host-pools 0)
                        ptr-node
                        ty)
                      (AstType.Expr))))]
              [_ tlci-host-callback-status-bad-request]))))]
    ;; Composite type templates: pop the element/inner type and push the
    ;; wrapper. Refs #5605.
    [(= operation tlci-host-callback-op-type-ptr)
      (compiler-comptime-host-type-wrap-step! 0 arg-a 0 0)]
    [(= operation tlci-host-callback-op-type-box)
      (compiler-comptime-host-type-wrap-step! 1 0 0 0)]
    [(= operation tlci-host-callback-op-type-dyn-array)
      (compiler-comptime-host-type-wrap-step! 2 0 0 0)]
    [(= operation tlci-host-callback-op-type-array)
      (compiler-comptime-host-type-wrap-step! 3 arg-a 0 0)]
    [(= operation tlci-host-callback-op-type-ref)
      (compiler-comptime-host-type-wrap-step! 4 arg-a arg-b _arg-c)]
    ;; Literal text out of a string-literal Expr operand, mirroring
    ;; `ctfe-source-string-value`: the pushed value carries the intern id the
    ;; text entered CTFE with, not a fresh one. Refs #5626.
    [(= operation tlci-host-callback-op-operand-expr-string-value)
      (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
        tlci-host-callback-status-bad-request
        (match (compiler-comptime-host-operand-expr arg-a)
          [(AstExpr.Literal (AstLiteral.String string-id))
            (compiler-comptime-host-push!
              (CompilerCtfeValue.String (intern-str string-id) string-id))]
          [_ tlci-host-callback-status-bad-request]))]
    ;; The `comptime.expr-string?` guard, answering the same 1/0-as-data the
    ;; interpreted inspector answers for an Expr operand. Refs #5701.
    [(= operation tlci-host-callback-op-operand-expr-string?)
      (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
        -3
        (match (compiler-comptime-host-operand-expr arg-a)
          [(AstExpr.Literal (AstLiteral.String _)) 1]
          [_ 0]))]
    [(= operation tlci-host-callback-op-operand-expr-int?)
      (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
        -3
        (match (compiler-comptime-host-operand-expr arg-a)
          [(AstExpr.Literal (AstLiteral.Int _ _)) 1]
          [_ 0]))]
    [(= operation tlci-host-callback-op-operand-expr-int-value)
      (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
        0
        (match (compiler-comptime-host-operand-expr arg-a)
          [(AstExpr.Literal (AstLiteral.Int value _)) value]
          [_ 0]))]
    ;; Local-slot twins of ops 155/156: a destructured `ExprList` payload lives
    ;; in a session local, and the fold bodies index it there. Refs #5602.
    [(= operation tlci-host-callback-op-local-expr-list-length)
      (if (or
        (< arg-a 0)
        (>= arg-a compiler-comptime-host-locals-cap)
        (not (array-ref compiler-comptime-host-locals-live arg-a)))
        -3
        (match (compiler-comptime-host-value-expr-list
          (array-ref compiler-comptime-host-locals arg-a))
          [(CompilerCtfeMaybeExprList.Some items) (ctfe-expr-list-length items)]
          [(CompilerCtfeMaybeExprList.None) -3]))]
    [(= operation tlci-host-callback-op-local-expr-list-nth)
      (if (or
        (< arg-a 0)
        (>= arg-a compiler-comptime-host-locals-cap)
        (not (array-ref compiler-comptime-host-locals-live arg-a)))
        tlci-host-callback-status-bad-request
        (let
          [value : CompilerCtfeValue
            (array-ref compiler-comptime-host-locals arg-a)]
          (match (compiler-comptime-host-value-expr-list value)
            [(CompilerCtfeMaybeExprList.Some items)
              (if (or (< arg-b 0) (>= arg-b (ctfe-expr-list-length items)))
                tlci-host-callback-status-bad-request
                (let
                  [node : i64 (ctfe-expr-list-nth items arg-b)]
                  (match value
                    [(CompilerCtfeValue.CapturedExprList _ pools)
                      (compiler-comptime-host-push!
                        (CompilerCtfeValue.CapturedExpr
                          node
                          (ctfe-untyped-expr-type)
                          pools))]
                    [_
                      (compiler-comptime-host-push!
                        (CompilerCtfeValue.Expr node (ctfe-untyped-expr-type)))])))]
            [(CompilerCtfeMaybeExprList.None)
              tlci-host-callback-status-bad-request])))]
    ;; value-i64: push a comptime i64 from the immediate, so a literal or a
    ;; data-local index can feed int->string. Refs #5700.
    [(= operation tlci-host-callback-op-value-i64)
      (compiler-comptime-host-push! (CompilerCtfeValue.I64 arg-a))]
    ;; int->string: pop a comptime i64 and push its decimal spelling as a
    ;; comptime String, mirroring the interpreted `comptime.int->string`
    ;; builtin. Refs #5700.
    [(= operation tlci-host-callback-op-int->string)
      (if (< compiler-comptime-host-stack-len 1)
        tlci-host-callback-status-bad-request
        (match (array-ref
          compiler-comptime-host-stack
          (- compiler-comptime-host-stack-len 1))
          [(CompilerCtfeValue.I64 value)
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              (compiler-comptime-host-push!
                (ctfe-generated-string-value (string.int->string value))))]
          [_ tlci-host-callback-status-bad-request]))]
    ;; `comptime.Expr.Var` destructuring (refs #5700). The probe answers as data
    ;; like the other operand shape probes; the accessor pushes the identifier's
    ;; spelling as a comptime String, which is what the nested-alias bodies
    ;; append to.
    [(= operation tlci-host-callback-op-operand-expr-var?)
      (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
        -3
        (match (compiler-comptime-host-operand-expr arg-a)
          [(AstExpr.Var _) 1]
          [_ 0]))]
    [(= operation tlci-host-callback-op-operand-expr-var-name)
      (if (or (< arg-a 0) (>= arg-a compiler-comptime-host-operand-count))
        tlci-host-callback-status-bad-request
        (match (compiler-comptime-host-operand-expr arg-a)
          [(AstExpr.Var name-id)
            (compiler-comptime-host-push!
              (ctfe-generated-string-value (intern-str name-id)))]
          [_ tlci-host-callback-status-bad-request]))]
    ;; Comptime string scanning over a String session local (refs #5701). The
    ;; two data probes mirror `ctfe-eval-string-length-call` and
    ;; `ctfe-eval-string-ref-call`: length is total, and an out-of-bounds index
    ;; is the interpreted diagnostic's native counterpart, a malformed request
    ;; rather than a silently clamped byte.
    [(= operation tlci-host-callback-op-local-string-length)
      (match (compiler-comptime-host-local-string arg-a)
        [(CompilerCtfeMaybeString.Some text) (string.string-length text)]
        [(CompilerCtfeMaybeString.None) -3])]
    [(= operation tlci-host-callback-op-local-string-ref)
      (match (compiler-comptime-host-local-string arg-a)
        [(CompilerCtfeMaybeString.Some text)
          (if (or (< arg-b 0) (>= arg-b (string.string-length text)))
            -3
            (cast (string.string-ref text arg-b) : i64))]
        [(CompilerCtfeMaybeString.None) -3])]
    ;; The `[b, b+c)` byte range as the generated comptime String value
    ;; `ctfe-eval-comptime-string-slice-call` yields, with the same bounds
    ;; contract.
    [(= operation tlci-host-callback-op-local-string-slice)
      (match (compiler-comptime-host-local-string arg-a)
        [(CompilerCtfeMaybeString.Some text)
          (if (or
            (< arg-b 0)
            (< _arg-c 0)
            (> (+ arg-b _arg-c) (string.string-length text)))
            tlci-host-callback-status-bad-request
            (compiler-comptime-host-push!
              (ctfe-generated-string-value (string.substring text arg-b _arg-c))))]
        [(CompilerCtfeMaybeString.None) tlci-host-callback-status-bad-request])]
    ;; expr-string-from-value: pop a comptime String and push the string
    ;; literal expression `ctfe-eval-expr-string-call` builds -- the popped
    ;; value's own intern id and the `String` expression type, so a template
    ;; embeds exactly the literal interpretation would.
    [(= operation tlci-host-callback-op-expr-string-from-value)
      (if (< compiler-comptime-host-stack-len 1)
        tlci-host-callback-status-bad-request
        (match (array-ref
          compiler-comptime-host-stack
          (- compiler-comptime-host-stack-len 1))
          [(CompilerCtfeValue.String _ string-id)
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              (compiler-comptime-host-push!
                (ctfe-syntax-expr-push
                  (ctfe-env-empty-with-pools
                    (array-ref compiler-comptime-host-pools 0))
                  (AstExpr.Literal (AstLiteral.String string-id))
                  (AstType.String))))]
          [_ tlci-host-callback-status-bad-request]))]
    [(= operation tlci-host-callback-op-expr-int-from-data)
      (compiler-comptime-host-push!
        (CompilerCtfeValue.Expr
          (ast-node-pool-context-expr-push
            (array-ref compiler-comptime-host-pools 0)
            (AstExpr.Literal (ast-lit-int arg-a)))
          (AstType.Expr)))]
    ;; expr-set-var: pop the value expression and push the set! node for the
    ;; place name in `a`/`b` (template-source marked like the interpreted
    ;; quote).
    [(= operation tlci-host-callback-op-expr-set-var)
      (if (or (<= arg-a 0) (< arg-b 0) (< compiler-comptime-host-stack-len 1))
        tlci-host-callback-status-bad-request
        (let
          [value-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [value-node : i64 (compiler-comptime-host-value-node value-value)]
          (if (< value-node 0)
            tlci-host-callback-status-bad-request
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              (compiler-comptime-host-push!
                (CompilerCtfeValue.Expr
                  (ast-expr-set-id-with-pools
                    (array-ref compiler-comptime-host-pools 0)
                    (ci.intern-template-source-id
                      (ci.intern-source-slice
                        (unsafe
                          (string-from-bytes (int->ptr arg-a : (Ptr u8)) arg-b))
                        0
                        arg-b))
                    value-node)
                  (AstType.Expr)))))))]
    ;; expr-while: pop the body then the condition expression and push the
    ;; while node the parser produces.
    [(= operation tlci-host-callback-op-expr-while)
      (if (< compiler-comptime-host-stack-len 2)
        tlci-host-callback-status-bad-request
        (let
          [body-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [cond-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [body-node : i64 (compiler-comptime-host-value-node body-value)]
          [cond-node : i64 (compiler-comptime-host-value-node cond-value)]
          (if (or (< body-node 0) (< cond-node 0))
            tlci-host-callback-status-bad-request
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 2))
              (compiler-comptime-host-push!
                (CompilerCtfeValue.Expr
                  (ast-expr-while-with-pools
                    (array-ref compiler-comptime-host-pools 0)
                    cond-node
                    body-node)
                  (AstType.Expr)))))))]
    ;; let-binding-typed: pop the type value then the init expression and
    ;; push a binding for the name in `a`/`b` (template-source marked) with
    ;; that type annotation. The producer emits the init template first and
    ;; the type second, so the type is the topmost stack value.
    [(= operation tlci-host-callback-op-let-binding-typed)
      (if (or (<= arg-a 0) (< arg-b 0) (< compiler-comptime-host-stack-len 2))
        tlci-host-callback-status-bad-request
        (let
          [type-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [init-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [init-node : i64 (compiler-comptime-host-value-node init-value)]
          (if (< init-node 0)
            tlci-host-callback-status-bad-request
            (match type-value
              [(CompilerCtfeValue.Type ty)
                (begin
                  (set!
                    compiler-comptime-host-stack-len
                    (- compiler-comptime-host-stack-len 2))
                  (compiler-comptime-host-push!
                    (CompilerCtfeValue.LetBinding
                      (ast-let-binding-id
                        (ci.intern-template-source-id
                          (ci.intern-source-slice
                            (unsafe
                              (string-from-bytes
                                (int->ptr arg-a : (Ptr u8))
                                arg-b))
                            0
                            arg-b))
                        (AstMaybeType.Some ty)
                        init-node))))]
              [_ tlci-host-callback-status-bad-request]))))]
    ;; type-kind: pop a type value and push its kind string, the same mapping
    ;; the interpreted reflection uses.
    [(= operation tlci-host-callback-op-type-kind)
      (if (< compiler-comptime-host-stack-len 1)
        tlci-host-callback-status-bad-request
        (match (array-ref
          compiler-comptime-host-stack
          (- compiler-comptime-host-stack-len 1))
          [(CompilerCtfeValue.Type ty)
            (begin
              (set!
                compiler-comptime-host-stack-len
                (- compiler-comptime-host-stack-len 1))
              (compiler-comptime-host-push!
                (ctfe-generated-string-value
                  (ctfe-type-kind-with-reflections-and-pools
                    (array-ref compiler-comptime-host-pools 0)
                    (array-ref compiler-comptime-host-reflections 0)
                    ty))))]
          [_ tlci-host-callback-status-bad-request]))]
    [(= operation tlci-host-callback-op-expr-list-fold-if)
      (if (or
        (< compiler-comptime-host-stack-len 2)
        (< arg-a 0)
        (>= arg-a compiler-comptime-host-operand-count))
        tlci-host-callback-status-bad-request
        (let
          [when-false-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [when-true-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [when-false-node : i64
            (compiler-comptime-host-value-node when-false-value)]
          [when-true-node : i64
            (compiler-comptime-host-value-node when-true-value)]
          [continue-on-true : bool (not (= arg-b 0))]
          (if (or (< when-false-node 0) (< when-true-node 0))
            tlci-host-callback-status-bad-request
            (match (array-ref compiler-comptime-host-operands arg-a)
              [(CompilerCtfeValue.ExprList items)
                (let
                  [pools : AstNodePoolContext
                    (array-ref compiler-comptime-host-pools 0)]
                  [index : i64 (- (ctfe-expr-list-length items) 1)]
                  [out-node : i64
                    (if continue-on-true
                      when-true-node
                      when-false-node)]
                  (begin
                    ;; Mirrors ctfe-eval-expr-list-fold-if-plain-at exactly:
                    ;; right-to-left, terminals from the two stack values.
                    (while (>= index 0)
                      (let
                        [cond-node : i64 (ctfe-expr-list-nth items index)]
                        (begin
                          (set!
                            out-node
                            (ast-expr-if-with-pools
                              pools
                              cond-node
                              (if continue-on-true
                                out-node
                                when-true-node)
                              (if continue-on-true
                                when-false-node
                                out-node)))
                          (set! index (- index 1)))))
                    (set!
                      compiler-comptime-host-stack-len
                      (- compiler-comptime-host-stack-len 2))
                    (if (and
                      (ctfe-hygiene-inert-literal-node? pools when-true-node)
                      (ctfe-hygiene-inert-literal-node? pools when-false-node))
                      (ctfe-result-hygiene-free-note! out-node)
                      unit)
                    (compiler-comptime-host-push!
                      (CompilerCtfeValue.Expr out-node (AstType.Expr)))))]
              [_ tlci-host-callback-status-bad-request]))))]
    [(= operation tlci-host-callback-op-expr-clause-list-fold-if)
      (if (or
        (< compiler-comptime-host-stack-len 2)
        (< arg-a 0)
        (>= arg-a compiler-comptime-host-operand-count))
        tlci-host-callback-status-bad-request
        (let
          [else-not-final-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1))]
          [missing-value : CompilerCtfeValue
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 2))]
          [else-not-final-node : i64
            (compiler-comptime-host-value-node else-not-final-value)]
          [missing-node : i64 (compiler-comptime-host-value-node missing-value)]
          (if (or (< else-not-final-node 0) (< missing-node 0))
            tlci-host-callback-status-bad-request
            (match (array-ref compiler-comptime-host-operands arg-a)
              [(CompilerCtfeValue.ExprClauseList items)
                (let
                  [pools : AstNodePoolContext
                    (array-ref compiler-comptime-host-pools 0)]
                  [n : i64 (ctfe-expr-clause-list-length items)]
                  [out-node : i64 missing-node]
                  [index : i64 (- n 2)]
                  (begin
                    ;; Mirrors ctfe-eval-expr-clause-list-fold-if exactly:
                    ;; the final clause seeds the accumulator (its result
                    ;; when it is an else clause, the missing marker
                    ;; otherwise), then right-to-left each clause wraps an
                    ;; if, with a non-final else collapsing to the marker.
                    (if (> n 0)
                      (let
                        [final-clause : AstExprClause
                          (ctfe-expr-clause-list-nth items (- n 1))]
                        (if (ctfe-expr-else-with-pools?
                          pools
                          (ctfe-expr-clause-first final-clause))
                          (set! out-node (ctfe-expr-clause-second final-clause))
                          unit))
                      unit)
                    (while (>= index 0)
                      (let
                        [clause : AstExprClause
                          (ctfe-expr-clause-list-nth items index)]
                        [test-node : i64 (ctfe-expr-clause-first clause)]
                        (begin
                          (set!
                            out-node
                            (if (ctfe-expr-else-with-pools? pools test-node)
                              else-not-final-node
                              (ast-expr-if-with-pools
                                pools
                                test-node
                                (ctfe-expr-clause-second clause)
                                out-node)))
                          (set! index (- index 1)))))
                    (set!
                      compiler-comptime-host-stack-len
                      (- compiler-comptime-host-stack-len 2))
                    (if (and
                      (ctfe-hygiene-inert-literal-node? pools missing-node)
                      (ctfe-hygiene-inert-literal-node?
                        pools
                        else-not-final-node))
                      (ctfe-result-hygiene-free-note! out-node)
                      unit)
                    (compiler-comptime-host-push!
                      (CompilerCtfeValue.Expr out-node (AstType.Expr)))))]
              [_ tlci-host-callback-status-bad-request]))))]
    [(= operation tlci-host-callback-op-commit-result)
      (if (< compiler-comptime-host-stack-len 1)
        tlci-host-callback-status-bad-request
        (begin
          (array-set!
            compiler-comptime-host-result
            0
            (array-ref
              compiler-comptime-host-stack
              (- compiler-comptime-host-stack-len 1)))
          (set!
            compiler-comptime-host-stack-len
            (- compiler-comptime-host-stack-len 1))
          (set! compiler-comptime-host-result-ready true)
          tlci-host-callback-status-ok))]
    [else tlci-host-callback-status-bad-request]))

;; A valid-session callback failure is terminal for that transformer
;; invocation. Native entries may remain branch-free: later probes observe the
;; first status without mutating the value stack or committing a result.
;; The operand-type-kind and list-length probes are the data-returning
;; operations: 1/0 (or the item count) is their result and a negative value is
;; their malformed-request sentinel. They must bypass the status latch;
;; generated entries translate the negative sentinel to the public bad-request
;; status before unwinding.
;; Invalid cookies do not poison the active session.
(define (compiler-comptime-host-invoke
  [session : i64]
  [operation : i64]
  [arg-a : i64]
  [arg-b : i64]
  [arg-c : i64]) : i64
  (if (or
    (= compiler-comptime-host-session-cookie 0)
    (not (= session compiler-comptime-host-session-cookie)))
    tlci-host-callback-status-bad-request
    (if (not
      (= compiler-comptime-host-session-status tlci-host-callback-status-ok))
      compiler-comptime-host-session-status
      (let
        [status : i64
          (compiler-comptime-host-invoke-step
            session
            operation
            arg-a
            arg-b
            arg-c)]
        (begin
          (when
            (and
              (not (compiler-comptime-host-data-operation? operation))
              (not (= status tlci-host-callback-status-ok)))
            (set! compiler-comptime-host-session-status status))
          status)))))

;; The data-returning operations: their result *is* the answer -- 1/0, an item
;; count, a byte length, a byte value -- and a negative value is their
;; malformed-request sentinel, so a non-zero return must not be mistaken for a
;; failed status. Missing an entry here is silent and total: the first such
;; call latches its own answer as the session status, and every later callback
;; in the transformer returns that number instead of doing anything.
(define (compiler-comptime-host-data-operation? [operation : i64]) : bool
  (or
    (= operation tlci-host-callback-op-operand-type-kind-eq)
    (= operation tlci-host-callback-op-operand-expr-type-kind-eq)
    (= operation tlci-host-callback-op-operand-type-key-eq)
    (= operation tlci-host-callback-op-expr-list-length)
    (= operation tlci-host-callback-op-string-eq)
    (= operation tlci-host-callback-op-array-length)
    (= operation tlci-host-callback-op-array-dynamic?)
    (= operation tlci-host-callback-op-struct-field-count)
    (= operation tlci-host-callback-op-enum-variant-count)
    (= operation tlci-host-callback-op-enum-variant-payload-count)
    (= operation tlci-host-callback-op-tuple-element-count)
    (= operation tlci-host-callback-op-operand-expr-call?)
    (= operation tlci-host-callback-op-operand-expr-int?)
    (= operation tlci-host-callback-op-operand-expr-var?)
    (= operation tlci-host-callback-op-operand-expr-int-value)
    (= operation tlci-host-callback-op-local-expr-list-length)
    (= operation tlci-host-callback-op-operand-expr-string?)
    (= operation tlci-host-callback-op-local-string-length)
    (= operation tlci-host-callback-op-local-string-ref)))

;; Real host callback table for production dispatch: the invoke slot carries
;; the address of the compiler-owned dispatcher. The abort slot keeps the
;; validation sentinel until the native-abort slice wires a real handler; no
;; operation sequence emitted by the current producer can reach it.
(define (compiler-comptime-host-table) : TlciHostCallbackTable
  (TlciHostCallbackTable
    tlci-host-callback-table-magic
    tlci-host-abi-version
    tlci-host-callback-table-size
    0
    0
    0
    (tl-comptime-host-invoke-set
      (cast
        (unsafe
          (cast compiler-comptime-host-invoke : u64))
        : i64))
    8192))