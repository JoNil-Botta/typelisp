;; End-to-end host-image coverage for package-owned macro captures (#2754).
;; Native template shapes beyond the original splice-only subset (nested
;; calls, literals, splices, if/begin/binary/unary forms, plain symbols,
;; computed list-length ifs, and identity bodies) are covered here too
;; (#5596), along with the `str-cat` shape -- an operand-count integer match
;; with indexed operand access and a count-binding default arm (#5617).
;; A body outside the supported subset keeps the counted interpreted-fallback
;; shell.
(import stdlib.str_cat_runtime as str_cat)
(import compiler_tlci_native_producer)

;; compiler_embedded_stdlib_tlci owns the loader import. Importing the same
;; graph again here gives Windows absolute-path runs two qualified page
;; surfaces and makes the second loader lose pages.ResultTlciPageUnit.
(import compiler_embedded_stdlib_tlci)
(import compiler_ctfe)
(import compiler_ast_types as ast)
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_owned_view as owned_view)
(import compiler_parse_core as parse_core)
(import tlci_core as tlci)
(import tlci_loader)
(import stdlib.arena)
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as producer_test_svec)

(define producer-test-cookie : i64
  0x2754)

(define (producer-test-macro-global-id [source-name-id : i64]) : i64
  (let
    [session : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names
        (ci.intern-source-name-session-capture-active-handle))]
    (cis.intern-macro-global-identity-raw
      (cis.intern-structural-session-macro-global-identity
        session
        cis.InternMacroGlobalRole.Legacy
        (ci.intern "producer.test.macro")
        source-name-id))))

;; Var ids produced by host templates carry the interpreted quote's
;; template-source mark over the lexer's source-name id for the spelling.
(define (producer-test-name-id [name : String]) : i64
  (ci.intern-template-source-id (ci.intern name)))

;; A native expansion rebuilds the parser's `Spanned` wrapper around every
;; template node, exactly as the interpreted quote does, so every shape probe
;; below reads a node through its wrappers. `producer-test-node-span` is the
;; complementary reader: the wrapper the probes see through is itself asserted
;; where a template span is the point of the case. Refs #5212.
(define (producer-test-expr-get
  [pools : (& pools ast.AstNodePoolContext)]
  [node : i64]) : ast.AstExpr
  (let
    [expr : ast.AstExpr (ast.ast-node-pool-context-expr-get pools node)]
    (match (owned_view.compiler-owned-shared-view expr)
      [(ast.AstExpr.Spanned inner _) (producer-test-expr-get pools inner)]
      [_ expr])))

;; The outermost source span on `node`, or the four-zero span when it carries
;; none. A template node always carries one; a synthesized node never does.
(define (producer-test-node-span
  [pools : (& pools ast.AstNodePoolContext)]
  [node : i64]) : ast.AstSourceSpan
  (match (ast.ast-node-pool-context-expr-get pools node)
    [(ast.AstExpr.Spanned _ span) span]
    [_ (ast.ast-source-span 0 0 0 0)]))

(define (producer-test-node-span-at?
  [pools : (& pools ast.AstNodePoolContext)]
  [node : i64]
  [line : i64]
  [col : i64]) : bool
  (let
    [span : ast.AstSourceSpan (producer-test-node-span pools node)]
    (and
      (= (ast.ast-source-span-start-line span) line)
      (= (ast.ast-source-span-start-col span) col)
      ;; Keep the legacy wrapper as a live oracle while #6329 migrates readers.
      ;; This fixture covers template-produced nodes, unquoted caller operands,
      ;; repeated splices, and both interpreted/package-native expansion routes.
      (match (ast.ast-node-pool-context-expr-view-span pools node)
        [(ast.AstMaybeSourceSpan.No) false]
        [(ast.AstMaybeSourceSpan.Some sidecar-span)
          (and
            (ast.ast-source-span-eq? span sidecar-span)
            (match (ast.ast-node-pool-context-expr-span-oracle pools node)
              [(ast.AstExprSpanOracleResult.CanonicalMatch) true]
              [(ast.AstExprSpanOracleResult.ReSpanMatch) true]
              [_ false]))]))))

;; An operand arrives from a parsed call site, so it carries its own span the
;; way a real macro argument does. That origin survives substitution: a
;; template's unquote position never covers it with the template's own span.
(define (producer-test-spanned-node
  [pools : (& pools ast.AstNodePoolContext)]
  [node : i64]
  [line : i64]
  [col : i64]) : i64
  (ast.ast-expr-spanned-with-pools
    pools
    node
    (ast.ast-source-span line col line (+ col 1))))

;; Push one operand node the way the parser would hand it over: spanned.
(define (producer-test-push-spanned
  [pools : (& pools ast.AstNodePoolContext)]
  [expr : ast.AstExpr]) : i64
  (producer-test-spanned-node
    pools
    (ast.ast-node-pool-context-expr-push
      (owned_view.compiler-owned-reference-shared-view pools)
      expr)
    900
    7))

(define (producer-test-collect-decl!
  [decl : ast.AstDecl]
  [module : String]
  [names : (&mut names producer_test_svec.Vec)]
  [captures
    : (&mut captures compiler_tlci_native_producer.TlciNativeMacroCaptures)]) : unit
  (match (owned_view.compiler-owned-shared-view decl)
    [(ast.AstDecl.DefMacro _ name params ret body)
      (let
        [identity : String
          (compiler_tlci_native_producer.embedded-stdlib-tlci-identity
            module
            name)]
        (begin
          (producer_test_svec.push-ref!
            names
            (owned_view.compiler-owned-shared-view identity))
          (compiler_tlci_native_producer.tlci-native-macro-captures-push!
            captures
            (compiler_tlci_native_producer.TlciNativeMacroCapture
              identity
              params
              (compiler_tlci_native_producer.embedded-native-macro-result-kind
                ret)
              body))))]
    [(ast.AstDecl.Unsafe inner)
      (producer-test-collect-decl!
        (owned_view.compiler-owned-box-shared-view inner)
        module
        names
        captures)]
    [(ast.AstDecl.ModuleBody nested body)
      (producer-test-collect-decls!
        (owned_view.compiler-owned-box-shared-view body)
        (ci.intern-str nested)
        names
        captures)]
    [_ unit]))

(define (producer-test-collect-decls!
  [decls : ast.AstDeclList]
  [module : String]
  [names : (&mut names producer_test_svec.Vec)]
  [captures
    : (&mut captures compiler_tlci_native_producer.TlciNativeMacroCaptures)]) : unit
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) unit]
    [(ast.AstDeclListStep.Cons decl rest)
      (match (owned_view.compiler-owned-shared-view decl)
        [(ast.AstDecl.Module next-module)
          (producer-test-collect-decls!
            rest
            (ci.intern-str next-module)
            names
            captures)]
        [_
          (begin
            (producer-test-collect-decl!
              decl
              (owned_view.compiler-owned-shared-view module)
              names
              captures)
            (producer-test-collect-decls! rest module names captures))])]))

