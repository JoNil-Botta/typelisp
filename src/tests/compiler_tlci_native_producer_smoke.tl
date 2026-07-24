;; End-to-end host-image coverage for package-owned macro captures (#2754).
;; Native template shapes beyond the original splice-only subset (nested
;; calls, literals, splices, if/begin/binary/unary forms, plain symbols,
;; computed list-length ifs, and identity bodies) are covered here too
;; (#5596); a let-rooted body keeps the counted interpreted-fallback shell.
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

;; Var ids produced by host templates carry the interpreted quote's
;; template-source mark over the lexer's source-name id for the spelling.
(define (producer-test-name-id [name : String]) : i64
  (ci.intern-template-source-id (ci.intern name)))

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
              [(AstExpr.Var name)
                (= name (producer-test-name-id expected-callee))]
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

;; `(stdlib.json.JsonValue (stdlib.json.JsonBool ,value))` rebuilds as one
;; nested call over the operand.
(define (producer-test-nest-result-ok?
  [pools : AstNodePoolContext]
  [operand : i64]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.Call callee args)
          (and
            (match (ast-node-pool-context-expr-get pools callee)
              [(AstExpr.Var name)
                (= name (producer-test-name-id "stdlib.json.JsonValue"))]
              [_ false])
            (= (ast-expr-list-len (& args)) 1)
            (let
              [inner : i64 (ast-expr-list-get (& args) 0 -1)]
              (match (ast-node-pool-context-expr-get pools inner)
                [(AstExpr.Call inner-callee inner-args)
                  (and
                    (match (ast-node-pool-context-expr-get pools inner-callee)
                      [(AstExpr.Var name)
                        (= name (producer-test-name-id "stdlib.json.JsonBool"))]
                      [_ false])
                    (= (ast-expr-list-len (& inner-args)) 1)
                    (= (ast-expr-list-get (& inner-args) 0 -1) operand))]
                [_ false])))]
        [_ false])]
    [_ false]))

;; `(f "a\tb" 'x' -7 true)` rebuilds with the exact literal payload nodes.
(define (producer-test-lits-result-ok? [pools : AstNodePoolContext]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.Call callee args)
          (and
            (match (ast-node-pool-context-expr-get pools callee)
              [(AstExpr.Var name) (= name (producer-test-name-id "f"))]
              [_ false])
            (= (ast-expr-list-len (& args)) 4)
            (match (ast-node-pool-context-expr-get
              pools
              (ast-expr-list-get (& args) 0 -1))
              [(AstExpr.Literal (AstLiteral.String sid))
                (string.eq (intern-str sid) "a\tb")]
              [_ false])
            (match (ast-node-pool-context-expr-get
              pools
              (ast-expr-list-get (& args) 1 -1))
              [(AstExpr.Literal (AstLiteral.Char c)) (= c 'x')]
              [_ false])
            (match (ast-node-pool-context-expr-get
              pools
              (ast-expr-list-get (& args) 2 -1))
              [(AstExpr.Literal (AstLiteral.Int value _)) (= value -7)]
              [_ false])
            (match (ast-node-pool-context-expr-get
              pools
              (ast-expr-list-get (& args) 3 -1))
              [(AstExpr.Literal (AstLiteral.Bool flag)) flag]
              [_ false]))]
        [_ false])]
    [_ false]))

;; The `when` shape over a two-item body operand: `(if ,condition (begin ,@body)
;; unit)` rebuilds an if node whose then branch splices both body items.
(define (producer-test-whenlike-result-ok?
  [pools : AstNodePoolContext]
  [condition : i64]
  [first : i64]
  [second : i64]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.If actual-condition then-node else-node)
          (and
            (= actual-condition condition)
            (match (ast-node-pool-context-expr-get pools then-node)
              [(AstExpr.Begin items)
                (and
                  (= (ast-expr-list-len (& items)) 2)
                  (= (ast-expr-list-get (& items) 0 -1) first)
                  (= (ast-expr-list-get (& items) 1 -1) second))]
              [_ false])
            (match (ast-node-pool-context-expr-get pools else-node)
              [(AstExpr.Literal (AstLiteral.Unit)) true]
              [_ false]))]
        [_ false])]
    [_ false]))

(define (producer-test-var-result-ok?
  [pools : AstNodePoolContext]
  [expected-name : String]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.Var name) (= name (producer-test-name-id expected-name))]
        [_ false])]
    [_ false]))

(define (producer-test-operand-result-ok? [operand : i64]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _) (= node operand)]
    [_ false]))

