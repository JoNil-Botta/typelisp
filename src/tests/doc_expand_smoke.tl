;; doc_expand_smoke.tl - Runnable smoke for generated-module docs.
(import doc_expand)
(import compiler_owned_view as owned_view)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import sym_i64_env)
(import (vector.vector String) as doc_svec)
(import doc_render)
(import doc_extract)
(import (vector.vector doc_render.DocModule core) as doc_module_vec)
(import (vector.vector doc_extract.DocItem core) as doc_item_vec)
(import compiler_load)
(import compiler_ast_types as ast)
(import compiler_diagnostic as cdiag)
(import compiler_intern as ci)
(import compiler_parse_core as parser)
(import compiler_typecheck_core as tc)
(import (vector.vector String core) as doc_import_form_vec)
(import (vector.vector doc_expand.DocMacroImportExample core) as doc_macro_import_example_vec)
(import (vector.vector doc_expand.DocGeneratedTargetExample core) as doc_generated_target_example_vec)

(define (main) : i64
  (begin
    (doc-expand-ignore-fence-smoke)
    (doc-expand-smoke)))

(test
  doc-macro-type-kind-constraint-source
  (unless
    (let
      [parsed : parser.ResultAstProgram
        (parser.parse-ast-source
          "(defmacro (catalog [T : type (:kind i64 struct)]) : Module unit)")]
      [ctx : doc_expand.DocExpandContext
        (let
          [pools (ast.ast-node-pool-context-capture-active)]
          [intern-state (ci.intern-compat-state-capture-active)]
          (doc_expand.doc-expand-context-from-pools-and-intern-state
            pools
            intern-state))]
      (match parsed
        [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
          (match (ast.ast-decl-list-step (deref decls-box))
            [(ast.AstDeclListStep.Cons
                (ast.AstDecl.DefMacro decl-meta _ params _ _)
                rest)
              (and
                (match (ast.ast-decl-list-step rest)
                  [(ast.AstDeclListStep.Nil) true]
                  [_ false])
                (= (ast.ast-macro-param-list-len (& params)) 1)
                (string.eq
                  (doc_expand.doc-ast-macro-param-source
                    ctx
                    (ast.ast-macro-param-list-get
                      (& params)
                      0
                      (ast.ast-macro-param-fallback)))
                  "[T : type (:kind i64 struct)]"))]
            [_ false])]
        [(parser.ResultAstProgram.Err _) false]))
    (io.panic "doc-expand: macro type-kind constraint signature mismatch")))

(test
  doc-generated-vector-growth-order
  (let
    [items : doc_item_vec.Vec (doc_item_vec.new)]
    [forms : doc_import_form_vec.Vec (doc_import_form_vec.new)]
    [macro-examples : doc_macro_import_example_vec.Vec
      (doc_macro_import_example_vec.new)]
    [targets : doc_generated_target_example_vec.Vec
      (doc_generated_target_example_vec.new)]
    [modules : doc_module_vec.Vec (doc_module_vec.new)]
    [index : i64 0]
    (begin
      (while (< index 6)
        (begin
          (doc_item_vec.push-ref!
            (&mut items)
            (doc_extract.DocItem.Item
              (doc_extract.DocItemKind.Define)
              (string.int->string index)
              ""
              ""
              0))
          (doc_import_form_vec.push-ref!
            (&mut forms)
            (string.int->string index))
          (doc_macro_import_example_vec.push-ref!
            (&mut macro-examples)
            (doc_expand.DocMacroImportExample (string.int->string index) ""))
          (doc_generated_target_example_vec.push-ref!
            (&mut targets)
            (doc_expand.DocGeneratedTargetExample (string.int->string index) ""))
          (doc_module_vec.push-ref!
            (&mut modules)
            (doc_render.DocModule.Module
              (string.int->string index)
              (doc_extract.doc-extraction-empty)))
          (set! index (+ index 1))))
      (unless
        (and
          (= (doc_extract.doc-item-list-count (clone items)) 6)
          (= (doc_import_form_vec.len (& forms)) 6)
          (= (doc_macro_import_example_vec.len (& macro-examples)) 6)
          (= (doc_generated_target_example_vec.len (& targets)) 6)
          (= (doc_render.doc-module-list-count (clone modules)) 6)
          (string.eq
            (doc_extract.doc-item-name
              (doc_extract.doc-item-list-ref (clone items) 0))
            "0")
          (string.eq
            (doc_extract.doc-item-name
              (doc_extract.doc-item-list-ref (clone items) 5))
            "5")
          (string.eq (doc_import_form_vec.get (& forms) 0 "") "0")
          (string.eq (doc_import_form_vec.get (& forms) 5 "") "5")
          (string.eq
            (__tl-project-field
              (doc_macro_import_example_vec.get
                (& macro-examples)
                5
                (doc_expand.doc-macro-import-example-fallback))
              alias)
            "5")
          (string.eq
            (__tl-project-field
              (doc_generated_target_example_vec.get
                (& targets)
                5
                (doc_expand.doc-generated-target-example-fallback))
              target)
            "5")
          (string.eq
            (doc_render.doc-module-path
              (doc_render.doc-module-list-ref (clone modules) 0))
            "0")
          (string.eq
            (doc_render.doc-module-path
              (doc_render.doc-module-list-ref (clone modules) 5))
            "5"))
        (io.panic "doc-expand: generated vector growth/order mismatch")))))

