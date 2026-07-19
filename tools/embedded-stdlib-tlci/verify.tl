;; Exercise the embedded bytes through the production loader and registration
;; entry. The exact count is pinned by the current 42-module source manifest so
;; additions/removals require regenerating and reviewing the catalog together.
;; The native check dispatches the one source-compiled entry with a real
;; operand through the compiler-owned host table and asserts the committed
;; result matches the interpreted builders' AST shape. Refs #5212.
(import "../../src/compiler_embedded_stdlib_tlci.tl")
(import "../../src/tlci_core.tl")
(import "../../src/tlci_loader.tl")
(import "../../src/compiler_ast_types.tl")
(import "../../src/compiler_ctfe.tl")
(import compiler_intern as ci)
(import stdlib.array)
(import stdlib.io)
(import stdlib.str_cat)
(import stdlib.string)

(define embedded-verify-cookie : i64
  0x5151)

(define (embedded-verify-result-shape-ok?
  [pools : AstNodePoolContext]
  [operand-node : i64]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.Call callee-id args)
          (and
            (match (ast-node-pool-context-expr-get pools callee-id)
              [(AstExpr.Var name-id)
                (= name-id (ci.intern "__tl_array-length"))]
              [_ false])
            (= (ast-expr-list-len (& args)) 1)
            (= (ast-expr-list-get (& args) 0 -1) operand-node))]
        [_ false])]
    [_ false]))

(define (embedded-verify-native-array-length-ok?) : bool
  (match (tlci-loader-load-from-bytes-with-host
    (compiler-embedded-stdlib-tlci-copy)
    (compiler-comptime-host-table))
    [(ResultTlciLoadedImage.Err _) false]
    [(ResultTlciLoadedImage.Ok loaded)
      (let
        [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
        [operand-node : i64
          (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "xs")))]
        [operands : (Array CompilerCtfeValue)
          (array.make-array CompilerCtfeValue 1)]
        (begin
          (array-set!
            operands
            0
            (CompilerCtfeValue.Expr operand-node (AstType.Expr)))
          (compiler-comptime-host-session-open!
            pools
            operands
            1
            32
            embedded-verify-cookie)
          (let
            [ok : bool
              (match (tlci-loader-dispatch-macro
                (& loaded)
                "stdlib.array/length"
                embedded-verify-cookie
                (array.make-array i64 0)
                0)
                [(ResultTlciMacroDispatch.Err _) false]
                [(ResultTlciMacroDispatch.Ok dispatch)
                  (and
                    (= (struct-get dispatch status) 0)
                    (compiler-comptime-host-result-ready?)
                    (embedded-verify-result-shape-ok? pools operand-node))])]
            (begin
              (compiler-comptime-host-session-close!)
              (match (tlci-loader-release loaded)
                [(ResultTlciLoaderUnit.Ok) ok]
                [(ResultTlciLoaderUnit.Err _) false])))))]))

(define (main) : i64
  (match (compiler-embedded-stdlib-tlci-validate)
    [(CompilerEmbeddedStdlibTlciValidation.Err message)
      (begin
        (io.print-error
          (str_cat.str-cat "embedded stdlib tlci validation failed: " message))
        1)]
    [(CompilerEmbeddedStdlibTlciValidation.Ok count)
      (if (= count 90)
        (if (embedded-verify-native-array-length-ok?)
          42
          (begin
            (io.print-error
              "embedded stdlib tlci native array/length dispatch failed")
            3))
        (begin
          (io.print-error
            (str_cat.str-cat
              "embedded stdlib tlci macro count mismatch: expected 90, got "
              (string.int->string count)))
          2))]))