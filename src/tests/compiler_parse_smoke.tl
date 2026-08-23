;; compiler_parse_smoke.tl - Runnable structural smoke for compiler_parse_core.
(import stdlib.str_cat_runtime as str_cat)
(import compiler_parse_core)
(import compiler_ast_types as ast)
(import read as reader)
(import stdlib.string)
(import compiler_diagnostic as diagnostic)
(import compiler_diagnostic_tests)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import stdlib.io)

(define (compiler-parse-test-decl-origin-start-ok?
  [origin : compiler_parse_core.CompilerParseMaybeDeclSpan]
  [line : i64]
  [col : i64]) : bool
  (match origin
    [(compiler_parse_core.CompilerParseMaybeDeclSpan.Some span)
      (and
        (= (ast.ast-source-span-start-line span) line)
        (= (ast.ast-source-span-start-col span) col))]
    [(compiler_parse_core.CompilerParseMaybeDeclSpan.None) false]))

(define (compiler-parse-test-decl-origin-records-ok?) : bool
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [ok : bool false]
    (begin
      (match (compiler_parse_core.parse-ast-source
        "(module alpha)
(unsafe (extern (bad [arg0 : (Tuple i64 i64)]) : i64 (:abi c)))
(defstruct RefBox (:lifetimes a a) (value (& a i64)))")
        [(compiler_parse_core.ResultAstProgram.Ok
            (ast.AstProgram.Program decls-box))
          (let
            [decls : ast.AstDeclList (__tl-box-place decls-box)]
            [tail1 : ast.AstDeclList (ast.ast-decl-list-tail decls)]
            [tail2 : ast.AstDeclList (ast.ast-decl-list-tail tail1)]
            [replacement : ast.AstDeclList (ast.ast-decl-list-with-capacity 3)]
            [alias1 : ast.AstDeclList (ast.ast-decl-list-with-capacity 3)]
            [alias2 : ast.AstDeclList (ast.ast-decl-list-with-capacity 3)]
            (begin
              (ast.ast-decl-list-append-from (&mut replacement) (& decls) 0)
              (compiler_parse_core.compiler-parse-decl-origin-register-maybe!
                (& replacement)
                0
                (compiler_parse_core.compiler-parse-decl-origin-span
                  (& decls)
                  0))
              (compiler_parse_core.compiler-parse-decl-origin-register-maybe!
                (& replacement)
                2
                (compiler_parse_core.compiler-parse-decl-origin-span
                  (& tail2)
                  0))
              (ast.ast-decl-list-append-from (&mut alias1) (& replacement) 0)
              (compiler_parse_core.compiler-parse-decl-origin-register-list-aliases!
                (& alias1)
                0
                replacement)
              (ast.ast-decl-list-append-from (&mut alias2) (& alias1) 0)
              (compiler_parse_core.compiler-parse-decl-origin-register-list-aliases!
                (& alias2)
                0
                alias1)
              (set!
                ok
                (and
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler_parse_core.compiler-parse-decl-origin-span
                      (& decls)
                      0)
                    1
                    1)
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler_parse_core.compiler-parse-decl-origin-span
                      (& tail1)
                      0)
                    2
                    9)
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler_parse_core.compiler-parse-decl-origin-span
                      (& tail2)
                      0)
                    3
                    1)
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler_parse_core.compiler-parse-decl-origin-span
                      (& replacement)
                      0)
                    1
                    1)
                  (match (compiler_parse_core.compiler-parse-decl-origin-span
                    (& replacement)
                    1)
                    [(compiler_parse_core.CompilerParseMaybeDeclSpan.None) true]
                    [_ false])
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler_parse_core.compiler-parse-decl-origin-span
                      (& replacement)
                      2)
                    3
                    1)
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler_parse_core.compiler-parse-decl-origin-span
                      (& alias2)
                      0)
                    1
                    1)
                  (match (compiler_parse_core.compiler-parse-decl-origin-span
                    (& alias2)
                    1)
                    [(compiler_parse_core.CompilerParseMaybeDeclSpan.None) true]
                    [_ false])
                  (compiler-parse-test-decl-origin-start-ok?
                    (compiler_parse_core.compiler-parse-decl-origin-span
                      (& alias2)
                      2)
                    3
                    1)))
              (reader.sp-node-pool-truncate! mark)
              (compiler_parse_core.compiler-parse-decl-origin-cache-reset!)
              (set!
                ok
                (and
                  ok
                  (match (compiler_parse_core.compiler-parse-decl-origin-span
                    (& decls)
                    0)
                    [(compiler_parse_core.CompilerParseMaybeDeclSpan.None) true]
                    [_ false])))))]
        [(compiler_parse_core.ResultAstProgram.Err _)
          (reader.sp-node-pool-truncate! mark)])
      ok)))

