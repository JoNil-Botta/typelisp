;; End-to-end host-image coverage for package-owned macro captures (#2754).
(import "../compiler_tlci_native_producer.tl")
(import "../compiler_embedded_stdlib_tlci.tl")
(import "../tlci_loader.tl")
(import "../compiler_ctfe.tl")
(import compiler_intern as ci)
(import stdlib.array)
(import stdlib.io)
(import stdlib.vector)
(import (vector.vector String) as producer_test_svec)

(define producer-test-cookie : i64
  0x2754)

(define (producer-test-collect-decl!
  [decl : AstDecl]
  [module : String]
  [names : (&mut names producer_test_svec.Vec)]
  [captures : (&mut captures TlciNativeMacroCaptures)]) : unit
  (match decl
    [(AstDecl.DefMacro _ name params _ body)
      (let
        [identity : String (embedded-stdlib-tlci-identity module name)]
        (begin
          (producer_test_svec.push names identity)
          (tlci-native-macro-captures-push!
            captures
            (TlciNativeMacroCapture identity params body))))]
    [(AstDecl.Unsafe inner)
      (producer-test-collect-decl! (box-get inner) module names captures)]
    [(AstDecl.ModuleBody nested body)
      (producer-test-collect-decls!
        (box-get body)
        (intern-str nested)
        names
        captures)]
    [_ unit]))

(define (producer-test-collect-decls!
  [decls : AstDeclList]
  [module : String]
  [names : (&mut names producer_test_svec.Vec)]
  [captures : (&mut captures TlciNativeMacroCaptures)]) : unit
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) unit]
    [(AstDeclListStep.Cons decl rest)
      (match decl
        [(AstDecl.Module next-module)
          (producer-test-collect-decls!
            rest
            (intern-str next-module)
            names
            captures)]
        [_
          (begin
            (producer-test-collect-decl! decl module names captures)
            (producer-test-collect-decls! rest module names captures))])]))

(define (producer-test-template-result-ok?
  [pools : AstNodePoolContext]
  [operand : i64]
  [expected-callee : String]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.Call callee args)
          (and
            (match (ast-node-pool-context-expr-get pools callee)
              [(AstExpr.Var name) (= name (ci.intern expected-callee))]
              [_ false])
            (= (ast-expr-list-len (& args)) 1)
            (= (ast-expr-list-get (& args) 0 -1) operand))]
        [_ false])]
    [_ false]))

(define (producer-test-fold-result-ok?
  [pools : AstNodePoolContext]
  [condition : i64]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.If actual-condition then-node else-node)
          (and
            (= actual-condition condition)
            (match (ast-node-pool-context-expr-get pools then-node)
              [(AstExpr.Literal (AstLiteral.Bool flag)) flag]
              [_ false])
            (match (ast-node-pool-context-expr-get pools else-node)
              [(AstExpr.Literal (AstLiteral.Bool flag)) (not flag)]
              [_ false]))]
        [_ false])]
    [_ false]))

