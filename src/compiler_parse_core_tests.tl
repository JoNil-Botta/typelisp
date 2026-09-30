;; compiler_parse_core_tests.tl - White-box tests for the parser: declarations,
;; expressions, patterns, metadata, spans, error paths and compiler-parse-smoke.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.io)
(import compiler_intern as ci)
(import compiler_ast_types as ast)
(import compiler_ast_types_tests as ast_tests)
(import compiler_builtin_ids as cbi)
(import compiler_diagnostic as cdiag)
(import lex as lexer)
(import read as reader)
(import reader_tests)
(import sym_i64_env)
(import stdlib.string)
(import stdlib.option)
(import token)
(import (option.option i64) as option_i64)
(import compiler_parse_core as parser)

;; Named compatibility adapter for parser-only tests that deliberately exercise
;; the installed serial table. Production parse paths use the dispatch owner.
(define (compiler-parse-name-text [name-id : i64]) : String
  (let
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    (parser.compiler-parse-name-text-with-state intern-state name-id)))

(define (parse-ast-program-with-cfg
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cfgs : sym_i64_env.SymI64Env]) : parser.ResultAstProgram
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : parser.ResultAstProgram
      (parser.parse-ast-program-with-cfg-and-pools toks cfgs pools)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      result)))

(define (parse-ast-program [toks : (__tl_dyn-array token.SpannedToken)]) : parser.ResultAstProgram
  (parse-ast-program-with-cfg toks (parser.compiler-cfg-empty)))

(define (parse-ast-source-recovery-diagnostic [path : String] [src : String]) : parser.ResultAstProgramRecovery
  (parser.parse-ast-source-recovery-diagnostic-with-cfg
    path
    src
    (parser.compiler-cfg-empty)))

(define (ast-decl-list-tag-sum [decls : ast.AstDeclList]) : i64
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) 0]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (+ (ast_tests.ast-decl-tag decl) (ast-decl-list-tag-sum rest)))]))

(define (compiler-parse-expr-list-count [exprs : (& exprs ast.AstExprList)]) : i64
  exprs.len)

(define (compiler-parse-macro-call-node-ok?
  [call-expr : i64]
  [name : String]
  [want-args : i64]) : bool
  (match (ast.ast-expr-unspan (ast.ast-node-get call-expr))
    [(ast.AstExpr.Call head args)
      (let
        [head-expr : ast.AstExpr (ast.ast-node-get head)]
        (and
          (= (compiler-parse-expr-list-count args) want-args)
          (match (ast.ast-expr-unspan head-expr)
            [(ast.AstExpr.Var found) (string.eq (ci.intern-str found) name)]
            [_ false])))]
    [_ false]))

(define (compiler-parse-resource-binding-count
  [bindings : ast.AstResourceBindingList]) : i64
  (ast.ast-resource-binding-list-len (& bindings)))

(define (ast-first-import-ok? [decls : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Cons
        (ast.AstDecl.Import
          _
          (ast.AstImportSpec.Spec
            (ast.AstImportKind.Module)
            path
            (ast.AstMaybeModuleName.Some module-name)
            (ast.AstMaybeImportAlias.Some alias)
            _))
        _)
      (and
        (string.eq path "stdlib.test")
        (string.eq (ci.intern-str module-name) "stdlib.test")
        (string.eq (ci.intern-str alias) "test"))]
    [_ false]))

(define (ast-first-include-str-ok? [decls : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Cons (ast.AstDecl.IncludeStr name path) _)
      (and
        (string.eq (ci.intern-str name) "payload")
        (string.eq path "data.txt"))]
    [_ false]))

(define (ast-first-include-str-comptime-ok? [decls : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Cons (ast.AstDecl.IncludeStrComptime name path) _)
      (and
        (string.eq (ci.intern-str name) "payload")
        (string.eq path "data.txt"))]
    [_ false]))

(define (ast-first-include-str-lzss-ok? [decls : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Cons (ast.AstDecl.IncludeStrLzss name path) _)
      (and
        (string.eq (ci.intern-str name) "payload")
        (string.eq path "data.txt"))]
    [_ false]))

(define (ast-first-include-bin-ok? [decls : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Cons (ast.AstDecl.IncludeBin name path) _)
      (and
        (string.eq (ci.intern-str name) "payload")
        (string.eq path "data.bin"))]
    [_ false]))

(define (compiler-parse-module-decl-ok?) : bool
  (match (parser.parse-ast-source "(module std.io)")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons (ast.AstDecl.Module name) rest)
            (let
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (= name (reader.stable-symbol-id "std.io"))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-module-body-ok?) : bool
  (match (parser.parse-ast-source
    "(module local.helper (define value : i64 1))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.ModuleBody name body-box)
              rest)
            (let
              [rest : ast.AstDeclList rest]
              [body : ast.AstDeclList (deref body-box)]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (match (ast.ast-decl-list-step body)
                    [(ast.AstDeclListStep.Cons
                        (ast.AstDecl.Def _ value-name _ _)
                        body-rest)
                      (let
                        [body-rest : ast.AstDeclList body-rest]
                        (and
                          (= name (reader.stable-symbol-id "local.helper"))
                          (= value-name (reader.stable-symbol-id "value"))
                          (match (ast.ast-decl-list-step body-rest)
                            [(ast.AstDeclListStep.Nil) true]
                            [_ false])))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-module-body-malformed-ok?) : bool
  (match (parser.parse-ast-source "(module local.helper (define bad))")
    [(parser.ResultAstProgram.Ok _) false]
    [(parser.ResultAstProgram.Err message)
      (string.eq message "parse: malformed value definition")]))

(define (compiler-parse-import-metadata-ok?) : bool
  (match (parser.parse-ast-source "(import stdlib.core_macros as io)")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.Import
                _
                (ast.AstImportSpec.Spec
                  (ast.AstImportKind.Module)
                  path
                  (ast.AstMaybeModuleName.Some module-name)
                  (ast.AstMaybeImportAlias.Some alias)
                  _))
              rest)
            (let
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (string.eq path "stdlib.core_macros")
                    (string.eq (ci.intern-str module-name) "stdlib.core_macros")
                    (string.eq (ci.intern-str alias) "io"))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-dotted-import-explicit-alias-ok?) : bool
  (match (parser.parse-ast-source "(import stdlib.core_macros as core)")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.Import
                _
                (ast.AstImportSpec.Spec
                  (ast.AstImportKind.Module)
                  module-path
                  (ast.AstMaybeModuleName.Some module-name)
                  (ast.AstMaybeImportAlias.Some alias)
                  _))
              rest)
            (let
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (string.eq module-path "stdlib.core_macros")
                    (string.eq (ci.intern-str module-name) "stdlib.core_macros")
                    (string.eq (ci.intern-str alias) "core"))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-dotted-import-default-alias-ok?) : bool
  (match (parser.parse-ast-source "(import stdlib.core_macros)")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.Import
                _
                (ast.AstImportSpec.Spec
                  (ast.AstImportKind.Module)
                  module-path
                  (ast.AstMaybeModuleName.Some module-name)
                  (ast.AstMaybeImportAlias.Some alias)
                  _))
              rest)
            (let
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (string.eq module-path "stdlib.core_macros")
                    (string.eq (ci.intern-str module-name) "stdlib.core_macros")
                    (string.eq (ci.intern-str alias) "core_macros"))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-dotted-import-wildcard-ok?) : bool
  (match (parser.parse-ast-source "(import stdlib.core_macros.*)")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.Import
                _
                (ast.AstImportSpec.Spec
                  (ast.AstImportKind.ModuleAll)
                  module-path
                  (ast.AstMaybeModuleName.Some module-name)
                  (ast.AstMaybeImportAlias.Some alias)
                  _))
              rest)
            (let
              [rest : ast.AstDeclList rest]
              (and
                (ast_tests.ast-decl-list-empty? (& rest))
                (string.eq module-path "stdlib.core_macros")
                (string.eq (ci.intern-str module-name) "stdlib.core_macros")
                (= alias cbi.compiler-builtin-id-fix-empty)))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-dotted-import-metadata-ok?) : bool
  (and
    (compiler-parse-dotted-import-explicit-alias-ok?)
    (compiler-parse-dotted-import-default-alias-ok?)
    (compiler-parse-dotted-import-wildcard-ok?)))

(define (compiler-parse-module-macro-call-ok?) : bool
  (match (parser.parse-ast-source "(point-vec i64)")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.Import
                _
                (ast.AstImportSpec.Spec
                  (ast.AstImportKind.MacroDecls call-expr _)
                  path
                  (ast.AstMaybeModuleName.No)
                  (ast.AstMaybeImportAlias.No)
                  _))
              rest)
            (let
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (string.eq path "")
                    (compiler-parse-macro-call-node-ok? call-expr "point-vec" 1))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-macro-import-ok?) : bool
  (match (parser.parse-ast-source "(import (vector.vector i64) as svec)")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.Import
                _
                (ast.AstImportSpec.Spec
                  (ast.AstImportKind.Macro call-expr _)
                  path
                  (ast.AstMaybeModuleName.No)
                  (ast.AstMaybeImportAlias.Some alias)
                  _))
              rest)
            (let
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (string.eq path "")
                    (string.eq (ci.intern-str alias) "svec")
                    (compiler-parse-macro-call-node-ok?
                      call-expr
                      "vector.vector"
                      1))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-module-macro-surface-ok?) : bool
  (and
    (compiler-parse-module-macro-call-ok?)
    (compiler-parse-macro-import-ok?)
    (compiler-parse-error-ok? "(import vector i64)" "parse: malformed import")))

(define (compiler-parse-dotted-import-errors-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(import \"stdlib/core.tl\")"
      "parse: string-path imports are no longer supported; use a dotted module identity")
    (compiler-parse-error-ok?
      "(import \"stdlib/core.tl\" module stdlib.core)"
      "parse: string-path imports are no longer supported; use a dotted module identity")
    (compiler-parse-error-ok?
      "(import stdlib.core :as core)"
      "parse: malformed import")
    (compiler-parse-error-ok?
      "(import stdlib..core)"
      "parse: invalid dotted import module name")
    (compiler-parse-error-ok?
      "(import stdlib/core)"
      "parse: invalid dotted import module name")
    (compiler-parse-error-ok?
      "(import pkg:math.core)"
      "parse: invalid dotted import module name")
    (compiler-parse-error-ok?
      "(import stdlib.core.* as core)"
      "parse: wildcard import cannot use as; import a selected item instead")
    (compiler-parse-error-ok?
      "(import stdlib.core_macros module stdlib.core_macros)"
      "parse: malformed import")))

(define (compiler-parse-include-str-ok?) : bool
  (match (parser.parse-ast-source "(include-str payload \"data.txt\")")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (ast-first-include-str-ok? decls))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-include-str-errors-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(include-str)"
      "parse: include-str expects name and string path")
    (compiler-parse-error-ok?
      "(include-str \"name\" \"data.txt\")"
      "parse: include-str name must be a symbol")
    (compiler-parse-error-ok?
      "(include-str payload data.txt)"
      "parse: include-str path must be a string")
    (compiler-parse-error-ok?
      "(include-str payload \"data.txt\" extra)"
      "parse: include-str expects exactly two operands")
    (compiler-parse-error-ok?
      "(include-str payload)"
      "parse: include-str expects name and string path")))

(define (compiler-parse-include-str-comptime-ok?) : bool
  (match (parser.parse-ast-source "(include-str-comptime payload \"data.txt\")")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (ast-first-include-str-comptime-ok? (deref decls-box))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-include-str-comptime-errors-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(include-str-comptime)"
      "parse: include-str-comptime expects name and string path")
    (compiler-parse-error-ok?
      "(include-str-comptime \"name\" \"data.txt\")"
      "parse: include-str-comptime name must be a symbol")
    (compiler-parse-error-ok?
      "(include-str-comptime payload data.txt)"
      "parse: include-str-comptime path must be a string")
    (compiler-parse-error-ok?
      "(include-str-comptime payload \"data.txt\" extra)"
      "parse: include-str-comptime expects exactly two operands")))

(define (compiler-parse-include-str-lzss-ok?) : bool
  (match (parser.parse-ast-source "(include-str-lzss payload \"data.txt\")")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (ast-first-include-str-lzss-ok? (deref decls-box))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-include-str-lzss-errors-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(include-str-lzss)"
      "parse: include-str-lzss expects name and string path")
    (compiler-parse-error-ok?
      "(include-str-lzss \"name\" \"data.txt\")"
      "parse: include-str-lzss name must be a symbol")
    (compiler-parse-error-ok?
      "(include-str-lzss payload data.txt)"
      "parse: include-str-lzss path must be a string")
    (compiler-parse-error-ok?
      "(include-str-lzss payload \"data.txt\" extra)"
      "parse: include-str-lzss expects exactly two operands")))

(define (compiler-parse-removed-compressed-include-rejected?) : bool
  (compiler-parse-error-ok?
    (str_cat.str-cat
      "("
      (parser.compiler-parse-removed-compressed-include-name)
      " payload \"data.txt\")")
    (parser.compiler-parse-removed-compressed-include-message)))

(define (compiler-parse-include-bin-ok?) : bool
  (match (parser.parse-ast-source "(include-bin payload \"data.bin\")")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (ast-first-include-bin-ok? decls))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-include-bin-errors-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(include-bin)"
      "parse: include-bin expects name and string path")
    (compiler-parse-error-ok?
      "(include-bin \"name\" \"data.bin\")"
      "parse: include-bin name must be a symbol")
    (compiler-parse-error-ok?
      "(include-bin payload data.bin)"
      "parse: include-bin path must be a string")
    (compiler-parse-error-ok?
      "(include-bin payload \"data.bin\" extra)"
      "parse: include-bin expects exactly two operands")
    (compiler-parse-error-ok?
      "(include-bin payload)"
      "parse: include-bin expects name and string path")))

(define (compiler-parse-defdispatch-variants-ok?
  [variants : ast.AstDispatchVariantList]) : bool
  (if (= variants.len 3)
    (match (ast.ast-dispatch-variant-list-get
      (& variants)
      0
      (ast.ast-dispatch-variant-fallback))
      [(ast.AstDispatchVariant.Variant (ast.AstDispatchIsa.Scalar) scalar-name)
        (match (ast.ast-dispatch-variant-list-get
          (& variants)
          1
          (ast.ast-dispatch-variant-fallback))
          [(ast.AstDispatchVariant.Variant (ast.AstDispatchIsa.Avx2) avx2-name)
            (match (ast.ast-dispatch-variant-list-get
              (& variants)
              2
              (ast.ast-dispatch-variant-fallback))
              [(ast.AstDispatchVariant.Variant
                  (ast.AstDispatchIsa.Avx512)
                  avx512-name)
                (and
                  (= scalar-name (reader.stable-symbol-id "dot-scalar"))
                  (= avx2-name (reader.stable-symbol-id "dot-avx2"))
                  (= avx512-name (reader.stable-symbol-id "dot-avx512")))]
              [_ false])]
          [_ false])]
      [_ false])
    false))

(define (compiler-parse-defdispatch-shape-ok?) : bool
  (match (parser.parse-ast-source
    "(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2) (avx512 dot-avx512))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefDispatch decl-meta name variants)
              rest)
            (let
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (= name (reader.stable-symbol-id "dot"))
                    (compiler-parse-defdispatch-variants-ok? variants))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-defdispatch-scalar-only-ok?) : bool
  (match (parser.parse-ast-source "(defdispatch id (scalar id-scalar))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefDispatch decl-meta name variants)
              rest)
            (let
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (= name (reader.stable-symbol-id "id"))
                    (= variants.len 1)
                    (match (ast.ast-dispatch-variant-list-get
                      (& variants)
                      0
                      (ast.ast-dispatch-variant-fallback))
                      [(ast.AstDispatchVariant.Variant
                          (ast.AstDispatchIsa.Scalar)
                          scalar-name)
                        (= scalar-name (reader.stable-symbol-id "id-scalar"))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-defdispatch-tests-ok?) : bool
  (and
    (compiler-parse-defdispatch-shape-ok?)
    (compiler-parse-defdispatch-scalar-only-ok?)
    (compiler-parse-error-ok?
      "(defdispatch dot)"
      "parse: defdispatch needs at least one variant")
    (compiler-parse-error-ok?
      "(defdispatch dot (sse2 dot-sse2))"
      "parse: unknown defdispatch ISA sse2")
    (compiler-parse-error-ok?
      "(defdispatch dot (scalar))"
      "parse: malformed defdispatch variant")))

(define (ast-expr-inner-tag [expr : ast.AstExpr]) : i64
  (ast_tests.ast-expr-tag (ast.ast-expr-unspan expr)))

(define (ast-main-body-tag [decls : ast.AstDeclList]) : i64
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) 0]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match decl
          [(ast.AstDecl.DefFn decl-meta name _ _ body-box _)
            (let
              [body : ast.AstExpr (ast.ast-node-get body-box)]
              (if (= name cbi.compiler-builtin-id-fix-main)
                (ast-expr-inner-tag body)
                (ast-main-body-tag rest)))]
          [_ (ast-main-body-tag rest)]))]))