(define (compiler-parse-test-semantic-origin-inner-ok?
  [decls : (& decls ast.AstDeclList)]
  [slot : i64]
  [index : i64]
  [expected-count : i64]
  [expected-kind : String]
  [expected-name : String]
  [start-line : i64]
  [start-col : i64]
  [end-line : i64]
  [end-col : i64]) : bool
  (match (compiler_parse_core.compiler-parse-semantic-origin-run decls slot)
    [(compiler_parse_core.CompilerParseMaybeSemanticOriginRun.Some run)
      (let
        [origin : compiler_parse_core.CompilerParseSemanticOrigin
          (compiler_parse_core.compiler-parse-semantic-origin-run-get
            (& run)
            index
            (compiler_parse_core.compiler-parse-semantic-origin-fallback))]
        [span : ast.AstSourceSpan origin.span]
        (and
          (=
            (compiler_parse_core.compiler-parse-semantic-origin-run-len (& run))
            expected-count)
          (= origin.ordinal index)
          (string.eq
            (compiler_parse_core.compiler-parse-semantic-origin-kind-marker
              origin.kind)
            expected-kind)
          (compiler-parse-test-name-id? origin.written-name expected-name)
          (= (ast.ast-source-span-start-line span) start-line)
          (= (ast.ast-source-span-start-col span) start-col)
          (= (ast.ast-source-span-end-line span) end-line)
          (= (ast.ast-source-span-end-col span) end-col)))]
    [(compiler_parse_core.CompilerParseMaybeSemanticOriginRun.None) false]))

(define (compiler-parse-test-semantic-origin-ok?
  [decls : (& decls ast.AstDeclList)]
  [slot : i64]
  [index : i64]
  [expected-count : i64]
  [expected-kind : String]
  [expected-name : String]
  [start-line : i64]
  [start-col : i64]
  [end-line : i64]
  [end-col : i64]) : bool
  (let
    [ok : bool
      (compiler-parse-test-semantic-origin-inner-ok?
        decls
        slot
        index
        expected-count
        expected-kind
        expected-name
        start-line
        start-col
        end-line
        end-col)]
    (begin
      (if ok
        unit
        (match (compiler_parse_core.compiler-parse-semantic-origin-run
          decls
          slot)
          [(compiler_parse_core.CompilerParseMaybeSemanticOriginRun.Some run)
            (let
              [origin : compiler_parse_core.CompilerParseSemanticOrigin
                (compiler_parse_core.compiler-parse-semantic-origin-run-get
                  (& run)
                  index
                  (compiler_parse_core.compiler-parse-semantic-origin-fallback))]
              [span : ast.AstSourceSpan origin.span]
              (io.print-error
                (str_cat.str-cat
                  "semantic origin mismatch: expected "
                  expected-name
                  ", actual "
                  (ci.intern-str origin.written-name)
                  ", count "
                  (string.int->string
                    (compiler_parse_core.compiler-parse-semantic-origin-run-len
                      (& run)))
                  ", kind "
                  (compiler_parse_core.compiler-parse-semantic-origin-kind-marker
                    origin.kind)
                  ", span "
                  (string.int->string (ast.ast-source-span-start-line span))
                  ":"
                  (string.int->string (ast.ast-source-span-start-col span))
                  "-"
                  (string.int->string (ast.ast-source-span-end-line span))
                  ":"
                  (string.int->string (ast.ast-source-span-end-col span))
                  "\n")))]
          [(compiler_parse_core.CompilerParseMaybeSemanticOriginRun.None)
            (io.print-error
              (str_cat.str-cat
                "semantic origin mismatch: missing run for "
                expected-name
                "\n"))]))
      ok)))

(define (compiler-parse-test-semantic-origin-none?
  [decls : (& decls ast.AstDeclList)]
  [slot : i64]) : bool
  (match (compiler_parse_core.compiler-parse-semantic-origin-run decls slot)
    [(compiler_parse_core.CompilerParseMaybeSemanticOriginRun.Some _) false]
    [(compiler_parse_core.CompilerParseMaybeSemanticOriginRun.None) true]))