;; Keep the focused Decls producer separate from the large expression-shape
;; corpus below so its result policy remains explicit in this cross-platform
;; image test.
(define (producer-test-add-decls-capture!
  [names : (&mut names producer_test_svec.Vec)]
  [captures
    : (&mut captures compiler_tlci_native_producer.TlciNativeMacroCaptures)]) : unit
  (match (parse_core.parse-ast-source
    "(module package.macros)
(defmacro (decls) : Decls
  `(begin
    (define generated-value : i64 42)
    (define (generated-id [x : i64]) : i64 x)))
")
    [(parse_core.ResultAstProgram.Err _) unit]
    [(parse_core.ResultAstProgram.Ok program)
      (match program
        [(ast.AstProgram.Program decls)
          (producer-test-collect-decls!
            (owned_view.compiler-owned-box-shared-view decls)
            ""
            names
            captures)])]))

(define (producer-test-template-result-ok?
  [pools : ast.AstNodePoolContext]
  [operand : i64]
  [expected-callee : String]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.Call callee args)
          (and
            (match (producer-test-expr-get (& pools) callee)
              [(ast.AstExpr.Var name)
                (= name (producer-test-name-id expected-callee))]
              [_ false])
            (= (ast.ast-expr-list-len (& args)) 1)
            (= (ast.ast-expr-list-get (& args) 0 -1) operand))]
        [_ false])]
    [_ false]))

(define (producer-test-fold-result-ok?
  [pools : ast.AstNodePoolContext]
  [condition : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.If actual-condition then-node else-node)
          (and
            (= actual-condition condition)
            (match (producer-test-expr-get (& pools) then-node)
              [(ast.AstExpr.Literal (ast.AstLiteral.Bool flag)) flag]
              [_ false])
            (match (producer-test-expr-get (& pools) else-node)
              [(ast.AstExpr.Literal (ast.AstLiteral.Bool flag)) (not flag)]
              [_ false]))]
        [_ false])]
    [_ false]))

;; `(stdlib.json.JsonValue (stdlib.json.JsonBool ,value))` rebuilds as one
;; nested call over the operand.
(define (producer-test-nest-result-ok?
  [pools : ast.AstNodePoolContext]
  [operand : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.Call callee args)
          (and
            (match (producer-test-expr-get (& pools) callee)
              [(ast.AstExpr.Var name)
                (= name (producer-test-name-id "stdlib.json.JsonValue"))]
              [_ false])
            (= (ast.ast-expr-list-len (& args)) 1)
            (let
              [inner : i64 (ast.ast-expr-list-get (& args) 0 -1)]
              (match (producer-test-expr-get (& pools) inner)
                [(ast.AstExpr.Call inner-callee inner-args)
                  (and
                    (match (producer-test-expr-get (& pools) inner-callee)
                      [(ast.AstExpr.Var name)
                        (= name (producer-test-name-id "stdlib.json.JsonBool"))]
                      [_ false])
                    (= (ast.ast-expr-list-len (& inner-args)) 1)
                    (= (ast.ast-expr-list-get (& inner-args) 0 -1) operand))]
                [_ false])))]
        [_ false])]
    [_ false]))

;; `(f "a\tb" 'x' -7 true)` rebuilds with the exact literal payload nodes.
(define (producer-test-lits-result-ok? [pools : ast.AstNodePoolContext]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.Call callee args)
          (and
            (match (producer-test-expr-get (& pools) callee)
              [(ast.AstExpr.Var name) (= name (producer-test-name-id "f"))]
              [_ false])
            (= (ast.ast-expr-list-len (& args)) 4)
            (match (producer-test-expr-get
              (& pools)
              (ast.ast-expr-list-get (& args) 0 -1))
              [(ast.AstExpr.Literal (ast.AstLiteral.String sid))
                (string.eq (ci.intern-str sid) "a\tb")]
              [_ false])
            (match (producer-test-expr-get
              (& pools)
              (ast.ast-expr-list-get (& args) 1 -1))
              [(ast.AstExpr.Literal (ast.AstLiteral.Char c)) (= c 'x')]
              [_ false])
            (match (producer-test-expr-get
              (& pools)
              (ast.ast-expr-list-get (& args) 2 -1))
              [(ast.AstExpr.Literal (ast.AstLiteral.Int value _)) (= value -7)]
              [_ false])
            (match (producer-test-expr-get
              (& pools)
              (ast.ast-expr-list-get (& args) 3 -1))
              [(ast.AstExpr.Literal (ast.AstLiteral.Bool flag)) flag]
              [_ false]))]
        [_ false])]
    [_ false]))

;; The `when` shape over a two-item body operand: `(if ,condition (begin ,@body)
;; unit)` rebuilds an if node whose then branch splices both body items.
(define (producer-test-whenlike-result-ok?
  [pools : ast.AstNodePoolContext]
  [condition : i64]
  [first : i64]
  [second : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.If actual-condition then-node else-node)
          (and
            (= actual-condition condition)
            (match (producer-test-expr-get (& pools) then-node)
              [(ast.AstExpr.Begin items)
                (and
                  (= (ast.ast-expr-list-len (& items)) 2)
                  (= (ast.ast-expr-list-get (& items) 0 -1) first)
                  (= (ast.ast-expr-list-get (& items) 1 -1) second))]
              [_ false])
            (match (producer-test-expr-get (& pools) else-node)
              [(ast.AstExpr.Literal (ast.AstLiteral.Unit)) true]
              [_ false]))]
        [_ false])]
    [_ false]))

(define (producer-test-var-result-ok?
  [pools : ast.AstNodePoolContext]
  [expected-name : String]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.Var name) (= name (producer-test-name-id expected-name))]
        [_ false])]
    [_ false]))

(define (producer-test-operand-result-ok? [operand : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _) (= node operand)]
    [_ false]))

(define (producer-test-dispatch-with?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)]
  [count : i64]
  [fallback-expected : bool]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    (begin
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        count
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [committed : i64
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) -1]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (if (= dispatch.status tlci.tlci-host-callback-status-ok)
                (if (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                  1
                  0)
                -1)])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          (if fallback-expected
            (= committed 0)
            (= committed 1)))))))

(define (producer-test-shell-cache?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [operand : compiler_ctfe.CompilerCtfeValue]) : bool
  (match (tlci_loader.tlci-loader-resolve-macro-entry
    loaded
    (owned_view.compiler-owned-shared-view identity))
    [(tlci_loader.TlciMacroEntryLookup.Resolved resolved)
      (let
        [pools : ast.AstNodePoolContext
          (ast.ast-node-pool-context-capture-active)]
        [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
          (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
        (begin
          (set! (array-ref operands 0) operand)
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
            (owned_view.compiler-owned-shared-view pools)
            (owned_view.compiler-owned-shared-view operands)
            1
            64
            producer-test-cookie
            (compiler_ctfe.ctfe-reflect-info-list-empty))
          (let
            [first-was-shell : bool
              (match (tlci_loader.tlci-loader-dispatch-resolved-macro
                loaded
                resolved
                producer-test-cookie
                (__tl_make-array i64 0)
                0)
                [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
                [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
                  (and
                    (= dispatch.status tlci.tlci-host-callback-status-ok)
                    (not
                      (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)))])]
            (begin
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
              (and
                first-was-shell
                (match (tlci_loader.tlci-loader-mark-macro-entry-shell!
                  loaded
                  resolved)
                  [(tlci_loader.ResultTlciLoaderUnit.Err _) false]
                  [(tlci_loader.ResultTlciLoaderUnit.Ok)
                    (and
                      (match (tlci_loader.tlci-loader-resolve-macro-entry
                        loaded
                        (owned_view.compiler-owned-shared-view identity))
                        [(tlci_loader.TlciMacroEntryLookup.Shell _) true]
                        [_ false])
                      ;; Known-shell dispatch stops at indexed state and needs
                      ;; no second compiler host session.
                      (match (tlci_loader.tlci-loader-dispatch-macro
                        loaded
                        identity
                        producer-test-cookie
                        (__tl_make-array i64 0)
                        0)
                        [(tlci_loader.ResultTlciMacroDispatch.Err message)
                          (string.eq
                            message
                            "tlci loader: macro entry is a known shell")]
                        [(tlci_loader.ResultTlciMacroDispatch.Ok _) false]))]))))))]
    [_ false]))

(define (producer-test-expr-operand [name : String]) : compiler_ctfe.CompilerCtfeValue
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    (compiler_ctfe.CompilerCtfeValue.Expr
      (producer-test-push-spanned (& pools) (ast.AstExpr.Var (ci.intern name)))
      (ast.AstType.Expr))))

;; The named local Expr probes return boolean data for live Expr slots and the
;; shared negative malformed-request sentinel for an unbound slot. Refs #5656.
(define (producer-test-local-expr-probes-ok?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [var-node : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "value")))]
    [string-node : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Literal (ast.AstLiteral.String (ci.intern "literal"))))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 2)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr var-node (ast.AstType.Expr)))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.Expr string-node (ast.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        2
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (and
            (=
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                producer-test-cookie
                0
                0
                0)
              tlci.tlci-host-callback-status-ok)
            (=
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-set
                producer-test-cookie
                0
                0
                0)
              tlci.tlci-host-callback-status-ok)
            (=
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
                producer-test-cookie
                1
                0
                0)
              tlci.tlci-host-callback-status-ok)
            (=
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-set
                producer-test-cookie
                1
                0
                0)
              tlci.tlci-host-callback-status-ok)
            (=
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-expr-var?
                producer-test-cookie
                0
                0
                0)
              1)
            (=
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-expr-string?
                producer-test-cookie
                0
                0
                0)
              0)
            (=
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-expr-var?
                producer-test-cookie
                1
                0
                0)
              0)
            (=
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-expr-string?
                producer-test-cookie
                1
                0
                0)
              1)
            (<
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-expr-var?
                producer-test-cookie
                2
                0
                0)
              0)
            (<
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-local-expr-string?
                producer-test-cookie
                2
                0
                0)
              0))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(test
  local-expr-shape-probes
  (unless
    (producer-test-local-expr-probes-ok?)
    (io.panic "local Expr shape probes failed")))

;; Dispatch one single-Expr-operand identity and inspect the committed
;; result; returns false when the dispatch errors or commits no result. The
;; `check` selector picks the result assertion: 0 = flat call template, 1 =
;; nested call template, 2 = literal argument pack, 3 = identity body, 4 =
;; quasiquoted plain symbol, 5 = match template, 6 = repeated set!, 7 =
;; StructSet/Box/BoxGet/Return AST nodes.
;; The `gen` fixture's computed module name: `(begin (module ,module-name)
;; ...)` with the let-computed string append resolved by the host.
(define (producer-test-gen-result-ok? [pools : ast.AstNodePoolContext]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.Begin items)
          (and
            (= (ast.ast-expr-list-len (& items)) 2)
            (let
              [first : i64 (ast.ast-expr-list-get (& items) 0 -1)]
              (match (producer-test-expr-get (& pools) first)
                [(ast.AstExpr.Call callee args)
                  (and
                    (match (producer-test-expr-get (& pools) callee)
                      [(ast.AstExpr.Var name)
                        (= name (producer-test-name-id "module"))]
                      [_ false])
                    (= (ast.ast-expr-list-len (& args)) 1)
                    (match (producer-test-expr-get
                      (& pools)
                      (ast.ast-expr-list-get (& args) 0 -1))
                      [(ast.AstExpr.Var name-id)
                        (string.eq (ci.intern-str name-id) "test.gen.i64")]
                      [_ false]))]
                [_ false])))]
        [_ false])]
    [_ false]))

;; A Decls body crosses the same opaque result slot as Module and expression
;; bodies. The host owns the resulting begin/define graph; no image pointer is
;; exposed to the declaration parser.
(define (producer-test-decls-result-ok? [pools : ast.AstNodePoolContext]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.Begin items)
          (and
            (= (ast.ast-expr-list-len (& items)) 2)
            (match (producer-test-expr-get
              (& pools)
              (ast.ast-expr-list-get (& items) 0 -1))
              [(ast.AstExpr.Call callee _)
                (match (producer-test-expr-get (& pools) callee)
                  [(ast.AstExpr.Var name)
                    (= name (producer-test-name-id "define"))]
                  [_ false])]
              [_ false])
            (match (producer-test-expr-get
              (& pools)
              (ast.ast-expr-list-get (& items) 1 -1))
              [(ast.AstExpr.Call callee _)
                (match (producer-test-expr-get (& pools) callee)
                  [(ast.AstExpr.Var name)
                    (= name (producer-test-name-id "define"))]
                  [_ false])]
              [_ false]))]
        [_ false])]
    [_ false]))

;; The `classify` fixture's match node: variant pattern with a wildcard and
;; a unit-variant pattern.
(define (producer-test-classify-result-ok? [pools : ast.AstNodePoolContext]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.Match match-box)
          (match (owned_view.compiler-owned-box-shared-view match-box)
            [(ast.AstMatch.Match _ arms)
              (and
                (= arms.len 2)
                (match (array-ref arms.slots 0)
                  [(ast.AstMatchArm.Arm pattern _)
                    (match pattern
                      [(ast.AstPattern.Variant name-id args-box)
                        (and
                          (= name-id (ci.intern "Some"))
                          (=
                            (__tl-project-field
                              (& (__tl-box-place args-box))
                              len)
                            1)
                          (match (ast.ast-pattern-list-get
                            (& (__tl-box-place args-box))
                            0
                            (ast.ast-pattern-fallback))
                            [(ast.AstPattern.Wildcard) true]
                            [_ false]))]
                      [_ false])]
                  [_ false])
                (match (array-ref arms.slots 1)
                  [(ast.AstMatchArm.Arm pattern _)
                    (match pattern
                      [(ast.AstPattern.Binding name-id)
                        (= name-id (producer-test-name-id "None"))]
                      [_ false])]
                  [_ false]))])]
        [_ false])]
    [_ false]))

;; The `twice` fixture's begin of two set! nodes for the same marked name.
(define (producer-test-twice-result-ok? [pools : ast.AstNodePoolContext]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.Begin items)
          (and
            (= (ast.ast-expr-list-len (& items)) 2)
            (match (producer-test-expr-get
              (& pools)
              (ast.ast-expr-list-get (& items) 0 -1))
              [(ast.AstExpr.Set name-id _)
                (= name-id (producer-test-name-id "flag"))]
              [_ false])
            (match (producer-test-expr-get
              (& pools)
              (ast.ast-expr-list-get (& items) 1 -1))
              [(ast.AstExpr.Set name-id _)
                (= name-id (producer-test-name-id "flag"))]
              [_ false]))]
        [_ false])]
    [_ false]))

;; The `catlike` fixture (the `str-cat` shape): an operand-count match whose
;; integer arms index operands with `expr-list-nth` and whose binder arm
;; splices the whole operand list and rebuilds the count as a literal.
;; Refs #5617.
(define (producer-test-catlike-result-ok?
  [pools : ast.AstNodePoolContext]
  [count : i64]
  [first : i64]
  [second : i64]
  [third : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (cond
        [(= count 0)
          (match (producer-test-expr-get (& pools) node)
            [(ast.AstExpr.Literal (ast.AstLiteral.String sid))
              (string.eq (ci.intern-str sid) "")]
            [_ false])]
        [(= count 1) (= node first)]
        [(= count 2)
          (match (producer-test-expr-get (& pools) node)
            [(ast.AstExpr.Call callee args)
              (and
                (match (producer-test-expr-get (& pools) callee)
                  [(ast.AstExpr.Var name)
                    (= name (producer-test-name-id "concat2"))]
                  [_ false])
                (= (ast.ast-expr-list-len (& args)) 2)
                (= (ast.ast-expr-list-get (& args) 0 -1) first)
                (= (ast.ast-expr-list-get (& args) 1 -1) second))]
            [_ false])]
        [else (producer-test-catlike-packed-ok? pools node first second third)])]
    [_ false]))

;; `(concat-all (pack (__args a b c) 3))` for the three-operand binder arm.
(define (producer-test-catlike-packed-ok?
  [pools : ast.AstNodePoolContext]
  [node : i64]
  [first : i64]
  [second : i64]
  [third : i64]) : bool
  (match (producer-test-expr-get (& pools) node)
    [(ast.AstExpr.Call callee args)
      (and
        (match (producer-test-expr-get (& pools) callee)
          [(ast.AstExpr.Var name) (= name (producer-test-name-id "concat-all"))]
          [_ false])
        (= (ast.ast-expr-list-len (& args)) 1)
        (match (producer-test-expr-get
          (& pools)
          (ast.ast-expr-list-get (& args) 0 -1))
          [(ast.AstExpr.Call pack-callee pack-args)
            (and
              (match (producer-test-expr-get (& pools) pack-callee)
                [(ast.AstExpr.Var name) (= name (producer-test-name-id "pack"))]
                [_ false])
              (= (ast.ast-expr-list-len (& pack-args)) 2)
              (match (producer-test-expr-get
                (& pools)
                (ast.ast-expr-list-get (& pack-args) 0 -1))
                [(ast.AstExpr.Call carrier-callee carrier-args)
                  (and
                    (match (producer-test-expr-get (& pools) carrier-callee)
                      [(ast.AstExpr.Var name)
                        (= name (producer-test-name-id "__args"))]
                      [_ false])
                    (= (ast.ast-expr-list-len (& carrier-args)) 3)
                    (= (ast.ast-expr-list-get (& carrier-args) 0 -1) first)
                    (= (ast.ast-expr-list-get (& carrier-args) 1 -1) second)
                    (= (ast.ast-expr-list-get (& carrier-args) 2 -1) third))]
                [_ false])
              (match (producer-test-expr-get
                (& pools)
                (ast.ast-expr-list-get (& pack-args) 1 -1))
                [(ast.AstExpr.Literal (ast.AstLiteral.Int value _)) (= value 3)]
                [_ false]))]
          [_ false]))]
    [_ false]))

;; Dispatch the `str-cat`-shaped fixture with `count` String operands.
(define (producer-test-dispatch-catlike?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [count : i64]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [first : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "alpha")))]
    [second : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "beta")))]
    [third : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "gamma")))]
    [items : ast.AstExprList (ast.ast-expr-list-new)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (when (>= count 1) (ast.ast-expr-list-push (&mut items) first))
      (when (>= count 2) (ast.ast-expr-list-push (&mut items) second))
      (when (>= count 3) (ast.ast-expr-list-push (&mut items) third))
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.ExprList
          (owned_view.compiler-owned-shared-view items)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (producer-test-catlike-result-ok?
                  pools
                  count
                  first
                  second
                  third))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; `str-cat-scoped` must preserve every operand node while selecting the
;; borrowed fixed-arity helper only when every expression is a literal or
;; variable. Refs #5656.
(define (producer-test-scoped-cat-result-ok?
  [pools : ast.AstNodePoolContext]
  [nodes : (__tl_dyn-array i64)]
  [count : i64]
  [borrowed : bool]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.Call callee args)
          (let
            [expected-base : String
              (cond
                [(<= count 3) "stdlib.string.concat3"]
                [(= count 4) "stdlib.string.concat4"]
                [else "stdlib.string.concat5"])]
            [expected : String
              (if borrowed
                (str_cat.str-cat expected-base "-borrowed")
                expected-base)]
            [expected-count : i64
              (if (= count 2)
                3
                count)]
            [index : i64 0]
            [ok : bool
              (and
                (match (producer-test-expr-get (& pools) callee)
                  [(ast.AstExpr.Var name)
                    (= name (producer-test-name-id expected))]
                  [_ false])
                (= (ast.ast-expr-list-len (& args)) expected-count))]
            (begin
              (while (and ok (< index count))
                (begin
                  (when
                    (not
                      (=
                        (ast.ast-expr-list-get (& args) index -1)
                        (array-ref nodes index)))
                    (set! ok false))
                  (set! index (+ index 1))))
              (if (and ok (= count 2))
                (match (producer-test-expr-get
                  (& pools)
                  (ast.ast-expr-list-get (& args) 2 -1))
                  [(ast.AstExpr.Literal (ast.AstLiteral.String sid))
                    (string.eq (ci.intern-str sid) "")]
                  [_ false])
                ok)))]
        [_ false])]
    [_ false]))

(define (producer-test-dispatch-scoped-cat?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [count : i64]
  [mixed : bool]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [nodes : (__tl_dyn-array i64) (__tl_make-array i64 5)]
    [items : ast.AstExprList (ast.ast-expr-list-new)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    [call-callee : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "make-value")))]
    (begin
      (set!
        (array-ref nodes 0)
        (producer-test-push-spanned
          (& pools)
          (ast.AstExpr.Literal (ast.AstLiteral.String (ci.intern "alpha")))))
      (set!
        (array-ref nodes 1)
        (producer-test-push-spanned
          (& pools)
          (ast.AstExpr.Var (ci.intern "beta"))))
      (set!
        (array-ref nodes 2)
        (producer-test-push-spanned
          (& pools)
          (ast.AstExpr.Literal (ast.AstLiteral.String (ci.intern "gamma")))))
      (set!
        (array-ref nodes 3)
        (producer-test-push-spanned
          (& pools)
          (ast.AstExpr.Var (ci.intern "delta"))))
      (set!
        (array-ref nodes 4)
        (producer-test-push-spanned
          (& pools)
          (ast.AstExpr.Literal (ast.AstLiteral.String (ci.intern "epsilon")))))
      (when
        mixed
        (set!
          (array-ref nodes 1)
          (producer-test-push-spanned
            (& pools)
            (ast.AstExpr.Call call-callee (ast.ast-expr-list-new)))))
      (let
        [index : i64 0]
        (while (< index count)
          (begin
            (ast.ast-expr-list-push (&mut items) (array-ref nodes index))
            (set! index (+ index 1)))))
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.ExprList items))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            "stdlib.str_cat_runtime/str-cat-scoped"
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (producer-test-scoped-cat-result-ok?
                  pools
                  nodes
                  count
                  (not mixed)))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; The `format-push` / `format-finish` shape: a computed match that
;; destructures an `Expr` operand with `(comptime.Expr.Call callee args)`,
;; binding the callee and the argument list into session locals. Check 0
;; rebuilds `(,callee ,@pieces ,piece)` from a two-argument call operand,
;; check 1 takes the non-call default arm, and check 2 rebuilds
;; `(joined ,@pieces)` with a wildcard callee pattern. Refs #5602.
(define (producer-test-calldestructure-result-ok?
  [pools : ast.AstNodePoolContext]
  [check : i64]
  [carrier : i64]
  [first : i64]
  [second : i64]
  [piece : i64]
  [callee : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (cond
        [(= check 1) (= node carrier)]
        [else
          (match (producer-test-expr-get (& pools) node)
            [(ast.AstExpr.Call actual-callee args)
              (and
                (if (= check 0)
                  (= actual-callee callee)
                  (match (producer-test-expr-get (& pools) actual-callee)
                    [(ast.AstExpr.Var name)
                      (= name (producer-test-name-id "joined"))]
                    [_ false]))
                (=
                  (ast.ast-expr-list-len (& args))
                  (if (= check 0)
                    3
                    2))
                (= (ast.ast-expr-list-get (& args) 0 -1) first)
                (= (ast.ast-expr-list-get (& args) 1 -1) second)
                (if (= check 0)
                  (= (ast.ast-expr-list-get (& args) 2 -1) piece)
                  true))]
            [_ false])])]
    [_ false]))

(define (producer-test-dispatch-calldestructure?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [check : i64]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [callee : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "carry")))]
    [first : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "alpha")))]
    [second : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "beta")))]
    [piece : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "gamma")))]
    [items : ast.AstExprList (ast.ast-expr-list-new)]
    [carrier : i64 0]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 2)]
    (begin
      (ast.ast-expr-list-push (&mut items) first)
      (ast.ast-expr-list-push (&mut items) second)
      (set!
        carrier
        (if (= check 1)
          piece
          (producer-test-push-spanned (& pools) (ast.AstExpr.Call callee items))))
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr carrier (ast.AstType.Expr)))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.Expr piece (ast.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        (if (= check 2)
          1
          2)
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (producer-test-calldestructure-result-ok?
                  pools
                  check
                  carrier
                  first
                  second
                  piece
                  callee))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; The `path-join-fold` / `str-cat-pack` shape: an outer
;; `(comptime.Expr.Int i)` match binds the literal as a compile-time i64, an
;; inner `(comptime.Expr.Call _ elems)` match binds the carrier's argument
;; list as a session local, and the body compares `i` against that local
;; list's length before indexing it. Checks 0 and 3 take the recursive template,
;; check 1 exhausts the list and returns the accumulator, and check 2 passes a
;; non-Int index so the outer default arm answers. Check 3 also proves a
;; diagnostic-only macro marker on the index is transparent to native matching.
;; The dispatch installs `foldlike` as a visible macro, so the recursive call's
;; callee must retain its parser span for nested diagnostic frames. Refs #5602,
;; #6328.
(define (producer-test-foldlike-callee-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [callee : i64]) : bool
  (match (ast.ast-node-pool-context-expr-get pools callee)
    [(ast.AstExpr.Spanned inner span)
      (and
        (> (ast.ast-source-span-start-line span) 0)
        (> (ast.ast-source-span-start-col span) 0)
        (match (producer-test-expr-get pools inner)
          [(ast.AstExpr.Var name) (= name (producer-test-name-id "foldlike"))]
          [_ false]))]
    [_ false]))

(define (producer-test-foldlike-result-ok?
  [pools : ast.AstNodePoolContext]
  [check : i64]
  [carrier : i64]
  [acc : i64]
  [first : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (if (or (= check 1) (= check 2))
        (= node acc)
        (match (producer-test-expr-get (& pools) node)
          [(ast.AstExpr.Call callee args)
            (and
              (producer-test-foldlike-callee-ok? (& pools) callee)
              (= (ast.ast-expr-list-len (& args)) 3)
              (= (ast.ast-expr-list-get (& args) 0 -1) carrier)
              (match (producer-test-expr-get
                (& pools)
                (ast.ast-expr-list-get (& args) 1 -1))
                [(ast.AstExpr.Call step-callee step-args)
                  (and
                    (match (producer-test-expr-get (& pools) step-callee)
                      [(ast.AstExpr.Var name)
                        (= name (producer-test-name-id "step"))]
                      [_ false])
                    (= (ast.ast-expr-list-len (& step-args)) 2)
                    (= (ast.ast-expr-list-get (& step-args) 0 -1) acc)
                    (= (ast.ast-expr-list-get (& step-args) 1 -1) first))]
                [_ false])
              (match (producer-test-expr-get
                (& pools)
                (ast.ast-expr-list-get (& args) 2 -1))
                [(ast.AstExpr.Literal (ast.AstLiteral.Int value _)) (= value 1)]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (producer-test-dispatch-foldlike?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [check : i64]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [head : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "carry")))]
    [first : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "alpha")))]
    [second : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "beta")))]
    [acc : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "seed")))]
    [items : ast.AstExprList (ast.ast-expr-list-new)]
    [carrier : i64 0]
    [idx : i64 0]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 3)]
    (begin
      (compiler_ctfe.ctfe-visible-macro-names-reset!)
      (compiler_ctfe.ctfe-visible-macro-name-add! (ci.intern "foldlike"))
      (ast.ast-expr-list-push (&mut items) first)
      (ast.ast-expr-list-push (&mut items) second)
      (set!
        carrier
        (producer-test-push-spanned (& pools) (ast.AstExpr.Call head items)))
      (set!
        idx
        (if (= check 2)
          acc
          (let
            [literal : i64
              (producer-test-push-spanned
                (& pools)
                (ast.AstExpr.Literal
                  (ast.ast-lit-int
                    (if (= check 1)
                      2
                      0))))]
            (if (= check 3)
              (ast.ast-expr-spanned-with-pools
                pools
                (producer-test-push-spanned
                  (& pools)
                  (ast.AstExpr.MacroExpansion literal 17 23))
                (ast.ast-source-span 1 1 1 2))
              literal))))
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr carrier (ast.AstType.Expr)))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.Expr acc (ast.AstType.Expr)))
      (set!
        (array-ref operands 2)
        (compiler_ctfe.CompilerCtfeValue.Expr idx (ast.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        3
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (producer-test-foldlike-result-ok?
                  pools
                  check
                  carrier
                  acc
                  first))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          (compiler_ctfe.ctfe-visible-macro-names-reset!)
          ok)))))

;; The serialize nested-alias shape, which is the whole point of the `Expr.Var`
;; destructuring: bind an index from an `Expr.Int` operand, bind an identifier's
;; spelling from an `Expr.Var` operand, and build a derived name from both. It
;; exercises the `Expr.Var` shape probe and name accessor, `int->string` over a
;; compile-time data local (which stages the index as a comptime value first),
;; and the existing `string-append` chain -- none of which any other fixture
;; reaches, and none of which the embedded image exercises yet, because every
;; consuming stdlib body is still blocked on its own reflection family.
;;
;; `var-operand` false passes a non-identifier first operand instead, so the
;; shape probe's negative answer and the wildcard arm stay covered too.
;; Refs #5700.
;; A computed identifier is interned from its assembled spelling, so it carries
;; no template-source mark -- compare the text, the way the `gen` fixture's
;; computed module name does.
(define (producer-test-alias-result-ok?
  [pools : ast.AstNodePoolContext]
  [expected : String]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.Var name-id) (string.eq (ci.intern-str name-id) expected)]
        [_ false])]
    [_ false]))

(define (producer-test-dispatch-aliaslike?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [name : String]
  [index : i64]
  [var-operand : bool]
  [expected : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [value : i64
      (if var-operand
        (producer-test-push-spanned
          (& pools)
          (ast.AstExpr.Var (ci.intern name)))
        (producer-test-push-spanned
          (& pools)
          (ast.AstExpr.Literal (ast.ast-lit-int index))))]
    [idx : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Literal (ast.ast-lit-int index)))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 2)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr value (ast.AstType.Expr)))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.Expr idx (ast.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        2
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (if var-operand
                  (producer-test-alias-result-ok? pools expected)
                  (producer-test-operand-result-ok? value)))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; The `places` fixture covers public place template nodes: a dotted Set AST
;; node, `(box ...)`, a BoxTake AST node from `deref`, and `(return ...)`.
;; Refs #5605, #6240.
(define (producer-test-places-result-ok?
  [pools : ast.AstNodePoolContext]
  [operand : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.Match match-box)
          (match (owned_view.compiler-owned-box-shared-view match-box)
            [(ast.AstMatch.Match _ arms)
              (and
                (= arms.len 2)
                (match (array-ref arms.slots 0)
                  [(ast.AstMatchArm.Arm _ body)
                    (match (producer-test-expr-get (& pools) body)
                      [(ast.AstExpr.Begin items)
                        (and
                          (= (ast.ast-expr-list-len (& items)) 2)
                          (match (producer-test-expr-get
                            (& pools)
                            (ast.ast-expr-list-get (& items) 0 -1))
                            [(ast.AstExpr.Set name value)
                              (and
                                (= name (producer-test-name-id "inner.len"))
                                (match (producer-test-expr-get (& pools) value)
                                  [(ast.AstExpr.Literal
                                      (ast.AstLiteral.Float text))
                                    (string.eq text "1.5")]
                                  [_ false]))]
                            [_ false])
                          (match (producer-test-expr-get
                            (& pools)
                            (ast.ast-expr-list-get (& items) 1 -1))
                            [(ast.AstExpr.BoxTake boxed)
                              (match (producer-test-expr-get (& pools) boxed)
                                [(ast.AstExpr.Box inner)
                                  (match (producer-test-expr-get
                                    (& pools)
                                    inner)
                                    [(ast.AstExpr.Var name)
                                      (= name (producer-test-name-id "inner"))]
                                    [_ false])]
                                [_ false])]
                            [_ false]))]
                      [_ false])]
                  [_ false])
                (match (array-ref arms.slots 1)
                  [(ast.AstMatchArm.Arm _ body)
                    (match (producer-test-expr-get (& pools) body)
                      [(ast.AstExpr.Return inner) (= inner operand)]
                      [_ false])]
                  [_ false]))])]
        [_ false])]
    [_ false]))

;; `(comptime.expr-var (comptime.expr-string-value value))`: the literal text of
;; a string-literal Expr operand becomes a variable name, exercising
;; `operand-expr-string-value` followed by the value-consuming
;; `expr-var-from-value`. Refs #5626.
(define (producer-test-dispatch-strval?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [literal : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Literal (ast.AstLiteral.String (ci.intern "picked.name"))))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr literal (ast.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
                  [(compiler_ctfe.CompilerCtfeValue.Expr node _)
                    (match (producer-test-expr-get (& pools) node)
                      ;; expr-var-from-value resolves the name through the
                      ;; source-name session rather than the template-source
                      ;; mark, so compare rendered text like the `gen` fixture.
                      [(ast.AstExpr.Var name-id)
                        (string.eq (ci.intern-str name-id) "picked.name")]
                      [_ false])]
                  [_ false]))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; `Expr.Var` destructuring binds an interpreted Name, not a generated String.
;; A structural macro-global id is the non-vacuous case: its visible text is
;; unwrapped to the source identifier while its original id remains intact.
;; Assert the callback value directly, then dispatch a native entry that feeds
;; that Name through `expr-var` and preserves the same id. Refs #5771.
(define (producer-test-dispatch-var-name-identity?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [source-id : i64 (ci.intern "structural.alias")]
    [structural-id : i64 (producer-test-macro-global-id source-id)]
    [operand : i64
      (producer-test-push-spanned (& pools) (ast.AstExpr.Var structural-id))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr operand (ast.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [callback-ok : bool
          (and
            (=
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-operand-expr-var-name
                producer-test-cookie
                0
                0
                0)
              tlci.tlci-host-callback-status-ok)
            (=
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-commit-result
                producer-test-cookie
                0
                0
                0)
              tlci.tlci-host-callback-status-ok)
            (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
              [(compiler_ctfe.CompilerCtfeValue.Name text name-id)
                (and
                  (string.eq text "structural.alias")
                  (= name-id structural-id))]
              [_ false]))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          (if (not callback-ok)
            false
            (begin
              (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
                (owned_view.compiler-owned-shared-view pools)
                (owned_view.compiler-owned-shared-view operands)
                1
                64
                producer-test-cookie
                (compiler_ctfe.ctfe-reflect-info-list-empty))
              (let
                [dispatch-ok : bool
                  (match (tlci_loader.tlci-loader-dispatch-macro
                    loaded
                    identity
                    producer-test-cookie
                    (__tl_make-array i64 0)
                    0)
                    [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
                    [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
                      (and
                        (= dispatch.status tlci.tlci-host-callback-status-ok)
                        (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                        (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
                          [(compiler_ctfe.CompilerCtfeValue.Expr node _)
                            (match (producer-test-expr-get (& pools) node)
                              [(ast.AstExpr.Var name-id)
                                (= name-id structural-id)]
                              [_ false])]
                          [_ false]))])]
                (begin
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
                  dispatch-ok)))))))))

;; Module operands are canonical identity Strings. `modname` routes that value
;; through module-name then expr-var, while `modhook` resolves a generated hook
;; to the same canonical qualified Var as interpreted CTFE. Refs #5699.
(define (producer-test-dispatch-module-name?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [module : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [module-id : i64 (ci.intern (owned_view.compiler-owned-shared-view module))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.String
          (owned_view.compiler-owned-shared-view module)
          module-id))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
                  [(compiler_ctfe.CompilerCtfeValue.Expr node _)
                    (match (producer-test-expr-get (& pools) node)
                      [(ast.AstExpr.Var name-id)
                        (string.eq (ci.intern-str name-id) module)]
                      [_ false])]
                  [_ false]))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-dispatch-module-hook?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [module : String]
  [hook : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [module-id : i64 (ci.intern (owned_view.compiler-owned-shared-view module))]
    [hook-id : i64 (ci.intern hook)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.String module module-id))
      (compiler_ctfe.ctfe-module-macro-export-reset!)
      (compiler_ctfe.ctfe-module-macro-export-add-id! module-id hook-id)
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
                  [(compiler_ctfe.CompilerCtfeValue.Expr node _)
                    (match (producer-test-expr-get (& pools) node)
                      [(ast.AstExpr.Var name-id)
                        (=
                          name-id
                          (ci.intern-composite-pair-id module-id hook-id))]
                      [_ false])]
                  [_ false]))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          (compiler_ctfe.ctfe-module-macro-export-reset!)
          ok)))))

(define (producer-test-dispatch-module-hook-missing?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [module : String]
  [hook : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.String
          (owned_view.compiler-owned-shared-view module)
          (ci.intern (owned_view.compiler-owned-shared-view module))))
      (compiler_ctfe.ctfe-module-macro-export-reset!)
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-diagnostic)
                (not
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?))
                (string.eq
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-diagnostic-text)
                  (compiler_ctfe.ctfe-module-hook-missing-message module hook)))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          (compiler_ctfe.ctfe-module-macro-export-reset!)
          ok)))))

;; `(marker ,(comptime.expr-type value))`: expr-type needs a *typechecked* Expr,
;; so the operand carries a real type rather than the untyped Expr type the
;; other fixtures use. Refs #5626.
(define (producer-test-dispatch-typeof?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operand : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "value")))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr operand (ast.AstType.I64)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
                  [(compiler_ctfe.CompilerCtfeValue.Expr node _)
                    (match (producer-test-expr-get (& pools) node)
                      [(ast.AstExpr.Call callee args)
                        (and
                          (match (producer-test-expr-get (& pools) callee)
                            [(ast.AstExpr.Var name)
                              (= name (producer-test-name-id "marker"))]
                            [_ false])
                          (= (ast.ast-expr-list-len (& args)) 1))]
                      [_ false])]
                  [_ false]))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-dispatch-type-expr?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [box-ty : ast.AstType
      (ast.ast-ty-box-with-pools
        (owned_view.compiler-owned-shared-view pools)
        (ast.AstType.I64))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Type
          (owned_view.compiler-owned-shared-view box-ty)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
                  [(compiler_ctfe.CompilerCtfeValue.Expr
                      node
                      (ast.AstType.Expr))
                    (match (producer-test-expr-get pools node)
                      [(ast.AstExpr.TypeLiteral ty-id)
                        (compiler_ctfe.ctfe-type-eq
                          (ast.ast-node-pool-context-type-get pools ty-id)
                          box-ty)]
                      [_ false])]
                  [_ false]))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-lambda-result-ok?
  [pools : ast.AstNodePoolContext]
  [expected : ast.AstType]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node (ast.AstType.Expr))
      (match (producer-test-expr-get pools node)
        [(ast.AstExpr.Lambda lambda-box)
          (match (__tl-box-place lambda-box)
            [(ast.AstLambda.Lambda params maybe-ret body)
              (and
                (= (ast.ast-param-list-len (& params)) 1)
                (match (ast.ast-param-list-get
                  (& params)
                  0
                  (ast.ast-param-fallback))
                  [(ast.AstParam.Param name actual false)
                    (and
                      (= name (producer-test-name-id "value"))
                      (compiler_ctfe.ctfe-type-eq actual (clone expected)))]
                  [_ false])
                (match maybe-ret
                  [(ast.AstMaybeType.Some actual)
                    (compiler_ctfe.ctfe-type-eq actual expected)]
                  [_ false])
                (match (producer-test-expr-get pools body)
                  [(ast.AstExpr.Var name)
                    (= name (producer-test-name-id "value"))]
                  [_ false]))])]
        [_ false])]
    [_ false]))

;; A lambda template consumes type-position unquotes for both its parameter
;; and return annotations on the package-native route. Refs #6868.
(define (producer-test-dispatch-lambda?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [owner-region : i64 (ci.intern "lambda-owner-region")]
    [text-region : i64 (ci.intern "lambda-text-region")]
    [lambda-ty : ast.AstType
      (ast.ast-ty-tuple
        (ast.ast-type-cons-with-pools
          (owned_view.compiler-owned-shared-view pools)
          (ast.ast-ty-ref-with-pools
            (owned_view.compiler-owned-shared-view pools)
            owner-region
            (ast.AstType.Var (ci.intern "package.model/Owner")))
          (ast.ast-type-cons-with-pools
            (owned_view.compiler-owned-shared-view pools)
            (ast.ast-ty-ref-with-pools
              (owned_view.compiler-owned-shared-view pools)
              text-region
              (ast.AstType.Str))
            (ast.ast-type-list-new))))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Type
          (owned_view.compiler-owned-shared-view lambda-ty)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (producer-test-lambda-result-ok? pools lambda-ty))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-lambda1-parameter-type-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [actual : ast.AstType]
  [owner-region : i64]
  [text-region : i64]) : bool
  (match actual
    [(ast.AstType.Tuple elems-box)
      (let
        [elems : ast.AstTypeList (ast.ast-type-list-box-shared-view elems-box)]
        (and
          (= (ast.ast-type-list-len (& elems)) 2)
          (match (ast.ast-node-pool-context-type-get
            pools
            (ast.ast-type-list-get (& elems) 0 -1))
            [(ast.AstType.Ref actual-region inner)
              (and
                (= actual-region owner-region)
                (match (ast.ast-node-pool-context-type-get pools inner)
                  [(ast.AstType.Var name)
                    (= name (ci.intern "package.model/Owner"))]
                  [_ false]))]
            [_ false])
          (match (ast.ast-node-pool-context-type-get
            pools
            (ast.ast-type-list-get (& elems) 1 -1))
            [(ast.AstType.Ref actual-region inner)
              (and
                (= actual-region text-region)
                (match (ast.ast-node-pool-context-type-get pools inner)
                  [(ast.AstType.Str) true]
                  [_ false]))]
            [_ false])))]
    [_ false]))

(define (producer-test-lambda1-result-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [owner-region : i64]
  [text-region : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node produced)
      (and
        (compiler_ctfe.ctfe-untyped-expr-type? produced)
        (match (producer-test-expr-get pools node)
          [(ast.AstExpr.Lambda lambda-box)
            (match (__tl-box-place lambda-box)
              [(ast.AstLambda.Lambda params maybe-ret body)
                (and
                  (= (ast.ast-param-list-len (& params)) 1)
                  (match (ast.ast-param-list-get
                    (& params)
                    0
                    (ast.ast-param-fallback))
                    [(ast.AstParam.Param parameter-name actual false)
                      (and
                        (string.eq
                          (ci.intern-str parameter-name)
                          "lambda1-values")
                        (producer-test-lambda1-parameter-type-ok?
                          pools
                          actual
                          owner-region
                          text-region)
                        (match (producer-test-expr-get pools body)
                          [(ast.AstExpr.TupleRef target 1)
                            (match (producer-test-expr-get pools target)
                              [(ast.AstExpr.Var target-name)
                                (= target-name parameter-name)]
                              [_ false])]
                          [_ false]))]
                    [_ false])
                  (match maybe-ret
                    [(ast.AstMaybeType.No) true]
                    [(ast.AstMaybeType.Some _) false]))])]
          [_ false]))]
    [_ false]))

;; The public computed builder takes an Expr operand's reflected heterogeneous
;; type, a fresh parameter identity, and a tuple projection assembled before
;; the lambda exists. The package-native result must preserve all three.
(define (producer-test-dispatch-lambda1?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 64 64)]
    [owner-region : i64 (ci.intern "lambda1-owner-region")]
    [text-region : i64 (ci.intern "lambda1-text-region")]
    [lambda-ty : ast.AstType
      (ast.ast-ty-tuple
        (ast.ast-type-cons-with-pools
          (owned_view.compiler-owned-shared-view pools)
          (ast.ast-ty-ref-with-pools
            (owned_view.compiler-owned-shared-view pools)
            owner-region
            (ast.AstType.Var (ci.intern "package.model/Owner")))
          (ast.ast-type-cons-with-pools
            (owned_view.compiler-owned-shared-view pools)
            (ast.ast-ty-ref-with-pools
              (owned_view.compiler-owned-shared-view pools)
              text-region
              (ast.AstType.Str))
            (ast.ast-type-list-new))))]
    [operand : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "anchors")))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr
          operand
          (compiler_ctfe.ctfe-captured-expr-type-with-pools
            (owned_view.compiler-owned-shared-view pools)
            lambda-ty)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (producer-test-lambda1-result-ok?
                  pools
                  owner-region
                  text-region))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-dispatch-type-expr-list?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [box-ty : ast.AstType
      (ast.ast-ty-box-with-pools
        (owned_view.compiler-owned-shared-view pools)
        (ast.AstType.I64))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Type
          (owned_view.compiler-owned-shared-view box-ty)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
                  [(compiler_ctfe.CompilerCtfeValue.ExprList items)
                    (and
                      (= (ast.ast-expr-list-len (& items)) 1)
                      (match (producer-test-expr-get
                        pools
                        (ast.ast-expr-list-get (& items) 0 -1))
                        [(ast.AstExpr.TypeLiteral ty-id)
                          (compiler_ctfe.ctfe-type-eq
                            (ast.ast-node-pool-context-type-get pools ty-id)
                            box-ty)]
                        [_ false]))]
                  [_ false]))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; The comptime string scanner: `comptime.expr-string?` (256) guards a String
;; session local that `expr-string-value` (246) binds, `string-length` (252)
;; measures, `string-ref` (253) indexes through a `char` cast, `string-slice`
;; (254) cuts and `expr-string-from-value` (255) turns back into a literal.
;; The two arms differ only in which byte the operand starts with, so an
;; off-by-one in any of those reads still commits a result -- the assertions
;; compare the exact literal each arm must produce. Refs #5701.
(define (producer-test-dispatch-scan?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [literal : String]
  [expected-callee : String]
  [expected-int : i64]
  [expected-text : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operand : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Literal (ast.AstLiteral.String (ci.intern literal))))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr operand (ast.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
                  [(compiler_ctfe.CompilerCtfeValue.Expr node _)
                    (match (producer-test-expr-get (& pools) node)
                      [(ast.AstExpr.Call callee args)
                        (and
                          (match (producer-test-expr-get (& pools) callee)
                            [(ast.AstExpr.Var name)
                              (= name (producer-test-name-id expected-callee))]
                            [_ false])
                          (= (ast.ast-expr-list-len (& args)) 1)
                          (producer-test-scan-argument-ok?
                            pools
                            (ast.ast-expr-list-get (& args) 0 0)
                            expected-int
                            expected-text))]
                      [_ false])]
                  [_ false]))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-scan-argument-ok?
  [pools : ast.AstNodePoolContext]
  [node : i64]
  [expected-int : i64]
  [expected-text : String]) : bool
  (match (producer-test-expr-get (& pools) node)
    [(ast.AstExpr.Literal (ast.AstLiteral.Int value _))
      (and (>= expected-int 0) (= value expected-int))]
    [(ast.AstExpr.Literal (ast.AstLiteral.String sid))
      (and (< expected-int 0) (string.eq (ci.intern-str sid) expected-text))]
    [_ false]))

;; The scanner's guard arm: a non-literal operand must reach the session
;; diagnostic rather than commit a silently empty template. Refs #5701.
(define (producer-test-dispatch-diagnostic?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [argument : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set! (array-ref operands 0) (producer-test-expr-operand argument))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-diagnostic)
                (not
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-dispatch-shape?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [argument : String]
  [check : i64]
  [expected : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operand : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern argument)))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr operand (ast.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (cond
                  [(= check 0)
                    (producer-test-template-result-ok? pools operand expected)]
                  [(= check 1) (producer-test-nest-result-ok? pools operand)]
                  [(= check 2) (producer-test-lits-result-ok? pools)]
                  [(= check 3) (producer-test-operand-result-ok? operand)]
                  [(= check 4) (producer-test-var-result-ok? pools expected)]
                  [(= check 5) (producer-test-classify-result-ok? pools)]
                  [(= check 6) (producer-test-twice-result-ok? pools)]
                  [else (producer-test-places-result-ok? pools operand)]))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; Dispatch the module-generator fixture with a type and an expression
;; operand; the computed module name must resolve to "test.gen.i64".
(define (producer-test-dispatch-gen?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operand : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "value")))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 2)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Type (ast.AstType.I64)))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.Expr operand (ast.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        2
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (if (= dispatch.status tlci.tlci-host-callback-status-ok)
                (if (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                  (producer-test-gen-result-ok? pools)
                  false)
                false)])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-local-type-result-ok?
  [pools : ast.AstNodePoolContext]
  [operand : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.Cast inner ty-id)
          (and
            (= inner operand)
            (match (ast.ast-node-pool-context-type-get pools ty-id)
              [(ast.AstType.I64) true]
              [_ false]))]
        [_ false])]
    [_ false]))

;; Keep the type-position unquote branch pinned for both direct operands and
;; session locals. This fixture binds the type operand once, then unquotes the
;; local into a cast annotation. Refs #5606, #6551.
(define (producer-test-dispatch-local-type?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operand : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "value")))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 2)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Type (ast.AstType.I64)))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.Expr operand (ast.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        2
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (producer-test-local-type-result-ok? pools operand))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; Dispatch the zero-operand declaration-generator fixture and retain its
;; result only through the compiler-owned handle table.
(define (producer-test-dispatch-decls?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        0
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (producer-test-decls-result-ok? pools))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; `(ctor ,T 0 ,value)` with a type operand rebuilds the type as type syntax
;; in argument position, matching the interpreted unquote substitution.
(define (producer-test-tytpl-result-ok?
  [pools : ast.AstNodePoolContext]
  [operand : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.Call callee args)
          (and
            (match (producer-test-expr-get (& pools) callee)
              [(ast.AstExpr.Var name)
                (=
                  name
                  (ci.intern-template-source-id
                    (ci.intern "stdlib.eq.struct-eq-fields")))]
              [_ false])
            (= (ast.ast-expr-list-len (& args)) 3)
            (match (producer-test-expr-get
              (& pools)
              (ast.ast-expr-list-get (& args) 0 -1))
              [(ast.AstExpr.Var _) true]
              [_ false])
            (match (producer-test-expr-get
              (& pools)
              (ast.ast-expr-list-get (& args) 1 -1))
              [(ast.AstExpr.Literal (ast.AstLiteral.Int value _)) (= value 0)]
              [_ false])
            (= (ast.ast-expr-list-get (& args) 2 -1) operand))]
        [_ false])]
    [_ false]))

(define (producer-test-dispatch-tytpl?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operand : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "value")))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 2)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Type (ast.AstType.I64)))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.Expr operand (ast.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        2
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (producer-test-tytpl-result-ok? pools operand))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; Every composite annotation in `typetpl` exercises its callback by name.
;; Loading the image is insufficient: a mismatched producer spelling only
;; fails when the emitted entry dispatches. Keep every reconstructed binding
;; pinned so a working sibling cannot hide one broken callback.
(define (producer-test-typetpl-ptr-binding-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [binding : ast.AstLetBinding]) : bool
  (match binding
    [(ast.AstLetBinding.Binding _ (ast.AstMaybeType.Some ty) _)
      (match ty
        [(ast.AstType.Ptr elem)
          (match (ast.ast-node-pool-context-type-get pools elem)
            [(ast.AstType.U8) true]
            [_ false])]
        [_ false])]
    [_ false]))

(define (producer-test-typetpl-dyn-array-binding-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [binding : ast.AstLetBinding]) : bool
  (match binding
    [(ast.AstLetBinding.Binding _ (ast.AstMaybeType.Some ty) _)
      (match ty
        [(ast.AstType.DynArray elem)
          (match (ast.ast-node-pool-context-type-get pools elem)
            [(ast.AstType.I64) true]
            [_ false])]
        [_ false])]
    [_ false]))

(define (producer-test-typetpl-box-binding-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [binding : ast.AstLetBinding]) : bool
  (match binding
    [(ast.AstLetBinding.Binding _ (ast.AstMaybeType.Some ty) _)
      (match ty
        [(ast.AstType.Box inner)
          (match (ast.ast-node-pool-context-type-get pools inner)
            [(ast.AstType.I64) true]
            [_ false])]
        [_ false])]
    [_ false]))

(define (producer-test-typetpl-array-binding-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [binding : ast.AstLetBinding]
  [expected-count : i64]) : bool
  (match binding
    [(ast.AstLetBinding.Binding _ (ast.AstMaybeType.Some ty) _)
      (match ty
        [(ast.AstType.Array elem count)
          (and
            (= count expected-count)
            (match (ast.ast-node-pool-context-type-get pools elem)
              [(ast.AstType.I64) true]
              [_ false]))]
        [_ false])]
    [_ false]))

(define (producer-test-typetpl-slice-binding-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [binding : ast.AstLetBinding]) : bool
  (match binding
    [(ast.AstLetBinding.Binding _ (ast.AstMaybeType.Some ty) _)
      (match ty
        [(ast.AstType.Slice elem)
          (match (ast.ast-node-pool-context-type-get pools elem)
            [(ast.AstType.I64) true]
            [_ false])]
        [_ false])]
    [_ false]))

(define (producer-test-typetpl-ref-binding-ok?
  [pools : (& pools ast.AstNodePoolContext)]
  [binding : ast.AstLetBinding]) : bool
  (match binding
    [(ast.AstLetBinding.Binding _ (ast.AstMaybeType.Some ty) _)
      (match ty
        [(ast.AstType.Ref region inner)
          (and
            (string.eq (ci.intern-str region) "region")
            (match (ast.ast-node-pool-context-type-get pools inner)
              [(ast.AstType.Str) true]
              [_ false]))]
        [_ false])]
    [_ false]))

(define (producer-test-typetpl-var-args-binding-ok?
  [binding : ast.AstLetBinding]
  [expected-name : String]
  [expected-first : String]
  [expected-second : String]
  [expected-count : i64]) : bool
  (match binding
    [(ast.AstLetBinding.Binding _ (ast.AstMaybeType.Some ty) _)
      (match ty
        [(ast.AstType.VarArgs name lifetimes-box)
          (let
            [lifetimes : ast.AstLifetimeList
              (owned_view.compiler-owned-box-shared-view lifetimes-box)]
            (and
              (= name (ci.intern expected-name))
              (= (ast.ast-lifetime-list-len (& lifetimes)) expected-count)
              (=
                (ast.ast-lifetime-list-get
                  (& lifetimes)
                  0
                  (ast.ast-lifetime-fallback))
                (ci.intern expected-first))
              (or
                (= expected-count 1)
                (=
                  (ast.ast-lifetime-list-get
                    (& lifetimes)
                    1
                    (ast.ast-lifetime-fallback))
                  (ci.intern expected-second)))))]
        [_ false])]
    [_ false]))

(define (producer-test-typetpl-result-ok? [pools : ast.AstNodePoolContext]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.Let let-box)
          (match (owned_view.compiler-owned-box-shared-view let-box)
            [(ast.AstLet.Let bindings _)
              (and
                (= (ast.ast-let-binding-list-len (& bindings)) 8)
                (producer-test-typetpl-ptr-binding-ok?
                  (& pools)
                  (ast.ast-let-binding-list-get
                    (& bindings)
                    0
                    (ast.ast-let-binding-fallback)))
                (producer-test-typetpl-dyn-array-binding-ok?
                  (& pools)
                  (ast.ast-let-binding-list-get
                    (& bindings)
                    1
                    (ast.ast-let-binding-fallback)))
                (producer-test-typetpl-ref-binding-ok?
                  (& pools)
                  (ast.ast-let-binding-list-get
                    (& bindings)
                    2
                    (ast.ast-let-binding-fallback)))
                (producer-test-typetpl-box-binding-ok?
                  (& pools)
                  (ast.ast-let-binding-list-get
                    (& bindings)
                    3
                    (ast.ast-let-binding-fallback)))
                (producer-test-typetpl-array-binding-ok?
                  (& pools)
                  (ast.ast-let-binding-list-get
                    (& bindings)
                    4
                    (ast.ast-let-binding-fallback))
                  4)
                (producer-test-typetpl-slice-binding-ok?
                  (& pools)
                  (ast.ast-let-binding-list-get
                    (& bindings)
                    5
                    (ast.ast-let-binding-fallback)))
                (producer-test-typetpl-var-args-binding-ok?
                  (ast.ast-let-binding-list-get
                    (& bindings)
                    6
                    (ast.ast-let-binding-fallback))
                  "LifetimeOne"
                  "text"
                  ""
                  1)
                (producer-test-typetpl-var-args-binding-ok?
                  (ast.ast-let-binding-list-get
                    (& bindings)
                    7
                    (ast.ast-let-binding-fallback))
                  "LifetimePair"
                  "left"
                  "right"
                  2))])]
        [_ false])]
    [_ false]))

(define (producer-test-dispatch-typetpl?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set! (array-ref operands 0) (producer-test-expr-operand "value"))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (producer-test-typetpl-result-ok? pools))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; The `kindof` fixture dispatches on the produced type of an Expr operand, so
;; the f64-typed operand must select the first arm and rebuild `(f64-op v)`.
;; The `keyof` fixture dispatches on a type operand's canonical key and builds
;; `(i64-op (cast v : i64))`, covering the cast template node. Refs #5604.
(define (producer-test-call-of-result-ok?
  [pools : ast.AstNodePoolContext]
  [expected-callee : String]
  [check-cast : bool]
  [operand : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.Call callee args)
          (and
            (match (producer-test-expr-get (& pools) callee)
              [(ast.AstExpr.Var name)
                (= name (producer-test-name-id expected-callee))]
              [_ false])
            (= (ast.ast-expr-list-len (& args)) 1)
            (let
              [arg : i64 (ast.ast-expr-list-get (& args) 0 -1)]
              (if check-cast
                (match (producer-test-expr-get (& pools) arg)
                  [(ast.AstExpr.Cast inner ty-id)
                    (and
                      (= inner operand)
                      (match (ast.ty-node-get ty-id)
                        [(ast.AstType.I64) true]
                        [_ false]))]
                  [_ false])
                (= arg operand))))]
        [_ false])]
    [_ false]))

(define (producer-test-dispatch-kindof?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operand : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "value")))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr operand (ast.AstType.F64)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (producer-test-call-of-result-ok? pools "f64-op" false operand))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-dispatch-keyof?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operand : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "value")))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 2)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Type (ast.AstType.I64)))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.Expr operand (ast.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        2
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (producer-test-call-of-result-ok? pools "i64-op" true operand))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; `type-nominal-module` must preserve the interpreted Name result, including
;; a structural macro-global module id whose displayed text is its source name.
;; Modes 0/1 dispatch struct/enum operands, mode 2 checks the interpreted
;; non-nominal diagnostic, and mode 3 proves a missing operand fails closed.
;; Refs #6000.
(define (producer-test-nominal-reflections
  [canonical-id : i64]
  [module-text : String]
  [name-text : String]
  [enum? : bool]) : compiler_ctfe.CtfeReflectInfoList
  (compiler_ctfe.ctfe-reflect-info-list-push-id
    (compiler_ctfe.ctfe-reflect-info-list-with-capacity 1)
    (if enum?
      (compiler_ctfe.CtfeReflectInfo.Enum
        (str_cat.str-cat
          (owned_view.compiler-owned-shared-view module-text)
          "/"
          (owned_view.compiler-owned-shared-view name-text))
        module-text
        name-text
        canonical-id
        (compiler_ctfe.CtfeReflectCleanup.No)
        (compiler_ctfe.ctfe-reflect-variant-list-with-capacity 0))
      (compiler_ctfe.CtfeReflectInfo.Struct
        (str_cat.str-cat
          (owned_view.compiler-owned-shared-view module-text)
          "/"
          (owned_view.compiler-owned-shared-view name-text))
        module-text
        name-text
        canonical-id
        (compiler_ctfe.CtfeReflectCleanup.No)
        (compiler_ctfe.ctfe-reflect-field-list-with-capacity 0)))
    canonical-id))

(define (producer-test-nominal-result-eq?
  [expected : compiler_ctfe.CompilerCtfeValue]) : bool
  (match expected
    [(compiler_ctfe.CompilerCtfeValue.Name expected-text expected-id)
      (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
        [(compiler_ctfe.CompilerCtfeValue.Name actual-text actual-id)
          (and (string.eq actual-text expected-text) (= actual-id expected-id))]
        [_ false])]
    [_ false]))

(define (producer-test-dispatch-nominal-module?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [mode : i64]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [source-module-id : i64 (ci.intern "producer.nominal.module")]
    [module-id : i64
      (if (= mode 0)
        (producer-test-macro-global-id source-module-id)
        source-module-id)]
    [name-id : i64 (ci.intern "Nominal")]
    [canonical-id : i64 (ci.intern-composite-pair-id module-id name-id)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    [infos : compiler_ctfe.CtfeReflectInfoList
      (if (< mode 2)
        (producer-test-nominal-reflections
          canonical-id
          "producer.nominal.module"
          "Nominal"
          (= mode 1))
        (compiler_ctfe.ctfe-reflect-info-list-empty))]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Type
          (cond
            [(= mode 0) (ast.AstType.Struct canonical-id)]
            [(= mode 1) (ast.AstType.Enum canonical-id)]
            [else (ast.AstType.I64)])))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        (if (= mode 3)
          0
          1)
        64
        producer-test-cookie
        infos)
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (cond
                [(< mode 2)
                  (and
                    (= dispatch.status tlci.tlci-host-callback-status-ok)
                    (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                    (producer-test-nominal-result-eq?
                      (compiler_ctfe.ctfe-name-value module-id)))]
                [(= mode 2)
                  (and
                    (=
                      dispatch.status
                      tlci.tlci-host-callback-status-diagnostic)
                    (not
                      (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?))
                    (string.eq
                      (compiler_embedded_stdlib_tlci.compiler-comptime-host-diagnostic-text)
                      "type-nominal-module requires struct or enum type"))]
                [else
                  (and
                    (=
                      dispatch.status
                      tlci.tlci-host-callback-status-bad-request)
                    (not
                      (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)))])])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; Reflected module identities are Name values, while string literals are
;; String values. Public string comparison accepts both on the interpreted
;; path; keep the native callback compatible so a computed condition such as
;; `(string-eq (type-nominal-module T) "")` is safe. Refs #5606.
(define (producer-test-nominal-module-string-eq?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [source-module-id : i64 (ci.intern "producer.nominal.module")]
    [module-id : i64 (producer-test-macro-global-id source-module-id)]
    [name-id : i64 (ci.intern "Nominal")]
    [canonical-id : i64 (ci.intern-composite-pair-id module-id name-id)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Type (ast.AstType.Struct canonical-id)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (producer-test-nominal-reflections
          canonical-id
          "producer.nominal.module"
          "Nominal"
          false))
      (let
        [push-status : i64
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
            producer-test-cookie
            0
            0
            0)]
        [module-status : i64
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-type-key
            producer-test-cookie
            1
            0
            0)]
        [literal-status : i64
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-push!
            (compiler_ctfe.ctfe-generated-string-value
              "producer.nominal.module"))]
        [equal : i64
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-string-eq
            producer-test-cookie
            0
            0
            0)]
        [ok : bool
          (and
            (= push-status tlci.tlci-host-callback-status-ok)
            (= module-status tlci.tlci-host-callback-status-ok)
            (= literal-status tlci.tlci-host-callback-status-ok)
            (= equal 1))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; Dotted append has identity semantics beyond its rendered text. A structural
;; module Name plus a generated `.member` suffix must remain the canonical
;; generated-module member identity, or syntax construction resolves the same
;; spelling in the wrong module. Refs #5606.
(define (producer-test-name-dotted-string-append?) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [source-module-id : i64 (ci.intern "producer.nominal.module")]
    [module-id : i64 (producer-test-macro-global-id source-module-id)]
    [dot-id : i64 (ci.intern ".")]
    [member-id : i64 (ci.intern "into-iterator")]
    [expected-suffix : compiler_ctfe.CompilerCtfeValue
      (compiler_ctfe.ctfe-generated-string-append-value
        "."
        dot-id
        "into-iterator"
        member-id)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 0)]
    (match expected-suffix
      [(compiler_ctfe.CompilerCtfeValue.String suffix-text suffix-id)
        (let
          [expected : compiler_ctfe.CompilerCtfeValue
            (compiler_ctfe.ctfe-generated-string-append-value
              "producer.nominal.module"
              module-id
              suffix-text
              suffix-id)]
          (begin
            (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
              (owned_view.compiler-owned-shared-view pools)
              (owned_view.compiler-owned-shared-view operands)
              0
              64
              producer-test-cookie
              (compiler_ctfe.ctfe-reflect-info-list-empty))
            (let
              [module-status : i64
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-push!
                  (compiler_ctfe.ctfe-name-value module-id))]
              [dot-status : i64
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-push!
                  (compiler_ctfe.ctfe-source-string-value dot-id))]
              [member-status : i64
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-push!
                  (compiler_ctfe.ctfe-source-string-value member-id))]
              [suffix-status : i64
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-string-append
                  producer-test-cookie
                  0
                  0
                  0)]
              [full-status : i64
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-string-append
                  producer-test-cookie
                  0
                  0
                  0)]
              [commit-status : i64
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-commit-result
                  producer-test-cookie
                  0
                  0
                  0)]
              [ok : bool
                (and
                  (= module-status tlci.tlci-host-callback-status-ok)
                  (= dot-status tlci.tlci-host-callback-status-ok)
                  (= member-status tlci.tlci-host-callback-status-ok)
                  (= suffix-status tlci.tlci-host-callback-status-ok)
                  (= full-status tlci.tlci-host-callback-status-ok)
                  (= commit-status tlci.tlci-host-callback-status-ok)
                  (match expected
                    [(compiler_ctfe.CompilerCtfeValue.String
                        expected-text
                        expected-id)
                      (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
                        [(compiler_ctfe.CompilerCtfeValue.String
                            actual-text
                            actual-id)
                          (and
                            (string.eq actual-text expected-text)
                            (= actual-id expected-id))]
                        [_ false])]
                    [_ false]))]
              (begin
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
                ok))))]
      [_ false])))

(define (producer-test-dispatch-fold?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [condition : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "flag")))]
    [items : ast.AstExprList
      (ast.ast-expr-cons condition (ast.ast-expr-list-new))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.ExprList items))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (producer-test-fold-result-ok? pools condition))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; Dispatch the `when`-shaped macro with a condition operand and a body list
;; of `body-count` items; checks the full template for two items and the
;; missing-body variable for zero.
(define (producer-test-dispatch-whenlike?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [body-count : i64]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [condition : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "flag")))]
    [first : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "alpha")))]
    [second : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "beta")))]
    [items : ast.AstExprList
      (if (= body-count 2)
        (ast.ast-expr-cons
          first
          (ast.ast-expr-cons second (ast.ast-expr-list-new)))
        (ast.ast-expr-list-new))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 2)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr condition (ast.AstType.Expr)))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.ExprList items))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        2
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (if (= body-count 2)
                  (producer-test-whenlike-result-ok?
                    pools
                    condition
                    first
                    second)
                  (producer-test-var-result-ok? pools "core-when-missing-body")))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-tuple-items-eq?
  [actual : (& actual ast.AstExprList)]
  [expected : (& expected ast.AstExprList)]) : bool
  (let
    [count : i64 (ast.ast-expr-list-len actual)]
    [index : i64 0]
    [ok : bool (= count (ast.ast-expr-list-len expected))]
    (begin
      (while (and ok (< index count))
        (begin
          (when
            (not
              (=
                (ast.ast-expr-list-get actual index -1)
                (ast.ast-expr-list-get expected index -2)))
            (set! ok false))
          (set! index (+ index 1))))
      ok)))

(define (producer-test-tuple-result-ok?
  [pools : ast.AstNodePoolContext]
  [expected : (& expected ast.AstExprList)]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.Tuple items)
          (producer-test-tuple-items-eq? (& items) expected)]
        [_ false])]
    [_ false]))

;; Variadic tuple templates reuse the list-splice path. Exercise the empty and
;; singleton boundaries explicitly; a larger splice is covered by the fixed
;; tuple and the package's existing variadic template fixtures.
(define (producer-test-dispatch-tuple-splice?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [count : i64]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [value : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "value")))]
    [items : ast.AstExprList
      (if (= count 0)
        (ast.ast-expr-list-new)
        (ast.ast-expr-cons value (ast.ast-expr-list-new)))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.ExprList
          (owned_view.compiler-owned-shared-view items)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (producer-test-tuple-result-ok? pools (& items)))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-dispatch-tuple-fixed?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [first : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "first")))]
    [second : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "second")))]
    [expected : ast.AstExprList
      (ast.ast-expr-cons
        first
        (ast.ast-expr-cons second (ast.ast-expr-list-new)))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 2)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr first (ast.AstType.Expr)))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.Expr second (ast.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        2
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (producer-test-tuple-result-ok? pools (& expected)))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-dispatch-tuple-marked?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [value : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "value")))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr value (ast.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
                  [(compiler_ctfe.CompilerCtfeValue.Expr node _)
                    (match (producer-test-expr-get (& pools) node)
                      [(ast.AstExpr.Tuple items)
                        (and
                          (= (ast.ast-expr-list-len (& items)) 2)
                          (match (producer-test-expr-get
                            (& pools)
                            (ast.ast-expr-list-get (& items) 0 -1))
                            [(ast.AstExpr.Var name)
                              (= name (producer-test-name-id "tuple-marker"))]
                            [_ false])
                          (= (ast.ast-expr-list-get (& items) 1 -1) value))]
                      [_ false])]
                  [_ false]))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; Drive the computed expr-struct-set entry with the two interpreted field
;; value kinds and with each malformed operand position. Modes 0/1 are a
;; structural reflected Name and a generated String; modes 2/3/4 corrupt the
;; field, target, and value respectively and must fail without committing.
;; Refs #5999.
(define (producer-test-dispatch-struct-set?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [mode : i64]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [target : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "struct-target")))]
    [value : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "struct-value")))]
    [source-name-id : i64 (ci.intern "name-field")]
    [structural-name-id : i64 (producer-test-macro-global-id source-name-id)]
    [string-value : compiler_ctfe.CompilerCtfeValue
      (compiler_ctfe.ctfe-generated-string-value "string-field")]
    [expected-env : compiler_ctfe.CtfeEnv
      (compiler_ctfe.ctfe-env-empty-with-pools
        (owned_view.compiler-owned-shared-view pools))]
    [expected-string-id : i64
      (match (owned_view.compiler-owned-shared-view string-value)
        [(compiler_ctfe.CompilerCtfeValue.String text string-id)
          (compiler_ctfe.ctfe-string-syntax-name-id
            (compiler_ctfe.ctfe-env-source-names (& expected-env))
            text
            string-id)]
        [_ -1])]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 3)]
    (begin
      (set!
        (array-ref operands 0)
        (if (= mode 3)
          (compiler_ctfe.CompilerCtfeValue.Bool false)
          (compiler_ctfe.CompilerCtfeValue.Expr target (ast.AstType.Expr))))
      (set!
        (array-ref operands 1)
        (cond
          [(= mode 0)
            (compiler_ctfe.CompilerCtfeValue.Name
              "name-field"
              structural-name-id)]
          [(= mode 2) (compiler_ctfe.CompilerCtfeValue.Bool false)]
          [else string-value]))
      (set!
        (array-ref operands 2)
        (if (= mode 4)
          (compiler_ctfe.CompilerCtfeValue.Bool false)
          (compiler_ctfe.CompilerCtfeValue.Expr value (ast.AstType.Expr))))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        3
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (if (< mode 2)
                (and
                  (= dispatch.status tlci.tlci-host-callback-status-ok)
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
                    [(compiler_ctfe.CompilerCtfeValue.Expr
                        node
                        (ast.AstType.Unit))
                      (match (producer-test-expr-get (& pools) node)
                        [(ast.AstExpr.StructSet
                            actual-target
                            actual-field
                            actual-value)
                          (and
                            (= actual-target target)
                            (=
                              actual-field
                              (if (= mode 0)
                                structural-name-id
                                expected-string-id))
                            (= actual-value value))]
                        [_ false])]
                    [_ false]))
                (and
                  (= dispatch.status tlci.tlci-host-callback-status-bad-request)
                  (not
                    (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?))))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; Drive a quasiquoted `(set! ,place ,value)` through each place shape accepted
;; by interpreted CTFE, plus one rejected shape whose diagnostic must remain
;; byte-identical. The unquoted place nodes retain their call-site name/field
;; identities rather than receiving template-source marks. Refs #6550.
(define (producer-test-dispatch-dynamic-set?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [mode : i64]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [receiver : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "dynamic-receiver")))]
    [field : i64 (ci.intern "dynamic-field")]
    [place : i64
      (producer-test-push-spanned
        (& pools)
        (cond
          [(= mode 0) (ast.AstExpr.Var (ci.intern "dynamic-var"))]
          [(= mode 1) (ast.AstExpr.StructGet receiver field)]
          [(= mode 2) (ast.AstExpr.BoxGet receiver)]
          [else (ast.AstExpr.Literal (ast.AstLiteral.Bool true))]))]
    [value : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "dynamic-value")))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 2)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr place (ast.AstType.Expr)))
      (set!
        (array-ref operands 1)
        (compiler_ctfe.CompilerCtfeValue.Expr value (ast.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        2
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (if (= mode 3)
                (and
                  (= dispatch.status tlci.tlci-host-callback-status-diagnostic)
                  (not
                    (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?))
                  (string.eq
                    (compiler_embedded_stdlib_tlci.compiler-comptime-host-diagnostic-text)
                    "quasiquote set! target must evaluate to a name, struct field place, or box place"))
                (and
                  (= dispatch.status tlci.tlci-host-callback-status-ok)
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
                    [(compiler_ctfe.CompilerCtfeValue.Expr
                        node
                        (ast.AstType.Unit))
                      (match (producer-test-expr-get (& pools) node)
                        [(ast.AstExpr.Set name actual-value)
                          (and
                            (= mode 0)
                            (= name (ci.intern "dynamic-var"))
                            (= actual-value value))]
                        [(ast.AstExpr.StructSet
                            actual-receiver
                            actual-field
                            actual-value)
                          (and
                            (= mode 1)
                            (= actual-receiver receiver)
                            (= actual-field field)
                            (= actual-value value))]
                        [(ast.AstExpr.BoxSet actual-receiver actual-value)
                          (and
                            (= mode 2)
                            (= actual-receiver receiver)
                            (= actual-value value))]
                        [_ false])]
                    [_ false])))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;: Owner arena for the smoke's image loads. Every one of them releases the
;: image before returning, so the arena current at the load already
;: outlives it.
(define (producer-test-image-owner-arena) : i64
  (arena.tl_arena_current))

(define (producer-test-emitted-bytes-ok?
  [bytes : (__tl_dyn-array u8)]
  [template-identity : String]
  [template-callee : String]
  [fold-identity : String]
  [fallback-identity : String]) : bool
  (match (tlci_loader.tlci-loader-load-from-bytes-with-host
    (producer-test-image-owner-arena)
    bytes
    (compiler_embedded_stdlib_tlci.compiler-comptime-host-table))
    [(tlci_loader.ResultTlciLoadedImage.Err _) false]
    [(tlci_loader.ResultTlciLoadedImage.Ok loaded)
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
              [fallback-operands : (__tl_dyn-array
                compiler_ctfe.CompilerCtfeValue)
                (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
              (begin
                (set!
                  (array-ref fallback-operands 0)
                  (producer-test-expr-operand "value"))
                (producer-test-dispatch-with?
                  (& loaded)
                  fallback-identity
                  fallback-operands
                  1
                  true))))]
        (match (tlci_loader.tlci-loader-release loaded)
          [(tlci_loader.ResultTlciLoaderUnit.Ok) ok]
          [(tlci_loader.ResultTlciLoaderUnit.Err _) false]))]))

;; Compile the checked-in scoped concatenator itself, then exercise every
;; fixed-arity branch with both all-borrowable and mixed expression shapes.
;; This keeps the focused producer smoke byte-for-byte aligned with the stdlib
;; macro instead of maintaining a simplified copy. Refs #5656.
(define (producer-test-str-cat-scoped-native-image-ok?) : bool
  (let
    [source : String
      (byte_buf.to-string (io.read-file "stdlib/str_cat_runtime.tl"))]
    [names : producer_test_svec.Vec (producer_test_svec.new)]
    [captures : compiler_tlci_native_producer.TlciNativeMacroCaptures
      (compiler_tlci_native_producer.tlci-native-macro-captures-new)]
    (match (parse_core.parse-ast-source source)
      [(parse_core.ResultAstProgram.Err _) false]
      [(parse_core.ResultAstProgram.Ok program)
        (match program
          [(ast.AstProgram.Program decls)
            (begin
              (producer-test-collect-decls!
                (owned_view.compiler-owned-box-shared-view decls)
                "stdlib.str_cat_runtime"
                (&mut names)
                (&mut captures))
              (let
                [name-count : i64 (producer_test_svec.len (& names))]
                [name-array : (__tl_dyn-array String)
                  (__tl_make-array String name-count)]
                [name-index : i64 0]
                [_copy-names : unit
                  (while (< name-index name-count)
                    (begin
                      (set!
                        (array-ref name-array name-index)
                        (producer_test_svec.get (& names) name-index ""))
                      (set! name-index (+ name-index 1))))]
                (match (compiler_tlci_native_producer.embedded-native-emit-package
                  (tlci.tlci-metadata-emit
                    (tlci.tlci-make-metadata "v1" "str-cat-scoped-test" "0.1.0"))
                  "producer-test"
                  (cfg windows true false)
                  (tlci.tlci-empty-bytes)
                  (owned_view.compiler-owned-shared-view name-array)
                  (& captures))
                  [(compiler_tlci_native_producer.ResultProducerBytes.Err _)
                    false]
                  [(compiler_tlci_native_producer.ResultProducerBytes.Ok bytes)
                    (match (tlci_loader.tlci-loader-load-from-bytes-with-host
                      (producer-test-image-owner-arena)
                      bytes
                      (compiler_embedded_stdlib_tlci.compiler-comptime-host-table))
                      [(tlci_loader.ResultTlciLoadedImage.Err _) false]
                      [(tlci_loader.ResultTlciLoadedImage.Ok loaded)
                        (let
                          [ok : bool
                            (and
                              (producer-test-dispatch-scoped-cat?
                                (& loaded)
                                2
                                false)
                              (producer-test-dispatch-scoped-cat?
                                (& loaded)
                                2
                                true)
                              (producer-test-dispatch-scoped-cat?
                                (& loaded)
                                3
                                false)
                              (producer-test-dispatch-scoped-cat?
                                (& loaded)
                                3
                                true)
                              (producer-test-dispatch-scoped-cat?
                                (& loaded)
                                4
                                false)
                              (producer-test-dispatch-scoped-cat?
                                (& loaded)
                                4
                                true)
                              (producer-test-dispatch-scoped-cat?
                                (& loaded)
                                5
                                false)
                              (producer-test-dispatch-scoped-cat?
                                (& loaded)
                                5
                                true))]
                          (match (tlci_loader.tlci-loader-release loaded)
                            [(tlci_loader.ResultTlciLoaderUnit.Ok) ok]
                            [(tlci_loader.ResultTlciLoaderUnit.Err _) false]))])])))])])))

(test
  str-cat-scoped-tlci-native-producer
  (unless
    (producer-test-str-cat-scoped-native-image-ok?)
    (io.panic "str-cat-scoped tlci native producer test failed")))

(define (producer-test-bytes-eq?
  [left : (& left (__tl_dyn-array u8))]
  [right : (& right (__tl_dyn-array u8))]) : bool
  (let
    [count : i64 (array-length left)]
    [index : i64 0]
    [equal : bool (= count (array-length right))]
    (begin
      (while (and equal (< index count))
        (if (= (array-ref left index) (array-ref right index))
          (set! index (+ index 1))
          (set! equal false)))
      equal)))

(define (producer-test-string-count [text : String] [needle : String]) : i64
  (let
    [needle-len : i64 (string.string-length needle)]
    [limit : i64 (string.string-length text)]
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (and (> needle-len 0) (<= (+ index needle-len) limit))
        (begin
          (when
            (string.is-string-prefix-at text needle index)
            (set! count (+ count 1)))
          (set! index (+ index 1))))
      count)))

;; Full blocker diagnostics use a second, non-emitting traversal. Two rejected
;; sibling template nodes prove it continues after the first, while comparing
;; the complete package bytes and coverage counters proves that recovery text
;; never escapes into the image-producing pass. Refs #5742.
(define (producer-test-full-blocker-second-pass-ok?
  [captures
    : (& captures compiler_tlci_native_producer.TlciNativeMacroCaptures)]
  [default-bytes : (& default-bytes (__tl_dyn-array u8))]
  [default-report : String]
  [default-native : i64]
  [default-partial : i64]
  [default-arms : i64]) : bool
  (begin
    (compiler_tlci_native_producer.embedded-native-full-blocker-report-set!
      true)
    (match (compiler_tlci_native_producer.embedded-native-emit-package
      (tlci.tlci-metadata-emit
        (tlci.tlci-make-metadata "v1" "diagnostics" "0.1.0"))
      "producer-full-blocker-test"
      (cfg windows true false)
      (tlci.tlci-empty-bytes)
      (__tl_make-array "package.multi/multi")
      captures)
      [(compiler_tlci_native_producer.ResultProducerBytes.Err _)
        (begin
          (compiler_tlci_native_producer.embedded-native-full-blocker-report-set!
            false)
          false)]
      [(compiler_tlci_native_producer.ResultProducerBytes.Ok full-bytes)
        (let
          [full-report : String
            (string.copy
              (&
                (array-ref
                  compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-full-reasons
                  0)))]
          [_reset-mode : unit
            (compiler_tlci_native_producer.embedded-native-full-blocker-report-set!
              false)]
          (and
            (string.eq
              default-report
              "package.multi/multi\ttemplate-node:in-arena\n")
            (=
              (producer-test-string-count
                (owned_view.compiler-owned-shared-view full-report)
                "package.multi/multi\tblocked\ttemplate-node:in-arena\n")
              1)
            (=
              (producer-test-string-count
                (owned_view.compiler-owned-shared-view full-report)
                "package.multi/multi\tblocked\ttemplate-node:with-arena\n")
              1)
            (=
              (producer-test-string-count
                (owned_view.compiler-owned-shared-view full-report)
                "package.multi/multi\twalked\ttemplate-node:begin\n")
              1)
            (producer-test-bytes-eq? default-bytes (& full-bytes))
            (= default-native 0)
            (=
              default-native
              (array-ref
                compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-count
                0))
            (=
              default-partial
              (array-ref
                compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-partial-count
                0))
            (=
              default-arms
              (array-ref
                compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-interpreted-arms
                0))))])))

(define (producer-test-full-blocker-default-pass-ok?
  [captures
    : (& captures compiler_tlci_native_producer.TlciNativeMacroCaptures)]) : bool
  (begin
    (compiler_tlci_native_producer.embedded-native-full-blocker-report-set!
      false)
    (match (compiler_tlci_native_producer.embedded-native-emit-package
      (tlci.tlci-metadata-emit
        (tlci.tlci-make-metadata "v1" "diagnostics" "0.1.0"))
      "producer-full-blocker-test"
      (cfg windows true false)
      (tlci.tlci-empty-bytes)
      (__tl_make-array "package.multi/multi")
      captures)
      [(compiler_tlci_native_producer.ResultProducerBytes.Err _) false]
      [(compiler_tlci_native_producer.ResultProducerBytes.Ok default-bytes)
        (producer-test-full-blocker-second-pass-ok?
          captures
          (& default-bytes)
          (string.copy
            (&
              (array-ref
                compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-reasons
                0)))
          (array-ref
            compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-count
            0)
          (array-ref
            compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-partial-count
            0)
          (array-ref
            compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-interpreted-arms
            0))])))

(define (producer-test-full-blocker-report-ok?) : bool
  (let
    [names : producer_test_svec.Vec (producer_test_svec.new)]
    [captures : compiler_tlci_native_producer.TlciNativeMacroCaptures
      (compiler_tlci_native_producer.tlci-native-macro-captures-new)]
    (match (parse_core.parse-ast-source
      "(module package.multi)\n(defmacro (multi [value : Expr]) : Expr `(begin (in-arena a value) (with-arena a value) ,value))\n")
      [(parse_core.ResultAstProgram.Err _) false]
      [(parse_core.ResultAstProgram.Ok program)
        (match program
          [(ast.AstProgram.Program decls)
            (begin
              (producer-test-collect-decls!
                (owned_view.compiler-owned-box-shared-view decls)
                ""
                (&mut names)
                (&mut captures))
              (and
                (= (producer_test_svec.len (& names)) 1)
                (= captures.len 1)
                (producer-test-full-blocker-default-pass-ok? (& captures))))])])))