(define (compiler-parse-nested-expr-span-ok?) : bool
  (match (parser.parse-ast-source "(define (main) : i64 (+ 1 (* 2 3)))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefFn decl-meta _ _ _ body-box _)
              _)
            (let
              [body : ast.AstExpr (ast.ast-node-get body-box)]
              (match body
                [(ast.AstExpr.Spanned inner-box body-span)
                  (let
                    [inner : ast.AstExpr (ast.ast-node-get inner-box)]
                    (match inner
                      [(ast.AstExpr.Binary _ _ right-box)
                        (let
                          [right : ast.AstExpr (ast.ast-node-get right-box)]
                          (match right
                            [(ast.AstExpr.Spanned right-inner-box right-span)
                              (let
                                [right-inner : ast.AstExpr
                                  (ast.ast-node-get right-inner-box)]
                                (match right-inner
                                  [(ast.AstExpr.Binary _ _ _)
                                    (and
                                      (=
                                        (ast.ast-source-span-start-line
                                          body-span)
                                        1)
                                      (=
                                        (ast.ast-source-span-start-line
                                          right-span)
                                        1)
                                      (>
                                        (ast.ast-source-span-start-col
                                          right-span)
                                        (ast.ast-source-span-start-col
                                          body-span)))]
                                  [_ false]))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-error-span-ok?) : bool
  (let
    [src : String "(define)"]
    (and
      (match (parser.parse-ast-source
        (parser.compiler-parse-place-shared-view src))
        [(parser.ResultAstProgram.Err message)
          (string.eq message "parse: malformed define")]
        [_ false])
      (match (lexer.spanned-result src)
        [(lexer.ResultSpannedTokens.Ok toks)
          (let
            [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
            (begin
              (set! (array-ref cur 0) 0)
              (match (reader.form-spanned-result (& toks) (&mut cur))
                [(reader.ResultSpannedSexpr.Ok form)
                  (let
                    [span : token.SourceSpan (reader.spanned-sexpr-span form)]
                    (and
                      (= (token.span-start-line span) 1)
                      (= (token.span-start-col span) 1)))]
                [(reader.ResultSpannedSexpr.Err _) false])))]
        [(lexer.ResultSpannedTokens.Err _) false]))))

(define (compiler-parse-diagnostic-location-ok?
  [path : String]
  [src : String]
  [want : String]
  [line : i64]
  [col : i64]) : bool
  (match (parser.parse-ast-source-diagnostic
    (parser.compiler-parse-place-shared-view path)
    src)
    [(parser.ResultAstProgramDiagnostic.Err diag)
      (and
        (string.eq (cdiag.compiler-diagnostic-path (__tl-box-place diag)) path)
        (= (cdiag.compiler-diagnostic-line (__tl-box-place diag)) line)
        (= (cdiag.compiler-diagnostic-col (__tl-box-place diag)) col)
        (string.eq
          (cdiag.compiler-diagnostic-message (__tl-box-place diag))
          want))]
    [(parser.ResultAstProgramDiagnostic.Ok _) false]))

(define (compiler-parse-nested-diagnostic-spans-ok?) : bool
  (and
    (compiler-parse-diagnostic-location-ok?
      "bad-define.tl"
      "(define)"
      "parse: malformed define"
      1
      1)
    (compiler-parse-diagnostic-location-ok?
      "nested-binary.tl"
      "(define (main) : i64
  (+ 1))"
      "parse: malformed binary expression"
      2
      3)
    (compiler-parse-diagnostic-location-ok?
      "nested-let.tl"
      "(define (main) : i64
  (let [x : i64 1]))"
      "parse: let missing body"
      2
      3)
    (compiler-parse-diagnostic-location-ok?
      "annotation-type.tl"
      "(define (main) : i64
  (cast 1 : (Ptr)))"
      "parse: Ptr expects exactly one type"
      2
      13)
    (compiler-parse-diagnostic-location-ok?
      "let-binding.tl"
      "(define (main) : i64
  (let [x : i64] x))"
      "parse: malformed let binding"
      2
      8)
    (compiler-parse-diagnostic-location-ok?
      "legacy-let-bindings.tl"
      "(define (main) : i64
  (let ([x : i64 1]) x))"
      "parse: parenthesized let bindings were removed; write leading [name [: type] init] bindings without parentheses"
      2
      8)
    (compiler-parse-diagnostic-location-ok?
      "legacy-empty-let.tl"
      "(define (main) : i64
  (let () 0))"
      "parse: (let () body...) was removed; write (let [] body...)"
      2
      8)))

(define (compiler-parse-reader-delimiter-diagnostics-ok?) : bool
  (and
    (compiler-parse-diagnostic-location-ok?
      "missing-paren.tl"
      "(define (main) : i64 0"
      "reader: unterminated list: reached end of input before ')'"
      1
      1)
    (compiler-parse-diagnostic-location-ok?
      "missing-bracket.tl"
      "["
      "reader: unterminated list: reached end of input before ']'"
      1
      1)
    (compiler-parse-diagnostic-location-ok?
      "wrong-close-list.tl"
      "(define]"
      "reader: mismatched delimiter: expected ')' but found ']' at 1:8"
      1
      8)
    (compiler-parse-diagnostic-location-ok?
      "wrong-close-bracket.tl"
      "[define)"
      "reader: mismatched delimiter: expected ']' but found ')' at 1:8"
      1
      8)))

(define (compiler-parse-float-literal-ok?) : bool
  (match (parser.parse-ast-source "(define (main) : f64 1.5)")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefFn _ name _ (ast.AstType.F64) body-box _)
              _)
            (let
              [body : ast.AstExpr (ast.ast-node-get body-box)]
              (and
                (= name cbi.compiler-builtin-id-fix-main)
                (match (ast.ast-expr-unspan body)
                  [(ast.AstExpr.Literal (ast.AstLiteral.Float text))
                    (string.eq text "1.5")]
                  [_ false])))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-smoke-score [program : ast.AstProgram]) : i64
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (+
          (parser.ast-decl-list-count
            (parser.compiler-parse-place-shared-view decls))
          (+
            (ast-decl-list-tag-sum
              (parser.compiler-parse-place-shared-view decls))
            (+
              (ast-main-body-tag
                (parser.compiler-parse-place-shared-view decls))
              (if (ast-first-import-ok? decls)
                1
                0)))))]))

;; True only when `src` fails to parse with exactly the wanted diagnostic. The
;; counterpart to the success-path smoke: it pins the parser's rejection
;; messages so a regression that drops or relabels an error is caught.
(define (compiler-parse-error-ok? [src : String] [want : String]) : bool
  (match (parser.parse-ast-source src)
    [(parser.ResultAstProgram.Err message) (string.eq message want)]
    [(parser.ResultAstProgram.Ok _) false]))

(define (compiler-parse-diagnostic-code-ok?) : bool
  (match (parser.parse-ast-source-diagnostic
    "parse-code.tl"
    (compiler-parse-malformed-binary-source))
    [(parser.ResultAstProgramDiagnostic.Err diag)
      (match (cdiag.compiler-diagnostic-code (__tl-box-place diag))
        [(CompilerDiagnosticSomeString code)
          (and
            (string.eq code (cdiag.compiler-diagnostic-code-parse))
            (match (cdiag.compiler-diagnostic-category (__tl-box-place diag))
              [(CompilerDiagnosticSomeString category)
                (string.eq category "parse")]
              [CompilerDiagnosticNoString false]))]
        [CompilerDiagnosticNoString false])]
    [(parser.ResultAstProgramDiagnostic.Ok _) false]))

;; Minimal complete programs that lex cleanly but reach a specific parser
;; rejection, one per representative special form.
(define (compiler-parse-malformed-binary-source) : String
  "(define (main) : i64 (+ 1))")

(define (compiler-parse-malformed-if-source) : String
  "(define (main) : i64 (if true 1))")

(define (compiler-parse-if-missing-else-diagnostic-notes-ok?) : bool
  (match (parser.parse-ast-source-diagnostic
    "missing-if-else.tl"
    (compiler-parse-malformed-if-source))
    [(parser.ResultAstProgramDiagnostic.Err diag)
      (let
        [rendered : String (cdiag.compiler-diagnostic-render (deref diag))]
        [message-needle : String "parse: if is missing its else branch"]
        [example-needle : String "example: (if condition then-expr else-expr)"]
        [when-needle : String "when condition body..."]
        [unless-needle : String "unless condition body..."]
        (and
          (string.contains (& rendered) (& message-needle))
          (string.contains (& rendered) (& example-needle))
          (string.contains (& rendered) (& when-needle))
          (string.contains (& rendered) (& unless-needle))))]
    [(parser.ResultAstProgramDiagnostic.Ok _) false]))

(define (compiler-parse-region-ok?) : bool
  (match (parser.parse-ast-source
    "(define (main) : (in r String)
  (with-arena r \"x\"))")
    [(parser.ResultAstProgram.Ok _) true]
    [(parser.ResultAstProgram.Err _) false]))

;; `with-arena` is the canonical spelling. Assert it parses to
;; the `AstExpr.WithRegion` form, not an unbound call.
(define (compiler-parse-arena-ok?) : bool
  (match (parser.parse-ast-source "(define (main) : i64
  (with-arena n 5))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefFn _ name _ (ast.AstType.I64) body-box _)
              _)
            (let
              [body : ast.AstExpr (ast.ast-node-get body-box)]
              (and
                (= name cbi.compiler-builtin-id-fix-main)
                (match (ast.ast-expr-unspan body)
                  [(ast.AstExpr.WithRegion region _)
                    (= region cbi.compiler-builtin-id-fix-n)]
                  [_ false])))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-type-ptr-u8? [ty : ast.AstType]) : bool
  (match ty
    [(ast.AstType.Ptr elem)
      (match (ast.ty-node-get elem)
        [(ast.AstType.U8) true]
        [_ false])]
    [_ false]))

(define (compiler-parse-type-ptr-i64? [ty : ast.AstType]) : bool
  (match ty
    [(ast.AstType.Ptr elem)
      (match (ast.ty-node-get elem)
        [(ast.AstType.I64) true]
        [_ false])]
    [_ false]))

(define (compiler-parse-type-mut-ptr-u8? [ty : ast.AstType]) : bool
  (match ty
    [(ast.AstType.MutPtr elem)
      (match (ast.ty-node-get elem)
        [(ast.AstType.U8) true]
        [_ false])]
    [_ false]))

(define (compiler-parse-type-mut-ptr-ptr-u8? [ty : ast.AstType]) : bool
  (match ty
    [(ast.AstType.MutPtr elem)
      (compiler-parse-type-ptr-u8? (ast.ty-node-get elem))]
    [_ false]))

(define (compiler-parse-type-ref-string? [ty : ast.AstType] [region : i64]) : bool
  (match ty
    [(ast.AstType.Ref actual inner)
      (and
        (= actual region)
        (match (ast.ty-node-get inner)
          [(ast.AstType.String) true]
          [_ false]))]
    [_ false]))

(define (compiler-parse-type-ref-str? [ty : ast.AstType] [region : i64]) : bool
  (match ty
    [(ast.AstType.Ref actual inner)
      (and
        (= actual region)
        (match (ast.ty-node-get inner)
          [(ast.AstType.Str) true]
          [_ false]))]
    [_ false]))

(define (compiler-parse-type-mut-ref-dyn-array-i64?
  [ty : ast.AstType]
  [region : i64]) : bool
  (match ty
    [(ast.AstType.MutRef actual inner)
      (and
        (= actual region)
        (match (ast.ty-node-get inner)
          [(ast.AstType.DynArray elem)
            (match (ast.ty-node-get elem)
              [(ast.AstType.I64) true]
              [_ false])]
          [_ false]))]
    [_ false]))

(define (compiler-parse-type-list-count [types : (& types ast.AstTypeList)]) : i64
  (ast.ast-type-list-len (& types)))

