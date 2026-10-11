(import compiler_typecheck_api as api)
(import compiler_typecheck_core as tc)
(import compiler_parse_core as parser)
(import compiler_ast_types as ast)
(import compiler_diagnostic as diag)
(import compiler_load as load)
(import compiler_intern as ci)
(import stdlib.iterator)
(import stdlib.string)
(import stdlib.str_cat_runtime as cat)
(import stdlib.test)

(define (check-prefix
  [prefix : String]
  [suffix : String]
  [count : i64]
  [entry : String]) : String
  (match (parser.parse-ast-source-diagnostic
    (string.copy (& entry))
    (cat.str-cat prefix suffix))
    [(Ok parsed)
      (let
        ;; Imported source prefixes contain module markers absent from the
        ;; symbol index. Keep that boundary in every cache reuse test.
        [program : ast.AstProgram
          (match parsed
            [(Program boxed)
              (ast.ast-program
                (ast.ast-decl-list-prepend-builder
                  (ast.AstDecl.Module (ci.intern ""))
                  (ast.ast-decl-list-prepend-builder
                    (ast.AstDecl.Module (ci.intern ""))
                    (ast.ast-decl-list-box-shared-view boxed))))])]
        [prefix-count : i64 (+ count 2)]
        [length : i64
          (match (tc.tc-global-shared-view program)
            [(Program decls)
              (let
                [items : ast.AstDeclList
                  (ast.ast-decl-list-box-shared-view decls)]
                (ast.ast-decl-list-len (& items)))])]
        [paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
        (for [index (iterator.range prefix-count length)]
          (set!
            paths
            (ast.ast-decl-root-path-cons (string.copy (& entry)) paths)))
        (for [index (iterator.range 0 prefix-count)]
          (set!
            paths
            (ast.ast-decl-root-path-cons
              "stdlib/tc_global_call_prefix.tl"
              paths)))
        (match (api.typecheck-compiler-program-with-paths program paths)
          [(Ok _) "ok"]
          [(Err boxed)
            (let
              [diagnostics : diag.CompilerDiagnosticList
                (diag.compiler-diagnostic-list-box-shared-view boxed)]
              [first : diag.CompilerDiagnostic
                (diag.compiler-diagnostic-list-first diagnostics)]
              (cat.str-cat
                (diag.compiler-diagnostic-code-or-empty (& first))
                (cat.str-cat ": " (diag.compiler-diagnostic-render (& first)))))]))]
    [(Err _) "parse error"]))

(define (start-cache!) : unit
  (load.compiler-load-session-cache-enable!)
  (tc.tc-prefix-snapshot-cache-clear!))

(define (finish-cache!) : unit
  (load.compiler-load-session-cache-disable-for-test!)
  (tc.tc-prefix-snapshot-cache-clear!)
  (api.compiler-typecheck-reset-load-session!))

(test
  global-call-pure-prefix-reuses-proof
  (start-cache!)
  (test.assert-true
    (string.eq
      (check-prefix
        "(define (shared [n : i64]) : i64 (+ n 1))\n"
        "(define (main) : i64 (shared 1))"
        1
        "target/global-call-pure-a.tl")
      "ok")
    "first pure prefix checks")
  (tc.compiler-typecheck-reset-file-state!)
  (test.assert-true
    (string.eq
      (check-prefix
        "(define (shared [n : i64]) : i64 (+ n 1))\n"
        "(define (main) : i64 (shared 2))"
        1
        "target/global-call-pure-b.tl")
      "ok")
    "second pure prefix checks")
  (test.assert-true
    (> (tc.tc-prefix-snapshot-cache-hit-count-value) 0)
    "module markers preserve context-independent prefix hits")
  (finish-cache!))

(test
  global-call-prefix-rechecks-callable-union
  (start-cache!)
  (let
    [prefix : String
      "(defstruct Big (a i64) (b i64) (c i64) (d i64))\n(define g : Big (Big 1 2 3 4))\n(define (read [r : (& r Big)] [n : i64]) : i64 r.a)\n(define (invoke [f : (-> i64)]) : i64 (read (& g) (f)))\n"]
    (test.assert-true
      (string.eq
        (check-prefix
          (string.copy (& prefix))
          "(define (pure) : i64 0)\n(define (main) : i64 (invoke pure))"
          4
          "target/global-call-union-a.tl")
        "ok")
      "prefix is safe with a pure callback")
    (test.assert-true
      (> (tc.tc-prefix-snapshot-cache-store-count-value) 0)
      "safe prefix was cached")
    (tc.compiler-typecheck-reset-file-state!)
    (let
      [message : String
        (check-prefix
          prefix
          "(define (write!) : i64 (set! g (Big 9 9 9 9)) 0)\n(define (main) : i64 (invoke write!))"
          4
          "target/global-call-union-b.tl")]
      (test.assert-true
        (string.contains message "E0222")
        (cat.str-cat
          "new callable union invalidates the cached borrow proof: "
          (string.copy (& message))))
      (test.assert-true
        (string.contains message "<indirect call/lambda> -> write!")
        "diagnostic follows the current callback")
      (test.assert-true
        (string.contains message "stdlib/tc_global_call_prefix.tl")
        "prefix borrow keeps its source path")))
  (finish-cache!))

(test
  global-call-prefix-reinfers-temporary-cleanup
  (start-cache!)
  (let
    [prefix : String
      "(defstruct Big (a i64) (b i64) (c i64) (d i64))\n(define g : Big (Big 1 2 3 4))\n(define (drop-word [n : i64]) : unit (set! g (Big n n n n)))\n(defstruct Handle (:cleanup close-handle) (n i64 (:cleanup drop-word)))\n(define (fd [h : (& Handle)]) : i64 h.n)\n(define (drop-temporary) : unit (fd (& (Handle 9))) unit)\n"]
    (test.assert-true
      (string.eq
        (check-prefix
          (string.copy (& prefix))
          "(define (main) : i64 (drop-temporary) 0)"
          6
          "target/global-call-temp-a.tl")
        "ok")
      "cleanup without a global loan checks")
    (test.assert-true
      (> (tc.tc-prefix-snapshot-cache-store-count-value) 0)
      "temporary-cleanup prefix was cached")
    (tc.compiler-typecheck-reset-file-state!)
    (let
      [message : String
        (check-prefix
          prefix
          "(define (read-after [r : (& r Big)]) : i64 (drop-temporary) r.a)\n(define (main) : i64 (read-after (& g)))"
          6
          "target/global-call-temp-b.tl")]
      (test.assert-true
        (string.contains message "E0222")
        (cat.str-cat
          "cached prefix still supplies inferred cleanup effects: "
          (string.copy (& message))))
      (test.assert-true
        (string.contains
          message
          "read-after -> drop-temporary -> close-handle -> drop-word")
        "temporary cleanup remains transitive")
      (test.assert-true
        (string.contains message "target/global-call-temp-b.tl")
        "deferred diagnostic keeps the consumer path")))
  (finish-cache!))