(test
  full-blocker-report-tlci-native-producer
  (unless
    (producer-test-full-blocker-report-ok?)
    (io.panic "full blocker report tlci native producer test failed")))

;; Direct host coverage for the captured type-list projection and boxed-type
;; reflection added for stdlib.clone. Modes exercise success, a non-type item,
;; a non-box type, an out-of-range index, and a non-list operand respectively.
;; Refs #6552.
(define (producer-test-type-list-callbacks-ok? [mode : i64]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [inner-id : i64
      (ast.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view pools)
        (ast.AstType.I64))]
    [outer-id : i64
      (ast.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view pools)
        (if (= mode 2)
          (ast.AstType.I64)
          (ast.AstType.Box inner-id)))]
    [node : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view pools)
        (if (= mode 1)
          (ast.AstExpr.Var (ci.intern "not-a-type"))
          (ast.AstExpr.TypeLiteral outer-id)))]
    [items : ast.AstExprList (ast.ast-expr-cons node (ast.ast-expr-list-new))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (if (= mode 4)
          (compiler_ctfe.CompilerCtfeValue.Bool false)
          (compiler_ctfe.CompilerCtfeValue.CapturedExprList
            items
            (owned_view.compiler-owned-shared-view pools))))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [type-status : i64
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-list-type-nth
            producer-test-cookie
            0
            (if (= mode 3)
              1
              0)
            0)]
        [box-status : i64
          (if (and (= type-status tlci.tlci-host-callback-status-ok) (< mode 3))
            (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-box-element-type
              producer-test-cookie
              0
              0
              0)
            type-status)]
        [commit-status : i64
          (if (= mode 0)
            (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-commit-result
              producer-test-cookie
              0
              0
              0)
            box-status)]
        [ok : bool
          (cond
            [(= mode 0)
              (and
                (= commit-status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
                  [(compiler_ctfe.CompilerCtfeValue.Type (ast.AstType.I64))
                    true]
                  [_ false]))]
            [(= mode 1)
              (and
                (= box-status tlci.tlci-host-callback-status-diagnostic)
                (string.eq
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-diagnostic-text)
                  "expr-list-type-nth expects a captured type literal"))]
            [(= mode 2)
              (and
                (= box-status tlci.tlci-host-callback-status-diagnostic)
                (string.eq
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-diagnostic-text)
                  "box-element-type requires box type"))]
            [(= mode 3)
              (and
                (= box-status tlci.tlci-host-callback-status-diagnostic)
                (string.eq
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-diagnostic-text)
                  "array-ref index out of range"))]
            [else
              (and
                (= box-status tlci.tlci-host-callback-status-diagnostic)
                (string.eq
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-diagnostic-text)
                  "expr-list-type-nth expects an ExprList"))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-type-expr-callback-ok? [valid : bool]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [box-ty : ast.AstType
      (ast.ast-ty-box-with-pools
        (owned_view.compiler-owned-shared-view pools)
        (ast.AstType.I64))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (if valid
          (compiler_ctfe.CompilerCtfeValue.Type
            (owned_view.compiler-owned-shared-view box-ty))
          (compiler_ctfe.CompilerCtfeValue.Bool false)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [push-status : i64
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
            producer-test-cookie
            0
            0
            0)]
        [type-expr-status : i64
          (if (= push-status tlci.tlci-host-callback-status-ok)
            (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-type-expr
              producer-test-cookie
              0
              0
              0)
            push-status)]
        [commit-status : i64
          (if (and valid (= type-expr-status tlci.tlci-host-callback-status-ok))
            (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-commit-result
              producer-test-cookie
              0
              0
              0)
            type-expr-status)]
        [ok : bool
          (if valid
            (and
              (= commit-status tlci.tlci-host-callback-status-ok)
              (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
                [(compiler_ctfe.CompilerCtfeValue.Expr node (ast.AstType.Expr))
                  (match (producer-test-expr-get pools node)
                    [(ast.AstExpr.TypeLiteral ty-id)
                      (compiler_ctfe.ctfe-type-eq
                        (ast.ast-node-pool-context-type-get pools ty-id)
                        box-ty)]
                    [_ false])]
                [_ false]))
            (and
              (= commit-status tlci.tlci-host-callback-status-bad-request)
              (not
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?))))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-expr-string-value-callback-ok? [literal : bool]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [string-id : i64 (ci.intern "clone.module")]
    [node : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view pools)
        (if literal
          (ast.AstExpr.Literal (ast.AstLiteral.String string-id))
          (ast.AstExpr.Var (ci.intern "not-a-string"))))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.CapturedExpr
          node
          (ast.AstType.Expr)
          (owned_view.compiler-owned-shared-view pools)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [push-status : i64
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
            producer-test-cookie
            0
            0
            0)]
        [value-status : i64
          (if (= push-status tlci.tlci-host-callback-status-ok)
            (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-string-value
              producer-test-cookie
              0
              0
              0)
            push-status)]
        [commit-status : i64
          (if (and literal (= value-status tlci.tlci-host-callback-status-ok))
            (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-commit-result
              producer-test-cookie
              0
              0
              0)
            value-status)]
        [ok : bool
          (if literal
            (and
              (= commit-status tlci.tlci-host-callback-status-ok)
              (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
                [(compiler_ctfe.CompilerCtfeValue.String text actual-id)
                  (and (string.eq text "clone.module") (= actual-id string-id))]
                [_ false]))
            (and
              (= commit-status tlci.tlci-host-callback-status-diagnostic)
              (string.eq
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-diagnostic-text)
                "expr-string-value expects a string literal Expr")))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; A generated String carries an identity from the compile job that created it.