(define (compiler-parse-raw-pointer-ok?) : bool
  (match (parser.parse-ast-source
    "(extern (raw-map [arg0 : (Ptr i64)]) : (MutPtr (Ptr u8)))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.Extern decl-meta name _ _ ty)
              rest)
            (let
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (= name (reader.stable-symbol-id "raw-map"))
                    (match ty
                      [(ast.AstType.Func args ret)
                        (let
                          [args-list : ast.AstTypeList (deref args)]
                          (and
                            (= (ast.ast-type-list-len (& args-list)) 1)
                            (compiler-parse-type-ptr-i64?
                              (ast.ty-node-get
                                (ast.ast-type-list-get
                                  (& args-list)
                                  0
                                  (ast.ast-type-id-fallback))))
                            (compiler-parse-type-mut-ptr-ptr-u8?
                              (ast.ty-node-get ret))))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-extern-link-inputs-ok?
  [inputs : ast.AstExternLinkInputList]) : bool
  (and
    (= (ast.ast-extern-link-input-list-len (& inputs)) 3)
    (match (ast.ast-extern-link-input-list-get
      (& inputs)
      0
      (ast.ast-extern-link-input-fallback))
      [(ast.AstExternLinkInput.Lib lib) (string.eq lib "m")]
      [_ false])
    (match (ast.ast-extern-link-input-list-get
      (& inputs)
      1
      (ast.ast-extern-link-input-fallback))
      [(ast.AstExternLinkInput.Search dir) (string.eq dir "native/lib")]
      [_ false])
    (match (ast.ast-extern-link-input-list-get
      (& inputs)
      2
      (ast.ast-extern-link-input-fallback))
      [(ast.AstExternLinkInput.Arg arg-value)
        (string.eq arg-value "-Wl,--as-needed")]
      [_ false])))

(define (compiler-parse-extern-metadata-ok?) : bool
  (match (parser.parse-ast-source
    "(extern (local-call [arg0 : i64]) : i64 (:abi c) (:symbol \"foreign_exact\") (:link-lib \"m\") (:link-search \"native/lib\") (:link-arg \"-Wl,--as-needed\"))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.Extern decl-meta name _ metadata ty)
              rest)
            (let
              [rest : ast.AstDeclList rest]
              [metadata-view : ast.AstExternMetadata (deref metadata)]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (= name (reader.stable-symbol-id "local-call"))
                    (string.eq
                      (ast.ast-extern-metadata-symbol
                        (parser.compiler-parse-place-shared-view metadata-view))
                      "foreign_exact")
                    (ast.ast-extern-abi-c?
                      (ast.ast-extern-metadata-abi
                        (parser.compiler-parse-place-shared-view metadata-view)))
                    (compiler-parse-extern-link-inputs-ok?
                      (ast.ast-extern-metadata-link-inputs metadata-view))
                    (match ty
                      [(ast.AstType.Func args ret)
                        (let
                          [args-list : ast.AstTypeList (deref args)]
                          (and
                            (= (ast.ast-type-list-len (& args-list)) 1)
                            (match (ast.ty-node-get
                              (ast.ast-type-list-get
                                (& args-list)
                                0
                                (ast.ast-type-id-fallback)))
                              [(ast.AstType.I64) true]
                              [_ false])
                            (match (ast.ty-node-get ret)
                              [(ast.AstType.I64) true]
                              [_ false])))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-extern-varargs-metadata-rejected-ok?) : bool
  (compiler-parse-error-ok?
    "(extern (snprintf [arg0 : (MutPtr u8)] [arg1 : i64] [arg2 : (Ptr u8)] [arg3 : f64]) : i32 (:abi c-varargs 3) (:symbol \"snprintf\"))"
    (parser.parse-ast-extern-c-varargs-legacy-message)))

(define (compiler-parse-extern-head-typed-varargs-decl-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Extern decl-meta name _ metadata ty)
      (and
        (= name (reader.stable-symbol-id "snprintf"))
        (match (ast.ast-extern-metadata-abi (deref metadata))
          [(ast.AstExternAbi.CVarargsTyped tail-ty)
            (match tail-ty
              [(ast.AstType.F64) true]
              [_ false])]
          [_ false])
        (match ty
          [(ast.AstType.Func args ret)
            (let
              [args-list : ast.AstTypeList (deref args)]
              (and
                (= (compiler-parse-type-list-count args-list) 3)
                (match (ast.ty-node-get ret)
                  [(ast.AstType.I32) true]
                  [_ false])
                (compiler-parse-type-mut-ptr-u8?
                  (ast.ty-node-get
                    (ast.ast-type-list-get
                      (& args-list)
                      0
                      (ast.ast-type-id-fallback))))
                (match (ast.ty-node-get
                  (ast.ast-type-list-get
                    (& args-list)
                    1
                    (ast.ast-type-id-fallback)))
                  [(ast.AstType.I64) true]
                  [_ false])
                (compiler-parse-type-ptr-u8?
                  (ast.ty-node-get
                    (ast.ast-type-list-get
                      (& args-list)
                      2
                      (ast.ast-type-id-fallback))))))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-extern-head-open-varargs-decl-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Extern decl-meta name _ metadata ty)
      (and
        (= name (reader.stable-symbol-id "printf"))
        (match (ast.ast-extern-metadata-abi (deref metadata))
          [(ast.AstExternAbi.CVarargsOpen) true]
          [_ false])
        (match ty
          [(ast.AstType.Func args ret)
            (let
              [args-list : ast.AstTypeList (deref args)]
              (and
                (= (compiler-parse-type-list-count args-list) 1)
                (match (ast.ty-node-get ret)
                  [(ast.AstType.I32) true]
                  [_ false])
                (compiler-parse-type-ptr-u8?
                  (ast.ty-node-get
                    (ast.ast-type-list-get
                      (& args-list)
                      0
                      (ast.ast-type-id-fallback))))))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-i64-type? [ty : ast.AstType]) : bool
  (match ty
    [(ast.AstType.I64) true]
    [_ false]))

(define (compiler-parse-two-i64-types? [args : ast.AstTypeList]) : bool
  (and
    (= (ast.ast-type-list-len (& args)) 2)
    (compiler-parse-i64-type?
      (ast.ty-node-get
        (ast.ast-type-list-get (& args) 0 (ast.ast-type-id-fallback))))
    (compiler-parse-i64-type?
      (ast.ty-node-get
        (ast.ast-type-list-get (& args) 1 (ast.ast-type-id-fallback))))))

(define (compiler-parse-extern-head-fixed-decl-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Extern decl-meta name _ metadata ty)
      (and
        (= name (reader.stable-symbol-id "local-add"))
        (string.eq
          (ast.ast-extern-metadata-symbol (deref metadata))
          "foreign_add_exact")
        (match ty
          [(ast.AstType.Func args ret)
            (let
              [args-list : ast.AstTypeList (deref args)]
              (and
                (= (compiler-parse-type-list-count args-list) 2)
                (compiler-parse-i64-type? (ast.ty-node-get ret))
                (compiler-parse-two-i64-types? args-list)))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-extern-function-head-varargs-ok?) : bool
  (match (parser.parse-ast-source
    "(extern (snprintf [buf : (MutPtr u8)] [len : i64] [fmt : (Ptr u8)] [arg : ...f64]) : i32 (:symbol \"snprintf\"))
(extern (printf [fmt : (Ptr u8)] ...) : i32 (:symbol \"printf\"))
(extern (local-add [a : i64] [b : i64]) : i64 (:symbol \"foreign_add_exact\"))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (match (ast.ast-decl-list-step (deref decls-box))
        [(ast.AstDeclListStep.Cons first rest0)
          (let
            [rest0 : ast.AstDeclList rest0]
            (match (ast.ast-decl-list-step rest0)
              [(ast.AstDeclListStep.Cons second rest1)
                (let
                  [rest1 : ast.AstDeclList rest1]
                  (match (ast.ast-decl-list-step rest1)
                    [(ast.AstDeclListStep.Cons third rest2)
                      (let
                        [rest2 : ast.AstDeclList rest2]
                        (match (ast.ast-decl-list-step rest2)
                          [(ast.AstDeclListStep.Nil)
                            (and
                              (compiler-parse-extern-head-typed-varargs-decl-ok?
                                first)
                              (compiler-parse-extern-head-open-varargs-decl-ok?
                                second)
                              (compiler-parse-extern-head-fixed-decl-ok? third))]
                          [_ false]))]
                    [_ false]))]
              [_ false]))]
        [_ false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-raw-pointer-ops-ok?) : bool
  (compiler-parse-ok?
    "(define (main [p : (MutPtr i64)] [n : u64]) : u64
  (unsafe
    (ptr-write! p (ptr-read p))
    (ptr->int (ptr-cast (ptr-offset (int->ptr n : (MutPtr i64)) 1) : (Ptr i64)))))"))

(define (compiler-parse-init-ok?) : bool
  (match (parser.parse-ast-source "(define (main) : i64 (init : i64))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (match (ast.ast-decl-list-step (deref decls-box))
        [(ast.AstDeclListStep.Cons
            (ast.AstDecl.DefFn decl-meta _ _ _ body-box _)
            done-box)
          (let
            [done : ast.AstDeclList done-box]
            (and
              (ast_tests.ast-decl-list-empty? (& done))
              (match (ast.ast-expr-unspan (ast.ast-node-get body-box))
                [(ast.AstExpr.Init ty-id)
                  (match (ast.ast-maybe-type-from-id ty-id)
                    [(ast.AstMaybeType.Some inner)
                      (match inner
                        [(ast.AstType.I64) true]
                        [_ false])]
                    [_ false])]
                [_ false])))]
        [_ false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-contextual-init-ok?) : bool
  (match (parser.parse-ast-source
    "(define (init) : i64 7) (define (main) : i64 (init))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (match (ast.ast-decl-list-step (deref decls-box))
        [(ast.AstDeclListStep.Cons _ rest)
          (match (ast.ast-decl-list-step rest)
            [(ast.AstDeclListStep.Cons
                (ast.AstDecl.DefFn decl-meta _ _ _ body-box _)
                done-box)
              (let
                [done : ast.AstDeclList done-box]
                (and
                  (ast_tests.ast-decl-list-empty? (& done))
                  (match (ast.ast-expr-unspan (ast.ast-node-get body-box))
                    [(ast.AstExpr.Init ty-id)
                      (match (ast.ast-maybe-type-from-id ty-id)
                        [(ast.AstMaybeType.No) true]
                        [_ false])]
                    [_ false])))]
            [_ false])]
        [_ false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-init-call-name-ok?) : bool
  (compiler-parse-ok?
    "(define (init [n : i64]) : i64 n)
(define (main) : i64 (init 7))"))

(define (compiler-parse-box-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : (Box i64) (box 7))")
    (compiler-parse-ok? "(define (main [b : (Box i64)]) : i64 (deref b))")
    (compiler-parse-ok?
      "(define (main) : i64 (with-arena r (let [b : (in r (Box i64)) (box 7)] (deref b))))")))

(define (compiler-parse-array-data-ok?) : bool
  (and
    (compiler-parse-ok?
      "(define (data [items : (__tl_dyn-array i64)]) : (MutPtr i64) (unsafe (__tl_array-data items)))")
    (compiler-parse-error-ok?
      "(define (data [items : (__tl_dyn-array i64)]) : (MutPtr i64) (unsafe (__tl_array-data items items)))"
      "parse: __tl_array-data expects exactly one expression")))

(define (compiler-parse-array-take-ok?) : bool
  (and
    (compiler-parse-ok?
      "(define (main [items : (__tl_dyn-array i64)] [live : (__tl_dyn-array bool)]) : (Tuple bool i64) (__tl_array-take! items live 0))")
    ;; Keep the neighboring parser tag distinct: a previous collision caused
    ;; every dereference to dispatch to an array-take parser.
    (compiler-parse-ok? "(define (main [item : (Box i64)]) : i64 (deref item))")
    ;; Every public arity reports the single migration diagnostic.
    (compiler-parse-error-ok?
      "(define (main [items : (Array i64 1)]) : i64 (array-take! items 0))"
      "parse: array-take! was removed; use (replace! (array-ref array index) replacement)")
    (compiler-parse-error-ok?
      "(define (main [items : (Array i64 1)] [live : (Array bool 1)]) : i64 (array-take! items live 0))"
      "parse: array-take! was removed; use (replace! (array-ref array index) replacement)")))

(define (compiler-parse-replace-ok?) : bool
  (and
    (compiler-parse-ok?
      "(define (main) : i64 (let [value : i64 1] (replace! value 2)))")
    (compiler-parse-ok?
      "(define (main [items : (Array i64 2)] [i : i64]) : i64 (replace! (array-ref items i) 7))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (replace! value))"
      "parse: replace! expects exactly two operands")
    (compiler-parse-error-ok?
      "(define (main) : i64 (replace! value 1 2))"
      "parse: replace! expects exactly two operands")))

(define (compiler-parse-reference-ok?) : bool
  (match (parser.parse-ast-source
    "(define (use [s : (& n String)] [view : (& n str)] [items : (&mut value (__tl_dyn-array i64))]) : unit unit)")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefFn decl-meta _ params _ _ _)
              rest)
            (let
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (= (ast.ast-param-list-len (& params)) 3)
                    (match (ast.ast-param-list-get
                      (& params)
                      0
                      (ast.ast-param-fallback))
                      [(ast.AstParam.Param _ first-ty false)
                        (compiler-parse-type-ref-string?
                          first-ty
                          cbi.compiler-builtin-id-fix-n)]
                      [_ false])
                    (match (ast.ast-param-list-get
                      (& params)
                      1
                      (ast.ast-param-fallback))
                      [(ast.AstParam.Param _ second-ty false)
                        (compiler-parse-type-ref-str?
                          second-ty
                          cbi.compiler-builtin-id-fix-n)]
                      [_ false])
                    (match (ast.ast-param-list-get
                      (& params)
                      2
                      (ast.ast-param-fallback))
                      [(ast.AstParam.Param _ third-ty false)
                        (compiler-parse-type-mut-ref-dyn-array-i64?
                          third-ty
                          cbi.compiler-builtin-id-fix-value)]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-type-invalidate? [ty : ast.AstType] [lifetime : i64]) : bool
  (match ty
    [(ast.AstType.Invalidate actual inner)
      (and
        (= actual lifetime)
        (match (ast.ty-node-get inner)
          [(ast.AstType.VarArgs _ _) true]
          [_ false]))]
    [_ false]))

;; `(:invalidate r)` parameter metadata wraps the parameter type, and the
;; `(:invalidate r T)` type form spells the same wrapper inside a function
;; type (#6670).
(define (compiler-parse-invalidate-ok?) : bool
  (match (parser.parse-ast-source
    "(define (release [owner : (Arena r) (:invalidate r)] [f : (-> (:invalidate q (Arena q)) unit)] [n : i64]) : unit unit)")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (match (ast.ast-decl-list-step (deref decls-box))
        [(ast.AstDeclListStep.Cons (ast.AstDecl.DefFn _ _ params _ _ _) _)
          (and
            (= (ast.ast-param-list-len (& params)) 3)
            (match (ast.ast-param-list-get
              (& params)
              0
              (ast.ast-param-fallback))
              [(ast.AstParam.Param _ owner-ty false)
                (compiler-parse-type-invalidate? owner-ty (ci.intern "r"))]
              [_ false])
            (match (ast.ast-param-list-get
              (& params)
              1
              (ast.ast-param-fallback))
              [(ast.AstParam.Param _ (ast.AstType.Func args _) false)
                (compiler-parse-type-invalidate?
                  (ast.ty-node-get
                    (ast.ast-type-list-get
                      (& (deref args))
                      0
                      (ast.ast-type-id-fallback)))
                  (ci.intern "q"))]
              [_ false])
            (match (ast.ast-param-list-get
              (& params)
              2
              (ast.ast-param-fallback))
              [(ast.AstParam.Param _ (ast.AstType.I64) false) true]
              [_ false]))]
        [_ false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-invalidate-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(define (f [a : (Arena r) (:invalidate)]) : unit unit)"
      "parse: malformed :invalidate metadata; expected (:invalidate lifetime)")
    (compiler-parse-error-ok?
      "(define (f [a : (Arena r) (:invalidate r s)]) : unit unit)"
      "parse: malformed :invalidate metadata; expected (:invalidate lifetime)")
    (compiler-parse-error-ok?
      "(define (f [a : (Arena r) (:invalidate 1)]) : unit unit)"
      "parse: malformed :invalidate metadata; expected (:invalidate lifetime)")
    (compiler-parse-error-ok?
      "(define (f [a : (Arena r) (:invalidate r) (:invalidate r)]) : unit unit)"
      "parse: duplicate :invalidate parameter metadata")
    (compiler-parse-error-ok?
      "(define (f [a : (Arena r) (:invalidate r) (:unknown)]) : unit unit)"
      "parse: unknown parameter metadata :unknown")
    (compiler-parse-error-ok?
      "(define (f [comptime a : (Arena r) (:invalidate r)]) : unit unit)"
      "parse: :invalidate requires a runtime parameter")
    (compiler-parse-error-ok?
      "(define (f [g : (-> (:invalidate q) unit)]) : unit unit)"
      "parse: malformed :invalidate type; expected (:invalidate lifetime type)")
    (compiler-parse-error-ok?
      "(define (f [g : (-> (:invalidate 1 (Arena q)) unit)]) : unit unit)"
      "parse: malformed :invalidate type; expected (:invalidate lifetime type)")
    (compiler-parse-error-ok?
      "(define (f [g : (-> (:invalidate q (Arena q) i64) unit)]) : unit unit)"
      "parse: malformed :invalidate type; expected (:invalidate lifetime type)")
    (compiler-parse-error-ok?
      "(define (f [g : (-> (:invalidate q (Ptr)) unit)]) : unit unit)"
      "parse: Ptr expects exactly one type")))

(define (compiler-parse-borrow-ok?) : bool
  (match (parser.parse-ast-source
    "(define (main [x : i64]) : i64
  (begin
    (& x)
    (& x x)
    (&mut x)
    x))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefFn decl-meta _ _ _ body-box _)
              rest)
            (let
              [body : ast.AstExpr (ast.ast-node-get body-box)]
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (match (ast.ast-expr-unspan body)
                    [(ast.AstExpr.Begin exprs)
                      (if (>= exprs.len 2)
                        (let
                          [first : ast.AstExpr
                            (ast.ast-node-get
                              (ast.ast-expr-list-get (& exprs) 0 0))]
                          [second : ast.AstExpr
                            (ast.ast-node-get
                              (ast.ast-expr-list-get (& exprs) 1 0))]
                          (match (ast.ast-expr-unspan first)
                            [(ast.AstExpr.Borrow
                                _
                                first-lifetime-id
                                first-place-box)
                              (let
                                [first-place : ast.AstExpr
                                  (ast.ast-node-get first-place-box)]
                                (match (ast.ast-expr-unspan first-place)
                                  [(ast.AstExpr.Var first-name)
                                    (if (=
                                      first-name
                                      cbi.compiler-builtin-id-fix-x)
                                      (match (ast.ast-expr-unspan second)
                                        [(ast.AstExpr.Borrow
                                            _
                                            lifetime
                                            second-place-box)
                                          (let
                                            [second-place : ast.AstExpr
                                              (ast.ast-node-get
                                                second-place-box)]
                                            (match (ast.ast-expr-unspan
                                              second-place)
                                              [(ast.AstExpr.Var second-name)
                                                (and
                                                  (= first-lifetime-id -1)
                                                  (=
                                                    lifetime
                                                    cbi.compiler-builtin-id-fix-x)
                                                  (=
                                                    second-name
                                                    cbi.compiler-builtin-id-fix-x))]
                                              [_ false]))]
                                        [_ false])
                                      false)]
                                  [_ false]))]
                            [_ false]))
                        false)]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-try-ok?) : bool
  (match (parser.parse-ast-source "(define (main) : i64 (wrap (try (read))))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefFn decl-meta _ _ _ body-box _)
              rest)
            (let
              [body : ast.AstExpr (ast.ast-node-get body-box)]
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (match (ast.ast-expr-unspan body)
                    [(ast.AstExpr.Call _ args)
                      (if (= args.len 1)
                        (let
                          [arg : ast.AstExpr
                            (ast.ast-node-get
                              (ast.ast-expr-list-get (& args) 0 0))]
                          (match (ast.ast-expr-unspan arg)
                            [(ast.AstExpr.Try _) true]
                            [_ false]))
                        false)]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-return-ok?) : bool
  (match (parser.parse-ast-source "(define (main) : i64 (return 42))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefFn decl-meta _ _ _ body-box _)
              rest)
            (let
              [body : ast.AstExpr (ast.ast-node-get body-box)]
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (match (ast.ast-expr-unspan body)
                    [(ast.AstExpr.Return inner-box)
                      (let
                        [inner : ast.AstExpr (ast.ast-node-get inner-box)]
                        (match (ast.ast-expr-unspan inner)
                          [(ast.AstExpr.Literal (ast.AstLiteral.Int 42 _)) true]
                          [_ false]))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-call-head-name? [expr : ast.AstExpr] [name : String]) : bool
  (match (ast.ast-expr-unspan expr)
    [(ast.AstExpr.Var found) (string.eq (ci.intern-str found) name)]
    [_ false]))

(define (compiler-parse-return-expr? [expr : ast.AstExpr]) : bool
  (match (ast.ast-expr-unspan expr)
    [(ast.AstExpr.Return _) true]
    [_ false]))

(define (compiler-parse-guard-call-args-ok? [args : ast.AstExprList]) : bool
  (if (= args.len 2)
    (let
      [cond : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get (& args) 0 0))]
      [body-arg : ast.AstExpr
        (ast.ast-node-get (ast.ast-expr-list-get (& args) 1 0))]
      (and
        (compiler-parse-call-head-name? cond "ok")
        (compiler-parse-return-expr? body-arg)))
    false))

(define (compiler-parse-call-arg-count [args : (& args ast.AstExprList)]) : i64
  args.len)

(define (compiler-parse-call-body-ok?
  [source : String]
  [name : String]
  [want-args : i64]
  [check-guard-args : bool]) : bool
  (match (parser.parse-ast-source source)
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefFn decl-meta _ _ _ body-box _)
              rest)
            (let
              [body : ast.AstExpr (ast.ast-node-get body-box)]
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (match (ast.ast-expr-unspan body)
                    [(ast.AstExpr.Call func-box args)
                      (let
                        [func : ast.AstExpr (ast.ast-node-get func-box)]
                        (and
                          (compiler-parse-call-head-name? func name)
                          (= (compiler-parse-call-arg-count args) want-args)
                          (if check-guard-args
                            (compiler-parse-guard-call-args-ok? args)
                            true)))]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-guard-forms-ok?) : bool
  (and
    (compiler-parse-call-body-ok?
      "(define (main [ok : bool]) : unit (when ok (return unit)))"
      "when"
      2
      true)
    (compiler-parse-call-body-ok?
      "(define (main [ok : bool]) : unit (unless ok (return unit)))"
      "unless"
      2
      true)))

(define (compiler-parse-bracket-cond-call-ok?) : bool
  (and
    (compiler-parse-call-body-ok?
      "(define (main) : i64 (cond [(= 1 1) 1] [else 0]))"
      "cond"
      2
      false)
    (compiler-parse-call-body-ok?
      "(define (main) : i64 (core.cond [(= 1 1) 1] [else 0]))"
      "core.cond"
      2
      false)))

(define (compiler-parse-and-or-macro-call-candidates-ok?) : bool
  (and
    (compiler-parse-call-body-ok? "(define (main) : bool (and))" "and" 0 false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool]) : bool (and x))"
      "and"
      1
      false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool] [y : bool]) : bool (and x y))"
      "and"
      2
      false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool] [y : bool] [z : bool]) : bool (and x y z))"
      "and"
      3
      false)
    (compiler-parse-call-body-ok? "(define (main) : bool (or))" "or" 0 false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool]) : bool (or x))"
      "or"
      1
      false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool] [y : bool]) : bool (or x y))"
      "or"
      2
      false)
    (compiler-parse-call-body-ok?
      "(define (main [x : bool] [y : bool] [z : bool]) : bool (or x y z))"
      "or"
      3
      false)))

(define (compiler-parse-unsafe-decl-ok?) : bool
  (match (parser.parse-ast-source
    "(unsafe (define (danger [x : i64]) : i64 x))
(unsafe (extern (raw-call [arg0 : i64]) : i64))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons first tail)
            (let
              [tail : ast.AstDeclList tail]
              (match first
                [(ast.AstDecl.Unsafe first-inner-box)
                  (let
                    [first-inner : ast.AstDecl (deref first-inner-box)]
                    (match first-inner
                      [(ast.AstDecl.DefFn
                          decl-meta
                          name
                          _
                          (ast.AstType.I64)
                          _
                          _)
                        (match (ast.ast-decl-list-step tail)
                          [(ast.AstDeclListStep.Cons second done-box)
                            (let
                              [done : ast.AstDeclList done-box]
                              (and
                                (ast_tests.ast-decl-list-empty? (& done))
                                (match second
                                  [(ast.AstDecl.Unsafe second-inner-box)
                                    (let
                                      [second-inner : ast.AstDecl
                                        (deref second-inner-box)]
                                      (match second-inner
                                        [(ast.AstDecl.Extern
                                            _
                                            extern-name
                                            _
                                            _
                                            extern-ty)
                                          (and
                                            (=
                                              name
                                              (reader.stable-symbol-id "danger"))
                                            (=
                                              extern-name
                                              (reader.stable-symbol-id
                                                "raw-call"))
                                            (match extern-ty
                                              [(ast.AstType.Func _ ret)
                                                (match (ast.ty-node-get ret)
                                                  [(ast.AstType.I64) true]
                                                  [_ false])]
                                              [_ false]))]
                                        [_ false]))]
                                  [_ false])))]
                          [_ false])]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-field-count [fields : (& fields ast.AstFieldDefList)]) : i64
  fields.len)

(define (compiler-parse-field-cleanup-score [cleanup : ast.AstFieldCleanup]) : i64
  (match cleanup
    [(ast.AstFieldCleanup.No) 0]
    [(ast.AstFieldCleanup.Fn _) 10]
    [(ast.AstFieldCleanup.Owned) 100]))

(define (compiler-parse-field-cleanup-list-score [fields : ast.AstFieldDefList]) : i64
  (compiler-parse-field-cleanup-list-score-at (& fields) 0))

(define (compiler-parse-field-cleanup-list-score-at
  [fields : (& fields ast.AstFieldDefList)]
  [index : i64]) : i64
  (if (>= index fields.len)
    0
    (match (ast.ast-field-def-list-get
      fields
      index
      (ast.ast-field-def-fallback))
      [(ast.AstFieldDef.Def _ _ cleanup)
        (+
          (compiler-parse-field-cleanup-score cleanup)
          (compiler-parse-field-cleanup-list-score-at fields (+ index 1)))])))

(define (compiler-parse-variant-payload-cleanup-score
  [cleanup : ast.AstVariantPayloadCleanup]) : i64
  (match cleanup
    [(ast.AstVariantPayloadCleanup.No) 0]
    [(ast.AstVariantPayloadCleanup.Fn _) 10]
    [(ast.AstVariantPayloadCleanup.Owned) 100]))

(define (compiler-parse-variant-payload-cleanup-list-score
  [cleanups : ast.AstVariantPayloadCleanupList]) : i64
  (compiler-parse-variant-payload-cleanup-list-score-at (& cleanups) 0))

(define (compiler-parse-variant-payload-cleanup-list-score-at
  [cleanups : (& cleanups ast.AstVariantPayloadCleanupList)]
  [index : i64]) : i64
  (if (>= index cleanups.len)
    0
    (+
      (compiler-parse-variant-payload-cleanup-score
        (ast.ast-variant-payload-cleanup-list-get
          cleanups
          index
          (ast.ast-variant-payload-cleanup-fallback)))
      (compiler-parse-variant-payload-cleanup-list-score-at
        cleanups
        (+ index 1)))))

(define (compiler-parse-variant-list-cleanup-score
  [variants : ast.AstVariantDefList]) : i64
  (compiler-parse-variant-list-cleanup-score-at (& variants) 0))

(define (compiler-parse-variant-list-cleanup-score-at
  [variants : (& variants ast.AstVariantDefList)]
  [index : i64]) : i64
  (if (>= index variants.len)
    0
    (match (ast.ast-variant-def-list-get
      variants
      index
      (ast.ast-variant-def-fallback))
      [(ast.AstVariantDef.Def _ _ cleanups)
        (+
          (compiler-parse-variant-payload-cleanup-list-score cleanups)
          (compiler-parse-variant-list-cleanup-score-at variants (+ index 1)))])))

(define (compiler-parse-struct-cleanup-ok?) : bool
  (match (parser.parse-ast-source
    "(defstruct Resource
  (:cleanup close-resource)
  (fd i64 (:cleanup close-fd))
  (child i64 (:owned))
  (status i64))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefStruct _ name repr cleanup fields)
              rest)
            (let
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (= name (reader.stable-symbol-id "Resource"))
                    (match repr
                      [(ast.AstStructRepr.Default) true]
                      [_ false])
                    (match cleanup
                      [(ast.AstStructCleanup.Fn cleanup-name)
                        (=
                          (ci.intern-syntax-id-value cleanup-name)
                          (reader.stable-symbol-id "close-resource"))]
                      [_ false])
                    (= (compiler-parse-field-count fields) 3)
                    (= (compiler-parse-field-cleanup-list-score fields) 110))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-enum-cleanup-ok?) : bool
  (match (parser.parse-ast-source
    "(defenum Resource
  (:cleanup close-resource)
  (File i64 (:cleanup close-fd) Child (:owned) i64))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefEnum decl-meta name cleanup variants)
              rest)
            (let
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (= name (reader.stable-symbol-id "Resource"))
                    (match cleanup
                      [(ast.AstEnumCleanup.Fn cleanup-name)
                        (=
                          (ci.intern-syntax-id-value cleanup-name)
                          (reader.stable-symbol-id "close-resource"))]
                      [_ false])
                    (= (compiler-parse-variant-list-cleanup-score variants) 110))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-cleanup-metadata-ok?) : bool
  (and (compiler-parse-struct-cleanup-ok?) (compiler-parse-enum-cleanup-ok?)))

(define (compiler-parse-repr-c-ok?) : bool
  (match (parser.parse-ast-source
    "(defstruct Stat
  (:repr c)
  (size i64)
  (mtime i64))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefStruct decl-meta name repr _ fields)
              rest)
            (let
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (= name (reader.stable-symbol-id "Stat"))
                    (ast.ast-struct-repr-c? repr)
                    (= (compiler-parse-field-count fields) 2))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-inline-test-ok?) : bool
  (match (parser.parse-ast-source "(test parser-basic
  (+ 1 2)
  3)")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.Test name body-box metadata span)
              tail)
            (let
              [body : ast.AstExpr (ast.ast-node-get body-box)]
              [tail : ast.AstDeclList tail]
              (match (ast.ast-decl-list-step tail)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (= name (reader.stable-symbol-id "parser-basic"))
                    (= (ast.ast-source-span-start-line span) 1)
                    (match (ast.ast-test-metadata-ignore-reason metadata)
                      [(ast.AstTestIgnoreReason.No) true]
                      [_ false])
                    (not (ast.ast-test-metadata-slow? metadata))
                    (match (ast.ast-expr-unspan body)
                      [(ast.AstExpr.Begin exprs)
                        (= (compiler-parse-expr-list-count exprs) 2)]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-inline-test-metadata-ok?) : bool
  (and
    (match (parser.parse-ast-source
      "(test parser-metadata (:ignore \"not on CI\") (:slow) unit)")
      [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
        (let
          [decls : ast.AstDeclList (deref decls-box)]
          (match (ast.ast-decl-list-get (& decls) 0 (ast.ast-decl-fallback))
            [(ast.AstDecl.Test name _ metadata span)
              (and
                (= name (reader.stable-symbol-id "parser-metadata"))
                (= (ast.ast-source-span-start-line span) 1)
                (ast.ast-test-metadata-slow? metadata)
                (match (ast.ast-test-metadata-ignore-reason metadata)
                  [(ast.AstTestIgnoreReason.Some reason)
                    (string.eq reason "not on CI")]
                  [_ false]))]
            [_ false]))]
      [_ false])
    (compiler-parse-error-ok?
      "(test x (:ignore \"a\") (:ignore \"b\") unit)"
      "parse: duplicate test :ignore metadata")
    (compiler-parse-error-ok?
      "(test x (:slow) (:slow) unit)"
      "parse: duplicate test :slow metadata")
    (compiler-parse-error-ok?
      "(test x (:ignore \"\") unit)"
      "parse: test :ignore reason must not be empty")
    (compiler-parse-error-ok?
      "(test x (:ignore 1) unit)"
      "parse: test :ignore metadata expects one string reason")
    (compiler-parse-error-ok?
      "(test x (:slow 1) unit)"
      "parse: test :slow metadata takes no values")
    (compiler-parse-error-ok?
      "(test x (:unknown) unit)"
      "parse: unknown test metadata :unknown")
    (compiler-parse-error-ok?
      "(test x unit (:slow))"
      "parse: test metadata must appear before body expressions")
    (compiler-parse-diagnostic-location-ok?
      "test-metadata.tl"
      "(test x unit (:slow))"
      "parse: test metadata must appear before body expressions"
      1
      1)
    (compiler-parse-error-ok?
      "(test x (:slow))"
      "parse: test needs at least one expression")))

(define (compiler-parse-repr-c-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(defstruct Bad (:repr c) (:repr c) (x i64))"
      "parse: duplicate defstruct :repr metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:repr rust) (x i64))"
      "parse: unknown struct repr rust")
    (compiler-parse-error-ok?
      "(defstruct Bad (:repr packed) (x i64))"
      "parse: packed repr is reserved")
    (compiler-parse-error-ok?
      "(defstruct Bad (x i64) (:repr c))"
      "parse: defstruct metadata must appear before fields")
    (compiler-parse-error-ok?
      "(defstruct Bad (:layout c) (x i64))"
      "parse: unknown defstruct metadata :layout")
    (compiler-parse-error-ok?
      "(defstruct Bad (:repr c))"
      "parse: defstruct needs at least one field")))

(define (compiler-parse-first-decl-must-use? [source : String]) : bool
  (match (parser.parse-ast-source source)
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (and
          (= (ast.ast-decl-list-len (& decls)) 1)
          (let
            [decl (ast.ast-decl-list-ref decls 0)]
            (ast.ast-decl-must-use? decl))))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-must-use-metadata-ok?) : bool
  (and
    (not (compiler-parse-first-decl-must-use? "(defstruct Ticket (id i64))"))
    (not
      (compiler-parse-first-decl-must-use? "(defenum Status (Ok) (Err i64))"))
    (compiler-parse-first-decl-must-use?
      "(defstruct Ticket (:must-use) (id i64))")
    (compiler-parse-first-decl-must-use?
      "(defenum Status (:must-use) (Ok) (Err i64))")
    (compiler-parse-first-decl-must-use?
      "(defstruct View (:lifetimes a) (:must-use) (value (& a i64)))")
    (compiler-parse-first-decl-must-use?
      "(defenum View (:must-use) (:lifetimes a) (Some (& a i64)))")
    (compiler-parse-first-decl-must-use?
      "(defstruct Stat (:must-use) (:repr c) (size i64))")
    (compiler-parse-first-decl-must-use?
      "(defstruct File (:cleanup close-file) (:must-use) (fd i64))")
    (compiler-parse-first-decl-must-use?
      "(defenum File (:cleanup close-file) (:must-use) (Open i64))")
    (compiler-parse-error-ok?
      "(defstruct Bad (:must-use) (:must-use) (x i64))"
      "parse: duplicate defstruct :must-use metadata")
    (compiler-parse-error-ok?
      "(defenum Bad (:must-use) (:must-use) (Yes))"
      "parse: duplicate defenum :must-use metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:must-use x) (x i64))"
      "parse: :must-use metadata takes no arguments")
    (compiler-parse-error-ok?
      "(defenum Bad (:must-use x) (Yes))"
      "parse: :must-use metadata takes no arguments")
    (compiler-parse-error-ok?
      "(defstruct Bad (x i64) (:must-use))"
      "parse: defstruct metadata must appear before fields")
    (compiler-parse-error-ok?
      "(defenum Bad (Yes) (:must-use))"
      "parse: defenum metadata must appear before variants")
    (compiler-parse-error-ok?
      "(defstruct Bad (:cleanup close-bad) (x i64 (:must-use)))"
      "parse: unknown field metadata :must-use")
    (compiler-parse-error-ok?
      "(defenum Bad (:cleanup close-bad) (Yes i64 (:must-use)))"
      "parse: unknown enum payload metadata :must-use")
    (compiler-parse-error-ok?
      "(defstruct Bad (x i64 (:must-use)))"
      "parse: field cleanup metadata requires struct :cleanup metadata")
    (compiler-parse-error-ok?
      "(defenum Bad (Yes i64 (:must-use)))"
      "parse: enum payload cleanup metadata requires enum :cleanup metadata")
    (compiler-parse-error-ok?
      "(define (bad) (:must-use) : i64 1)"
      "parse: unknown define metadata :must-use")
    (compiler-parse-error-ok?
      "(test bad (:must-use) unit)"
      "parse: unknown test metadata :must-use")))

(define (compiler-parse-cleanup-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(defstruct Bad (:cleanup close) (:cleanup close2) (x i64))"
      "parse: duplicate defstruct :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (x i64 (:cleanup close-x)))"
      "parse: field cleanup metadata requires struct :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:repr c) (:cleanup close) (x i64))"
      "parse: defstruct cannot combine :repr c with :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:cleanup close) (:repr c) (x i64))"
      "parse: defstruct cannot combine :repr c with :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:cleanup) (x i64))"
      "parse: malformed defstruct :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:cleanup close) (x i64 (:cleanup)))"
      "parse: malformed field :cleanup metadata")
    (compiler-parse-error-ok?
      "(defstruct Bad (:cleanup close) (x i64 (:cleanup close-x) (:owned)))"
      "parse: duplicate field cleanup metadata")
    (compiler-parse-error-ok?
      "(defenum Bad (:cleanup close) (:cleanup close2) (A))"
      "parse: duplicate defenum :cleanup metadata")
    (compiler-parse-error-ok?
      "(defenum Bad (:cleanup) (A))"
      "parse: malformed defenum :cleanup metadata")
    (compiler-parse-error-ok?
      "(defenum Bad (A) (:cleanup close))"
      "parse: defenum metadata must appear before variants")
    (compiler-parse-error-ok?
      "(defenum Bad (A i64 (:cleanup close)))"
      "parse: enum payload cleanup metadata requires enum :cleanup metadata")))

(define (compiler-parse-unsafe-decl-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(unsafe)"
      "parse: unsafe declaration expects exactly one declaration")
    (compiler-parse-error-ok?
      "(unsafe (define value : i64 1))"
      "parse: unsafe declaration accepts only function define or extern")
    (compiler-parse-error-ok?
      "(unsafe (defstruct Bad (x i64)))"
      "parse: unsafe declaration accepts only function define or extern")
    (compiler-parse-error-ok?
      "(unsafe (extern (a) : i64) (extern (b) : i64))"
      "parse: unsafe declaration expects exactly one declaration")))

(define (compiler-parse-flat-let-call-body-ok?) : bool
  (match (parser.parse-ast-source
    "(define (id [x : i64]) : i64 x)
(define (main) : i64 (let [x : i64 41] (id x)))")
    [(parser.ResultAstProgram.Ok _) true]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-let-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(define (main) : i64 (let 1))"
      "parse: let requires at least one binding")
    (compiler-parse-error-ok?
      "(define (main) : i64 (let [x : i64] x))"
      "parse: malformed let binding")
    (compiler-parse-error-ok?
      "(define (main) : i64 (let [x : i64 1]))"
      "parse: let missing body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (let []))"
      "parse: let missing body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (let ()))"
      "parse: (let () body...) was removed; write (let [] body...)")
    (compiler-parse-error-ok?
      "(define (main) : i64 (let ([x : i64 1]) x))"
      "parse: parenthesized let bindings were removed; write leading [name [: type] init] bindings without parentheses")
    (compiler-parse-error-ok?
      "(define (main) : i64 (let ([x 1] [y (+ x 1)]) y))"
      "parse: parenthesized let bindings were removed; write leading [name [: type] init] bindings without parentheses")))

(define (compiler-parse-abstraction-policy-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(defgeneric Box [T] (value T))"
      (parser.compiler-parse-abstraction-policy-message))
    (compiler-parse-error-ok?
      "(trait Printable (print-self : (-> Self unit)))"
      (parser.compiler-parse-abstraction-policy-message))
    (compiler-parse-error-ok?
      "(define value : (Option i64) 0)"
      (parser.compiler-parse-generic-type-policy-message "Option"))))

(define (compiler-parse-raw-pointer-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(define (main [p : (Ptr)]) : unit unit)"
      "parse: Ptr expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main [p : (MutPtr i64 i64)]) : unit unit)"
      "parse: MutPtr expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main [p : (Ptr (Array))]) : unit unit)"
      "parse: malformed array type")
    (compiler-parse-error-ok?
      "(define (main [p : (Ptr i64)]) : i64 (ptr-read))"
      "parse: ptr-read expects exactly one expression")
    (compiler-parse-error-ok?
      "(define (main [p : (MutPtr i64)]) : unit (ptr-write! p))"
      "parse: ptr-write! expects exactly two expressions")
    (compiler-parse-error-ok?
      "(define (main) : (MutPtr i64) (unsafe (ptr-addr-of)))"
      "parse: ptr-addr-of expects exactly one addressable place")
    (compiler-parse-error-ok?
      "(define (main [x : i64] [y : i64]) : (MutPtr i64) (unsafe (ptr-addr-of x y)))"
      "parse: ptr-addr-of expects exactly one addressable place")
    (compiler-parse-error-ok?
      "(define (main [p : (Ptr i64)]) : (Ptr u8) (ptr-cast p (Ptr u8)))"
      "parse: pointer cast expects (form expr : pointer-type)")))

(define (compiler-parse-box-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(define (main [p : (Box)]) : unit unit)"
      "parse: Box expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main [p : (Box i64 bool)]) : unit unit)"
      "parse: Box expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main) : (Box i64) (box))"
      "parse: box expects exactly one expression")
    (compiler-parse-error-ok?
      "(define (main [b : (Box i64)]) : i64 (deref b b))"
      "parse: deref expects exactly one expression")))

(define (compiler-parse-place-migration-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(define (main [p : i64]) : i64 (struct-get p value))"
      "parse: struct-get was removed; use dotted field projection value.field")
    (compiler-parse-error-ok?
      "(define (main [p : i64]) : unit (struct-set p value 1))"
      "parse: struct-set/struct-set! was removed; use (set! value.field replacement)")
    (compiler-parse-error-ok?
      "(define (main [p : i64]) : unit (struct-set! p value 1))"
      "parse: struct-set/struct-set! was removed; use (set! value.field replacement)")
    (compiler-parse-error-ok?
      "(define (main [xs : (Array i64 1)]) : unit (array-set! xs 0 1))"
      "parse: array-set! was removed; use (set! (array-ref array index) value)")
    (compiler-parse-error-ok?
      "(define (main [b : (Box i64)]) : i64 (box-get b))"
      "parse: box-get was removed; use (deref box)")
    (compiler-parse-error-ok?
      "(define (main [b : (Box i64)]) : i64 (box-take b))"
      "parse: box-take was removed; use (deref box)")))

(define (compiler-parse-public-dynamic-array-removal-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(define (main [items : (Array i64)]) : i64 0)"
      "parse: unsized (Array T) was removed; use (Array T N), stdlib.vector, or a borrowed Slice")
    (compiler-parse-ok?
      "(define (main) : i64 (array-length (make-array i64 1)))")
    (compiler-parse-error-ok?
      "(define (main [items : (__tl_dyn-array i64)]) : unit (array-push! items 1))"
      "parse: bare array-push! was removed; use a generated vector mutator")
    (compiler-parse-error-ok?
      "(define (main [items : (__tl_dyn-array i64)]) : (MutPtr i64) (unsafe (array-data items)))"
      "parse: array-data was removed; raw dynamic-buffer storage is compiler-private")
    (compiler-parse-ok?
      "(define (main) : i64 (array-length (__tl_make-array i64 1)))")
    (compiler-parse-ok?
      "(define (main [items : (__tl_dyn-array i64)]) : unit (__tl_array-push! items 1))")
    (compiler-parse-ok?
      "(define (main [items : (__tl_dyn-array i64)]) : (MutPtr i64) (unsafe (__tl_array-data items)))")))

(define (compiler-parse-extern-metadata-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(extern (f) : i64 (:abi stdcall))"
      "parse: unknown extern ABI stdcall")
    (compiler-parse-error-ok?
      "(extern (f) : i64 (:symbol bad))"
      "parse: malformed extern :symbol metadata")
    (compiler-parse-error-ok?
      "(extern (f) : i64 (:link-lib bad))"
      "parse: malformed extern :link-lib metadata")
    (compiler-parse-error-ok?
      "(extern (f) : i64 (:link-arg \"\"))"
      "parse: extern :link-arg must not be empty")
    (compiler-parse-error-ok?
      "(extern (f) : i64 (:abi c) (:abi c))"
      "parse: duplicate extern :abi metadata")
    (compiler-parse-error-ok?
      "(extern (f) : i64 (:abi c-varargs))"
      (parser.parse-ast-extern-c-varargs-legacy-message))
    (compiler-parse-error-ok?
      "(extern (f) : i64 (:abi c-varargs -1))"
      (parser.parse-ast-extern-c-varargs-legacy-message))
    (compiler-parse-error-ok?
      "(extern (f ... [x : i64]) : i64)"
      "parse: extern varargs tail must be final")
    (compiler-parse-error-ok?
      "(extern (f [x : i64] ...) (:abi c-varargs 1) : i64)"
      (parser.parse-ast-extern-c-varargs-legacy-message))
    (compiler-parse-error-ok?
      "(extern (f) : i64 (:link \"x\"))"
      "parse: unknown extern metadata :link")))

(define (compiler-parse-reference-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(define (main [p : (&)]) : unit unit)"
      "parse: & expects an optional lifetime and exactly one type")
    (compiler-parse-ok? "(define (main [p : (& r)]) : unit unit)")
    (compiler-parse-error-ok?
      "(define (main [p : (& 1 i64)]) : unit unit)"
      "parse: reference lifetime must be an identifier")
    (compiler-parse-error-ok?
      "(define (main [p : (& r i64 i64)]) : unit unit)"
      "parse: & expects an optional lifetime and exactly one type")
    (compiler-parse-ok? "(define (main [p : (&mut phase)]) : unit unit)")
    (compiler-parse-error-ok?
      "(define (main [x : i64]) : unit (&))"
      "parse: borrow expects a place or lifetime and place")
    (compiler-parse-error-ok?
      "(define (main [x : i64]) : unit (& x x x))"
      "parse: borrow expects a place or lifetime and place")
    (compiler-parse-error-ok?
      "(define (main [x : i64]) : unit (& 1 x))"
      "parse: borrow lifetime must be an identifier")))

(define (compiler-parse-special-form-error-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      (compiler-parse-malformed-binary-source)
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      (compiler-parse-malformed-if-source)
      "parse: if is missing its else branch")
    (compiler-parse-if-missing-else-diagnostic-notes-ok?)
    (compiler-parse-error-ok?
      "(define (main) : i64 (while true))"
      "parse: malformed while")
    (compiler-parse-error-ok?
      "(define (main) : i64 (set! x))"
      "parse: malformed set!")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-arena r))"
      "parse: with-arena 'r' requires a non-empty body")
    (compiler-parse-error-ok?
      "(define (main) : (in 1 String) 0)"
      "parse: region name must be an identifier")
    (compiler-parse-error-ok?
      "(define (main) : i64 (try))"
      "parse: try expects exactly one expression")
    (compiler-parse-error-ok?
      "(define (main) : i64 (return 1 2))"
      "parse: return expects exactly one expression")))