(test
  doc-expand-context-owner-isolation
  (let
    [home-intern : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [home-pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-capture-active)]
    [intern-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [intern-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [name-a : i64
      (ci.intern-compat-state-intern (&mut intern-a) "owner-a-name")]
    [name-b : i64
      (ci.intern-compat-state-intern (&mut intern-b) "decoy-b-name")]
    [pools-a : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 2)]
    [pools-b : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 2)]
    [type-a : i64
      (ast.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view pools-a)
        (ast.AstType.Struct name-a))]
    [type-b : i64
      (ast.ast-node-pool-context-type-push
        (owned_view.compiler-owned-shared-view pools-b)
        (ast.AstType.I64))]
    [expr-a : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view pools-a)
        (ast.AstExpr.TypeLiteral type-a))]
    [expr-b : i64
      (ast.ast-node-pool-context-expr-push
        (owned_view.compiler-owned-shared-view pools-b)
        (ast.AstExpr.Literal (ast.ast-lit-int 99)))]
    [ctx-a : doc_expand.DocExpandContext
      (doc_expand.doc-expand-context-from-pools-and-intern-state
        pools-a
        intern-a)]
    [decoy-intern-before : i64 (ci.intern-compat-state-pool-len (& intern-b))]
    [decoy-exprs-before : i64 (ast.ast-node-pool-context-expr-len pools-b)]
    [decoy-types-before : i64 (ast.ast-node-pool-context-type-len pools-b)]
    [ok : bool false]
    (begin
      (ci.intern-compat-state-install!
        (owned_view.compiler-owned-shared-view intern-b))
      (ast.ast-node-pool-context-install!
        (owned_view.compiler-owned-shared-view pools-b))
      (set!
        ok
        (and
          (= name-a name-b)
          (= type-a type-b)
          (= expr-a expr-b)
          (string.eq
            (doc_expand.doc-ast-expr-source ctx-a expr-a)
            "(type owner-a-name)")
          (= (ci.intern-compat-state-pool-len (& intern-b)) decoy-intern-before)
          (= (ast.ast-node-pool-context-expr-len pools-b) decoy-exprs-before)
          (= (ast.ast-node-pool-context-type-len pools-b) decoy-types-before)
          (=
            (ci.intern-active-table-id)
            (ci.intern-compat-state-table-id (& intern-b)))
          (=
            (ast.ast-node-pool-active-expr-segment-bases)
            (ast.ast-node-pool-context-expr-segment-bases (& pools-b)))
          (=
            (ast.ast-node-pool-reader-type-segment-bases)
            (ast.ast-node-pool-context-type-segment-bases (& pools-b)))))
      (ci.intern-compat-state-install! home-intern)
      (ast.ast-node-pool-context-install! home-pools)
      (ast.ast-node-pool-context-destroy-storage! pools-a)
      (ast.ast-node-pool-context-destroy-storage! pools-b)
      (unless
        ok
        (io.panic "doc-expand: explicit owner context followed active decoy")))))

(define (doc-expand-smoke) : i64
  (let
    [roots : doc_svec.Vec (doc_svec.new)]
    (match (compiler_load.compiler-load-source-with-paths-and-roots
      "doc_expand_smoke.tl"
      "(module doc.generated.fixture)
(import stdlib.comptime)

(defmacro (boxmod [T : type]) : Module
  (let
    [module-name : comptime.Expr
      (comptime.expr-var \"doc.generated.fixture.box_i64\")]
    `(begin
      (module ,module-name)
      (defstruct Box
        (value ,T))
      (defenum Status
        (Empty)
        (Full ,T))
      (define (new [value : ,T]) : Box
        (Box value))
      (define (value [b : (& b Box)]) : ,T
        b.value))))

(import (boxmod i64) as ibox)"
      (sym_i64_env.sym-i64-empty)
      (owned_view.compiler-owned-shared-view roots))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
        (let
          [pools : ast.AstNodePoolContext
            (ast.ast-node-pool-context-capture-active)]
          [intern-state : ci.InternCompatState
            (ci.intern-compat-state-capture-active)]
          (match (doc_expand.doc-expanded-generated-modules-from-loaded-decls-with-state-and-pools-and-intern-state
            (compiler_load.compiler-load-serial-test-session-state)
            (tc.tc-serial-job-state)
            decls
            paths
            roots
            pools
            intern-state)
            [(doc_expand.ResultDocExpandedModules.Ok modules)
              (let
                [rendered : String
                  (doc_render.doc-render-module-graph-markdown modules)]
                (if (and
                  (string.contains rendered "doc.generated.fixture.box\\_i64")
                  (string.contains rendered "(import (boxmod i64) as ibox)")
                  (string.contains rendered "### Box")
                  (string.contains rendered "### Status")
                  (string.contains rendered "### new"))
                  42
                  (io.panic "doc-expand: generated module docs smoke mismatch")))]
            [(doc_expand.ResultDocExpandedModules.Err message)
              (io.panic
                (doc_expand.doc-cat2 "doc-expand: expansion failed: " message))]))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
        (io.panic
          (doc_expand.doc-cat2
            "doc-expand: load failed: "
            (cdiag.compiler-diagnostic-render
              (cdiag.compiler-diagnostic-box-shared-view diag))))])))

(define (doc-expand-ignore-fence-smoke) : i64
  (let
    [ignored : String
      "Before
```lisp test=ignore name=sketch
(import missing.format as fmt)
(import (serialize.serialize fmt Person) as person_ser)
```
After"]
    [active : String
      "```typelisp
(import stdlib.vector)
(import (vector.vector i64) as ivec)
```"]
    [ignored-scan : doc_expand.DocImportFormScan
      (doc_expand.doc-import-forms-from-doc-text ignored)]
    [active-scan : doc_expand.DocImportFormScan
      (doc_expand.doc-import-forms-from-doc-text active)]
    (if (and (not ignored-scan.has-macro) active-scan.has-macro)
      42
      (io.panic "doc-expand: ignored fence import scan mismatch"))))