(define (compiler-parse-semantic-origin-categories-ok?) : bool
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [ok : bool false]
    (begin
      (match (compiler_parse_core.parse-ast-source
        "(module pkg.inner)
(import foo.bar)
(import foo.bar as dep)
(defstruct Pair
  (left dep.Thing)
  (right (Array dep.Thing 2)))
(defenum Choice
  (Some dep.Thing)
  (None))
(defdispatch choose (scalar dep.choose))
; Repeated semantic-looking spelling next to the real tokens: Pair dep.Thing α
(define (f [p : Pair] [x : dep.Thing]) : Pair
  (let [y : dep.Thing x]
    (begin
      \"left Some None Pair dep.Thing α\"
      '(Some dep.Thing left)
      (begin \"α\" (__tl_struct-get p left))
      (set! (__tl_struct-get p left) y)
      (match (Some y)
        [(Some (None)) p]))))")
        [(compiler_parse_core.ResultAstProgram.Ok
            (ast.AstProgram.Program decls-box))
          (let
            [decls : ast.AstDeclList (__tl-box-place decls-box)]
            (set!
              ok
              (and
                ;; Dotted module definitions retain every exact component.
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  0
                  0
                  2
                  "__tl_semantic_origin_module_definition"
                  "pkg"
                  1
                  9
                  1
                  12)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  0
                  1
                  2
                  "__tl_semantic_origin_module_definition"
                  "inner"
                  1
                  13
                  1
                  18)
                ;; Default and explicit import aliases are distinct occurrences.
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  1
                  0
                  3
                  "__tl_semantic_origin_module_path"
                  "foo"
                  2
                  9
                  2
                  12)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  1
                  1
                  3
                  "__tl_semantic_origin_module_path"
                  "bar"
                  2
                  13
                  2
                  16)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  1
                  2
                  3
                  "__tl_semantic_origin_import_alias"
                  "bar"
                  2
                  13
                  2
                  16)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  2
                  2
                  3
                  "__tl_semantic_origin_import_alias"
                  "dep"
                  3
                  20
                  3
                  23)
                ;; Definitions plus nested/qualified nominal type syntax.
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  3
                  0
                  7
                  "__tl_semantic_origin_type_definition"
                  "Pair"
                  4
                  12
                  4
                  16)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  3
                  1
                  7
                  "__tl_semantic_origin_struct_field_definition"
                  "left"
                  5
                  4
                  5
                  8)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  3
                  2
                  7
                  "__tl_semantic_origin_module_path"
                  "dep"
                  5
                  9
                  5
                  12)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  3
                  3
                  7
                  "__tl_semantic_origin_type_name"
                  "Thing"
                  5
                  13
                  5
                  18)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  3
                  4
                  7
                  "__tl_semantic_origin_struct_field_definition"
                  "right"
                  6
                  4
                  6
                  9)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  3
                  5
                  7
                  "__tl_semantic_origin_module_path"
                  "dep"
                  6
                  17
                  6
                  20)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  3
                  6
                  7
                  "__tl_semantic_origin_type_name"
                  "Thing"
                  6
                  21
                  6
                  26)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  4
                  0
                  5
                  "__tl_semantic_origin_type_definition"
                  "Choice"
                  7
                  10
                  7
                  16)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  4
                  1
                  5
                  "__tl_semantic_origin_enum_variant_definition"
                  "Some"
                  8
                  4
                  8
                  8)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  4
                  4
                  5
                  "__tl_semantic_origin_enum_variant_definition"
                  "None"
                  9
                  4
                  9
                  8)
                ;; Dispatch function, explicit field operand, and nested patterns.
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  5
                  0
                  2
                  "__tl_semantic_origin_module_path"
                  "dep"
                  10
                  29
                  10
                  32)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  5
                  1
                  2
                  "__tl_semantic_origin_dispatch_function"
                  "choose"
                  10
                  33
                  10
                  39)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  6
                  0
                  10
                  "__tl_semantic_origin_type_name"
                  "Pair"
                  12
                  17
                  12
                  21)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  6
                  1
                  10
                  "__tl_semantic_origin_module_path"
                  "dep"
                  12
                  28
                  12
                  31)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  6
                  2
                  10
                  "__tl_semantic_origin_type_name"
                  "Thing"
                  12
                  32
                  12
                  37)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  6
                  3
                  10
                  "__tl_semantic_origin_type_name"
                  "Pair"
                  12
                  42
                  12
                  46)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  6
                  4
                  10
                  "__tl_semantic_origin_module_path"
                  "dep"
                  13
                  13
                  13
                  16)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  6
                  5
                  10
                  "__tl_semantic_origin_type_name"
                  "Thing"
                  13
                  17
                  13
                  22)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  6
                  6
                  10
                  "__tl_semantic_origin_struct_field_use"
                  "left"
                  17
                  38
                  17
                  42)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  6
                  7
                  10
                  "__tl_semantic_origin_struct_field_use"
                  "left"
                  18
                  32
                  18
                  36)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  6
                  8
                  10
                  "__tl_semantic_origin_enum_variant_pattern"
                  "Some"
                  20
                  11
                  20
                  15)
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  6
                  9
                  10
                  "__tl_semantic_origin_enum_variant_pattern"
                  "None"
                  20
                  17
                  20
                  21))))]
        [(compiler_parse_core.ResultAstProgram.Err message)
          (io.print-error
            (str_cat.str-cat "semantic origin parse failed: " message "\n"))])
      (reader.sp-node-pool-truncate! mark)
      (compiler_parse_core.compiler-parse-decl-origin-cache-reset!)
      ok)))