(define (compiler-parse-recovery-balanced-decl-ok?) : bool
  (match (parse-ast-source-recovery-diagnostic
    "tests/recovery-balanced.tl"
    "(define)
(define (kept-a) : i64 1)
(define (kept-b) : i64 2)")
    [(parser.ResultAstProgramRecovery.Parsed
        (ast.AstProgram.Program decls-box)
        diagnostics-box)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList (deref diagnostics-box)]
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first diagnostics)]
        (and
          (= (ast.ast-decl-list-len (& (__tl-box-place decls-box))) 2)
          (= (cdiag.compiler-diagnostic-list-count diagnostics) 1)
          (string.eq
            (cdiag.compiler-diagnostic-message first)
            "parse: malformed define")
          (= (cdiag.compiler-diagnostic-line first) 1)))]
    [(parser.ResultAstProgramRecovery.Fatal _) false]))

(define (compiler-parse-recovery-ordered-errors-ok?) : bool
  (match (parse-ast-source-recovery-diagnostic
    "tests/recovery-ordered.tl"
    "(define)
(define (kept-a) : i64 1)
(define)
(define (kept-b) : i64 2)")
    [(parser.ResultAstProgramRecovery.Parsed
        (ast.AstProgram.Program decls-box)
        diagnostics-box)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList (deref diagnostics-box)]
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-get diagnostics 0)]
        [second : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-get diagnostics 1)]
        (and
          (= (ast.ast-decl-list-len (& (__tl-box-place decls-box))) 2)
          (= (cdiag.compiler-diagnostic-list-count diagnostics) 2)
          (= (cdiag.compiler-diagnostic-line first) 1)
          (string.eq
            (cdiag.compiler-diagnostic-message first)
            "parse: malformed define")
          (= (cdiag.compiler-diagnostic-line second) 3)
          (string.eq
            (cdiag.compiler-diagnostic-message second)
            "parse: malformed define")))]
    [(parser.ResultAstProgramRecovery.Fatal _) false]))

