;; End-to-end host-image coverage for package-owned macro captures (#2754).
;; Native template shapes beyond the original splice-only subset (nested
;; calls, literals, splices, if/begin/binary/unary forms, plain symbols,
;; computed list-length ifs, and identity bodies) are covered here too
;; (#5596), along with the `str-cat` shape -- an operand-count integer match
;; with indexed operand access and a count-binding default arm (#5617).
;; A body outside the supported subset keeps the counted interpreted-fallback
;; shell.
(import "../compiler_tlci_native_producer.tl")

;; compiler_embedded_stdlib_tlci owns the loader import. Importing the same
;; graph again here gives Windows absolute-path runs two qualified page
;; surfaces and makes the second loader lose pages.ResultTlciPageUnit.
(import "../compiler_embedded_stdlib_tlci.tl")
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

;; Keep the focused Decls producer separate from the large expression-shape
;; corpus below so its result policy remains explicit in this cross-platform
;; image test.
(define (producer-test-add-decls-capture!
  [names : (&mut names producer_test_svec.Vec)]
  [captures : (&mut captures TlciNativeMacroCaptures)]) : unit
  (match (parse-ast-source
    "(module package.macros)
(defmacro (decls) : Decls
  `(begin
    (define generated-value : i64 42)
    (define (generated-id [x : i64]) : i64 x)))
")
    [(ResultAstProgram.Err _) unit]
    [(ResultAstProgram.Ok program)
      (match program
        [(AstProgram.Program decls)
          (producer-test-collect-decls! (box-get decls) "" names captures)])]))

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
;; quasiquoted plain symbol, 5 = match template, 6 = repeated set!, 7 =
;; struct-set!/box/box-get/return places.
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

;; A Decls body crosses the same opaque result slot as Module and expression
;; bodies. The host owns the resulting begin/define graph; no image pointer is
;; exposed to the declaration parser.
(define (producer-test-decls-result-ok? [pools : AstNodePoolContext]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.Begin items)
          (and
            (= (ast-expr-list-len (& items)) 2)
            (match (ast-node-pool-context-expr-get
              pools
              (ast-expr-list-get (& items) 0 -1))
              [(AstExpr.Call callee _)
                (match (ast-node-pool-context-expr-get pools callee)
                  [(AstExpr.Var name) (= name (producer-test-name-id "define"))]
                  [_ false])]
              [_ false])
            (match (ast-node-pool-context-expr-get
              pools
              (ast-expr-list-get (& items) 1 -1))
              [(AstExpr.Call callee _)
                (match (ast-node-pool-context-expr-get pools callee)
                  [(AstExpr.Var name) (= name (producer-test-name-id "define"))]
                  [_ false])]
              [_ false]))]
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

;; The `catlike` fixture (the `str-cat` shape): an operand-count match whose
;; integer arms index operands with `expr-list-nth` and whose binder arm
;; splices the whole operand list and rebuilds the count as a literal.
;; Refs #5617.
(define (producer-test-catlike-result-ok?
  [pools : AstNodePoolContext]
  [count : i64]
  [first : i64]
  [second : i64]
  [third : i64]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (cond
        [(= count 0)
          (match (ast-node-pool-context-expr-get pools node)
            [(AstExpr.Literal (AstLiteral.String sid))
              (string.eq (intern-str sid) "")]
            [_ false])]
        [(= count 1) (= node first)]
        [(= count 2)
          (match (ast-node-pool-context-expr-get pools node)
            [(AstExpr.Call callee args)
              (and
                (match (ast-node-pool-context-expr-get pools callee)
                  [(AstExpr.Var name)
                    (= name (producer-test-name-id "concat2"))]
                  [_ false])
                (= (ast-expr-list-len (& args)) 2)
                (= (ast-expr-list-get (& args) 0 -1) first)
                (= (ast-expr-list-get (& args) 1 -1) second))]
            [_ false])]
        [else (producer-test-catlike-packed-ok? pools node first second third)])]
    [_ false]))

;; `(concat-all (pack (__args a b c) 3))` for the three-operand binder arm.
(define (producer-test-catlike-packed-ok?
  [pools : AstNodePoolContext]
  [node : i64]
  [first : i64]
  [second : i64]
  [third : i64]) : bool
  (match (ast-node-pool-context-expr-get pools node)
    [(AstExpr.Call callee args)
      (and
        (match (ast-node-pool-context-expr-get pools callee)
          [(AstExpr.Var name) (= name (producer-test-name-id "concat-all"))]
          [_ false])
        (= (ast-expr-list-len (& args)) 1)
        (match (ast-node-pool-context-expr-get
          pools
          (ast-expr-list-get (& args) 0 -1))
          [(AstExpr.Call pack-callee pack-args)
            (and
              (match (ast-node-pool-context-expr-get pools pack-callee)
                [(AstExpr.Var name) (= name (producer-test-name-id "pack"))]
                [_ false])
              (= (ast-expr-list-len (& pack-args)) 2)
              (match (ast-node-pool-context-expr-get
                pools
                (ast-expr-list-get (& pack-args) 0 -1))
                [(AstExpr.Call carrier-callee carrier-args)
                  (and
                    (match (ast-node-pool-context-expr-get pools carrier-callee)
                      [(AstExpr.Var name)
                        (= name (producer-test-name-id "__args"))]
                      [_ false])
                    (= (ast-expr-list-len (& carrier-args)) 3)
                    (= (ast-expr-list-get (& carrier-args) 0 -1) first)
                    (= (ast-expr-list-get (& carrier-args) 1 -1) second)
                    (= (ast-expr-list-get (& carrier-args) 2 -1) third))]
                [_ false])
              (match (ast-node-pool-context-expr-get
                pools
                (ast-expr-list-get (& pack-args) 1 -1))
                [(AstExpr.Literal (AstLiteral.Int value _)) (= value 3)]
                [_ false]))]
          [_ false]))]
    [_ false]))

;; Dispatch the `str-cat`-shaped fixture with `count` String operands.
(define (producer-test-dispatch-catlike?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]
  [count : i64]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [first : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "alpha")))]
    [second : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "beta")))]
    [third : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "gamma")))]
    [items : AstExprList (ast-expr-list-new)]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    (begin
      (when (>= count 1) (ast-expr-list-push (&mut items) first))
      (when (>= count 2) (ast-expr-list-push (&mut items) second))
      (when (>= count 3) (ast-expr-list-push (&mut items) third))
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
                (producer-test-catlike-result-ok?
                  pools
                  count
                  first
                  second
                  third))])]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

;; The `format-push` / `format-finish` shape: a computed match that
;; destructures an `Expr` operand with `(comptime.Expr.Call callee args)`,
;; binding the callee and the argument list into session locals. Check 0
;; rebuilds `(,callee ,@pieces ,piece)` from a two-argument call operand,
;; check 1 takes the non-call default arm, and check 2 rebuilds
;; `(joined ,@pieces)` with a wildcard callee pattern. Refs #5602.
(define (producer-test-calldestructure-result-ok?
  [pools : AstNodePoolContext]
  [check : i64]
  [carrier : i64]
  [first : i64]
  [second : i64]
  [piece : i64]
  [callee : i64]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (cond
        [(= check 1) (= node carrier)]
        [else
          (match (ast-node-pool-context-expr-get pools node)
            [(AstExpr.Call actual-callee args)
              (and
                (if (= check 0)
                  (= actual-callee callee)
                  (match (ast-node-pool-context-expr-get pools actual-callee)
                    [(AstExpr.Var name)
                      (= name (producer-test-name-id "joined"))]
                    [_ false]))
                (=
                  (ast-expr-list-len (& args))
                  (if (= check 0)
                    3
                    2))
                (= (ast-expr-list-get (& args) 0 -1) first)
                (= (ast-expr-list-get (& args) 1 -1) second)
                (if (= check 0)
                  (= (ast-expr-list-get (& args) 2 -1) piece)
                  true))]
            [_ false])])]
    [_ false]))

(define (producer-test-dispatch-calldestructure?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]
  [check : i64]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [callee : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "carry")))]
    [first : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "alpha")))]
    [second : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "beta")))]
    [piece : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "gamma")))]
    [items : AstExprList (ast-expr-list-new)]
    [carrier : i64 0]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 2)]
    (begin
      (ast-expr-list-push (&mut items) first)
      (ast-expr-list-push (&mut items) second)
      (set!
        carrier
        (if (= check 1)
          piece
          (ast-node-pool-context-expr-push pools (AstExpr.Call callee items))))
      (array-set! operands 0 (CompilerCtfeValue.Expr carrier (AstType.Expr)))
      (array-set! operands 1 (CompilerCtfeValue.Expr piece (AstType.Expr)))
      (compiler-comptime-host-session-open!
        pools
        operands
        (if (= check 2)
          1
          2)
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
                (producer-test-calldestructure-result-ok?
                  pools
                  check
                  carrier
                  first
                  second
                  piece
                  callee))])]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

;; The `path-join-fold` / `str-cat-pack` shape: an outer
;; `(comptime.Expr.Int i)` match binds the literal as a compile-time i64, an
;; inner `(comptime.Expr.Call _ elems)` match binds the carrier's argument
;; list as a session local, and the body compares `i` against that local
;; list's length before indexing it. Check 0 takes the recursive template,
;; check 1 exhausts the list and returns the accumulator, and check 2 passes a
;; non-Int index so the outer default arm answers. Refs #5602.
(define (producer-test-foldlike-result-ok?
  [pools : AstNodePoolContext]
  [check : i64]
  [carrier : i64]
  [acc : i64]
  [first : i64]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (if (> check 0)
        (= node acc)
        (match (ast-node-pool-context-expr-get pools node)
          [(AstExpr.Call callee args)
            (and
              (match (ast-node-pool-context-expr-get pools callee)
                [(AstExpr.Var name) (= name (producer-test-name-id "foldlike"))]
                [_ false])
              (= (ast-expr-list-len (& args)) 3)
              (= (ast-expr-list-get (& args) 0 -1) carrier)
              (match (ast-node-pool-context-expr-get
                pools
                (ast-expr-list-get (& args) 1 -1))
                [(AstExpr.Call step-callee step-args)
                  (and
                    (match (ast-node-pool-context-expr-get pools step-callee)
                      [(AstExpr.Var name)
                        (= name (producer-test-name-id "step"))]
                      [_ false])
                    (= (ast-expr-list-len (& step-args)) 2)
                    (= (ast-expr-list-get (& step-args) 0 -1) acc)
                    (= (ast-expr-list-get (& step-args) 1 -1) first))]
                [_ false])
              (match (ast-node-pool-context-expr-get
                pools
                (ast-expr-list-get (& args) 2 -1))
                [(AstExpr.Literal (AstLiteral.Int value _)) (= value 1)]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (producer-test-dispatch-foldlike?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]
  [check : i64]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [head : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "carry")))]
    [first : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "alpha")))]
    [second : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "beta")))]
    [acc : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "seed")))]
    [items : AstExprList (ast-expr-list-new)]
    [carrier : i64 0]
    [idx : i64 0]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 3)]
    (begin
      (ast-expr-list-push (&mut items) first)
      (ast-expr-list-push (&mut items) second)
      (set!
        carrier
        (ast-node-pool-context-expr-push pools (AstExpr.Call head items)))
      (set!
        idx
        (if (= check 2)
          acc
          (ast-node-pool-context-expr-push
            pools
            (AstExpr.Literal
              (ast-lit-int
                (if (= check 1)
                  2
                  0))))))
      (array-set! operands 0 (CompilerCtfeValue.Expr carrier (AstType.Expr)))
      (array-set! operands 1 (CompilerCtfeValue.Expr acc (AstType.Expr)))
      (array-set! operands 2 (CompilerCtfeValue.Expr idx (AstType.Expr)))
      (compiler-comptime-host-session-open!
        pools
        operands
        3
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
                (producer-test-foldlike-result-ok?
                  pools
                  check
                  carrier
                  acc
                  first))])]
        (begin
          (compiler-comptime-host-session-close!)
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
  [pools : AstNodePoolContext]
  [expected : String]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.Var name-id) (string.eq (intern-str name-id) expected)]
        [_ false])]
    [_ false]))

(define (producer-test-dispatch-aliaslike?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]
  [name : String]
  [index : i64]
  [var-operand : bool]
  [expected : String]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [value : i64
      (if var-operand
        (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern name)))
        (ast-node-pool-context-expr-push
          pools
          (AstExpr.Literal (ast-lit-int index))))]
    [idx : i64
      (ast-node-pool-context-expr-push
        pools
        (AstExpr.Literal (ast-lit-int index)))]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 2)]
    (begin
      (array-set! operands 0 (CompilerCtfeValue.Expr value (AstType.Expr)))
      (array-set! operands 1 (CompilerCtfeValue.Expr idx (AstType.Expr)))
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
                (if var-operand
                  (producer-test-alias-result-ok? pools expected)
                  (producer-test-operand-result-ok? value)))])]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

;; The `places` fixture covers the template node kinds the json/serialize hooks
;; need: `(set! (struct-get ...) <float literal>)`, `(box ...)`, `(box-get ...)`,
;; and `(return ...)`. Refs #5605.
(define (producer-test-places-result-ok?
  [pools : AstNodePoolContext]
  [operand : i64]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.Match match-box)
          (match (box-get match-box)
            [(AstMatch.Match _ arms)
              (and
                (= (struct-get arms len) 2)
                (match (array-ref (struct-get arms slots) 0)
                  [(AstMatchArm.Arm _ body)
                    (match (ast-node-pool-context-expr-get pools body)
                      [(AstExpr.Begin items)
                        (and
                          (= (ast-expr-list-len (& items)) 2)
                          (match (ast-node-pool-context-expr-get
                            pools
                            (ast-expr-list-get (& items) 0 -1))
                            [(AstExpr.StructSet target field value)
                              (and
                                (= field (ci.intern "len"))
                                (match (ast-node-pool-context-expr-get
                                  pools
                                  target)
                                  [(AstExpr.Var name)
                                    (= name (producer-test-name-id "inner"))]
                                  [_ false])
                                (match (ast-node-pool-context-expr-get
                                  pools
                                  value)
                                  [(AstExpr.Literal (AstLiteral.Float text))
                                    (string.eq text "1.5")]
                                  [_ false]))]
                            [_ false])
                          (match (ast-node-pool-context-expr-get
                            pools
                            (ast-expr-list-get (& items) 1 -1))
                            [(AstExpr.BoxGet boxed)
                              (match (ast-node-pool-context-expr-get
                                pools
                                boxed)
                                [(AstExpr.Box inner)
                                  (match (ast-node-pool-context-expr-get
                                    pools
                                    inner)
                                    [(AstExpr.Var name)
                                      (= name (producer-test-name-id "inner"))]
                                    [_ false])]
                                [_ false])]
                            [_ false]))]
                      [_ false])]
                  [_ false])
                (match (array-ref (struct-get arms slots) 1)
                  [(AstMatchArm.Arm _ body)
                    (match (ast-node-pool-context-expr-get pools body)
                      [(AstExpr.Return inner) (= inner operand)]
                      [_ false])]
                  [_ false]))])]
        [_ false])]
    [_ false]))

;; `(comptime.expr-var (comptime.expr-string-value value))`: the literal text of
;; a string-literal Expr operand becomes a variable name, exercising op 246
;; followed by the value-consuming `expr-var-from-value` (206). Refs #5626.
(define (producer-test-dispatch-strval?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [literal : i64
      (ast-node-pool-context-expr-push
        pools
        (AstExpr.Literal (AstLiteral.String (ci.intern "picked.name"))))]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    (begin
      (array-set! operands 0 (CompilerCtfeValue.Expr literal (AstType.Expr)))
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
                (match (compiler-comptime-host-result-value)
                  [(CompilerCtfeValue.Expr node _)
                    (match (ast-node-pool-context-expr-get pools node)
                      ;; op 206 resolves the name through the source-name
                      ;; session rather than the template-source mark, so
                      ;; compare rendered text like the `gen` fixture does.
                      [(AstExpr.Var name-id)
                        (string.eq (intern-str name-id) "picked.name")]
                      [_ false])]
                  [_ false]))])]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

;; `(marker ,(comptime.expr-type value))`: op 125 needs a *typechecked* Expr, so
;; the operand carries a real type rather than the untyped Expr type the other
;; fixtures use. Refs #5626.
(define (producer-test-dispatch-typeof?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operand : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "value")))]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    (begin
      (array-set! operands 0 (CompilerCtfeValue.Expr operand (AstType.I64)))
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
                (match (compiler-comptime-host-result-value)
                  [(CompilerCtfeValue.Expr node _)
                    (match (ast-node-pool-context-expr-get pools node)
                      [(AstExpr.Call callee args)
                        (and
                          (match (ast-node-pool-context-expr-get pools callee)
                            [(AstExpr.Var name)
                              (= name (producer-test-name-id "marker"))]
                            [_ false])
                          (= (ast-expr-list-len (& args)) 1))]
                      [_ false])]
                  [_ false]))])]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

;; The comptime string scanner: `comptime.expr-string?` (256) guards a String
;; session local that `expr-string-value` (246) binds, `string-length` (252)
;; measures, `string-ref` (253) indexes through a `char` cast, `string-slice`
;; (254) cuts and `expr-string-from-value` (255) turns back into a literal.
;; The two arms differ only in which byte the operand starts with, so an
;; off-by-one in any of those reads still commits a result -- the assertions
;; compare the exact literal each arm must produce. Refs #5701.
(define (producer-test-dispatch-scan?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]
  [literal : String]
  [expected-callee : String]
  [expected-int : i64]
  [expected-text : String]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operand : i64
      (ast-node-pool-context-expr-push
        pools
        (AstExpr.Literal (AstLiteral.String (ci.intern literal))))]
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
                          (producer-test-scan-argument-ok?
                            pools
                            (ast-expr-list-get (& args) 0 0)
                            expected-int
                            expected-text))]
                      [_ false])]
                  [_ false]))])]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-scan-argument-ok?
  [pools : AstNodePoolContext]
  [node : i64]
  [expected-int : i64]
  [expected-text : String]) : bool
  (match (ast-node-pool-context-expr-get pools node)
    [(AstExpr.Literal (AstLiteral.Int value _))
      (and (>= expected-int 0) (= value expected-int))]
    [(AstExpr.Literal (AstLiteral.String sid))
      (and (< expected-int 0) (string.eq (intern-str sid) expected-text))]
    [_ false]))

;; The scanner's guard arm: a non-literal operand must reach the session
;; diagnostic rather than commit a silently empty template. Refs #5701.
(define (producer-test-dispatch-diagnostic?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]
  [argument : String]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    (begin
      (array-set! operands 0 (producer-test-expr-operand argument))
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
                (=
                  (struct-get dispatch status)
                  tlci-host-callback-status-diagnostic)
                (not (compiler-comptime-host-result-ready?)))])]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

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
                  [(= check 6) (producer-test-twice-result-ok? pools)]
                  [else (producer-test-places-result-ok? pools operand)]))])]
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

;; Dispatch the zero-operand declaration-generator fixture and retain its
;; result only through the compiler-owned handle table.
(define (producer-test-dispatch-decls?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    (begin
      (compiler-comptime-host-session-open!
        pools
        operands
        0
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
                (producer-test-decls-result-ok? pools))])]
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

;; The fixed-array and shared-reference annotations in `typetpl` exercise the
;; two composite-type operations that were renumbered after their producer
;; support was written. Loading the image is insufficient: the stale ids only
;; fail when the emitted entry dispatches and the host interprets them.
(define (producer-test-typetpl-array-binding-ok?
  [pools : AstNodePoolContext]
  [binding : AstLetBinding]
  [expected-count : i64]) : bool
  (match binding
    [(AstLetBinding.Binding _ (AstMaybeType.Some ty) _)
      (match ty
        [(AstType.Array elem count)
          (and
            (= count expected-count)
            (match (ast-node-pool-context-type-get pools elem)
              [(AstType.I64) true]
              [_ false]))]
        [_ false])]
    [_ false]))

(define (producer-test-typetpl-ref-binding-ok?
  [pools : AstNodePoolContext]
  [binding : AstLetBinding]) : bool
  (match binding
    [(AstLetBinding.Binding _ (AstMaybeType.Some ty) _)
      (match ty
        [(AstType.Ref region inner)
          (and
            (string.eq (intern-str region) "region")
            (match (ast-node-pool-context-type-get pools inner)
              [(AstType.Str) true]
              [_ false]))]
        [_ false])]
    [_ false]))

(define (producer-test-typetpl-result-ok? [pools : AstNodePoolContext]) : bool
  (match (compiler-comptime-host-result-value)
    [(CompilerCtfeValue.Expr node _)
      (match (ast-node-pool-context-expr-get pools node)
        [(AstExpr.Let let-box)
          (match (box-get let-box)
            [(AstLet.Let bindings _)
              (and
                (= (ast-let-binding-list-len (& bindings)) 5)
                (producer-test-typetpl-ref-binding-ok?
                  pools
                  (ast-let-binding-list-get
                    (& bindings)
                    2
                    (ast-let-binding-fallback)))
                (producer-test-typetpl-array-binding-ok?
                  pools
                  (ast-let-binding-list-get
                    (& bindings)
                    4
                    (ast-let-binding-fallback))
                  4))])]
        [_ false])]
    [_ false]))

(define (producer-test-dispatch-typetpl?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    (begin
      (array-set! operands 0 (producer-test-expr-operand "value"))
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
                (producer-test-typetpl-result-ok? pools))])]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

;; The `kindof` fixture dispatches on the produced type of an Expr operand, so
;; the f64-typed operand must select the first arm and rebuild `(f64-op v)`.
;; The `keyof` fixture dispatches on a type operand's canonical key and builds
;; `(i64-op (cast v : i64))`, covering the cast template node. Refs #5604.
(define (producer-test-call-of-result-ok?
  [pools : AstNodePoolContext]
  [expected-callee : String]
  [check-cast : bool]
  [operand : i64]) : bool
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
            (let
              [arg : i64 (ast-expr-list-get (& args) 0 -1)]
              (if check-cast
                (match (ast-node-pool-context-expr-get pools arg)
                  [(AstExpr.Cast inner ty)
                    (and
                      (= inner operand)
                      (match ty
                        [(AstType.I64) true]
                        [_ false]))]
                  [_ false])
                (= arg operand))))]
        [_ false])]
    [_ false]))

(define (producer-test-dispatch-kindof?
  [loaded : (& loaded TlciLoadedImage)]
  [identity : String]) : bool
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [operand : i64
      (ast-node-pool-context-expr-push pools (AstExpr.Var (ci.intern "value")))]
    [operands : (Array CompilerCtfeValue)
      (array.make-array CompilerCtfeValue 1)]
    (begin
      (array-set! operands 0 (CompilerCtfeValue.Expr operand (AstType.F64)))
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
                (producer-test-call-of-result-ok? pools "f64-op" false operand))])]
        (begin
          (compiler-comptime-host-session-close!)
          ok)))))

(define (producer-test-dispatch-keyof?
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
                (producer-test-call-of-result-ok? pools "i64-op" true operand))])]
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
    [source : String
      "(module package.macros)\n(defmacro (wrap [value : Expr]) : Expr `(identity ,value))\n(defmacro (fold [items : Expr ...]) : bool (comptime.expr-list-fold-if items (comptime.expr-bool true) (comptime.expr-bool false) true))\n(defmacro (unsupported [value : Expr]) : Expr (match value [(comptime.Expr.If c t e) c] [_ value]))\n(defmacro (nest [value : Expr]) : Expr `(stdlib.json.JsonValue (stdlib.json.JsonBool ,value)))\n(defmacro (ident [value : Expr]) : Expr value)\n(defmacro (whenlike [condition : bool] [body : unit ...]) : unit (if (= (comptime.expr-list-length body) 0) (comptime.expr-var \"core-when-missing-body\") `(if ,condition (begin ,@body) unit)))\n(defmacro (lits [value : Expr]) : Expr `(f \"a\\tb\" 'x' -7 true))\n(defmacro (qqvar [value : Expr]) : Expr `some.nil)\n(defmacro (tytpl [T : type] [value : Expr]) : Expr `(stdlib.eq.struct-eq-fields ,T 0 ,value))\n(defmacro (gen [T : type] [value : Expr]) : Module (let [module-name : Expr (expr-var (comptime.string-append \"test.gen.\" (type-key T)))] `(begin (module ,module-name) (define (id [x : ,T]) : ,T x))))\n(defmacro (classify [value : Expr]) : Expr `(match value [(Some _) true] [None false]))\n(defmacro (twice [value : Expr]) : Expr `(begin (set! flag 1) (set! flag 2)))\n(defmacro (catlike [args : String ...]) : String (match (comptime.expr-list-length args) [0 `\"\"] [1 (comptime.expr-list-nth args 0)] [2 `(concat2 ,(comptime.expr-list-nth args 0) ,(comptime.expr-list-nth args 1))] [n `(concat-all (pack (__args ,@args) ,(comptime.expr-int n)))]))\n(defmacro (pushlike [carrier : Expr] [piece : Expr]) : Expr (match carrier [(comptime.Expr.Call callee pieces) `(,callee ,@pieces ,piece)] [_ carrier]))\n(defmacro (finishlike [carrier : Expr]) : Expr (match carrier [(comptime.Expr.Call _ pieces) `(joined ,@pieces)] [_ `\"\"]))\n(defmacro (kindfull [T : type] [value : Expr]) : Expr (match (type-kind T) [\"i64\" `(kind-i64 ,value)] [\"f64\" `(kind-f64 ,value)]))\n(defmacro (kindly [T : type] [value : Expr]) : Expr (match (type-kind T) [\"i64\" `(kind-i64 ,value)] [other (comptime.comptime-error \"kindly: unsupported\")]))
(defmacro (kindwild [T : type] [value : Expr]) : Expr (match (type-kind T) [\"i64\" `(kind-i64 ,value)] [_ `(kind-other ,value)]))\n(defmacro (places [value : Expr]) : Expr `(match ,value [(Some inner) (begin (set! (struct-get inner len) 1.5) (box-get (box inner)))] [_ (return ,value)]))\n(defmacro (foldlike [carrier : Expr] [acc : Expr] [idx : Expr]) : Expr (match idx [(comptime.Expr.Int i) (match carrier [(comptime.Expr.Call _ elems) (if (>= i (comptime.expr-list-length elems)) acc `(foldlike ,carrier (step ,acc ,(comptime.expr-list-nth elems i)) ,(comptime.expr-int (+ i 1))))] [_ acc])] [_ acc]))\n(defmacro (kindof [value : Expr]) : Expr (match (type-kind (comptime.expr-type value)) [\"f64\" `(f64-op ,value)] [_ `(other ,value)]))\n(defmacro (keyof [T : type] [value : Expr]) : Expr (match (type-key T) [\"i64\" `(i64-op (cast ,value : i64))] [_ `(other ,value)]))\n(defmacro (rawptr [value : Expr]) : Expr `(unsafe (ptr-write! (ptr-offset (string-data ,value) 1) (ptr-read (ptr-offset (array-data ,value) 2))) (string-from-bytes (string-data ,value) (ptr->int (string-data ,value)))))\n(defmacro (strval [value : Expr]) : Expr (comptime.expr-var (comptime.expr-string-value value)))\n(defmacro (typeof [value : Expr]) : Expr `(marker ,(comptime.expr-type value)))\n(defmacro (aliaslike [value : Expr] [idx : Expr]) : Expr (match idx [(comptime.Expr.Int i) (match value [(comptime.Expr.Var t) (comptime.expr-var (comptime.string-append (comptime.string-append t \"_n\") (comptime.int->string i)))] [_ value])] [_ value]))\n(defmacro (typetpl [value : Expr]) : Expr `(let [a : (Ptr u8) (ptr-cast (string-data ,value) : (Ptr u8))] [b : (Array i64) ,value] [c : (& region str) ,value] [d : (Box i64) ,value] [e : (Array i64 4) ,value] (marker a b c d e)))\n(defmacro (scan [text : Expr]) : Expr (if (comptime.expr-string? text) (let [s : String (comptime.expr-string-value text)] [n : i64 (string.string-length s)] (if (= (cast (string.string-ref s 0) : i64) 123) `(brace ,(comptime.expr-int n)) `(plain ,(comptime.expr-string (comptime.string-slice s 1 (- n 1)))))) (comptime.comptime-error \"scan: expects a string literal\")))\n"]
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
              (producer-test-add-decls-capture! (&mut names) (&mut captures))
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
                              (= (array-length name-array) 29)
                              (= (struct-get captures len) 29)
                              (=
                                (array-ref
                                  embedded-stdlib-tlci-native-report-count
                                  0)
                                28)
                              (=
                                (array-ref
                                  embedded-stdlib-tlci-native-report-partial-count
                                  0)
                                2)
                              (=
                                (array-ref
                                  embedded-stdlib-tlci-native-report-interpreted-arms
                                  0)
                                2)
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