;; The native host must use that same job's source-name boundary when turning
;; the String back into syntax: equal text in the compatibility-global session
;; is not the same identity domain. Refs #5262.
(define (producer-test-string-var-preserves-source-session?) : bool
  (let
    [state : ci.InternCompatState (ci.intern-compat-state-new)]
    [source-id : i64
      (ci.intern-compat-state-intern (&mut state) "clone.module")]
    [source-names : ci.InternSourceNameSessionHandle
      (ci.intern-source-name-session-handle-from-state (& state))]
    [generated-id : i64
      (ci.intern-compat-state-generated-name (&mut state) "clone.module")]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open-with-macro-state!
        (owned_view.compiler-owned-shared-view pools)
        (& operands)
        0
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty)
        source-names
        (compiler_ctfe.compiler-ctfe-serial-macro-state))
      (let
        [push-status : i64
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-push!
            (compiler_ctfe.CompilerCtfeValue.String "clone.module" generated-id))]
        [var-status : i64
          (if (= push-status tlci.tlci-host-callback-status-ok)
            (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-var-from-value
              producer-test-cookie
              0
              0
              0)
            push-status)]
        [commit-status : i64
          (if (= var-status tlci.tlci-host-callback-status-ok)
            (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-commit-result
              producer-test-cookie
              0
              0
              0)
            var-status)]
        [ok : bool
          (and
            (= commit-status tlci.tlci-host-callback-status-ok)
            (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
              [(compiler_ctfe.CompilerCtfeValue.Expr node _)
                (match (producer-test-expr-get (& pools) node)
                  [(ast.AstExpr.Var name-id) (= name-id source-id)]
                  [_ false])]
              [_ false]))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; `expr-string-value` also accepts an identity-bearing Name that syntax
;; inspection turned into a string literal. The native host must render the
;; table-backed identity through the session supplied by this compile job while
;; preserving that identity in the returned String value.
(define (producer-test-expr-string-value-structural-id?) : bool
  (let
    [installed : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [state : ci.InternCompatState (ci.intern-compat-state-new)]
    [source-id : i64
      (ci.intern-compat-state-intern (&mut state) "structural.clone.module")]
    [_install : unit
      (ci.intern-compat-state-install! (ci.intern-global-shared-view state))]
    [source-names : ci.InternSourceNameSessionHandle
      (ci.intern-source-name-session-handle-from-state (& state))]
    [session : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names source-names)]
    [string-id : i64
      (cis.intern-macro-global-identity-raw
        (cis.intern-structural-session-macro-global-identity
          session
          cis.InternMacroGlobalRole.Context
          source-id
          source-id))]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [node : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view pools)
        (ast.AstExpr.Literal (ast.AstLiteral.String string-id)))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.CapturedExpr
          node
          (ast.AstType.Expr)
          (owned_view.compiler-owned-shared-view pools)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open-with-macro-state!
        (owned_view.compiler-owned-shared-view pools)
        (& operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty)
        source-names
        (compiler_ctfe.compiler-ctfe-serial-macro-state))
      (let
        [push-status : i64
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-push-operand
            producer-test-cookie
            0
            0
            0)]
        [value-status : i64
          (if (= push-status tlci.tlci-host-callback-status-ok)
            (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-expr-string-value
              producer-test-cookie
              0
              0
              0)
            push-status)]
        [commit-status : i64
          (if (= value-status tlci.tlci-host-callback-status-ok)
            (compiler_embedded_stdlib_tlci.compiler-comptime-host-callback-commit-result
              producer-test-cookie
              0
              0
              0)
            value-status)]
        [ok : bool
          (and
            (= commit-status tlci.tlci-host-callback-status-ok)
            (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
              [(compiler_ctfe.CompilerCtfeValue.String text actual-id)
                (and
                  (string.eq text "structural.clone.module")
                  (= actual-id string-id))]
              [_ false]))]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          (ci.intern-compat-state-install! installed)
          ok)))))