(define (compiler-parse-recovery-reader-progress-ok?) : bool
  (and
    (match (parse-ast-source-recovery-diagnostic
      "tests/recovery-mismatch.tl"
      "(define]
(define (kept) : i64 1)")
      [(parser.ResultAstProgramRecovery.Parsed
          (ast.AstProgram.Program decls-box)
          diagnostics-box)
        (let
          [diagnostics : cdiag.CompilerDiagnosticList (deref diagnostics-box)]
          [first : cdiag.CompilerDiagnostic
            (cdiag.compiler-diagnostic-list-first diagnostics)]
          [message : String (cdiag.compiler-diagnostic-message first)]
          [needle : String "reader: mismatched delimiter"]
          (and
            (= (ast.ast-decl-list-len (& (__tl-box-place decls-box))) 1)
            (= (cdiag.compiler-diagnostic-list-count diagnostics) 1)
            (string.contains (& message) (& needle))))]
      [(parser.ResultAstProgramRecovery.Fatal _) false])
    (match (parse-ast-source-recovery-diagnostic
      "tests/recovery-stray.tl"
      ") ] (define (kept) : i64 1)")
      [(parser.ResultAstProgramRecovery.Parsed
          (ast.AstProgram.Program decls-box)
          diagnostics-box)
        (and
          (= (ast.ast-decl-list-len (& (__tl-box-place decls-box))) 1)
          (= (cdiag.compiler-diagnostic-list-count (deref diagnostics-box)) 2))]
      [(parser.ResultAstProgramRecovery.Fatal _) false])
    (match (parse-ast-source-recovery-diagnostic
      "tests/recovery-unterminated.tl"
      "(define
(define (not-a-boundary) : i64 1))")
      [(parser.ResultAstProgramRecovery.Parsed
          (ast.AstProgram.Program decls-box)
          diagnostics-box)
        (and
          (= (ast.ast-decl-list-len (& (__tl-box-place decls-box))) 0)
          (= (cdiag.compiler-diagnostic-list-count (deref diagnostics-box)) 1))]
      [(parser.ResultAstProgramRecovery.Fatal _) false])))

(define (compiler-parse-recovery-tests-ok?) : bool
  (and
    (compiler-parse-recovery-balanced-decl-ok?)
    (compiler-parse-recovery-ordered-errors-ok?)
    (compiler-parse-recovery-reader-progress-ok?)))

(define (compiler-parse-error-tests-ok?) : bool
  (cond
    [(not (compiler-parse-diagnostic-code-ok?)) false]
    [(not (compiler-parse-nested-diagnostic-spans-ok?)) false]
    [(not (compiler-parse-recovery-tests-ok?)) false]
    [(not (compiler-parse-special-form-error-tests-ok?)) false]
    [(not (compiler-parse-unsafe-decl-error-tests-ok?)) false]
    [(not (compiler-parse-repr-c-error-tests-ok?)) false]
    [(not (compiler-parse-must-use-metadata-ok?)) false]
    [(not (compiler-parse-cleanup-error-tests-ok?)) false]
    [(not (compiler-parse-error-ok? "(module)" "parse: malformed module"))
      false]
    [(not
        (compiler-parse-error-ok?
          "(import stdlib.core as)"
          "parse: malformed import"))
      false]
    [(not
        (compiler-parse-error-ok?
          "(test empty)"
          "parse: test needs at least one expression"))
      false]
    [(not (compiler-parse-let-error-tests-ok?)) false]
    [(not (compiler-parse-abstraction-policy-tests-ok?)) false]
    [(not (compiler-parse-raw-pointer-error-tests-ok?)) false]
    [(not (compiler-parse-extern-metadata-error-tests-ok?)) false]
    [(not (compiler-parse-box-error-tests-ok?)) false]
    [(not (compiler-parse-reference-error-tests-ok?)) false]
    [(not (compiler-parse-invalidate-error-tests-ok?)) false]
    [else true]))

;; Top-level declaration parsing: accept value/function `define`,
;; `extern`, `defenum`, `defstruct`, and `import`; reject malformed forms with
;; stable diagnostics. Migrated from src/parser.rs declaration coverage.
(define (compiler-parse-ok? [src : String]) : bool
  (match (parser.parse-ast-source src)
    [(parser.ResultAstProgram.Ok _) true]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-ok-with-cfg?
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (match (parser.parse-ast-source-with-cfg src cfgs)
    [(parser.ResultAstProgram.Ok _) true]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-cfg-decl-count-ok?
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]
  [want : i64]) : bool
  (match (parser.parse-ast-source-with-cfg src cfgs)
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (= (parser.ast-decl-list-count decls) want))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-cfg-error?
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (match (parser.parse-ast-source-with-cfg src cfgs)
    [(parser.ResultAstProgram.Ok _) false]
    [(parser.ResultAstProgram.Err _) true]))

(define (compiler-parse-cfg-tests-ok?) : bool
  (let
    [feature-cfg : sym_i64_env.SymI64Env
      (parser.compiler-cfg-enable (parser.compiler-cfg-empty) "feature")]
    [feature-union-cfg : sym_i64_env.SymI64Env
      (parser.compiler-cfg-union (parser.compiler-cfg-empty) "feature")]
    [windows-feature-cfg : sym_i64_env.SymI64Env
      (parser.compiler-cfg-enable feature-cfg "windows")]
    (and
      (compiler-parse-cfg-decl-count-ok?
        "(cfg feature (define answer : i64 42))"
        (parser.compiler-cfg-empty)
        0)
      (compiler-parse-cfg-decl-count-ok?
        "(cfg feature (define answer : i64 42))"
        feature-cfg
        1)
      (compiler-parse-cfg-decl-count-ok?
        "(cfg feature (define answer : i64 42))"
        feature-union-cfg
        1)
      (compiler-parse-cfg-decl-count-ok?
        "(cfg feature (define))"
        (parser.compiler-cfg-empty)
        0)
      (compiler-parse-cfg-decl-count-ok?
        "(cfg (all feature windows) (define answer : i64 42))"
        windows-feature-cfg
        1)
      (compiler-parse-cfg-decl-count-ok?
        "(cfg (any missing feature) (define answer : i64 42))"
        feature-cfg
        1)
      (compiler-parse-cfg-decl-count-ok?
        "(cfg (not missing) (define answer : i64 42))"
        feature-cfg
        1)
      (compiler-parse-cfg-decl-count-ok?
        "(define (main) : i64 (begin (cfg feature (if)) 42))"
        (parser.compiler-cfg-empty)
        1)
      (compiler-parse-cfg-decl-count-ok?
        "(define (main) : i64 (cfg feature (if) 42))"
        (parser.compiler-cfg-empty)
        1)
      (compiler-parse-ok-with-cfg?
        "(define (main) : i64 (cfg feature 42 (if)))"
        feature-cfg)
      (compiler-parse-cfg-error?
        "(define (main) : i64 (cfg feature 42 (if)))"
        feature-union-cfg)
      (compiler-parse-cfg-error?
        "(define (main) : i64 (cfg feature (if) 42))"
        feature-cfg))))

(define (compiler-parse-declaration-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define answer : i64 42)")
    (compiler-parse-ok? "(define (add [a : i64] [b : i64]) : i64 (+ a b))")
    (compiler-parse-ok? "(extern (puts [arg0 : String]) : unit)")
    (compiler-parse-ok? "(defenum Maybe (Some i64) (None))")
    (compiler-parse-ok? "(defstruct Point (x i64) (y i64))")
    (compiler-parse-ok? "(import stdlib.core)")
    (compiler-parse-include-str-ok?)
    (compiler-parse-include-str-errors-ok?)
    (compiler-parse-include-str-comptime-ok?)
    (compiler-parse-include-str-comptime-errors-ok?)
    (compiler-parse-include-str-lzss-ok?)
    (compiler-parse-include-str-lzss-errors-ok?)
    (compiler-parse-removed-compressed-include-rejected?)
    (compiler-parse-include-bin-ok?)
    (compiler-parse-include-bin-errors-ok?)
    (compiler-parse-error-ok?
      "(define answer : i64)"
      "parse: malformed value definition")
    (compiler-parse-error-ok?
      "(define (main) : i64)"
      "parse: malformed function definition")
    (compiler-parse-error-ok? "(extern puts)" "parse: malformed extern")
    (compiler-parse-error-ok? "(defenum)" "parse: malformed defenum")
    (compiler-parse-error-ok? "(defstruct)" "parse: malformed defstruct")
    (compiler-parse-error-ok? "(import)" "parse: malformed import")))

