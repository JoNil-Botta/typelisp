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
  (Ok String (Array u8))
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

;; Expression node id of a stack value, or -1 when the value does not carry
;; one. Captured operands keep their caller-pool node id; the pool-context
;; bridging refinement is tracked with the real-body slice.
(define (compiler-comptime-host-value-node [value : CompilerCtfeValue]) : i64
  (match value
    [(CompilerCtfeValue.Expr node _) node]
    [(CompilerCtfeValue.CapturedExpr node _ _) node]
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

;; The compiler-owned callback invoke installed into the tlci host callback
;; table. TypeLisp's native convention passes scalar arguments in the SysV
;; integer registers, so this function is directly callable from the mapped
;; image on Linux; the Windows adapter is tracked with the dispatch slice.
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
          [node : i64
            (ast-node-pool-context-expr-push
              (array-ref compiler-comptime-host-pools 0)
              (AstExpr.Var (ci.intern name)))]
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
                    (ast-expr-call-with-pools
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
            (not (= status tlci-host-callback-status-ok))
            (set! compiler-comptime-host-session-status status))
          status)))))

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