(test
  clone-host-callbacks-tlci-native-producer
  (unless
    (and
      (producer-test-type-list-callbacks-ok? 0)
      (producer-test-type-list-callbacks-ok? 1)
      (producer-test-type-list-callbacks-ok? 2)
      (producer-test-type-list-callbacks-ok? 3)
      (producer-test-type-list-callbacks-ok? 4)
      (producer-test-type-expr-callback-ok? true)
      (producer-test-type-expr-callback-ok? false)
      (producer-test-expr-string-value-callback-ok? true)
      (producer-test-expr-string-value-callback-ok? false)
      (producer-test-string-var-preserves-source-session?)
      (producer-test-expr-string-value-structural-id?))
    (io.panic "clone host callbacks tlci native producer test failed")))

(define (producer-test-clone-route-result-ok? [pools : ast.AstNodePoolContext]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.ExprList items)
      (and
        (= (ast.ast-expr-list-len (& items)) 2)
        (match (producer-test-expr-get
          (& pools)
          (ast.ast-expr-list-get (& items) 0 -1))
          [(ast.AstExpr.Call callee args)
            (and
              (match (producer-test-expr-get (& pools) callee)
                [(ast.AstExpr.Var name-id)
                  (= name-id (producer-test-name-id "module"))]
                [_ false])
              (= (ast.ast-expr-list-len (& args)) 1)
              (match (producer-test-expr-get
                (& pools)
                (ast.ast-expr-list-get (& args) 0 -1))
                [(ast.AstExpr.Var name-id)
                  (string.eq (ci.intern-str name-id) "clone.module")]
                [_ false]))]
          [_ false])
        (match (producer-test-expr-get
          (& pools)
          (ast.ast-expr-list-get (& items) 1 -1))
          [(ast.AstExpr.Call callee args)
            (and
              (match (producer-test-expr-get (& pools) callee)
                [(ast.AstExpr.Var name-id)
                  (= name-id (producer-test-name-id "marker"))]
                [_ false])
              (= (ast.ast-expr-list-len (& args)) 1)
              (match (producer-test-expr-get
                (& pools)
                (ast.ast-expr-list-get (& args) 0 -1))
                [(ast.AstExpr.Var name-id)
                  (string.eq (ci.intern-str name-id) "i64")]
                [_ false]))]
          [_ false]))]
    [_ false]))