;; enum/struct expression coverage: defenum empty rejection,
;; defstruct mixed field types, empty struct rejection, field projection, and
;; struct construction-as-call.
(define (compiler-parse-enum-struct-tests-ok?) : bool
  (and
    (compiler-parse-error-ok?
      "(defenum Empty)"
      "parse: defenum needs at least one variant")
    (compiler-parse-ok? "(defstruct Point (x i64) (y i64))")
    (compiler-parse-ok? "(defstruct Mixed (a i64) (b bool) (c f64))")
    (compiler-parse-error-ok?
      "(defstruct Empty)"
      "parse: defstruct needs at least one field")
    (compiler-parse-ok? "(define (f [p : Point]) : i64 p.x)")
    (compiler-parse-ok? "(define (f) : Point (Point 1 2))")
    (compiler-parse-ok? "(defstruct RefBox (:lifetimes a) (value (& a i64)))")
    (compiler-parse-ok?
      "(defenum RefOption (:lifetimes a) (SomeRef (& a i64)) (NoRef))")
    (compiler-parse-ok? "(define (f [box : (RefBox n)]) : (& n i64) box.value)")))

;
;; Let-binding parsing accepts only leading bracket bindings, including the
;; canonical empty `[]` wrapper.
(define (compiler-parse-let-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (let [x 1] x))")
    (compiler-parse-ok?
      "(define (main) : i64 (let [x : i64 1] [y : i64 2] (+ x y)))")
    (compiler-parse-ok? "(define (main) : i64 (let [x 1] [y (+ x 1)] y))")
    (compiler-parse-ok? "(define (main) : i64 (let [] 0))")))

(define (compiler-parse-implicit-body-tail-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (let [x : i64 1] x (+ x 1)))")
    (compiler-parse-ok? "(define (main) : i64 (let [] 1 2))")
    (compiler-parse-ok?
      "(define (main) : i64 (begin (while false unit unit) 0))")
    (compiler-parse-ok? "(define (main) : i64 unit 42)")
    (compiler-parse-ok? "(define (main) : i64 ((lambda () : i64 unit 42)))")))

(define (compiler-parse-spmd-tests-ok?) : bool
  (and
    (compiler-parse-ok?
      "(define (main) : i64 (begin (foreach ([i : i64 0 3]) unit) 0))")
    (compiler-parse-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))")
    (compiler-parse-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit (spmd-scan sum ([i : i64 0 n] [prefix : i64 0]) (array-ref xs i) (set! (array-ref out i) prefix)))")
    (compiler-parse-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (set! (array-ref out i) (spmd-broadcast (array-ref xs i) 0))) 0))")
    (compiler-parse-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (set! (array-ref out i) (spmd-shuffle (array-ref xs i) i))) 0))")
    (compiler-parse-ok?
      "(define (main [out : (__tl_dyn-array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (set! (array-ref out i) (+ (program-index) (program-count)))) 0))")
    (compiler-parse-ok?
      "(define (main [out : (__tl_dyn-array i64)] [n : i64]) : i64 (spmd-compact ([i : i64 0 n] [slot : i64 2]) (= (% i 2) 0) (set! (array-ref out slot) i)))")
    ;; foreach-active takes the shared bare typed binding and several body
    ;; forms; the shared grammar also accepts a parenthesized binding.
    (compiler-parse-ok?
      "(define (main [n : i64]) : i64 (let [t : i64 0] (begin (foreach ([i : i64 0 n]) (foreach-active [lane : i64] (set! t (+ t (lane-value i))) unit)) t)))")
    (compiler-parse-ok?
      "(define (main) : i64 (begin (foreach ([i : i64 0 3]) (foreach-active (lane : i64) unit)) 0))")
    ;; An empty range, a non-i64 index type, and expression
    ;; start/end bounds all parse (range semantics are checked later).
    (compiler-parse-ok?
      "(define (main) : i64 (begin (foreach ([i : i64 5 5]) unit) 0))")
    (compiler-parse-ok?
      "(define (main) : i64 (begin (foreach ([i : u32 0 3]) unit) 0))")
    (compiler-parse-ok?
      "(define (main [n : i64]) : i64 (begin (foreach ([i : i64 (+ 0 1) (* n 2)]) unit) 0))")
    ;; An unknown reduce operator is rejected by the parser.
    (compiler-parse-error-ok?
      "(define (main [n : i64]) : i64 (spmd-reduce bogus ([i : i64 0 n]) 0 i))"
      "parse: unsupported spmd-reduce operator `bogus`; expected one of sum, min, max, all, any")
    (compiler-parse-error-ok?
      "(define (main [n : i64]) : unit (spmd-scan bogus ([i : i64 0 n] [prefix : i64 0]) i unit))"
      "parse: unsupported spmd-scan operator `bogus`; expected one of sum, min, max, all, any")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach ([i i64 0 3 4]) unit) 0))"
      "parse: expected ':' in foreach")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach ([i : i64 0]) unit) 0))"
      "parse: malformed foreach binding")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach) 0))"
      "parse: malformed foreach")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-reduce sum))"
      "parse: malformed spmd-reduce")
    ;; Mirrored malformed binding cases lock down each shared grammar path's
    ;; form-specific diagnostics and left-to-right first-error behavior.
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-reduce sum ([i nope i64 0 3]) 0 i))"
      "parse: expected ':' in spmd-reduce")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-reduce sum ([i : i64 0]) 0 i))"
      "parse: malformed spmd-reduce")
    (compiler-parse-error-ok?
      "(define (main) : unit (spmd-scan sum ([i nope i64 0 3] [prefix : i64 0]) i unit))"
      "parse: expected ':' in spmd-scan range binding")
    (compiler-parse-error-ok?
      "(define (main) : unit (spmd-scan sum ([i : i64 0] [prefix : i64 0]) i unit))"
      "parse: malformed spmd-scan range binding")
    (compiler-parse-error-ok?
      "(define (main) : unit (spmd-scan sum ([i : i64 0 3] [prefix nope i64 0]) i unit))"
      "parse: expected ':' in spmd-scan prefix binding")
    (compiler-parse-error-ok?
      "(define (main) : unit (spmd-scan sum ([i : i64 0 3] [prefix : i64]) i unit))"
      "parse: malformed spmd-scan prefix binding")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-reduce sum ([0 : i64 0 3]) 0 0))"
      "parse: malformed spmd-reduce")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-reduce sum ([i : i64 0 3 4]) 0 i))"
      "parse: malformed spmd-reduce")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-reduce sum ([i : (Ptr) 0 3]) 0 i))"
      "parse: Ptr expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-reduce sum ([i : i64 (if) 3]) 0 i))"
      "parse: if expects condition, then branch, and else branch")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-reduce sum ([i : i64 0 (if)]) 0 i))"
      "parse: if expects condition, then branch, and else branch")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-reduce sum ([i : i64 0 3]) (if) i))"
      "parse: if expects condition, then branch, and else branch")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-reduce sum ([i : i64 0 3]) 0 (if)))"
      "parse: if expects condition, then branch, and else branch")
    (compiler-parse-error-ok?
      "(define (main) : unit (spmd-scan sum ([i : i64 0 3] [0 : i64 0]) i unit))"
      "parse: malformed spmd-scan prefix binding")
    (compiler-parse-error-ok?
      "(define (main) : unit (spmd-scan sum ([i : i64 0 3] [prefix : i64 0 1]) i unit))"
      "parse: malformed spmd-scan prefix binding")
    (compiler-parse-error-ok?
      "(define (main) : unit (spmd-scan sum ([i : i64 0 3] [prefix : (Ptr) 0]) i unit))"
      "parse: Ptr expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main) : unit (spmd-scan sum ([i : i64 0 3] [prefix : i64 (if)]) i unit))"
      "parse: if expects condition, then branch, and else branch")
    (compiler-parse-error-ok?
      "(define (main) : unit (spmd-scan sum ([i : i64 0 3] [prefix : i64 0]) (if) unit))"
      "parse: if expects condition, then branch, and else branch")
    (compiler-parse-error-ok?
      "(define (main) : unit (spmd-scan sum ([i : i64 0 3] [prefix : i64 0]) i (if)))"
      "parse: if expects condition, then branch, and else branch")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-compact))"
      "parse: malformed spmd-compact")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-compact ([i nope i64 0 3] [slot : i64 0]) true unit))"
      "parse: expected ':' in spmd-compact range binding")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-compact ([i : i64 0 3] [slot nope i64 0]) true unit))"
      "parse: expected ':' in spmd-compact slot binding")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-compact ([i : i64 0] [slot : i64 0]) true unit))"
      "parse: malformed spmd-compact range binding")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-compact ([i : i64 0 3] [slot : i64]) true unit))"
      "parse: malformed spmd-compact slot binding")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-compact ([i : i64 0 3] [0 : i64 0]) true unit))"
      "parse: malformed spmd-compact slot binding")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-compact ([i : i64 0 3] [slot : i64 0 1]) true unit))"
      "parse: malformed spmd-compact slot binding")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-compact ([i : i64 0 3] [slot : (Ptr) 0]) true unit))"
      "parse: Ptr expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-compact ([i : i64 0 3] [slot : i64 (if)]) true unit))"
      "parse: if expects condition, then branch, and else branch")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-compact ([i : i64 0 3] [slot : i64 0]) (if) unit))"
      "parse: if expects condition, then branch, and else branch")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-compact ([i : i64 0 3] [slot : i64 0]) true (if)))"
      "parse: if expects condition, then branch, and else branch")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-broadcast 1))"
      "parse: malformed spmd-broadcast")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-shuffle 1))"
      "parse: malformed spmd-shuffle")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach-active [lane : i32] unit) 0))"
      "parse: foreach-active lane binding must have type i64")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach-active [lane : i64]) 0))"
      "parse: foreach-active requires a body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach-active [lane i64] unit) 0))"
      "parse: malformed foreach-active binding; expected [lane : i64]")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach-active [lane nope i64] unit) 0))"
      "parse: expected ':' in foreach-active binding")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach-active [0 : i64] unit) 0))"
      "parse: malformed foreach-active binding; expected [lane : i64]")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach-active [lane : i64 0] unit) 0))"
      "parse: malformed foreach-active binding; expected [lane : i64]")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach-active) 0))"
      "parse: malformed foreach-active; expected (foreach-active [lane : i64] body...)")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach-active [lane : (Ptr)] unit) 0))"
      "parse: Ptr expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (foreach-active [lane : i64] unit (if)) 0))"
      "parse: if expects condition, then branch, and else branch")
    (compiler-parse-error-ok?
      "(define (main) : i64 (lane-value))"
      "parse: lane-value takes exactly one expression")
    (compiler-parse-error-ok?
      "(define (main) : i64 (lane-value 1 2))"
      "parse: lane-value takes exactly one expression")
    (compiler-parse-error-ok?
      "(define (main) : i64 (lane-value (if)))"
      "parse: if expects condition, then branch, and else branch")
    (compiler-parse-error-ok?
      "(define (main) : i64 (program-index 0))"
      "parse: program-index expects no arguments")
    (compiler-parse-error-ok?
      "(define (main) : i64 (program-count 0))"
      "parse: program-count expects no arguments")))

(define (compiler-parse-pattern-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (match 1 [0 1] [_ 0]))")
    (compiler-parse-ok?
      "(define (main [b : bool]) : i64 (match b [true 1] [false 0]))")
    (compiler-parse-ok?
      "(defenum E (A i64) (B))
(define (main [e : E]) : i64 (match e [(A x) x] [(B) 0]))")
    (compiler-parse-ok? "(define (main) : i64 (match 5 [x x]))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (match))"
      "parse: malformed match")
    (compiler-parse-error-ok?
      "(define (main) : i64 (match 1 [_]))"
      "parse: malformed match arm")
    (compiler-parse-error-ok?
      "(define (main) : i64 (match 1 [() 0]))"
      "parse: expected pattern")))

;; pattern literals: string literal arms, nested string payload,
;; char literals in pattern and value position.
(define (compiler-parse-pattern-string-char-tests-ok?) : bool
  (and
    ;; string literal arms
    (compiler-parse-ok?
      "(define (f [s : String]) : i64 (match s [\"if\" 10] [\"let\" 20] [_ 0]))")
    ;; nested string payload
    (compiler-parse-ok?
      "(defenum Token (TIdent String))\n(define (f [t : Token]) : i64 (match t [(TIdent \"if\") 1] [_ 0]))")
    ;; char literal in pattern (space + literal char)
    (compiler-parse-ok?
      "(define (f [c : char]) : i64 (match c [' ' 1] ['a' 2] [_ 0]))")
    ;; escaped char literal in value position
    (compiler-parse-ok? "(define (f) : char '\\n')")))

;
;; operator parsing: accept unary (not/neg/bit-not), binary
;; arithmetic/comparison, and bitwise/shift operator forms; reject
;; parser-owned malformed unary/binary operator expressions. Parse-shape only;
;; operator type rules live in the typechecker tests.
(define (compiler-parse-operator-tests-ok?) : bool
  (and
    (compiler-parse-ok?
      "(define (main [a : i64] [p : bool]) : i64 (begin (neg a) (bit-not a) (if (not p) 1 0)))")
    (compiler-parse-ok?
      "(define (main [a : i64] [b : i64]) : i64 (begin (+ a b) (- a b) (* a b) (< a b) (<= a b) (> a b) (>= a b) (= a b) (!= a b)))")
    (compiler-parse-ok?
      "(define (main [a : i64] [b : i64] [c : i64] [d : i64]) : i64 (begin (+ a b c d) (* a b c d)))")
    (compiler-parse-ok?
      "(define (main [a : i64] [b : i64] [p : bool]) : i64 (begin (bit-and a b) (bit-or a b) (bit-xor a b) (shl a b) (shr a b) (if (not p) 1 0)))")
    (compiler-parse-ok?
      "(define (main [a : i64] [b : i64] [c : i64] [d : i64]) : i64 (begin (bit-and a b c d) (bit-or a b c d) (bit-xor a b c d)))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (not))"
      "parse: malformed unary expression")
    (compiler-parse-error-ok?
      "(define (main [a : i64]) : i64 (+ a))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main) : i64 (+))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main [a : i64]) : i64 (* a))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main) : i64 (*))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main [a : i64]) : i64 (bit-and a))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main) : i64 (bit-or))"
      "parse: malformed binary expression")
    (compiler-parse-error-ok?
      "(define (main [a : i64] [b : i64] [c : i64]) : i64 (shl a b c))"
      "parse: malformed binary expression")))

;; Public Array is fixed-size only; the dynamic-buffer spelling is private.
(define (compiler-parse-type-literal-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (begin (type i64) 0))")
    (compiler-parse-ok? "(define (main) : i64 (begin (type (Array i64 4)) 0))")
    (compiler-parse-ok?
      "(define (main) : i64 (begin (type (__tl_dyn-array i64)) 0))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (type (Array i64)) 0))"
      "parse: unsized (Array T) was removed; use (Array T N), stdlib.vector, or a borrowed Slice")
    (compiler-parse-ok? "(define (main) : i64 (begin (type (Slice i64)) 0))")
    (compiler-parse-ok?
      "(define (main) : i64 (begin (type (Slice (Array i64 2))) 0))")
    (compiler-parse-ok? "(define (main) : i64 (begin (type (-> i64 i64)) 0))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (type (__tl_dyn-array i64 4)) 0))"
      "parse: __tl_dyn-array expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (type (Slice)) 0))"
      "parse: Slice expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main) : i64 (begin (type (Slice i64 bool)) 0))"
      "parse: Slice expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main) : i64 (type))"
      "parse: type expects exactly one type")
    (compiler-parse-error-ok?
      "(define (main) : i64 (type i64 bool))"
      "parse: type expects exactly one type")))

