;; Exercise the embedded bytes through the production loader and registration
;; entry. The exact count is pinned by the current 42-module source manifest so
;; additions/removals require regenerating and reviewing the catalog together.
;; The native check dispatches the one source-compiled entry with a real
;; operand through the compiler-owned host table and asserts the committed
;; result matches the interpreted builders' AST shape. Refs #5212.
(import compiler_embedded_stdlib_tlci)
(import tlci_core)
(import tlci_loader)
(import compiler_ast_types)
(import compiler_ctfe)
(import compiler_intern as ci)
(import stdlib.array)
(import stdlib.arena)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)

(define embedded-verify-cookie : i64
  0x5151)

(define (embedded-verify-result-shape-ok?
  [pools : compiler_ast_types.AstNodePoolContext]
  [operand-node : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (compiler_ast_types.ast-node-pool-context-expr-get pools node)
        [(compiler_ast_types.AstExpr.Call callee-id args)
          (and
            (match (compiler_ast_types.ast-node-pool-context-expr-get
              pools
              callee-id)
              [(compiler_ast_types.AstExpr.Var name-id)
                (=
                  name-id
                  (ci.intern-template-source-id (ci.intern "__tl_array-length")))]
              [_ false])
            (= (compiler_ast_types.ast-expr-list-len (& args)) 1)
            (=
              (compiler_ast_types.ast-expr-list-get (& args) 0 -1)
              operand-node))]
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
        [operand-node : i64
          (compiler_ast_types.ast-node-pool-context-expr-push
            pools
            (compiler_ast_types.AstExpr.Var (ci.intern "xs")))]
        [operands : (Array compiler_ctfe.CompilerCtfeValue)
          (array.make-array compiler_ctfe.CompilerCtfeValue 1)]
        (begin
          (array-set!
            operands
            0
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
                "stdlib.array/length"
                embedded-verify-cookie
                (array.make-array i64 0)
                0)
                [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
                [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
                  (and
                    (= (struct-get dispatch status) 0)
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
        [operand-node : i64
          (compiler_ast_types.ast-node-pool-context-expr-push
            pools
            (compiler_ast_types.AstExpr.Var (ci.intern "xs")))]
        [operands : (Array compiler_ctfe.CompilerCtfeValue)
          (array.make-array compiler_ctfe.CompilerCtfeValue 1)]
        (begin
          (array-set!
            operands
            0
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
                "stdlib.array/length"
                embedded-verify-cookie
                (array.make-array i64 0)
                0)
                [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
                [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
                  (and
                    (= (struct-get dispatch status) expected-status)
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
      (if (= count 102)
        (if (and
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
              "embedded stdlib tlci native array/length dispatch failed")
            3))
        (begin
          (io.print-error
            (str_cat.str-cat
              "embedded stdlib tlci macro count mismatch: expected 102, got "
              (string.int->string count)))
          2))]))