(define (compiler-parse-semantic-origin-aliases-ok?) : bool
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [ok : bool false]
    (begin
      (match (compiler_parse_core.parse-ast-source
        "(module alias.test)
(defstruct Pair (field dep.Thing))")
        [(compiler_parse_core.ResultAstProgram.Ok
            (ast.AstProgram.Program decls-box))
          (let
            [decls : ast.AstDeclList (__tl-box-place decls-box)]
            [tail : ast.AstDeclList (ast.ast-decl-list-tail decls)]
            [alias : ast.AstDeclList (ast.ast-decl-list-with-capacity 1)]
            [generated : ast.AstDeclList (ast.ast-decl-list-with-capacity 2)]
            (begin
              (ast.ast-decl-list-push-from
                (&mut alias)
                (& decls.slots)
                (+ decls.offset 1))
              (compiler_parse_core.compiler-parse-decl-origin-register-alias-record!
                (& alias)
                0
                1
                (compiler_parse_core.compiler-parse-decl-list-storage-key
                  (& decls))
                (+ decls.offset 1)
                false)
              (ast.ast-decl-list-push-from
                (&mut generated)
                (& decls.slots)
                (+ decls.offset 1))
              (ast.ast-decl-list-push-from
                (&mut generated)
                (& decls.slots)
                (+ decls.offset 1))
              (compiler_parse_core.compiler-parse-decl-origin-register-alias-record!
                (& generated)
                0
                2
                (compiler_parse_core.compiler-parse-decl-list-storage-key
                  (& decls))
                (+ decls.offset 1)
                true)
              (set!
                ok
                (and
                  ;; Same-storage slices and ordinary copied aliases retain runs.
                  (compiler-parse-test-semantic-origin-ok?
                    (& tail)
                    0
                    3
                    4
                    "__tl_semantic_origin_type_name"
                    "Thing"
                    2
                    28
                    2
                    33)
                  (compiler-parse-test-semantic-origin-ok?
                    (& alias)
                    0
                    3
                    4
                    "__tl_semantic_origin_type_name"
                    "Thing"
                    2
                    28
                    2
                    33)
                  ;; A one-to-many generated rewrite has no editable origins.
                  (compiler-parse-test-semantic-origin-none? (& generated) 0)
                  (compiler-parse-test-semantic-origin-none? (& generated) 1)))))]
        [(compiler_parse_core.ResultAstProgram.Err _) unit])
      (reader.sp-node-pool-truncate! mark)
      (compiler_parse_core.compiler-parse-decl-origin-cache-reset!)
      ok)))

(define (compiler-parse-semantic-origin-nested-module-ok?) : bool
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [ok : bool false]
    (begin
      (match (compiler_parse_core.parse-ast-source
        "(module outer.inner (defstruct Inside (field dep.Type)))")
        [(compiler_parse_core.ResultAstProgram.Ok
            (ast.AstProgram.Program decls-box))
          (let
            [decls : ast.AstDeclList (__tl-box-place decls-box)]
            (match (ast.ast-decl-list-get (& decls) 0 (ast.ast-decl-fallback))
              [(ast.AstDecl.ModuleBody _ body-box)
                (let
                  [body : ast.AstDeclList (__tl-box-place body-box)]
                  (set!
                    ok
                    (and
                      (compiler-parse-test-semantic-origin-ok?
                        (& decls)
                        0
                        0
                        2
                        "__tl_semantic_origin_module_definition"
                        "outer"
                        1
                        9
                        1
                        14)
                      (compiler-parse-test-semantic-origin-ok?
                        (& decls)
                        0
                        1
                        2
                        "__tl_semantic_origin_module_definition"
                        "inner"
                        1
                        15
                        1
                        20)
                      (compiler-parse-test-semantic-origin-ok?
                        (& body)
                        0
                        0
                        4
                        "__tl_semantic_origin_type_definition"
                        "Inside"
                        1
                        32
                        1
                        38)
                      (compiler-parse-test-semantic-origin-ok?
                        (& body)
                        0
                        3
                        4
                        "__tl_semantic_origin_type_name"
                        "Type"
                        1
                        50
                        1
                        54))))]
              [_ unit]))]
        [(compiler_parse_core.ResultAstProgram.Err _) unit])
      (reader.sp-node-pool-truncate! mark)
      (compiler_parse_core.compiler-parse-decl-origin-cache-reset!)
      ok)))

(define (compiler-parse-semantic-origin-growth-reset-ok?) : bool
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    [ok : bool false]
    (begin
      (match (compiler_parse_core.parse-ast-source
        "(module m00)
(module m01)
(module m02)
(module m03)
(module m04)
(module m05)
(module m06)
(module m07)
(module m08)
(module m09)
(module m10)
(module m11)
(module m12)
(module m13)
(module m14)
(module m15)
(module m16)
(module m17)
(module m18)
(module m19)")
        [(compiler_parse_core.ResultAstProgram.Ok
            (ast.AstProgram.Program decls-box))
          (let
            [decls : ast.AstDeclList (__tl-box-place decls-box)]
            (begin
              (set!
                ok
                (compiler-parse-test-semantic-origin-ok?
                  (& decls)
                  19
                  0
                  1
                  "__tl_semantic_origin_module_definition"
                  "m19"
                  20
                  9
                  20
                  12))
              (reader.sp-node-pool-truncate! mark)
              (compiler_parse_core.compiler-parse-decl-origin-cache-reset!)
              (set!
                ok
                (and
                  ok
                  (compiler-parse-test-semantic-origin-none? (& decls) 19)))))]
        [(compiler_parse_core.ResultAstProgram.Err _) unit])
      (if (> (reader.sp-node-pool-len) mark)
        (reader.sp-node-pool-truncate! mark)
        unit)
      (compiler_parse_core.compiler-parse-decl-origin-cache-reset!)
      ok)))