;; region parsing: `(with-arena <ident> body+)` accepts (basic,
;; multi-expression body, nested region) and rejects missing binder,
;; non-identifier binder, and empty body. Parse-shape + parser-owned diagnostics
;; only; region typing/lowering live in their own tests.
(define (compiler-parse-region-tests-ok?) : bool
  (and
    (compiler-parse-ok? "(define (main) : i64 (with-arena r 0))")
    (compiler-parse-ok? "(define (main) : i64 (with-arena r 1 2 0))")
    (compiler-parse-ok? "(define (main) : i64 (with-arena r (with-arena s 0)))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-arena))"
      "parse: with-arena requires a region name before its body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-arena 5 0))"
      "parse: with-arena region name must be an identifier")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with-arena r))"
      "parse: with-arena 'r' requires a non-empty body")))

(define (compiler-parse-resource-with-shape-ok?) : bool
  (match (parser.parse-ast-source
    "(define (main) : i64
  (with ([h (open-handle) close-handle]
         [tmp (open-temp) close-temp])
    (use h)
    (with ([inner (open-inner tmp) close-inner])
      42)))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefFn decl-meta _ _ _ body-box _)
              rest)
            (let
              [body : ast.AstExpr (ast.ast-node-get body-box)]
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (match (ast.ast-expr-unspan body)
                    [(ast.AstExpr.WithResource wr-box)
                      (match (deref wr-box)
                        [(ast.AstWithResource.WithResource bindings body-exprs)
                          (if (and
                            (=
                              (compiler-parse-resource-binding-count bindings)
                              2)
                            (= (compiler-parse-expr-list-count body-exprs) 2))
                            (let
                              [nested : ast.AstExpr
                                (ast.ast-node-get
                                  (ast.ast-expr-list-get (& body-exprs) 1 0))]
                              (match (ast.ast-expr-unspan nested)
                                [(ast.AstExpr.WithResource nested-wr-box)
                                  (match (deref nested-wr-box)
                                    [(ast.AstWithResource.WithResource
                                        nested-bindings
                                        nested-body)
                                      (and
                                        (=
                                          (compiler-parse-resource-binding-count
                                            nested-bindings)
                                          1)
                                        (=
                                          (compiler-parse-expr-list-count
                                            nested-body)
                                          1))])]
                                [_ false]))
                            false)])]
                    [_ false])]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-resource-with-tests-ok?) : bool
  (and
    (compiler-parse-resource-with-shape-ok?)
    (compiler-parse-ok?
      "(define (main) : i64 (with ([h (open-handle) close-handle]) 42))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with))"
      "parse: with requires a binding list before its body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with () 42))"
      "parse: with requires a non-empty binding list")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ([1 (open) close]) 42))"
      "parse: with binding name must be an identifier")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ([h]) 42))"
      "parse: with binding is missing initializer")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ([h (open)]) 42))"
      "parse: with binding is missing cleanup function")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ([h (open) close extra]) 42))"
      "parse: with binding has too many fields")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ([h (open) close])))"
      "parse: with requires a non-empty body")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with [h (open) close] 42))"
      "parse: malformed with binding list")
    (compiler-parse-error-ok?
      "(define (main) : i64 (with ((h (open) close)) 42))"
      "parse: with binding must use bracket syntax")))

(define (compiler-parse-quote-syntax-shape-ok?) : bool
  (match (parser.parse-ast-source
    "(define (mk [e : Expr]) : Expr `(if ,e true false))")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefFn decl-meta _ _ ret-ty body-box _)
              rest)
            (let
              [body : ast.AstExpr (ast.ast-node-get body-box)]
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (match ret-ty
                      [(ast.AstType.Var name)
                        (string.eq (ci.intern-str name) "Expr")]
                      [_ false])
                    (match (ast.ast-expr-unspan body)
                      [(ast.AstExpr.Quasiquote template-box)
                        (let
                          [template : ast.AstExpr
                            (ast.ast-node-get template-box)]
                          (match (ast.ast-expr-unspan template)
                            [(ast.AstExpr.If cond-box _ _)
                              (let
                                [cond : ast.AstExpr (ast.ast-node-get cond-box)]
                                (match (ast.ast-expr-unspan cond)
                                  [(ast.AstExpr.Unquote unquoted-box)
                                    (let
                                      [unquoted : ast.AstExpr
                                        (ast.ast-node-get unquoted-box)]
                                      (match (ast.ast-expr-unspan unquoted)
                                        [(ast.AstExpr.Var name)
                                          (string.eq (ci.intern-str name) "e")]
                                        [_ false]))]
                                  [_ false]))]
                            [_ false]))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-quote-syntax-tests-ok?) : bool
  (and
    (compiler-parse-quote-syntax-shape-ok?)
    (compiler-parse-ok? "(define x : Expr '(+ 1 2))")
    (compiler-parse-ok? "(define x : Expr `(begin ,@xs))")
    (compiler-parse-ok?
      "(define (mk [target : Expr]) : Expr `(set! ,target 1))")
    (compiler-parse-error-ok?
      "(define x : Expr (quote))"
      "parse: quote form expects exactly one expression")))

;; REPL-item parsing: `parse-ast-repl-source` accepts a single
;; top-level declaration, a parenthesized expression, or a bare expression, and
;; rejects trailing tokens and a malformed expression. Mirrors the Rust
;; parser's `parse_repl_item` tests.
(define (compiler-parse-repl-decl-ok? [src : String]) : bool
  (match (parser.parse-ast-repl-source src)
    [(parser.ResultAstReplItem.Ok item)
      (match item
        [(AstReplDecl _) true]
        [(AstReplExpr _) false])]
    [(parser.ResultAstReplItem.Err _) false]))

(define (compiler-parse-repl-expr-ok? [src : String]) : bool
  (match (parser.parse-ast-repl-source src)
    [(parser.ResultAstReplItem.Ok item)
      (match item
        [(AstReplExpr _) true]
        [(AstReplDecl _) false])]
    [(parser.ResultAstReplItem.Err _) false]))

(define (compiler-parse-repl-error-ok? [src : String] [expected : String]) : bool
  (match (parser.parse-ast-repl-source src)
    [(parser.ResultAstReplItem.Ok _) false]
    [(parser.ResultAstReplItem.Err diag)
      (let
        [error : cdiag.CompilerDiagnostic (deref diag)]
        (and
          (string.eq (cdiag.compiler-diagnostic-message error) expected)
          (match (cdiag.compiler-diagnostic-code error)
            [(cdiag.CompilerDiagnosticSomeString code)
              (string.eq code (cdiag.compiler-diagnostic-code-parse))]
            [cdiag.CompilerDiagnosticNoString false])
          (>= (cdiag.compiler-diagnostic-line error) 1)))]))

(define (compiler-parse-repl-error-at? [src : String] [line : i64] [col : i64]) : bool
  (match (parser.parse-ast-repl-source src)
    [(parser.ResultAstReplItem.Ok _) false]
    [(parser.ResultAstReplItem.Err diag)
      (let
        [error : cdiag.CompilerDiagnostic (deref diag)]
        (and
          (= (cdiag.compiler-diagnostic-line error) line)
          (= (cdiag.compiler-diagnostic-col error) col)))]))

(define (compiler-parse-repl-tests-ok?) : bool
  (and
    ;; declaration item
    (compiler-parse-repl-decl-ok? "(define x : i64 42)")
    ;; parenthesized expression item
    (compiler-parse-repl-expr-ok? "(+ 1 2)")
    ;; unknown function-style calls are REPL expressions, not module macro decls
    (compiler-parse-repl-expr-ok? "(double 4)")
    ;; bare expression item
    (compiler-parse-repl-expr-ok? "42")
    ;; trailing tokens after a complete item are rejected
    (compiler-parse-repl-error-ok?
      "42 43"
      "parse: trailing tokens after REPL input")
    ;; a malformed expression item surfaces the expression diagnostic
    (compiler-parse-repl-error-ok? "(+ 1)" "parse: malformed binary expression")
    ;; errors are located in the input: at the trailing token, and at the
    ;; malformed input form, including one on a later line
    (compiler-parse-repl-error-at? "42 43" 1 4)
    (compiler-parse-repl-error-at? "(+ 1)" 1 1)
    (compiler-parse-repl-error-at? "\n  (+ 1)" 2 3)
    (compiler-parse-repl-error-at? "" 1 1)))

;; comptime function-parameter parsing: `[comptime n : i64]`
;; and the type-valued `[comptime T : type]` parse as top-level function
;; parameters marked comptime; a comptime parameter on a lambda is rejected
;; (comptime params are top-level-only). Mirrors the Rust parser's
;; test_parse_comptime_function_param / _type_valued_comptime_param /
;; _comptime_lambda_param_rejected.
(define (compiler-parse-first-fn-has-comptime-param? [src : String]) : bool
  (match (parser.parse-ast-source src)
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefFn decl-meta _ params _ _ _)
              _)
            (parser.ast-param-list-has-comptime? params)]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-comptime-param-tests-ok?) : bool
  (and
    (compiler-parse-first-fn-has-comptime-param?
      "(define (scale [comptime n : i64] [x : i64]) : i64 (* n x))")
    (compiler-parse-first-fn-has-comptime-param?
      "(define (alloc [comptime T : type] [n : i64]) : (__tl_dyn-array i64) (__tl_make-array T n))")
    (compiler-parse-error-ok?
      "(define (main) : i64 ((lambda ([comptime n : i64]) n) 1))"
      "comptime parameters are only supported on top-level function definitions")))

(define (compiler-parse-defmacro-shape-ok?) : bool
  (match (parser.parse-ast-source
    "(defmacro (all [first : bool] [rest : bool ...]) : bool first)")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefMacro _ name params (ast.AstType.Bool) _)
              rest)
            (let
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (= name (reader.stable-symbol-id "all"))
                    (= (ast.ast-macro-param-list-len (& params)) 2)
                    (match (ast.ast-macro-param-list-get
                      (& params)
                      0
                      (ast.ast-macro-param-fallback))
                      [(ast.AstMacroParam.Param
                          first
                          (ast.AstType.Bool)
                          false
                          first-kinds)
                        (and
                          (= first (reader.stable-symbol-id "first"))
                          (ast.ast-macro-type-kind-list-empty? (& first-kinds)))]
                      [_ false])
                    (match (ast.ast-macro-param-list-get
                      (& params)
                      1
                      (ast.ast-macro-param-fallback))
                      [(ast.AstMacroParam.Param
                          rest
                          (ast.AstType.Bool)
                          true
                          rest-kinds)
                        (and
                          (= rest (reader.stable-symbol-id "rest"))
                          (ast.ast-macro-type-kind-list-empty? (& rest-kinds)))]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-macro-type-kind-list-shape-ok?
  [kinds : (& kinds ast.AstMacroTypeKindList)]) : bool
  (and
    (= (ast.ast-macro-type-kind-list-len kinds) 3)
    (string.eq
      (ci.intern-str (ast.ast-macro-type-kind-list-get kinds 0 0))
      "i64")
    (string.eq
      (ci.intern-str (ast.ast-macro-type-kind-list-get kinds 1 0))
      "struct")
    (string.eq
      (ci.intern-str (ast.ast-macro-type-kind-list-get kinds 2 0))
      "type-var")))

