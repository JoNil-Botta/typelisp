;; Exercise the embedded bytes through the production loader and registration
;; entry. The exact count is pinned by the current 42-module source manifest so
;; additions/removals require regenerating and reviewing the catalog together.
;; The native check dispatches the one source-compiled entry with a real
;; operand through the compiler-owned host table and asserts the committed
;; result matches the interpreted builders' AST shape. Refs #5212.
(import compiler_embedded_stdlib_tlci)
(import compiler_embedded_stdlib_tlci_payload as compressed_payload)
(import tlci_core)
(import tlci_loader)
(import compiler_ast_types)
(import compiler_ctfe)
(import compiler_intern as ci)
(import stdlib.arena)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)

;; The raw verifier image is immutable process-global storage. Equality needs
;; a shallow view of its bytes, not ownership of the global array.
(defmacro (embedded-verify-global-shared-view [place : Expr]) : Expr
  (cfg
    stage0-seed-bootstrap
    place
    `(unsafe
      (ptr-read (ptr-addr-of ,place)))))

;; Compare expansion with the builder's ordinary, directly mappable format-v2
;; artifact. This is intentionally a verifier-only second embedding; shipped
;; compilers carry only the compressed payload.
(include-bin
  embedded-verify-raw-image
  "../../target/embedded-stdlib-tlci/stdlib.tlci")

(define embedded-verify-cookie : i64
  0x5151)

(define (embedded-verify-payload-exact-and-bounded?) : bool
  (let
    [expanded : (__tl_dyn-array u8)
      (compiler_embedded_stdlib_tlci.compiler-embedded-stdlib-tlci-copy)]
    [raw-len : i64 (array-length embedded-verify-raw-image)]
    [compressed-len : i64
      (array-length compressed_payload.embedded-stdlib-tlci-bytes)]
    (begin
      (io.print-error
        (str_cat.str-cat
          "embedded stdlib tlci payload: raw="
          (string.int->string raw-len)
          " compressed="
          (string.int->string compressed-len)
          "\n"))
      (and
        (> raw-len 0)
        (> compressed-len 0)
        (<= (* compressed-len 100) (* raw-len 40))
        (tlci_core.tlci-bytes-eq?
          (embedded-verify-global-shared-view embedded-verify-raw-image)
          expanded)))))

;; The expansion carries the template's `Spanned` wrappers, the way the
;; interpreted quote leaves them, so the shape probe reads through them.
(define (embedded-verify-expr-get
  [pools : compiler_ast_types.AstNodePoolContext]
  [node : i64]) : compiler_ast_types.AstExpr
  (let
    [expr : compiler_ast_types.AstExpr
      (compiler_ast_types.ast-node-pool-context-expr-get pools node)]
    (match expr
      [(compiler_ast_types.AstExpr.Spanned inner _)
        (embedded-verify-expr-get pools inner)]
      [_ expr])))

;; The operand is the node a parsed call site would hand over, so it carries
;; its own span: substitution into the template's unquote position keeps that
;; origin and the argument stays the very node passed in.
(define (embedded-verify-operand-node
  [pools : compiler_ast_types.AstNodePoolContext]) : i64
  (compiler_ast_types.ast-expr-spanned-with-pools
    pools
    (compiler_ast_types.ast-node-pool-context-expr-push
      pools
      (compiler_ast_types.AstExpr.Var (ci.intern "xs")))
    (compiler_ast_types.ast-source-span 900 7 900 9)))

(define (embedded-verify-result-shape-ok?
  [pools : compiler_ast_types.AstNodePoolContext]
  [operand-node : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (embedded-verify-expr-get pools node)
        [(compiler_ast_types.AstExpr.BoxGet inner) (= inner operand-node)]
        [_ false])]
    [_ false]))

(define (embedded-verify-native-array-length-ok?) : bool
  (match (tlci_loader.tlci-loader-load-from-bytes-with-host
    (arena.tl_arena_current)
    (compiler_embedded_stdlib_tlci.compiler-embedded-stdlib-tlci-copy)
    (compiler_embedded_stdlib_tlci.compiler-comptime-host-table))
    [(tlci_loader.ResultTlciLoadedImage.Err _) false]
    [(tlci_loader.ResultTlciLoadedImage.Ok loaded)
      (let
        [pools : compiler_ast_types.AstNodePoolContext
          (compiler_ast_types.ast-node-pool-context-capture-active)]
        [operand-node : i64 (embedded-verify-operand-node pools)]
        [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
          (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
        (begin
          (set!
            (array-ref operands 0)
            (compiler_ctfe.CompilerCtfeValue.Expr
              operand-node
              (compiler_ast_types.AstType.Expr)))
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
            pools
            operands
            1
            32
            embedded-verify-cookie
            (compiler_ctfe.ctfe-reflect-info-list-empty))
          (let
            [ok : bool
              (match (tlci_loader.tlci-loader-dispatch-macro
                (& loaded)
                "stdlib.core_macros/__tl-box-place"
                embedded-verify-cookie
                (__tl_make-array i64 0)
                0)
                [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
                [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
                  (and
                    (= dispatch.status 0)
                    (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                    (embedded-verify-result-shape-ok? pools operand-node))])]
            (begin
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
              (match (tlci_loader.tlci-loader-release loaded)
                [(tlci_loader.ResultTlciLoaderUnit.Ok) ok]
                [(tlci_loader.ResultTlciLoaderUnit.Err _) false])))))]))

(define (embedded-verify-native-array-length-error-ok?
  [fuel : i64]
  [operand-count : i64]
  [expected-status : i64]) : bool
  (match (tlci_loader.tlci-loader-load-from-bytes-with-host
    (arena.tl_arena_current)
    (compiler_embedded_stdlib_tlci.compiler-embedded-stdlib-tlci-copy)
    (compiler_embedded_stdlib_tlci.compiler-comptime-host-table))
    [(tlci_loader.ResultTlciLoadedImage.Err _) false]
    [(tlci_loader.ResultTlciLoadedImage.Ok loaded)
      (let
        [pools : compiler_ast_types.AstNodePoolContext
          (compiler_ast_types.ast-node-pool-context-capture-active)]
        [operand-node : i64 (embedded-verify-operand-node pools)]
        [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
          (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
        (begin
          (set!
            (array-ref operands 0)
            (compiler_ctfe.CompilerCtfeValue.Expr
              operand-node
              (compiler_ast_types.AstType.Expr)))
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
            pools
            operands
            operand-count
            fuel
            embedded-verify-cookie
            (compiler_ctfe.ctfe-reflect-info-list-empty))
          (let
            [ok : bool
              (match (tlci_loader.tlci-loader-dispatch-macro
                (& loaded)
                "stdlib.core_macros/__tl-box-place"
                embedded-verify-cookie
                (__tl_make-array i64 0)
                0)
                [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
                [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
                  (and
                    (= dispatch.status expected-status)
                    (not
                      (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)))])]
            (begin
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
              (match (tlci_loader.tlci-loader-release loaded)
                [(tlci_loader.ResultTlciLoaderUnit.Ok) ok]
                [(tlci_loader.ResultTlciLoaderUnit.Err _) false])))))]))

(define (main) : i64
  (match (compiler_embedded_stdlib_tlci.compiler-embedded-stdlib-tlci-validate)
    [(compiler_embedded_stdlib_tlci.CompilerEmbeddedStdlibTlciValidation.Err
        message)
      (begin
        (io.print-error
          (str_cat.str-cat "embedded stdlib tlci validation failed: " message))
        1)]
    [(compiler_embedded_stdlib_tlci.CompilerEmbeddedStdlibTlciValidation.Ok
        count)
      (if (= count 116)
        (if (and
          (embedded-verify-payload-exact-and-bounded?)
          (embedded-verify-native-array-length-ok?)
          (embedded-verify-native-array-length-error-ok?
            0
            1
            tlci_core.tlci-host-callback-status-fuel-exhausted)
          (embedded-verify-native-array-length-error-ok?
            32
            0
            tlci_core.tlci-host-callback-status-bad-request))
          42
          (begin
            (io.print-error
              "embedded stdlib tlci payload/native verification failed")
            3))
        (begin
          (io.print-error
            (str_cat.str-cat
              "embedded stdlib tlci macro count mismatch: expected 116, got "
              (string.int->string count)))
          2))]))