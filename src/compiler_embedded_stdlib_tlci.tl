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
            (compiler-embedded-stdlib-tlci-host-table))
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
(define compiler-comptime-host-pools : (Array AstNodePoolContext)
  (array.make-array AstNodePoolContext 1))
(define compiler-comptime-host-operands : (Array CompilerCtfeValue)
  (array.make-array CompilerCtfeValue 8))
(define compiler-comptime-host-operand-count : i64
  0)
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
(extern tl-comptime-host-invoke-entry-ptr (:symbol "tl_comptime_host_invoke_entry_ptr") : i64)

(define (compiler-comptime-host-session-open!
  [pools : AstNodePoolContext]
  [operands : (Array CompilerCtfeValue)]
  [operand-count : i64]
  [fuel : i64]
  [cookie : i64]) : unit
  (begin
    (array-set! compiler-comptime-host-pools 0 pools)
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
    (set! compiler-comptime-host-stack-len 0)
    (set! compiler-comptime-host-result-ready false)
    (array-set! compiler-comptime-host-diagnostic 0 "")
    (tl-comptime-host-invoke-set
      (cast
        (unsafe
          (cast compiler-comptime-host-invoke : u64))
        : i64))
    (set! compiler-comptime-host-session-cookie cookie)))

(define (compiler-comptime-host-session-close!) : unit
  (begin
    (set! compiler-comptime-host-session-cookie 0)
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

;; The compiler-owned callback invoke installed into the tlci host callback
;; table. TypeLisp's native convention passes scalar arguments in the SysV
;; integer registers, so this function is directly callable from the mapped
;; image on Linux; the Windows adapter is tracked with the dispatch slice.
(define (compiler-comptime-host-invoke
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
    tl-comptime-host-invoke-entry-ptr
    8192))