(define (compiler-parse-member-origin-boundary-ok?) : bool
  (match (compiler_parse_core.parse-ast-source
    "(defstruct First (x i64))
(defstruct Second (y i64))")
    [(compiler_parse_core.ResultAstProgram.Ok
        (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        (match (ast.ast-decl-list-get (& decls) 0 (ast.ast-decl-fallback))
          [(ast.AstDecl.DefStruct decl-meta _ _ _ fields)
            (let
              [span : ast.AstSourceSpan
                (compiler_parse_core.compiler-parse-field-def-list-span-get
                  (& fields)
                  1
                  (ast.ast-decl-span-fallback))]
              (and
                (= (ast.ast-source-span-start-line span) 1)
                (= (ast.ast-source-span-start-col span) 12)))]
          [_ false]))]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-parse-test-name-id? [name-id : i64] [text : String]) : bool
  (match (ci.intern-lookup text)
    [(ci.InternLookupFound expected-id) (= name-id expected-id)]
    [(ci.InternLookupMissing) false]))

(define (compiler-parse-name-id-provenance-ok?) : bool
  ;; Keep the inline-test discovery marker split: this source is parser input,
  ;; not an inline test declaration in this file.
  (match (compiler_parse_core.parse-ast-source
    (str_cat.str-cat
      "(module parsed.module)
(defstruct ParsedType (parsed-field i64))
(define (parsed-fn [parsed-param : ParsedType]) : ParsedType parsed-param)
"
      "("
      "test parsed-test unit)"))
    [(compiler_parse_core.ResultAstProgram.Ok
        (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        (and
          (match (ast.ast-decl-list-get (& decls) 0 (ast.ast-decl-fallback))
            [(ast.AstDecl.Module name)
              (compiler-parse-test-name-id? name "parsed.module")]
            [_ false])
          (match (ast.ast-decl-list-get (& decls) 1 (ast.ast-decl-fallback))
            [(ast.AstDecl.DefStruct decl-meta name _ _ fields)
              (and
                (compiler-parse-test-name-id? name "ParsedType")
                (match (ast.ast-field-def-list-get
                  (& fields)
                  0
                  (ast.ast-field-def-fallback))
                  [(ast.AstFieldDef.Def field _ _)
                    (compiler-parse-test-name-id? field "parsed-field")]))]
            [_ false])
          (match (ast.ast-decl-list-get (& decls) 2 (ast.ast-decl-fallback))
            [(ast.AstDecl.DefFn decl-meta name params ret _ _)
              (and
                (compiler-parse-test-name-id? name "parsed-fn")
                (match (ast.ast-param-list-get
                  (& params)
                  0
                  (ast.ast-param-fallback))
                  [(ast.AstParam.Param param ty _ _)
                    (and
                      (compiler-parse-test-name-id? param "parsed-param")
                      (match ty
                        [(ast.AstType.Var type-name)
                          (compiler-parse-test-name-id? type-name "ParsedType")]
                        [_ false]))])
                (match ret
                  [(ast.AstType.Var type-name)
                    (compiler-parse-test-name-id? type-name "ParsedType")]
                  [_ false]))]
            [_ false])
          (match (ast.ast-decl-list-get (& decls) 3 (ast.ast-decl-fallback))
            [(ast.AstDecl.Test name _ _)
              (compiler-parse-test-name-id? name "parsed-test")]
            [_ false])))]
    [(compiler_parse_core.ResultAstProgram.Err _) false]))

(define (compiler-parse-removed-declaration-errors-ok?) : bool
  (and
    (compiler_parse_core.compiler-parse-error-ok?
      "(comptime-decl (define value : i64 1))"
      (compiler_parse_core.parse-ast-removed-declaration-message))
    (compiler_parse_core.compiler-parse-error-ok?
      "(comptime-decls (define value : i64 1))"
      (compiler_parse_core.parse-ast-removed-declaration-message))
    (compiler_parse_core.compiler-parse-error-ok?
      "(define (main) : i64 (comptime-decl (define value : i64 1)))"
      (compiler_parse_core.parse-ast-removed-declaration-message))
    (compiler_parse_core.compiler-parse-error-ok?
      "(define (main) : i64 (comptime-decls (define value : i64 1)))"
      (compiler_parse_core.parse-ast-removed-declaration-message))))

(define (compiler-parse-state-diagnostic-message
  [path : String]
  [source : String]
  [parse-state : compiler_parse_core.CompilerParseState]
  [pools : ast.AstNodePoolContext]) : String
  (match (compiler_parse_core.parse-ast-source-diagnostic-with-cfg-and-pools
    path
    source
    (compiler_parse_core.compiler-parse-state-cfgs
      parse-state
      (compiler_parse_core.compiler-cfg-empty))
    pools)
    [(compiler_parse_core.ResultAstProgramDiagnostic.Ok _) "parse succeeded"]
    [(compiler_parse_core.ResultAstProgramDiagnostic.Err diag)
      (diagnostic.compiler-diagnostic-message (__tl-box-place diag))]))

(define (compiler-parse-state-import-ok?
  [source : String]
  [expected-path : String]
  [expected-alias : String]
  [intern-state : ci.InternCompatState]
  [parse-state : compiler_parse_core.CompilerParseState]
  [pools : ast.AstNodePoolContext]) : bool
  (match (compiler_parse_core.parse-ast-source-diagnostic-with-cfg-and-pools
    "owner-import.tl"
    source
    (compiler_parse_core.compiler-parse-state-cfgs
      parse-state
      (compiler_parse_core.compiler-cfg-empty))
    pools)
    [(compiler_parse_core.ResultAstProgramDiagnostic.Err _) false]
    [(compiler_parse_core.ResultAstProgramDiagnostic.Ok
        (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
              (string.eq path expected-path)
              (string.eq
                (ci.intern-compat-state-str intern-state module-name)
                expected-path)
              (string.eq
                (ci.intern-compat-state-str intern-state alias)
                expected-alias))]
          [_ false]))]
    [(compiler_parse_core.ResultAstProgramDiagnostic.Ok _) false]))

(define (compiler-parse-state-source-ok?
  [source : String]
  [parse-state : compiler_parse_core.CompilerParseState]
  [pools : ast.AstNodePoolContext]) : bool
  (match (compiler_parse_core.parse-ast-source-diagnostic-with-cfg-and-pools
    "installed-owner.tl"
    source
    (compiler_parse_core.compiler-parse-state-cfgs
      parse-state
      (compiler_parse_core.compiler-cfg-empty))
    pools)
    [(compiler_parse_core.ResultAstProgramDiagnostic.Ok _) true]
    [(compiler_parse_core.ResultAstProgramDiagnostic.Err _) false]))

(define (compiler-parse-installed-owner-lex-sync-ok?) : bool
  (let
    [home : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [intern-state : ci.InternCompatState (ci.intern-compat-state-new)]
    [parse-state : compiler_parse_core.CompilerParseState
      (compiler_parse_core.compiler-parse-state-new-with-intern-state
        intern-state)]
    [pools : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 64 32)]
    [first-len : i64 0]
    [second-len : i64 0]
    [ok : bool false]
    (begin
      ;; The temporary driver bridge seeds builtins through the installed
      ;; globals. Explicit lexing must capture that scalar advance, then publish
      ;; each file's new count so the next file cannot rewind the same owner.
      (ci.intern-compat-state-install! intern-state)
      (cbi.compiler-builtin-reset!)
      (cbi.compiler-builtin-initialize-for-parse!)
      (set!
        ok
        (compiler-parse-state-source-ok?
          "(define (first-owner-fn [first-owner-param : i64]) : i64 first-owner-param)"
          parse-state
          pools))
      (set! first-len (ci.intern-compat-state-pool-len intern-state))
      (set!
        ok
        (and
          ok
          (= first-len (ci.intern-pool-len))
          (compiler-parse-state-source-ok?
            "(define (second-owner-fn [second-owner-param : i64]) : i64 (+ second-owner-param 1))"
            parse-state
            pools)))
      (set! second-len (ci.intern-compat-state-pool-len intern-state))
      (set!
        ok
        (and ok (> second-len first-len) (= second-len (ci.intern-pool-len))))
      (ci.intern-compat-state-install! home)
      (cbi.compiler-builtin-reset!)
      (cbi.compiler-builtin-initialize-for-parse!)
      ok)))

(define (compiler-parse-intern-owner-isolation-ok?) : bool
  (let
    [active-decoy-id : i64 (ci.intern-source-slice "parser-active-decoy" 0 19)]
    [home : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [state-a : ci.InternCompatState (ci.intern-compat-state-new)]
    [state-b : ci.InternCompatState (ci.intern-compat-state-new)]
    [message-a : String ""]
    [message-b : String ""]
    [ok : bool false]
    (begin
      ;; Seed fixed builtin IDs identically in both inactive owners, then leave
      ;; the active table as a decoy while lexing and parsing through A and B.
      (ci.intern-compat-state-install! state-a)
      (cbi.compiler-builtin-reset!)
      (cbi.compiler-builtin-initialize-for-parse!)
      (ci.intern-compat-state-capture-from-globals! state-a)
      (ci.intern-compat-state-install! state-b)
      (cbi.compiler-builtin-reset!)
      (cbi.compiler-builtin-initialize-for-parse!)
      (ci.intern-compat-state-capture-from-globals! state-b)
      (ci.intern-compat-state-install! home)
      (cbi.compiler-builtin-reset!)
      (cbi.compiler-builtin-initialize-for-parse!)
      (let
        [active-table-before : i64 (ci.intern-active-table-id)]
        [active-generation-before : i64 (ci.intern-generation)]
        [active-len-before : i64 (ci.intern-pool-len)]
        [parse-state-a : compiler_parse_core.CompilerParseState
          (compiler_parse_core.compiler-parse-state-new-with-intern-state
            state-a)]
        [parse-state-b : compiler_parse_core.CompilerParseState
          (compiler_parse_core.compiler-parse-state-new-with-intern-state
            state-b)]
        [pools-a : ast.AstNodePoolContext
          (ast.ast-node-pool-context-new-with-capacities 64 32)]
        [pools-b : ast.AstNodePoolContext
          (ast.ast-node-pool-context-new-with-capacities 64 32)]
        (begin
          (set!
            message-a
            (compiler-parse-state-diagnostic-message
              "owner-a.tl"
              "(defmacro (bad [T : type (:owner-a)]) : Module unit)"
              parse-state-a
              pools-a))
          (set!
            message-b
            (compiler-parse-state-diagnostic-message
              "owner-b.tl"
              "(defmacro (bad [T : type (:owner-b)]) : Module unit)"
              parse-state-b
              pools-b))
          (set!
            ok
            (and
              (string.eq
                message-a
                "parse: macro type operand T has unknown constraint form :owner-a")
              (string.eq
                message-b
                "parse: macro type operand T has unknown constraint form :owner-b")
              (compiler-parse-state-import-ok?
                "(import owner-a.pkg.alpha)"
                "owner-a.pkg.alpha"
                "alpha"
                state-a
                parse-state-a
                pools-a)
              (compiler-parse-state-import-ok?
                "(import owner-b.pkg.beta)"
                "owner-b.pkg.beta"
                "beta"
                state-b
                parse-state-b
                pools-b)
              (= (ci.intern-active-table-id) active-table-before)
              (= (ci.intern-generation) active-generation-before)
              (= (ci.intern-pool-len) active-len-before)
              (string.eq (ci.intern-str active-decoy-id) "parser-active-decoy")))))
      ok)))

(define (compiler-diagnostic-test-source-position-index
  [source : String]
  [target-line : i64]
  [target-col : i64]) : i64
  (let
    [idx : i64 0]
    [source-len : i64 (string.string-length source)]
    [line : i64 1]
    [col : i64 1]
    [found : i64 -1]
    (begin
      (while (and (< found 0) (< idx source-len))
        (if (and (= line target-line) (= col target-col))
          (set! found idx)
          (begin
            (if (= (string.string-ref source idx) '\n')
              (begin
                (set! line (+ line 1))
                (set! col 1))
              (set! col (+ col 1)))
            (set! idx (+ idx 1)))))
      (if (and (< found 0) (= line target-line) (= col target-col))
        source-len
        found))))

(define (compiler-diagnostic-test-apply-edit
  [source : String]
  [edit : diagnostic.CompilerDiagnosticTextEdit]) : diagnostic.CompilerDiagnosticMaybeString
  (let
    [span : diagnostic.CompilerDiagnosticSpan
      (diagnostic.compiler-diagnostic-text-edit-span edit)]
    [start : i64
      (compiler-diagnostic-test-source-position-index
        source
        (diagnostic.compiler-diagnostic-span-start-line span)
        (diagnostic.compiler-diagnostic-span-start-col span))]
    [end : i64
      (compiler-diagnostic-test-source-position-index
        source
        (diagnostic.compiler-diagnostic-span-end-line span)
        (diagnostic.compiler-diagnostic-span-end-col span))]
    [source-len : i64 (string.string-length source)]
    (if (or (< start 0) (< end start))
      CompilerDiagnosticNoString
      (CompilerDiagnosticSomeString
        (str_cat.str-cat
          (string.substring source 0 start)
          (diagnostic.compiler-diagnostic-text-edit-replacement edit)
          (string.substring source end (- source-len end)))))))

;; The compiler itself never emits a multi-edit fix, so the shipped module keeps
;; only the single-edit constructor and this fixture builds the pair locally.
(define (compiler-diagnostic-test-edit-pair
  [first : diagnostic.CompilerDiagnosticTextEdit]
  [second : diagnostic.CompilerDiagnosticTextEdit]) : diagnostic.CompilerDiagnosticTextEditSeq
  (let
    [slots : (__tl_dyn-array diagnostic.CompilerDiagnosticTextEdit)
      (__tl_make-array diagnostic.CompilerDiagnosticTextEdit 2)]
    (begin
      (set! (array-ref slots 0) first)
      (set! (array-ref slots 1) second)
      (diagnostic.CompilerDiagnosticTextEditSeq slots 2))))

(define (compiler-diagnostic-fix-model-ok?) : bool
  (let
    [plain : diagnostic.CompilerDiagnostic
      (diagnostic.compiler-diagnostic-simple "plain.tl" 1 1 "plain")]
    [fix : diagnostic.CompilerDiagnosticFix
      (diagnostic.compiler-diagnostic-fix-new
        "Apply both edits"
        CompilerDiagnosticMachineApplicable
        (compiler-diagnostic-test-edit-pair
          (diagnostic.compiler-diagnostic-text-edit-new
            (diagnostic.CompilerDiagnosticSpan "" 1 2 1 4)
            "first")
          (diagnostic.compiler-diagnostic-text-edit-new
            (diagnostic.CompilerDiagnosticSpan "other.tl" 2 3 2 5)
            "λ")))]
    [diag : diagnostic.CompilerDiagnostic
      (diagnostic.compiler-diagnostic-with-fix plain fix)]
    [copied : diagnostic.CompilerDiagnostic
      (diagnostic.compiler-diagnostic-copy diag)]
    [moved : diagnostic.CompilerDiagnostic
      (diagnostic.compiler-diagnostic-with-primary-span
        (diagnostic.compiler-diagnostic-with-path copied "new.tl")
        (diagnostic.CompilerDiagnosticSpan "new.tl" 4 5 4 6))]
    [fixes : diagnostic.CompilerDiagnosticFixSeq
      (diagnostic.compiler-diagnostic-fixes moved)]
    (and
      (=
        (__tl-project-field (diagnostic.compiler-diagnostic-fixes plain) len)
        0)
      (= fixes.len 1)
      (let
        [copied-fix : diagnostic.CompilerDiagnosticFix
          (array-ref fixes.slots 0)]
        [edits : diagnostic.CompilerDiagnosticTextEditSeq
          (diagnostic.compiler-diagnostic-fix-edits copied-fix)]
        (and
          (string.eq
            (diagnostic.compiler-diagnostic-fix-title copied-fix)
            "Apply both edits")
          (match (diagnostic.compiler-diagnostic-fix-applicability copied-fix)
            [CompilerDiagnosticMachineApplicable true]
            [_ false])
          (= edits.len 2)
          (let
            [first : diagnostic.CompilerDiagnosticTextEdit
              (array-ref edits.slots 0)]
            [second : diagnostic.CompilerDiagnosticTextEdit
              (array-ref edits.slots 1)]
            [first-span : diagnostic.CompilerDiagnosticSpan
              (diagnostic.compiler-diagnostic-text-edit-span first)]
            [second-span : diagnostic.CompilerDiagnosticSpan
              (diagnostic.compiler-diagnostic-text-edit-span second)]
            (and
              (string.eq
                (diagnostic.compiler-diagnostic-span-path first-span)
                "new.tl")
              (string.eq
                (diagnostic.compiler-diagnostic-text-edit-replacement first)
                "first")
              (string.eq
                (diagnostic.compiler-diagnostic-span-path second-span)
                "other.tl")
              (= (diagnostic.compiler-diagnostic-span-start-line second-span) 2)
              (= (diagnostic.compiler-diagnostic-span-start-col second-span) 3)
              (string.eq
                (diagnostic.compiler-diagnostic-text-edit-replacement second)
                "λ"))))))))

(define (compiler-diagnostic-invalid-fixes-rejected-ok?) : bool
  (let
    [base : diagnostic.CompilerDiagnostic
      (diagnostic.compiler-diagnostic-simple "invalid.tl" 1 1 "invalid")]
    [unknown : diagnostic.CompilerDiagnostic
      (diagnostic.compiler-diagnostic-with-fix
        base
        (diagnostic.compiler-diagnostic-fix-new
          "Unknown span"
          CompilerDiagnosticMachineApplicable
          (diagnostic.compiler-diagnostic-text-edit-single
            (diagnostic.compiler-diagnostic-text-edit-new
              (diagnostic.CompilerDiagnosticSpan "" 0 0 0 0)
              "x"))))]
    [overlap : diagnostic.CompilerDiagnostic
      (diagnostic.compiler-diagnostic-with-fix
        base
        (diagnostic.compiler-diagnostic-fix-new
          "Overlapping edits"
          CompilerDiagnosticMachineApplicable
          (compiler-diagnostic-test-edit-pair
            (diagnostic.compiler-diagnostic-text-edit-new
              (diagnostic.CompilerDiagnosticSpan "" 1 2 1 6)
              "left")
            (diagnostic.compiler-diagnostic-text-edit-new
              (diagnostic.CompilerDiagnosticSpan "" 1 4 1 7)
              "right"))))]
    (and
      (=
        (__tl-project-field (diagnostic.compiler-diagnostic-fixes unknown) len)
        0)
      (=
        (__tl-project-field (diagnostic.compiler-diagnostic-fixes overlap) len)
        0))))

(define (compiler-diagnostic-unicode-byte-edit-ok?) : bool
  (let
    [source : String "αx\n"]
    [edit : diagnostic.CompilerDiagnosticTextEdit
      (diagnostic.compiler-diagnostic-text-edit-new
        ;; alpha occupies UTF-8 byte columns 1-2, so x is byte column 3.
        (diagnostic.CompilerDiagnosticSpan "unicode.tl" 1 3 1 4)
        "β")]
    (match (compiler-diagnostic-test-apply-edit source edit)
      [(CompilerDiagnosticSomeString updated) (string.eq updated "αβ\n")]
      [CompilerDiagnosticNoString false])))

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (if (and
      (= (compiler_diagnostic_tests.compiler-diagnostic-self-test) 42)
      (compiler-parse-test-decl-origin-records-ok?)
      (compiler-parse-semantic-origin-categories-ok?)
      (compiler-parse-semantic-origin-aliases-ok?)
      (compiler-parse-semantic-origin-nested-module-ok?)
      (compiler-parse-semantic-origin-growth-reset-ok?)
      (compiler-parse-member-origin-boundary-ok?)
      (compiler-parse-name-id-provenance-ok?)
      (compiler-parse-removed-declaration-errors-ok?)
      (compiler-parse-intern-owner-isolation-ok?)
      (compiler-parse-installed-owner-lex-sync-ok?)
      (compiler-diagnostic-fix-model-ok?)
      (compiler-diagnostic-invalid-fixes-rejected-ok?)
      (compiler-diagnostic-unicode-byte-edit-ok?))
      (compiler_parse_core.compiler-parse-smoke)
      1)))