(define (compiler-parse-defmacro-type-kind-constraint-shape-ok?) : bool
  (match (parser.parse-ast-source
    "(defmacro (catalog [T : type (:kind i64 struct type-var)]) : Module unit)")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (match (ast.ast-decl-list-step (deref decls-box))
        [(ast.AstDeclListStep.Cons
            (ast.AstDecl.DefMacro decl-meta name params _ _)
            rest)
          (and
            (string.eq (ci.intern-str name) "catalog")
            (match (ast.ast-decl-list-step rest)
              [(ast.AstDeclListStep.Nil) true]
              [_ false])
            (= (ast.ast-macro-param-list-len (& params)) 1)
            (match (ast.ast-macro-param-list-get
              (& params)
              0
              (ast.ast-macro-param-fallback))
              [(ast.AstMacroParam.Param
                  param-name
                  (ast.AstType.Var type-name)
                  false
                  type-kinds)
                (and
                  (string.eq (ci.intern-str param-name) "T")
                  (string.eq (ci.intern-str type-name) "type")
                  (compiler-parse-macro-type-kind-list-shape-ok? (& type-kinds)))]
              [_ false]))]
        [_ false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-macro-type-kind-expected-all-id [index : i64]) : i64
  (cond
    [(= index 0) (cbi.compiler-builtin-ctfe "i64")]
    [(= index 1) (cbi.compiler-builtin-ctfe "i32")]
    [(= index 2) (cbi.compiler-builtin-ctfe "i16")]
    [(= index 3) (cbi.compiler-builtin-ctfe "i8")]
    [(= index 4) (cbi.compiler-builtin-ctfe "u64")]
    [(= index 5) (cbi.compiler-builtin-ctfe "u32")]
    [(= index 6) (cbi.compiler-builtin-ctfe "u16")]
    [(= index 7) (cbi.compiler-builtin-ctfe "u8")]
    [(= index 8) (cbi.compiler-builtin-ctfe "f64")]
    [(= index 9) (cbi.compiler-builtin-ctfe "f32")]
    [(= index 10) (cbi.compiler-builtin-ctfe "bool")]
    [(= index 11) (cbi.compiler-builtin-ctfe "char")]
    [(= index 12) (cbi.compiler-builtin-ctfe "string")]
    [(= index 13) (cbi.compiler-builtin-ctfe "unit")]
    [(= index 14) (cbi.compiler-builtin-ctfe "never")]
    [(= index 15) (cbi.compiler-builtin-ctfe "array")]
    [(= index 16) (cbi.compiler-builtin-ctfe "dyn-array")]
    [(= index 17) (cbi.compiler-builtin-ctfe "function")]
    [(= index 18) (cbi.compiler-builtin-ctfe "tuple")]
    [(= index 19) (cbi.compiler-builtin-ctfe "struct")]
    [(= index 20) (cbi.compiler-builtin-ctfe "enum")]
    [(= index 21) (cbi.compiler-builtin-ctfe "str")]
    [(= index 22) (cbi.compiler-builtin-ctfe "ptr")]
    [(= index 23) (cbi.compiler-builtin-ctfe "mut-ptr")]
    [(= index 24) (cbi.compiler-builtin-ctfe "ref")]
    [(= index 25) (cbi.compiler-builtin-ctfe "mut-ref")]
    [(= index 26) (cbi.compiler-builtin-ctfe "region")]
    [(= index 27) (cbi.compiler-builtin-ctfe "type-var")]
    [(= index 28) (cbi.compiler-builtin-ctfe "box")]
    [(= index 29) (cbi.compiler-builtin-ctfe "slice")]
    [else 0]))

(define (compiler-parse-macro-type-kind-all-order-ok?
  [kinds : (& kinds ast.AstMacroTypeKindList)]
  [index : i64]) : bool
  (if (>= index 30)
    (= (ast.ast-macro-type-kind-list-len kinds) 30)
    (and
      (=
        (ast.ast-macro-type-kind-list-get kinds index 0)
        (compiler-parse-macro-type-kind-expected-all-id index))
      (compiler-parse-macro-type-kind-all-order-ok? kinds (+ index 1)))))

(define (compiler-parse-defmacro-type-kind-storage-case-ok?
  [source : String]
  [expected-count : i64]
  [expected-first : String]
  [expected-last : String]
  [verify-all : bool]) : bool
  (match (parser.parse-ast-source source)
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (match (ast.ast-decl-list-step (deref decls-box))
        [(ast.AstDeclListStep.Cons (ast.AstDecl.DefMacro _ _ params _ _) rest)
          (and
            (match (ast.ast-decl-list-step rest)
              [(ast.AstDeclListStep.Nil) true]
              [_ false])
            (= (ast.ast-macro-param-list-len (& params)) 1)
            (match (ast.ast-macro-param-list-get
              (& params)
              0
              (ast.ast-macro-param-fallback))
              [(ast.AstMacroParam.Param _ _ _ type-kinds)
                (let
                  [count : i64
                    (ast.ast-macro-type-kind-list-len (& type-kinds))]
                  (and
                    (= count expected-count)
                    (if (= count 0)
                      true
                      (and
                        (string.eq
                          (ci.intern-str
                            (ast.ast-macro-type-kind-list-get
                              (& type-kinds)
                              0
                              0))
                          expected-first)
                        (string.eq
                          (ci.intern-str
                            (ast.ast-macro-type-kind-list-get
                              (& type-kinds)
                              (- count 1)
                              0))
                          expected-last)))
                    (if verify-all
                      (compiler-parse-macro-type-kind-all-order-ok?
                        (& type-kinds)
                        0)
                      true)))]
              [_ false]))]
        [_ false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-parse-defmacro-type-kind-storage-shapes-ok?) : bool
  (and
    (compiler-parse-defmacro-type-kind-storage-case-ok?
      "(defmacro (empty [T : type]) : Module unit)"
      0
      ""
      ""
      false)
    (compiler-parse-defmacro-type-kind-storage-case-ok?
      "(defmacro (single [T : type (:kind box)]) : Module unit)"
      1
      "box"
      "box"
      false)
    (compiler-parse-defmacro-type-kind-storage-case-ok?
      "(defmacro (single [T : type (:kind invalidate c-function)]) : Module unit)"
      2
      "invalidate"
      "c-function"
      false)
    (compiler-parse-defmacro-type-kind-storage-case-ok?
      "(defmacro (all-kinds [T : type (:kind i64 i32 i16 i8 u64 u32 u16 u8 f64 f32 bool char string unit never array dyn-array function tuple struct enum str ptr mut-ptr ref mut-ref region type-var box slice)]) : Module unit)"
      30
      "i64"
      "slice"
      true)))

(define (compiler-parse-fixed-source-id-only-ok?
  [text : String]
  [fixed-id : i64]) : bool
  (let
    [source-id : i64
      (reader.stable-symbol-id (parser.compiler-parse-place-shared-view text))]
    [generated-id : i64
      (ci.intern-generated-canonical-name
        (parser.compiler-parse-place-shared-view text))]
    (and
      (= source-id fixed-id)
      (not (= generated-id fixed-id))
      (string.eq (compiler-parse-name-text generated-id) text))))

(define (compiler-parse-fixed-syntax-name-provenance-ok?) : bool
  (let
    [source-kind : i64 (reader.stable-symbol-id "i64")]
    [generated-kind : i64 (ci.intern-generated-canonical-name "i64")]
    [source-all : i64 (reader.stable-symbol-id "all")]
    [generated-all : i64 (ci.intern-generated-canonical-name "all")]
    [source-dots : i64 (reader.stable-symbol-id "...")]
    [generated-dots : i64 (ci.intern-generated-canonical-name "...")]
    (and
      (parser.parse-ast-macro-type-kind-known?
        (ci.intern-syntax-id-from-raw source-kind))
      (not
        (parser.parse-ast-macro-type-kind-known?
          (ci.intern-syntax-id-from-raw generated-kind)))
      (parser.parse-ast-macro-type-kind-known?
        (ci.intern-syntax-id-from-raw (reader.stable-symbol-id "box")))
      (not
        (parser.parse-ast-macro-type-kind-known?
          (ci.intern-syntax-id-from-raw
            (ci.intern-generated-canonical-name "box"))))
      (= source-all (cbi.compiler-builtin-ctfe "all"))
      (not (= generated-all (cbi.compiler-builtin-ctfe "all")))
      (= source-dots (cbi.compiler-builtin-ctfe "..."))
      (not (= generated-dots (cbi.compiler-builtin-ctfe "...")))
      (= (reader.stable-symbol-id "slice") (cbi.compiler-builtin-ctfe "slice"))
      (not
        (=
          (ci.intern-generated-canonical-name "slice")
          (cbi.compiler-builtin-ctfe "slice")))
      ;; One adversarial spelling per new fixed-name family proves that equal
      ;; rendered text does not confer parser syntax identity.
      (compiler-parse-fixed-source-id-only-ok?
        ":cleanup"
        (cbi.compiler-builtin-ctfe ":cleanup"))
      (compiler-parse-fixed-source-id-only-ok?
        "scalar"
        (cbi.compiler-builtin-ctfe "scalar"))
      (compiler-parse-fixed-source-id-only-ok?
        "cfg"
        (cbi.compiler-builtin-ctfe "cfg"))
      (compiler-parse-fixed-source-id-only-ok?
        "sum"
        (cbi.compiler-builtin-ctfe "sum"))
      (compiler-parse-fixed-source-id-only-ok?
        ":spmd-callable"
        (cbi.compiler-builtin-ctfe ":spmd-callable"))
      (compiler-parse-fixed-source-id-only-ok?
        ":ignore"
        (cbi.compiler-builtin-ctfe ":ignore"))
      (compiler-parse-fixed-source-id-only-ok?
        ":slow"
        (cbi.compiler-builtin-ctfe ":slow"))
      (compiler-parse-fixed-source-id-only-ok?
        ":abi"
        (cbi.compiler-builtin-ctfe ":abi"))
      (compiler-parse-fixed-source-id-only-ok?
        "as"
        (cbi.compiler-builtin-ctfe "as"))
      (compiler-parse-fixed-source-id-only-ok?
        "defgeneric"
        (cbi.compiler-builtin-ctfe "defgeneric")))))

(define (compiler-parse-defmacro-tests-ok?) : bool
  (and
    (compiler-parse-defmacro-shape-ok?)
    (compiler-parse-defmacro-type-kind-constraint-shape-ok?)
    (compiler-parse-defmacro-type-kind-storage-shapes-ok?)
    (compiler-parse-fixed-syntax-name-provenance-ok?)
    (compiler-parse-ok?
      "(defmacro (and2 [lhs : bool] [rhs : bool]) : bool (expr-if lhs rhs (expr-bool false)))")
    (compiler-parse-ok?
      "(defmacro (binding-body [bindings : ExprBindingClause ...] [body : Expr ...]) : Expr (expr-list-nth body 0))")
    (compiler-parse-ok?
      "(defmacro (box-elem [T : type (:kind box)]) : Module unit)")
    (compiler-parse-error-ok?
      "(defmacro (bad [rest : bool ...] [x : bool]) : bool rest)"
      "parse: only ExprBindingClause macro operands may be variadic before a later operand")
    (compiler-parse-error-ok?
      "(defmacro (bad [T : type (:kind)]) : Module unit)"
      "parse: macro type operand T constraint :kind requires at least one kind")
    (compiler-parse-error-ok?
      "(defmacro (bad [T : type (:kind i64 i64)]) : Module unit)"
      "parse: macro type operand T constraint :kind has duplicate kind i64")
    (compiler-parse-error-ok?
      "(defmacro (bad [T : type (:kind record)]) : Module unit)"
      "parse: macro type operand T constraint :kind has unknown kind record")
    (compiler-parse-error-ok?
      "(defmacro (bad [value : Expr (:kind i64)]) : Expr value)"
      "parse: macro operand value constraint :kind is only legal on fixed type operands")
    (compiler-parse-error-ok?
      "(defmacro (bad [T : type (:kind i64) ...]) : Module unit)"
      "parse: macro type operand T constraint :kind is not legal on variadic operands")
    (compiler-parse-error-ok?
      "(defmacro (bad [T : type (:kind i64) (:kind i32)]) : Module unit)"
      "parse: macro type operand T constraint :kind allows only one constraint form")
    (compiler-parse-error-ok?
      "(defmacro (bad [T : type (:shape struct)]) : Module unit)"
      "parse: macro type operand T has unknown constraint form :shape")
    (compiler-parse-error-ok?
      "(defmacro (bad [T : type (:kind \"i64\")]) : Module unit)"
      "parse: macro type operand T constraint :kind expects unquoted kind names")))

(define (compiler-parse-source-symbol-ids-preserved-ok?) : bool
  (let
    ;; Prime the fixed dispatch-name ids before measuring source parsing.
    [_dispatch : sym_i64_env.SymI64Env (parser.parse-ast-program-dispatch)]
    (match (lexer.spanned-result "(define (f [x : User]) : User x)")
      [(lexer.ResultSpannedTokens.Ok toks)
        (let
          [before : i64 (ci.intern-pool-len)]
          [parsed : parser.ResultAstProgram (parse-ast-program toks)]
          (and
            (= before (ci.intern-pool-len))
            (match parsed
              [(parser.ResultAstProgram.Ok _) true]
              [(parser.ResultAstProgram.Err _) false])))]
      [(lexer.ResultSpannedTokens.Err _) false])))

(define (compiler-parse-spmd-callable-metadata-ok?) : bool
  (and
    (match (parser.parse-ast-source
      "(define (helper [x : i64] [scale : i64])
  (:spmd-callable
    (specialization
      (result varying)
      (args varying uniform)
      (index-param 0)
      (lanes 8)))
  : i64
  (+ x scale))")
      [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
        (let
          [decls : ast.AstDeclList (deref decls-box)]
          (match (ast.ast-decl-list-get (& decls) 0 (ast.ast-decl-fallback))
            [(ast.AstDecl.DefFn decl-meta _ _ _ _ metadata)
              (match (ast.ast-fn-metadata-spmd-callable metadata)
                [(ast.AstSpmdCallable.Callable specializations)
                  (let
                    [fallback : ast.AstSpmdSpecialization
                      (ast.AstSpmdSpecialization
                        2
                        (box (ast.ast-spmd-param-class-list-new))
                        ast.AstSpmdResultClass.Unit
                        -1)]
                    [specialization : ast.AstSpmdSpecialization
                      (ast.ast-spmd-specialization-list-get
                        (& specializations)
                        0
                        fallback)]
                    [args : ast.AstSpmdParamClassList
                      (ast_tests.ast-spmd-param-class-list-box-shared-view
                        specialization.args)]
                    (and
                      (=
                        (ast.ast-spmd-specialization-list-len
                          (& specializations))
                        1)
                      (= specialization.lanes 8)
                      (= specialization.index-param 0)
                      (match specialization.result
                        [(ast.AstSpmdResultClass.Varying) true]
                        [_ false])
                      (match (ast.ast-spmd-param-class-list-get
                        (& args)
                        0
                        ast.AstSpmdParamClass.Uniform)
                        [(ast.AstSpmdParamClass.Varying) true]
                        [_ false])
                      (match (ast.ast-spmd-param-class-list-get
                        (& args)
                        1
                        ast.AstSpmdParamClass.Varying)
                        [(ast.AstSpmdParamClass.Uniform) true]
                        [_ false])))]
                [_ false])]
            [_ false]))]
      [_ false])
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param 0)) (specialization (lanes 8) (args varying) (result varying) (index-param 0))) : i64 x)"
      "parse: duplicate :spmd-callable specialization")
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:spmd-callable (specialization (lanes 8) (args uniform varying) (result varying) (index-param none))) : i64 x)"
      "parse: :spmd-callable args must contain one class per ordinary parameter")
    (compiler-parse-error-ok?
      "(define (f [comptime x : i64]) (:spmd-callable (specialization (lanes 8) (args uniform) (result uniform) (index-param none))) : i64 x)"
      "parse: define :spmd-callable cannot be used on functions with comptime parameters")
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:export-symbol \"f\") (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param 0))) : i64 x)"
      "parse: define :spmd-callable cannot be combined with :export-symbol")
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (bogus none) (index-param 0))) : i64 x)"
      "parse: unknown :spmd-callable specialization field bogus")
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:spmd-callable (specialization (lanes 1) (args varying) (result varying) (index-param 0))) : i64 x)"
      "parse: :spmd-callable lanes must be greater than one")
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:spmd-callable (specialization (lanes 8) (args varying) (result varying) (index-param 2))) : i64 x)"
      "parse: :spmd-callable index-param is outside the parameter list")
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:spmd-callable (specialization (lanes 8) (args dynamic) (result varying) (index-param none))) : i64 x)"
      "parse: :spmd-callable args expects only uniform or varying")
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:spmd-callable (specialization (args varying) (result varying) (index-param 0))) : i64 x)"
      "parse: :spmd-callable specialization is missing lanes")
    (compiler-parse-error-ok?
      "(define (f [x : i64]) (:spmd-callable (specialization (lanes 8) (lanes 16) (args varying) (result varying) (index-param 0))) : i64 x)"
      "parse: duplicate :spmd-callable lanes field")))

(define (compiler-parse-origin-lookup-cache-tests-ok?) : bool
  (begin
    (parser.compiler-parse-semantic-origin-lookup-cache-reset!)
    (parser.compiler-parse-semantic-origin-lookup-insert! 1 101 7 1 11 2 0 0)
    ;; Re-registering the same query must replace, rather than duplicate, the
    ;; earlier value because append-order defines the authoritative sidecar.
    (parser.compiler-parse-semantic-origin-lookup-insert! 1 101 7 1 29 3 0 0)
    (parser.compiler-parse-semantic-origin-lookup-insert! 2 101 7 3 4 5 6 7)
    (parser.compiler-parse-semantic-origin-lookup-insert! 1 202 9 2 0 0 101 7)
    (let
      [direct : parser.CompilerParseSemanticOriginLookupSlot
        (parser.compiler-parse-semantic-origin-lookup 1 101 7)]
      [separate-domain : parser.CompilerParseSemanticOriginLookupSlot
        (parser.compiler-parse-semantic-origin-lookup 2 101 7)]
      [alias : parser.CompilerParseSemanticOriginLookupSlot
        (parser.compiler-parse-semantic-origin-lookup 1 202 9)]
      [missing : parser.CompilerParseSemanticOriginLookupSlot
        (parser.compiler-parse-semantic-origin-lookup 1 303 11)]
      [ok : bool
        (and
          (= parser.compiler-parse-semantic-origin-lookup-len 3)
          (= direct.kind 1)
          (= direct.run-start 29)
          (= direct.run-count 3)
          (= separate-domain.kind 3)
          (= separate-domain.run-start 4)
          (= separate-domain.run-count 5)
          (= separate-domain.source-key 6)
          (= separate-domain.source-slot 7)
          (= alias.kind 2)
          (= alias.source-key 101)
          (= alias.source-slot 7)
          (= missing.kind 0))]
      (begin
        (parser.compiler-parse-semantic-origin-lookup-cache-reset!)
        ok))))

(define (compiler-parse-smoke) : i64
  (match (parser.parse-ast-source
    "(import stdlib.test)
(defstruct Point (x i64) (y i64))
(defenum Maybe (None) (Some i64))
(extern (io.emit-string [arg0 : String]) : unit)
(define answer : i64 42)
(define (main [argc : i64] [name : String]) : i64
  (let
    [x : i64 1]
    [arr (array 1 2 3)]
      (begin
        (set! x (+ x 41))
        (cond
          [(and (= x 42) true)
          (match (Some x) [(Some v) v] [_ 0])]
          [else 0]))))")
    [(parser.ResultAstProgram.Ok program)
      (if (and
        (= (compiler-parse-smoke-score program) 36)
        (compiler-parse-nested-expr-span-ok?)
        (compiler-parse-error-span-ok?)
        (compiler-parse-reader-delimiter-diagnostics-ok?)
        (compiler-parse-float-literal-ok?)
        (compiler-parse-region-ok?)
        (compiler-parse-arena-ok?)
        (compiler-parse-unsafe-decl-ok?)
        (compiler-parse-module-decl-ok?)
        (compiler-parse-module-body-ok?)
        (compiler-parse-module-body-malformed-ok?)
        (compiler-parse-origin-lookup-cache-tests-ok?)
        (compiler-parse-import-metadata-ok?)
        (compiler-parse-dotted-import-metadata-ok?)
        (compiler-parse-module-macro-surface-ok?)
        (compiler-parse-defdispatch-tests-ok?)
        (compiler-parse-flat-let-call-body-ok?)
        (compiler-parse-implicit-body-tail-ok?)
        (compiler-parse-inline-test-ok?)
        (compiler-parse-inline-test-metadata-ok?)
        (compiler-parse-try-ok?)
        (compiler-parse-return-ok?)
        (compiler-parse-guard-forms-ok?)
        (compiler-parse-bracket-cond-call-ok?)
        (compiler-parse-and-or-macro-call-candidates-ok?)
        (compiler-parse-repr-c-ok?)
        (compiler-parse-cleanup-metadata-ok?)
        (compiler-parse-raw-pointer-ok?)
        (compiler-parse-extern-metadata-ok?)
        (compiler-parse-extern-varargs-metadata-rejected-ok?)
        (compiler-parse-extern-function-head-varargs-ok?)
        (compiler-parse-raw-pointer-ops-ok?)
        (compiler-parse-init-ok?)
        (compiler-parse-contextual-init-ok?)
        (compiler-parse-init-call-name-ok?)
        (reader_tests.symbol-id-preservation-ok?)
        (compiler-parse-source-symbol-ids-preserved-ok?)
        (compiler-parse-box-ok?)
        (compiler-parse-array-data-ok?)
        (compiler-parse-array-take-ok?)
        (compiler-parse-replace-ok?)
        (compiler-parse-reference-ok?)
        (compiler-parse-invalidate-ok?)
        (compiler-parse-borrow-ok?)
        (compiler-parse-resource-with-shape-ok?)
        (compiler-parse-spmd-callable-metadata-ok?)
        (compiler-parse-quote-syntax-shape-ok?))
        (if (and
          (compiler-parse-error-tests-ok?)
          (compiler-parse-declaration-tests-ok?)
          (compiler-parse-let-tests-ok?)
          (compiler-parse-spmd-tests-ok?)
          (compiler-parse-pattern-tests-ok?)
          (compiler-parse-pattern-string-char-tests-ok?)
          (compiler-parse-enum-struct-tests-ok?)
          (compiler-parse-operator-tests-ok?)
          (compiler-parse-type-literal-tests-ok?)
          (compiler-parse-region-tests-ok?)
          (compiler-parse-repl-tests-ok?)
          (compiler-parse-comptime-param-tests-ok?)
          (compiler-parse-defmacro-tests-ok?)
          (compiler-parse-resource-with-tests-ok?)
          (compiler-parse-quote-syntax-tests-ok?)
          (compiler-parse-place-migration-error-tests-ok?)
          (compiler-parse-public-dynamic-array-removal-tests-ok?)
          (compiler-parse-dotted-import-errors-ok?)
          (compiler-parse-cfg-tests-ok?))
          42
          (io.panic "parse: error-path self-tests failed"))
        (io.panic "parse: compiler AST smoke score mismatch"))]
    [(parser.ResultAstProgram.Err message) (io.panic message)]))