(define (producer-test-dispatch-with?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]
  [operands : (Array CompilerCtfeValue)]
  [count : i64]
  [fallback-expected : bool]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    (begin
      (compiler-comptime-host-session-open!
        pools
        operands
        count
        64
        producer-test-cookie
        (ctfe-reflect-info-list-empty))
      (let
        [committed : i64
          (match (tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (array.make-array i64 0)
            0)
            [(ResultTlciMacroDispatch.Err _) -1]
            [(ResultTlciMacroDispatch.Ok dispatch)
              (if (= (struct-get dispatch status) tlci-host-callback-status-ok)
                (if (compiler-comptime-host-result-ready?)
                  1
                  0)
                -1)])]
        (begin
          (compiler-comptime-host-session-close!)
          (if fallback-expected
            (= committed 0)
            (= committed 1)))))))

(define (producer-test-expr-operand [name : String]) : CompilerCtfeValue
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    (CompilerCtfeValue.Expr
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern name)))
      (AstType.Expr))))

;; Dispatch one single-Expr-operand identity and inspect the committed
;; result; returns false when the dispatch errors or commits no result. The
;; `check` selector picks the result assertion: 0 = flat call template, 1 =
;; nested call template, 2 = literal argument pack, 3 = identity body, 4 =
;; quasiquoted plain symbol.
;; The `gen` fixture's computed module name: `(begin (module ,module-name)
;; ...)` with the let-computed string append resolved by the host.
(define (producer-test-gen-result-ok? [pools : AstNodePoolContext]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.Begin items)
          (and
            (= (ast-expr-list-len (& items)) 2)
            (let
              [first : i64 (ast-expr-list-get (& items) 0 -1)]
              (match (ast-node-pool-context-expr-get pools first)
                [(AstExpr.Call callee args)
                  (and
                    (match (ast-node-pool-context-expr-get pools callee)
                      [(AstExpr.Var name)
                        (= name (producer-test-name-id "module"))]
                      [_ false])
                    (= (ast-expr-list-len (& args)) 1)
                    (match (ast-node-pool-context-expr-get
                      pools
                      (ast-expr-list-get (& args) 0 -1))
                      [(AstExpr.Var name-id)
                        (string.eq (intern-str name-id) "test.gen.i64")]
                      [_ false]))]
                [_ false])))]
        [_ false])]
    [_ false]))

;; The `classify` fixture's match node: variant pattern with a wildcard and
;; a unit-variant pattern.
(define (producer-test-classify-result-ok? [pools : AstNodePoolContext]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.Match match-box)
          (match (box-get match-box)
            [(AstMatch.Match _ arms)
              (and
                (= (struct-get arms len) 2)
                (match (array-ref (struct-get arms slots) 0)
                  [(AstMatchArm.Arm pattern _)
                    (match pattern
                      [(AstPattern.Variant name-id args-box)
                        (and
                          (= name-id (ci.intern "Some"))
                          (= (struct-get (& (box-get args-box)) len) 1)
                          (match (ast-pattern-list-get
                            (& (box-get args-box))
                            0
                            (ast-pattern-fallback))
                            [(AstPattern.Wildcard) true]
                            [_ false]))]
                      [_ false])]
                  [_ false])
                (match (array-ref (struct-get arms slots) 1)
                  [(AstMatchArm.Arm pattern _)
                    (match pattern
                      [(AstPattern.Binding name-id)
                        (= name-id (producer-test-name-id "None"))]
                      [_ false])]
                  [_ false]))])]
        [_ false])]
    [_ false]))

;; The `twice` fixture's begin of two set! nodes for the same marked name.
(define (producer-test-twice-result-ok? [pools : AstNodePoolContext]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.Begin items)
          (and
            (= (ast-expr-list-len (& items)) 2)
            (match (ast-node-pool-context-expr-get
              pools
              (ast-expr-list-get (& items) 0 -1))
              [(AstExpr.Set name-id _)
                (= name-id (producer-test-name-id "flag"))]
              [_ false])
            (match (ast-node-pool-context-expr-get
              pools
              (ast-expr-list-get (& items) 1 -1))
              [(AstExpr.Set name-id _)
                (= name-id (producer-test-name-id "flag"))]
              [_ false]))]
        [_ false])]
    [_ false]))

(define (producer-test-dispatch-shape?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]
  [argument : String]
  [check : i64]
  [expected : String]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operand : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern argument)))]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    (begin
      (array-set! operands 0 (CompilerCtfeValue.Expr operand (AstType.Expr)))
      (compiler-comptime-host-session-open!
        pools
        operands
        1
        64
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
                (cond
                  [(= check 0)
                    (producer-test-template-result-ok? pools operand expected)]
                  [(= check 1) (producer-test-nest-result-ok? pools operand)]
                  [(= check 2) (producer-test-lits-result-ok? pools)]
                  [(= check 3) (producer-test-operand-result-ok? operand)]
                  [(= check 4) (producer-test-var-result-ok? pools expected)]
                  [(= check 5) (producer-test-classify-result-ok? pools)]
                  [else (producer-test-twice-result-ok? pools)]))])]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

;; Dispatch the module-generator fixture with a type and an expression
;; operand; the computed module name must resolve to "test.gen.i64".
(define (producer-test-dispatch-gen?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operand : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "value")))]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 2)]
    (begin
      (array-set! operands 0 (CompilerCtfeValue.Type (AstType.I64)))
      (array-set! operands 1 (CompilerCtfeValue.Expr operand (AstType.Expr)))
      (compiler-comptime-host-session-open!
        pools
        operands
        2
        64
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
              (if (= (struct-get dispatch status) tlci-host-callback-status-ok)
                (if (compiler-comptime-host-result-ready?)
                  (producer-test-gen-result-ok? pools)
                  false)
                false)])]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

;; `(ctor ,T 0 ,value)` with a type operand rebuilds the type as type syntax
;; in argument position, matching the interpreted unquote substitution.
(define (producer-test-tytpl-result-ok?
  [pools : AstNodePoolContext]
  [operand : i64]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.Call callee args)
          (and
            (match (ast-node-pool-context-expr-get pools callee)
              [(AstExpr.Var name)
                (=
                  name
                  (ci.intern-template-source-id
                    (ci.intern "stdlib.eq.struct-eq-fields")))]
              [_ false])
            (= (ast-expr-list-len (& args)) 3)
            (match (ast-node-pool-context-expr-get
              pools
              (ast-expr-list-get (& args) 0 -1))
              [(AstExpr.Var _) true]
              [_ false])
            (match (ast-node-pool-context-expr-get
              pools
              (ast-expr-list-get (& args) 1 -1))
              [(AstExpr.Literal (AstLiteral.Int value _)) (= value 0)]
              [_ false])
            (= (ast-expr-list-get (& args) 2 -1) operand))]
        [_ false])]
    [_ false]))

(define (producer-test-dispatch-tytpl?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operand : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "value")))]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 2)]
    (begin
      (array-set! operands 0 (CompilerCtfeValue.Type (AstType.I64)))
      (array-set! operands 1 (CompilerCtfeValue.Expr operand (AstType.Expr)))
      (compiler-comptime-host-session-open!
        pools
        operands
        2
        64
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
                (producer-test-tytpl-result-ok? pools operand))])]
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
        64
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

;; Dispatch the `when`-shaped macro with a condition operand and a body list
;; of `body-count` items; checks the full template for two items and the
;; missing-body variable for zero.
(define (producer-test-dispatch-whenlike?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]
  [body-count : i64]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [condition : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "flag")))]
    [first : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "alpha")))]
    [second : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "beta")))]
    [items : AstExprList
      (if (= body-count 2)
        (ast-expr-cons first (ast-expr-cons second (ast-expr-list-new)))
        (ast-expr-list-new))]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 2)]
    (begin
      (array-set! operands 0 (CompilerCtfeValue.Expr condition (AstType.Expr)))
      (array-set! operands 1 (CompilerCtfeValue.ExprList items))
      (compiler-comptime-host-session-open!
        pools
        operands
        2
        64
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
                (if (= body-count 2)
                  (producer-test-whenlike-result-ok?
                    pools
                    condition
                    first
                    second)
                  (producer-test-var-result-ok? pools "core-when-missing-body")))])]
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
            (producer-test-dispatch-shape?
              (& loaded)
              template-identity
              "value"
              0
              template-callee)
            (producer-test-dispatch-fold? (& loaded) fold-identity)
            (let
              [fallback-operands : (Array CompilerCtfeValue)
                (array.make-array CompilerCtfeValue 1)]
              (begin
                (array-set!
                  fallback-operands
                  0
                  (producer-test-expr-operand "value"))
                (producer-test-dispatch-with?
                  (& loaded)
                  fallback-identity
                  fallback-operands
                  1
                  true))))]
        (match (tlci-loader-release loaded)
          [(ResultTlciLoaderUnit.Ok) ok]
          [(ResultTlciLoaderUnit.Err _) false]))]))

;; In-package coverage: every supported shape dispatches natively and the
;; let-rooted body stays a counted shell. The report count must equal the
;; number of supported entries (7 of 8).
(define (producer-test-package-native-image-ok?) : bool
  (let
    [source : String
      "(module package.macros)\n(defmacro (wrap [value : Expr]) : Expr `(identity ,value))\n(defmacro (fold [items : Expr ...]) : bool (comptime.expr-list-fold-if items (comptime.expr-bool true) (comptime.expr-bool false) true))\n(defmacro (unsupported [value : Expr]) : Expr (match value [(comptime.Expr.Int n) value] [_ value]))\n(defmacro (nest [value : Expr]) : Expr `(stdlib.json.JsonValue (stdlib.json.JsonBool ,value)))\n(defmacro (ident [value : Expr]) : Expr value)\n(defmacro (whenlike [condition : bool] [body : unit ...]) : unit (if (= (comptime.expr-list-length body) 0) (comptime.expr-var \"core-when-missing-body\") `(if ,condition (begin ,@body) unit)))\n(defmacro (lits [value : Expr]) : Expr `(f \"a\\tb\" 'x' -7 true))\n(defmacro (qqvar [value : Expr]) : Expr `some.nil)\n(defmacro (tytpl [T : type] [value : Expr]) : Expr `(stdlib.eq.struct-eq-fields ,T 0 ,value))\n(defmacro (gen [T : type] [value : Expr]) : Module (let [module-name : Expr (expr-var (comptime.string-append \"test.gen.\" (type-key T)))] `(begin (module ,module-name) (define (id [x : ,T]) : ,T x))))\n(defmacro (classify [value : Expr]) : Expr `(match value [(Some _) true] [None false]))\n(defmacro (twice [value : Expr]) : Expr `(begin (set! flag 1) (set! flag 2)))\n"]
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
                    (match (tlci-loader-load-from-bytes-with-host
                      bytes
                      (compiler-comptime-host-table))
                      [(ResultTlciLoadedImage.Err _) false]
                      [(ResultTlciLoadedImage.Ok loaded)
                        (let
                          [ok : bool
                            (and
                              (= (array-length name-array) 12)
                              (= (struct-get captures len) 12)
                              (=
                                (array-ref
                                  embedded-stdlib-tlci-native-report-count
                                  0)
                                11)
                              (producer-test-dispatch-shape?
                                (& loaded)
                                "package.macros/wrap"
                                "value"
                                0
                                "identity")
                              (producer-test-dispatch-fold?
                                (& loaded)
                                "package.macros/fold")
                              (producer-test-dispatch-shape?
                                (& loaded)
                                "package.macros/nest"
                                "value"
                                1
                                "")
                              (producer-test-dispatch-shape?
                                (& loaded)
                                "package.macros/ident"
                                "value"
                                3
                                "")
                              (producer-test-dispatch-whenlike?
                                (& loaded)
                                "package.macros/whenlike"
                                2)
                              (producer-test-dispatch-whenlike?
                                (& loaded)
                                "package.macros/whenlike"
                                0)
                              (producer-test-dispatch-tytpl?
                                (& loaded)
                                "package.macros/tytpl")
                              (producer-test-dispatch-gen?
                                (& loaded)
                                "package.macros/gen")
                              (producer-test-dispatch-shape?
                                (& loaded)
                                "package.macros/classify"
                                "value"
                                5
                                "")
                              (producer-test-dispatch-shape?
                                (& loaded)
                                "package.macros/twice"
                                "value"
                                6
                                "")
                              (producer-test-dispatch-shape?
                                (& loaded)
                                "package.macros/lits"
                                "value"
                                2
                                "")
                              (producer-test-dispatch-shape?
                                (& loaded)
                                "package.macros/qqvar"
                                "value"
                                4
                                "some.nil")
                              (let
                                [fallback-operands : (Array CompilerCtfeValue)
                                  (array.make-array CompilerCtfeValue 1)]
                                (begin
                                  (array-set!
                                    fallback-operands
                                    0
                                    (producer-test-expr-operand "value"))
                                  (producer-test-dispatch-with?
                                    (& loaded)
                                    "package.macros/unsupported"
                                    fallback-operands
                                    1
                                    true))))]
                          (match (tlci-loader-release loaded)
                            [(ResultTlciLoaderUnit.Ok) ok]
                            [(ResultTlciLoaderUnit.Err _) false]))])])))])])))

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