;; Miniature clone route: captured TypeLiteral projection, computed string
;; extraction, a match-valued expr-list-cons tail, and boxed element reflection
;; must all run inside one native entry. Refs #6552.
(define (producer-test-dispatch-clone-route?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [inner-id : i64
      (ast.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view pools)
        (ast.AstType.I64))]
    [box-id : i64
      (ast.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view pools)
        (ast.AstType.Box inner-id))]
    [type-node : i64
      (producer-test-push-spanned (& pools) (ast.AstExpr.TypeLiteral box-id))]
    [module-node : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Literal (ast.AstLiteral.String (ci.intern "clone.module"))))]
    [items : ast.AstExprList
      (ast.ast-expr-cons
        type-node
        (ast.ast-expr-cons module-node (ast.ast-expr-list-new)))]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.CapturedExprList
          items
          (owned_view.compiler-owned-shared-view pools)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        256
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (producer-test-clone-route-result-ok? pools))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-literal-match-result-ok?
  [pools : ast.AstNodePoolContext]
  [expected-callee : String]
  [expected-value : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (match (producer-test-expr-get (& pools) node)
        [(ast.AstExpr.Call callee args)
          (and
            (match (producer-test-expr-get (& pools) callee)
              [(ast.AstExpr.Var name-id)
                (= name-id (producer-test-name-id expected-callee))]
              [_ false])
            (= (ast.ast-expr-list-len (& args)) 1)
            (match (producer-test-expr-get
              (& pools)
              (ast.ast-expr-list-get (& args) 0 -1))
              [(ast.AstExpr.Literal (ast.AstLiteral.Int value _))
                (= value expected-value)]
              [_ false]))]
        [_ false])]
    [_ false]))