(define (producer-test-dispatch-template?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]
  [expected-callee : String]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operand : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "value")))]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    (begin
      (array-set! operands 0 (CompilerCtfeValue.Expr operand (AstType.Expr)))
      (compiler-comptime-host-session-open!
        pools
        operands
        1
        32
        producer-test-cookie
        (ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (array.make-array i64 0)
            0)
            [(ResultTlciMacroDispatch.Err _) false]
            [(ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= (struct-get dispatch status) tlci-host-callback-status-ok)
                (compiler-comptime-host-result-ready?)
                (producer-test-template-result-ok?
                  pools
                  operand
                  expected-callee))])]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-dispatch-fold?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [condition : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "flag")))]
    [items : AstExprList (ast-expr-cons condition (ast-expr-list-new))]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    (begin
      (array-set! operands 0 (CompilerCtfeValue.ExprList items))
      (compiler-comptime-host-session-open!
        pools
        operands
        1
        32
        producer-test-cookie
        (ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (array.make-array i64 0)
            0)
            [(ResultTlciMacroDispatch.Err _) false]
            [(ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= (struct-get dispatch status) tlci-host-callback-status-ok)
                (compiler-comptime-host-result-ready?)
                (producer-test-fold-result-ok? pools condition))])]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-dispatch-fallback?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operand : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "value")))]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    (begin
      (array-set! operands 0 (CompilerCtfeValue.Expr operand (AstType.Expr)))
      (compiler-comptime-host-session-open!
        pools
        operands
        1
        32
        producer-test-cookie
        (ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (array.make-array i64 0)
            0)
            [(ResultTlciMacroDispatch.Err _) false]
            [(ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= (struct-get dispatch status) tlci-host-callback-status-ok)
                (not (compiler-comptime-host-result-ready?)))])]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-emitted-bytes-ok?
  [bytes : (Array u8)]
  [template-identity : String]
  [template-callee : String]
  [fold-identity : String]
  [fallback-identity : String]) : bool
  (match (tlci-loader-load-from-bytes-with-host
    bytes
    (compiler-comptime-host-table))
    [(ResultTlciLoadedImage.Err _) false]
    [(ResultTlciLoadedImage.Ok loaded)
      (let
        [ok : bool
          (and
            (producer-test-dispatch-template?
              (& loaded)
              template-identity
              template-callee)
            (producer-test-dispatch-fold? (& loaded) fold-identity)
            (producer-test-dispatch-fallback? (& loaded) fallback-identity))]
        (match (tlci-loader-release loaded)
          [(ResultTlciLoaderUnit.Ok) ok]
          [(ResultTlciLoaderUnit.Err _) false]))]))

(define (producer-test-package-native-image-ok?) : bool
  (let
    [source : String
      "(module package.macros)\n(defmacro (wrap [value : Expr]) : Expr `(identity ,value))\n(defmacro (fold [items : Expr ...]) : bool (comptime.expr-list-fold-if items (comptime.expr-bool true) (comptime.expr-bool false) true))\n(defmacro (unsupported [value : Expr]) : Expr value)\n"]
    [names : producer_test_svec.Vec (producer_test_svec.new)]
    [captures : TlciNativeMacroCaptures (tlci-native-macro-captures-new)]
    (match (parse-ast-source source)
      [(ResultAstProgram.Err _) false]
      [(ResultAstProgram.Ok program)
        (match program
          [(AstProgram.Program decls)
            (begin
              (producer-test-collect-decls!
                (box-get decls)
                ""
                (&mut names)
                (&mut captures))
              (let
                [name-array : (Array String)
                  (producer_test_svec.to-array (& names))]
                (match (embedded-native-emit-package
                  (tlci-metadata-emit
                    (tlci-make-metadata "v1" "package" "0.1.0"))
                  "producer-test"
                  (cfg windows true false)
                  (tlci-empty-bytes)
                  name-array
                  (& captures))
                  [(ResultProducerBytes.Err _) false]
                  [(ResultProducerBytes.Ok bytes)
                    (and
                      (= (array-length name-array) 3)
                      (= (struct-get captures len) 3)
                      (=
                        (array-ref embedded-stdlib-tlci-native-report-count 0)
                        2)
                      (producer-test-emitted-bytes-ok?
                        bytes
                        "package.macros/wrap"
                        "identity"
                        "package.macros/fold"
                        "package.macros/unsupported"))])))])])))

(test
  package-tlci-native-producer
  (unless
    (producer-test-package-native-image-ok?)
    (io.panic "package tlci native producer test failed")))

(define (main) : i64
  (if (= (io.arg-count) 6)
    (if (producer-test-emitted-bytes-ok?
      (tlci-string->bytes (io.read-file (io.arg 1)))
      (io.arg 2)
      (io.arg 3)
      (io.arg 4)
      (io.arg 5))
      0
      (begin
        (io.print-error "package tlci native verification failed\n")
        1))
    (begin
      (io.print-error
        "usage: verifier <image.tlci> <template-identity> <callee> <fold-identity> <fallback-identity>\n")
      2)))