;; A miniature sort/serialize classifier: ordered String-literal arms produce
;; both bool and i64 data locals, and the bool selects one of two computed Expr
;; initializers. Modes 0/1/2 exercise the first, later, and wildcard arms;
;; mode 3 proves a malformed non-type operand fails closed. Refs #6554, #6555.
(define (producer-test-dispatch-literal-match-route?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]
  [identity : String]
  [mode : i64]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    (begin
      (set!
        (array-ref operands 0)
        (if (= mode 3)
          (compiler_ctfe.CompilerCtfeValue.Bool false)
          (compiler_ctfe.CompilerCtfeValue.Type
            (cond
              [(= mode 0) (ast.AstType.I64)]
              [(= mode 1) (ast.AstType.F64)]
              [else (ast.AstType.String)]))))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        128
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            identity
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (if (= mode 3)
                (and
                  (= dispatch.status tlci.tlci-host-callback-status-bad-request)
                  (not
                    (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)))
                (and
                  (= dispatch.status tlci.tlci-host-callback-status-ok)
                  (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                  (producer-test-literal-match-result-ok?
                    pools
                    (if (= mode 2)
                      "custom"
                      "scalar")
                    (cond [(= mode 0) 7] [(= mode 1) 9] [else 11]))))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; In-package coverage: every supported shape dispatches natively and the
;; let-rooted body stays a counted shell. The report count must equal the
;; number of supported entries, and the arm-level counters must count every
;; site that hands the scrutinee back to the interpreter. Two entries here do:
;; `kindwild`, whose wildcard body is outside the supported subset, and
;; `kindfull`, which has no wildcard at all and so falls off the end of its arm
;; chain for any type that is neither `i64` nor `f64`. The second was
;; previously uncounted -- the chain terminator emitted the ok-with-no-result
;; form without the marker -- which made a non-exhaustive dispatch look fully
;; native. Refs #5596, #5604.
(define (producer-test-package-native-image-ok?) : bool
  (let
    [source-base : String
      "(module package.macros)
(defmacro (wrap [value : Expr]) : Expr `(identity ,value))
(defmacro (fold [items : Expr ...]) : bool (comptime.expr-list-fold-if items (comptime.expr-bool true) (comptime.expr-bool false) true))
(defmacro (unsupported [value : Expr]) : Expr (match value [(comptime.Expr.If c t e) c] [_ value]))
(defmacro (nest [value : Expr]) : Expr `(stdlib.json.JsonValue (stdlib.json.JsonBool ,value)))
(defmacro (ident [value : Expr]) : Expr value)
(defmacro (whenlike [condition : bool] [body : unit ...]) : unit (if (= (comptime.expr-list-length body) 0) (comptime.expr-var \"core-when-missing-body\") `(if ,condition (begin ,@body) unit)))
(defmacro (lits [value : Expr]) : Expr `(f \"a\\tb\" 'x' -7 true))
(defmacro (qqvar [value : Expr]) : Expr `some.nil)
(defmacro (tytpl [T : type] [value : Expr]) : Expr `(stdlib.eq.struct-eq-fields ,T 0 ,value))
(defmacro (gen [T : type] [value : Expr]) : Module (let [module-name : Expr (expr-var (comptime.string-append \"test.gen.\" (type-key T)))] `(begin (module ,module-name) (define (id [x : ,T]) : ,T x))))
(defmacro (localtype [T : type] [value : Expr]) : Expr (let [U : type T] `(cast ,value : ,U)))
(defmacro (lambdatpl [T : type]) : Expr `(lambda ([value : ,T]) : ,T value))
(defmacro (lambda1 [anchors : Expr]) : Expr (let [T : Expr (comptime.expr-type anchors)] [name : String (comptime.syntax-name-fresh \"lambda1-values\")] [values : Expr (comptime.expr-var name)] [body : Expr (comptime.expr-tuple-ref values 1)] (comptime.expr-lambda1 name T body)))
(defmacro (modname [format : Module]) : Expr (comptime.expr-var (comptime.module-name format)))
(defmacro (modhook [format : Module]) : Expr (comptime.module-hook format \"object-field\"))
(defmacro (classify [value : Expr]) : Expr `(match value [(Some _) true] [None false]))
(defmacro (twice [value : Expr]) : Expr `(begin (set! flag 1) (set! flag 2)))
(defmacro (catlike [args : String ...]) : String (match (comptime.expr-list-length args) [0 `\"\"] [1 (comptime.expr-list-nth args 0)] [2 `(concat2 ,(comptime.expr-list-nth args 0) ,(comptime.expr-list-nth args 1))] [n `(concat-all (pack (__args ,@args) ,(comptime.expr-int n)))]))
(defmacro (pushlike [carrier : Expr] [piece : Expr]) : Expr (match carrier [(comptime.Expr.Call callee pieces) `(,callee ,@pieces ,piece)] [_ carrier]))
(defmacro (finishlike [carrier : Expr]) : Expr (match carrier [(comptime.Expr.Call _ pieces) `(joined ,@pieces)] [_ `\"\"]))
(defmacro (kindfull [T : type] [value : Expr]) : Expr (match (type-kind T) [\"i64\" `(kind-i64 ,value)] [\"f64\" `(kind-f64 ,value)]))
(defmacro (kindly [T : type] [value : Expr]) : Expr (match (type-kind T) [\"i64\" `(kind-i64 ,value)] [other (comptime.comptime-error \"kindly: unsupported\")]))
(defmacro (kindwild [T : type] [value : Expr]) : Expr (match (type-kind T) [\"i64\" `(kind-i64 ,value)] [_ `(kind-other ,value)]))
(defmacro (places [value : Expr]) : Expr `(match ,value [(Some inner) (begin (set! inner.len 1.5) (deref (box inner)))] [_ (return ,value)]))
(defmacro (foldlike [carrier : Expr] [acc : Expr] [idx : Expr]) : Expr (match idx [(comptime.Expr.Int i) (match carrier [(comptime.Expr.Call _ elems) (if (>= i (comptime.expr-list-length elems)) acc `(foldlike ,carrier (step ,acc ,(comptime.expr-list-nth elems i)) ,(comptime.expr-int (+ i 1))))] [_ acc])] [_ acc]))
(defmacro (kindof [value : Expr]) : Expr (match (type-kind (comptime.expr-type value)) [\"f64\" `(f64-op ,value)] [_ `(other ,value)]))
(defmacro (keyof [T : type] [value : Expr]) : Expr (match (type-key T) [\"i64\" `(i64-op (cast ,value : i64))] [_ `(other ,value)]))
(defmacro (rawptr [value : Expr]) : Expr `(unsafe (ptr-write! (ptr-offset (string-data ,value) 1) (ptr-read (ptr-offset (__tl_array-data ,value) 2))) (string-from-bytes (string-data ,value) (ptr->int (string-data ,value)))))
(defmacro (strval [value : Expr]) : Expr (comptime.expr-var (comptime.expr-string-value value)))
(defmacro (typeof [value : Expr]) : Expr `(marker ,(comptime.expr-type value)))
(defmacro (typeexpr [T : type]) : Expr (comptime.type-expr T))
(defmacro (typeexprlist [T : type]) : ExprList (comptime.expr-list-cons (comptime.type-expr T) (comptime.expr-list-empty)))
(defmacro (aliaslike [value : Expr] [idx : Expr]) : Expr (match idx [(comptime.Expr.Int i) (match value [(comptime.Expr.Var t) (comptime.expr-var (comptime.string-append (comptime.string-append t \"_n\") (comptime.int->string i)))] [_ value])] [_ value]))
(defmacro (typetpl [value : Expr]) : Expr `(let [a : (Ptr u8) (ptr-cast (string-data ,value) : (Ptr u8))] [b : (__tl_dyn-array i64) ,value] [c : (& region str) ,value] [d : (Box i64) ,value] [e : (Array i64 4) ,value] [f : (Slice i64) ,value] [g : (LifetimeOne text) ,value] [h : (LifetimePair left right) ,value] (marker a b c d e f g h)))
(defmacro (scan [text : Expr]) : Expr (if (comptime.expr-string? text) (let [s : String (comptime.expr-string-value text)] [n : i64 (string.string-length s)] (if (= (cast (string.string-ref s 0) : i64) 123) `(brace ,(comptime.expr-int n)) `(plain ,(comptime.expr-string (comptime.string-slice s 1 (- n 1)))))) (comptime.comptime-error \"scan: expects a string literal\")))
(defmacro (clonepath [items : Expr ...]) : ExprList (let [T : Expr (comptime.expr-list-type-nth items 0)] [module-name : Expr (comptime.expr-var (comptime.expr-string-value (comptime.expr-list-nth items 1)))] (comptime.expr-list-cons `(module ,module-name) (match (type-kind T) [\"box\" (comptime.expr-list-cons `(marker ,(comptime.box-element-type T)) (comptime.expr-list-empty))] [_ (comptime.expr-list-empty)]))))
"]
    [source : String
      (str_cat.str-cat
        source-base
        "(defmacro (literalmatch [T : type]) : Expr (let [kind : String (type-kind T)] [scalar? : bool (match kind [\"i64\" true] [\"f64\" true] [_ false])] [rank : i64 (match kind [\"i64\" 7] [\"f64\" 9] [_ 11])] [selected : Expr (if scalar? `(scalar ,(comptime.expr-int rank)) `(custom ,(comptime.expr-int rank)))] selected))\n"
        "(defmacro (tuplepack [items : Expr ...]) : Expr `(tuple ,@items))\n(defmacro (tuplepair [a : Expr] [b : Expr]) : Expr `(tuple ,a ,b))\n(defmacro (tuplemarked [value : Expr]) : Expr `(tuple tuple-marker ,value))\n(defmacro (nommod [T : type]) : String (type-nominal-module T))\n(defmacro (nameidentity [value : Expr]) : Expr (match value [(comptime.Expr.Var name) (comptime.expr-var name)] [_ value]))\n(defmacro (structset [target : Expr] [field : String] [value : Expr]) : Expr (comptime.expr-struct-set target field value))\n(defmacro (dynamicset [place : Expr] [value : Expr]) : Expr `(set! ,place ,value))\n")]
    [names : producer_test_svec.Vec (producer_test_svec.new)]
    [captures : compiler_tlci_native_producer.TlciNativeMacroCaptures
      (compiler_tlci_native_producer.tlci-native-macro-captures-new)]
    (match (parse_core.parse-ast-source source)
      [(parse_core.ResultAstProgram.Err _) false]
      [(parse_core.ResultAstProgram.Ok program)
        (match program
          [(ast.AstProgram.Program decls)
            (begin
              (producer-test-collect-decls!
                (owned_view.compiler-owned-box-shared-view decls)
                ""
                (&mut names)
                (&mut captures))
              (producer-test-add-decls-capture! (&mut names) (&mut captures))
              (let
                [name-count : i64 (producer_test_svec.len (& names))]
                [name-array (__tl_make-array String name-count)]
                [name-index : i64 0]
                [_copy-names : unit
                  (while (< name-index name-count)
                    (begin
                      (set!
                        (array-ref name-array name-index)
                        (producer_test_svec.get (& names) name-index ""))
                      (set! name-index (+ name-index 1))))]
                (match (compiler_tlci_native_producer.embedded-native-emit-package
                  (tlci.tlci-metadata-emit
                    (tlci.tlci-make-metadata "v1" "package" "0.1.0"))
                  "producer-test"
                  (cfg windows true false)
                  (tlci.tlci-empty-bytes)
                  (owned_view.compiler-owned-shared-view name-array)
                  (& captures))
                  [(compiler_tlci_native_producer.ResultProducerBytes.Err
                      message)
                    (begin
                      (io.print-error
                        (str_cat.str-cat "producer error: " message))
                      (io.print-error "\n")
                      false)]
                  [(compiler_tlci_native_producer.ResultProducerBytes.Ok bytes)
                    (match (tlci_loader.tlci-loader-load-from-bytes-with-host
                      (producer-test-image-owner-arena)
                      bytes
                      (compiler_embedded_stdlib_tlci.compiler-comptime-host-table))
                      [(tlci_loader.ResultTlciLoadedImage.Err message)
                        (begin
                          (io.print-error
                            (str_cat.str-cat "loader error: " message))
                          (io.print-error "\n")
                          false)]
                      [(tlci_loader.ResultTlciLoadedImage.Ok loaded)
                        (let
                          [ok : bool
                            (and
                              (= (array-length name-array) 45)
                              (= captures.len 45)
                              (=
                                (array-ref
                                  compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-count
                                  0)
                                44)
                              (=
                                (array-ref
                                  compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-partial-count
                                  0)
                                2)
                              (=
                                (array-ref
                                  compiler_tlci_native_producer.embedded-stdlib-tlci-native-report-interpreted-arms
                                  0)
                                2)
                              (producer-test-dispatch-lambda1?
                                (& loaded)
                                "package.macros/lambda1")
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
                              (producer-test-dispatch-local-type?
                                (& loaded)
                                "package.macros/localtype")
                              (producer-test-dispatch-lambda?
                                (& loaded)
                                "package.macros/lambdatpl")
                              (producer-test-dispatch-module-name?
                                (& loaded)
                                "package.macros/modname"
                                "toy.format")
                              (producer-test-dispatch-module-hook?
                                (& loaded)
                                "package.macros/modhook"
                                "toy.format"
                                "object-field")
                              (producer-test-dispatch-module-hook-missing?
                                (& loaded)
                                "package.macros/modhook"
                                "toy.empty"
                                "object-field")
                              (producer-test-dispatch-decls?
                                (& loaded)
                                "package.macros/decls")
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
                              (producer-test-dispatch-kindof?
                                (& loaded)
                                "package.macros/kindof")
                              (producer-test-dispatch-keyof?
                                (& loaded)
                                "package.macros/keyof")
                              (producer-test-dispatch-nominal-module?
                                (& loaded)
                                "package.macros/nommod"
                                0)
                              (producer-test-dispatch-nominal-module?
                                (& loaded)
                                "package.macros/nommod"
                                1)
                              (producer-test-dispatch-nominal-module?
                                (& loaded)
                                "package.macros/nommod"
                                2)
                              (producer-test-dispatch-nominal-module?
                                (& loaded)
                                "package.macros/nommod"
                                3)
                              (producer-test-nominal-module-string-eq?)
                              (producer-test-name-dotted-string-append?)
                              (producer-test-dispatch-shape?
                                (& loaded)
                                "package.macros/places"
                                "value"
                                7
                                "")
                              (producer-test-dispatch-shape?
                                (& loaded)
                                "package.macros/lits"
                                "value"
                                2
                                "")
                              (producer-test-dispatch-strval?
                                (& loaded)
                                "package.macros/strval")
                              (producer-test-dispatch-typeof?
                                (& loaded)
                                "package.macros/typeof")
                              (producer-test-dispatch-type-expr?
                                (& loaded)
                                "package.macros/typeexpr")
                              (producer-test-dispatch-type-expr-list?
                                (& loaded)
                                "package.macros/typeexprlist")
                              (producer-test-dispatch-typetpl?
                                (& loaded)
                                "package.macros/typetpl")
                              (producer-test-dispatch-scan?
                                (& loaded)
                                "package.macros/scan"
                                "{ab"
                                "brace"
                                3
                                "")
                              (producer-test-dispatch-scan?
                                (& loaded)
                                "package.macros/scan"
                                "xyz"
                                "plain"
                                -1
                                "yz")
                              (producer-test-dispatch-clone-route?
                                (& loaded)
                                "package.macros/clonepath")
                              (producer-test-dispatch-literal-match-route?
                                (& loaded)
                                "package.macros/literalmatch"
                                0)
                              (producer-test-dispatch-literal-match-route?
                                (& loaded)
                                "package.macros/literalmatch"
                                1)
                              (producer-test-dispatch-literal-match-route?
                                (& loaded)
                                "package.macros/literalmatch"
                                2)
                              (producer-test-dispatch-literal-match-route?
                                (& loaded)
                                "package.macros/literalmatch"
                                3)
                              (producer-test-dispatch-diagnostic?
                                (& loaded)
                                "package.macros/scan"
                                "value")
                              (producer-test-dispatch-shape?
                                (& loaded)
                                "package.macros/qqvar"
                                "value"
                                4
                                "some.nil")
                              (producer-test-dispatch-catlike?
                                (& loaded)
                                "package.macros/catlike"
                                0)
                              (producer-test-dispatch-catlike?
                                (& loaded)
                                "package.macros/catlike"
                                1)
                              (producer-test-dispatch-catlike?
                                (& loaded)
                                "package.macros/catlike"
                                2)
                              (producer-test-dispatch-catlike?
                                (& loaded)
                                "package.macros/catlike"
                                3)
                              (producer-test-dispatch-calldestructure?
                                (& loaded)
                                "package.macros/pushlike"
                                0)
                              (producer-test-dispatch-calldestructure?
                                (& loaded)
                                "package.macros/pushlike"
                                1)
                              (producer-test-dispatch-calldestructure?
                                (& loaded)
                                "package.macros/finishlike"
                                2)
                              (producer-test-dispatch-foldlike?
                                (& loaded)
                                "package.macros/foldlike"
                                0)
                              (producer-test-dispatch-foldlike?
                                (& loaded)
                                "package.macros/foldlike"
                                1)
                              (producer-test-dispatch-foldlike?
                                (& loaded)
                                "package.macros/foldlike"
                                2)
                              (producer-test-dispatch-foldlike?
                                (& loaded)
                                "package.macros/foldlike"
                                3)
                              (producer-test-dispatch-aliaslike?
                                (& loaded)
                                "package.macros/aliaslike"
                                "alias"
                                3
                                true
                                "alias_n3")
                              (producer-test-dispatch-aliaslike?
                                (& loaded)
                                "package.macros/aliaslike"
                                "alias"
                                3
                                false
                                "")
                              (producer-test-dispatch-var-name-identity?
                                (& loaded)
                                "package.macros/nameidentity")
                              (producer-test-dispatch-struct-set?
                                (& loaded)
                                "package.macros/structset"
                                0)
                              (producer-test-dispatch-struct-set?
                                (& loaded)
                                "package.macros/structset"
                                1)
                              (producer-test-dispatch-struct-set?
                                (& loaded)
                                "package.macros/structset"
                                2)
                              (producer-test-dispatch-struct-set?
                                (& loaded)
                                "package.macros/structset"
                                3)
                              (producer-test-dispatch-struct-set?
                                (& loaded)
                                "package.macros/structset"
                                4)
                              (producer-test-dispatch-dynamic-set?
                                (& loaded)
                                "package.macros/dynamicset"
                                0)
                              (producer-test-dispatch-dynamic-set?
                                (& loaded)
                                "package.macros/dynamicset"
                                1)
                              (producer-test-dispatch-dynamic-set?
                                (& loaded)
                                "package.macros/dynamicset"
                                2)
                              (producer-test-dispatch-dynamic-set?
                                (& loaded)
                                "package.macros/dynamicset"
                                3)
                              (producer-test-dispatch-tuple-splice?
                                (& loaded)
                                "package.macros/tuplepack"
                                0)
                              (producer-test-dispatch-tuple-splice?
                                (& loaded)
                                "package.macros/tuplepack"
                                1)
                              (producer-test-dispatch-tuple-fixed?
                                (& loaded)
                                "package.macros/tuplepair")
                              (producer-test-dispatch-tuple-marked?
                                (& loaded)
                                "package.macros/tuplemarked")
                              (producer-test-shell-cache?
                                (& loaded)
                                "package.macros/unsupported"
                                (producer-test-expr-operand "value")))]
                          (match (tlci_loader.tlci-loader-release loaded)
                            [(tlci_loader.ResultTlciLoaderUnit.Ok) ok]
                            [(tlci_loader.ResultTlciLoaderUnit.Err _) false]))])])))])])))

(test
  package-tlci-native-producer
  (unless
    (producer-test-package-native-image-ok?)
    (io.panic "package tlci native producer test failed")))

;; Every template node carries the span the parser gave it, and the unquote
;; position leaves the substituted operand's own call-site span alone. This is
;; the whole of what a native expansion has to reproduce for lowering to place
;; the same located runtime-abort sites as an interpreted one: a compiler built
;; with `--cfg embedded-stdlib-tlci` and a compiler built without it must emit
;; the same assembly, and before the producer walked these wrappers they
;; disagreed on exactly the bounds checks whose spans were dropped here.
;; Refs #5212.
(define (producer-test-span-result-ok?
  [pools : ast.AstNodePoolContext]
  [operand : i64]) : bool
  (match (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-value)
    [(compiler_ctfe.CompilerCtfeValue.Expr node _)
      (and
        (producer-test-node-span-at? (& pools) node 2 44)
        (match (producer-test-expr-get (& pools) node)
          [(ast.AstExpr.Call callee args)
            (and
              (producer-test-node-span-at? (& pools) callee 2 45)
              (match (producer-test-expr-get (& pools) callee)
                [(ast.AstExpr.Var name)
                  (= name (producer-test-name-id "outer"))]
                [_ false])
              (= (ast.ast-expr-list-len (& args)) 1)
              (let
                [inner : i64 (ast.ast-expr-list-get (& args) 0 -1)]
                (and
                  (producer-test-node-span-at? (& pools) inner 2 51)
                  (match (producer-test-expr-get (& pools) inner)
                    [(ast.AstExpr.Call inner-callee inner-args)
                      (and
                        (producer-test-node-span-at?
                          (& pools)
                          inner-callee
                          2
                          52)
                        (match (producer-test-expr-get (& pools) inner-callee)
                          [(ast.AstExpr.Var name)
                            (= name (producer-test-name-id "inner"))]
                          [_ false])
                        (= (ast.ast-expr-list-len (& inner-args)) 1)
                        (= (ast.ast-expr-list-get (& inner-args) 0 -1) operand)
                        (producer-test-node-span-at? (& pools) operand 900 7))]
                    [_ false]))))]
          [_ false]))]
    [_ false]))

(define (producer-test-dispatch-span?
  [loaded : (& loaded tlci_loader.TlciLoadedImage)]) : bool
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [operands : (__tl_dyn-array compiler_ctfe.CompilerCtfeValue)
      (__tl_make-array compiler_ctfe.CompilerCtfeValue 1)]
    ;; Built through this function's own captured pools: a second capture
    ;; would take its own watermark and hand back a node id the expansion
    ;; then reuses.
    [operand : i64
      (producer-test-push-spanned
        (& pools)
        (ast.AstExpr.Var (ci.intern "value")))]
    (begin
      (set!
        (array-ref operands 0)
        (compiler_ctfe.CompilerCtfeValue.Expr operand (ast.AstType.Expr)))
      (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-open!
        (owned_view.compiler-owned-shared-view pools)
        (owned_view.compiler-owned-shared-view operands)
        1
        64
        producer-test-cookie
        (compiler_ctfe.ctfe-reflect-info-list-empty))
      (let
        [ok : bool
          (match (tlci_loader.tlci-loader-dispatch-macro
            loaded
            "span.macros/spanned"
            producer-test-cookie
            (__tl_make-array i64 0)
            0)
            [(tlci_loader.ResultTlciMacroDispatch.Err _) false]
            [(tlci_loader.ResultTlciMacroDispatch.Ok dispatch)
              (and
                (= dispatch.status tlci.tlci-host-callback-status-ok)
                (compiler_embedded_stdlib_tlci.compiler-comptime-host-result-ready?)
                (>= operand 0)
                (producer-test-span-result-ok? pools operand))])]
        (begin
          (compiler_embedded_stdlib_tlci.compiler-comptime-host-session-close!)
          ok)))))

;; One template whose every node sits at a column this test names outright.
;; Line 2 of the source below reads, with column 1 at the opening paren:
;;   44 `(outer (inner ,value))`   51 `(inner ,value)`   58 `,value`
;;   45 `outer`                    52 `inner`
(define (producer-test-span-image-ok?) : bool
  (let
    [names : producer_test_svec.Vec (producer_test_svec.new)]
    [captures : compiler_tlci_native_producer.TlciNativeMacroCaptures
      (compiler_tlci_native_producer.tlci-native-macro-captures-new)]
    (match (parse_core.parse-ast-source
      "(module span.macros)
(defmacro (spanned [value : Expr]) : Expr `(outer (inner ,value)))
")
      [(parse_core.ResultAstProgram.Err _) false]
      [(parse_core.ResultAstProgram.Ok program)
        (match program
          [(ast.AstProgram.Program decls)
            (begin
              (producer-test-collect-decls!
                (owned_view.compiler-owned-box-shared-view decls)
                ""
                (&mut names)
                (&mut captures))
              (let
                [name-count : i64 (producer_test_svec.len (& names))]
                [name-array : (__tl_dyn-array String)
                  (__tl_make-array String name-count)]
                [name-index : i64 0]
                [_copy-names : unit
                  (while (< name-index name-count)
                    (begin
                      (set!
                        (array-ref name-array name-index)
                        (producer_test_svec.get (& names) name-index ""))
                      (set! name-index (+ name-index 1))))]
                (match (compiler_tlci_native_producer.embedded-native-emit-package
                  (tlci.tlci-metadata-emit
                    (tlci.tlci-make-metadata "v1" "span-test" "0.1.0"))
                  "producer-test"
                  (cfg windows true false)
                  (tlci.tlci-empty-bytes)
                  (owned_view.compiler-owned-shared-view name-array)
                  (& captures))
                  [(compiler_tlci_native_producer.ResultProducerBytes.Err _)
                    false]
                  [(compiler_tlci_native_producer.ResultProducerBytes.Ok bytes)
                    (match (tlci_loader.tlci-loader-load-from-bytes-with-host
                      (producer-test-image-owner-arena)
                      bytes
                      (compiler_embedded_stdlib_tlci.compiler-comptime-host-table))
                      [(tlci_loader.ResultTlciLoadedImage.Err _) false]
                      [(tlci_loader.ResultTlciLoadedImage.Ok loaded)
                        (let
                          [ok : bool (producer-test-dispatch-span? (& loaded))]
                          (match (tlci_loader.tlci-loader-release loaded)
                            [(tlci_loader.ResultTlciLoaderUnit.Ok) ok]
                            [(tlci_loader.ResultTlciLoaderUnit.Err _) false]))])])))])])))

(test
  template-span-tlci-native-producer
  (unless
    (producer-test-span-image-ok?)
    (io.panic "template span tlci native producer test failed")))

(define (main) : i64
  (if (= (io.arg-count) 6)
    (if (producer-test-emitted-bytes-ok?
      (byte_buf.to-array (io.read-file (io.arg 1)))
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