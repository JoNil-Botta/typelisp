;; doc_expand.tl - Expansion-aware generated-module docs.
(import compiler_owned_view as owned_view)
(import stdlib.str_cat_runtime as str_cat)
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
(import compiler_typecheck_api)

(define (doc-cat2 [a : String] [b : String]) : String
  (str_cat.str-cat a b ""))

(define (doc-cat3 [a : String] [b : String] [c : String]) : String
  (str_cat.str-cat a b c))

(define (doc-cat4 [a : String] [b : String] [c : String] [d : String]) : String
  (str_cat.str-cat a b c d ""))

(define (doc-cat5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (str_cat.str-cat a b c d e))

(define (doc-cat6
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]
  [f : String]) : String
  (str_cat.str-cat a b c d e f ""))

(defenum DocMaybeItem
  (No)
  (Some doc_extract.DocItem))

(import (vector.vector String core) as doc_import_form_vec)

(defstruct DocImportFormScan
  (forms doc_import_form_vec.Vec)
  (has-macro bool))

(defstruct DocMacroImportExample
  (alias String)
  (form String))

(import (vector.vector DocMacroImportExample core) as doc_macro_import_example_vec)

(defstruct DocGeneratedTargetExample
  (target String)
  (form String))

(import (vector.vector DocGeneratedTargetExample core) as doc_generated_target_example_vec)

(defenum ResultDocExpandedModules
  (Ok doc_module_vec.Vec)
  (Err String))

(define (doc-import-form-list-mut-contains-from?
  [forms : (&mut forms doc_import_form_vec.Vec)]
  [form : String]
  [index : i64]) : bool
  (if (>= index (doc_import_form_vec.len forms))
    false
    (if (string.eq (doc_import_form_vec.get forms index "") form)
      true
      (doc-import-form-list-mut-contains-from? forms form (+ index 1)))))

(define (doc-import-form-list-mut-contains?
  [forms : (&mut forms doc_import_form_vec.Vec)]
  [form : String]) : bool
  (doc-import-form-list-mut-contains-from? forms form 0))

(define (doc-import-form-list-push-unique!
  [forms : (&mut forms doc_import_form_vec.Vec)]
  [form : String]) : unit
  (if (doc-import-form-list-mut-contains?
    forms
    (owned_view.compiler-owned-shared-view form))
    unit
    (doc_import_form_vec.push-ref! forms form)))

(define (doc-import-form-list-source-from
  [forms : doc_import_form_vec.Vec]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      (doc_import_form_vec.get (& forms) index "")
      "\n"
      (doc-import-form-list-source-from forms (+ index 1) count))))

(define (doc-import-form-list-source [forms : doc_import_form_vec.Vec]) : String
  (doc-import-form-list-source-from
    (owned_view.compiler-owned-shared-view forms)
    0
    (doc_import_form_vec.len (& forms))))

(define (doc-import-alias-string [alias : ast.AstMaybeImportAlias]) : String
  (match alias
    [(ast.AstMaybeImportAlias.Some name) (ci.intern-str name)]
    [(ast.AstMaybeImportAlias.No) ""]))

(define (doc-symbol-text [name-id : i64]) : String
  (tc.tc-hygiene-name-text-id name-id))

(define (doc-ast-type-id-source [type-segment-bases : i64] [ty-id : i64]) : String
  (doc-ast-type-source
    type-segment-bases
    (ast.ast-type-segment-bases-get type-segment-bases ty-id)))

(define (doc-ast-type-list-source-from
  [type-segment-bases : i64]
  [types : ast.AstTypeList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      (if (= index 0)
        ""
        " ")
      (doc-ast-type-id-source
        type-segment-bases
        (ast.ast-type-list-get (& types) index 0))
      (doc-ast-type-list-source-from type-segment-bases types (+ index 1) count))))

(define (doc-ast-type-list-source
  [type-segment-bases : i64]
  [types : ast.AstTypeList]) : String
  (doc-ast-type-list-source-from
    type-segment-bases
    (owned_view.compiler-owned-shared-view types)
    0
    (ast.ast-type-list-len (& types))))

(define (doc-ast-lifetime-list-source-from
  [lifetimes : ast.AstLifetimeList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      (if (= index 0)
        ""
        " ")
      (doc-symbol-text
        (ast.ast-lifetime-list-get
          (& lifetimes)
          index
          (ast.ast-lifetime-fallback)))
      (doc-ast-lifetime-list-source-from lifetimes (+ index 1) count))))

(define (doc-ast-lifetime-list-source [lifetimes : ast.AstLifetimeList]) : String
  (let
    [count : i64 (ast.ast-lifetime-list-len (& lifetimes))]
    (if (= count 0)
      ""
      (doc-cat3
        " (:lifetimes "
        (doc-ast-lifetime-list-source-from lifetimes 0 count)
        ")"))))

(define (doc-ast-type-source [type-segment-bases : i64] [ty : ast.AstType]) : String
  (match ty
    [(ast.AstType.I64) "i64"]
    [(ast.AstType.I32) "i32"]
    [(ast.AstType.I16) "i16"]
    [(ast.AstType.I8) "i8"]
    [(ast.AstType.U64) "u64"]
    [(ast.AstType.U32) "u32"]
    [(ast.AstType.U16) "u16"]
    [(ast.AstType.U8) "u8"]
    [(ast.AstType.F64) "f64"]
    [(ast.AstType.F32) "f32"]
    [(ast.AstType.Bool) "bool"]
    [(ast.AstType.Char) "char"]
    [(ast.AstType.String) "String"]
    [(ast.AstType.Str) "str"]
    [(ast.AstType.Bytes) "bytes"]
    [(ast.AstType.Unit) "unit"]
    [(ast.AstType.Never) "never"]
    [(ast.AstType.Expr) "Expr"]
    [(ast.AstType.ExprList) "ExprList"]
    [(ast.AstType.Func args-box ret)
      (doc-cat5
        "(-> "
        (doc-ast-type-list-source
          type-segment-bases
          (owned_view.compiler-owned-box-shared-view args-box))
        " "
        (doc-ast-type-id-source type-segment-bases ret)
        ")")]
    [(ast.AstType.Tuple elems-box)
      (doc-cat3
        "(Tuple "
        (doc-ast-type-list-source
          type-segment-bases
          (owned_view.compiler-owned-box-shared-view elems-box))
        ")")]
    [(ast.AstType.Array elem size)
      (doc-cat5
        "(Array "
        (doc-ast-type-id-source type-segment-bases elem)
        " "
        (string.int->string size)
        ")")]
    [(ast.AstType.DynArray elem)
      (doc-cat3
        "(__tl_dyn-array "
        (doc-ast-type-id-source type-segment-bases elem)
        ")")]
    [(ast.AstType.Slice elem)
      (doc-cat3 "(Slice " (doc-ast-type-id-source type-segment-bases elem) ")")]
    [(ast.AstType.Box elem)
      (doc-cat3 "(Box " (doc-ast-type-id-source type-segment-bases elem) ")")]
    [(ast.AstType.Region region elem)
      (doc-cat5
        "(Region "
        (doc-symbol-text region)
        " "
        (doc-ast-type-id-source type-segment-bases elem)
        ")")]
    [(ast.AstType.Ref lifetime elem)
      (doc-cat5
        "(& "
        (doc-symbol-text lifetime)
        " "
        (doc-ast-type-id-source type-segment-bases elem)
        ")")]
    [(ast.AstType.MutRef lifetime elem)
      (doc-cat5
        "(&mut "
        (doc-symbol-text lifetime)
        " "
        (doc-ast-type-id-source type-segment-bases elem)
        ")")]
    [(ast.AstType.Enum name) (doc-symbol-text name)]
    [(ast.AstType.EnumArgs name _) (doc-symbol-text name)]
    [(ast.AstType.Struct name) (doc-symbol-text name)]
    [(ast.AstType.StructArgs name _) (doc-symbol-text name)]
    [(ast.AstType.Var name) (doc-symbol-text name)]
    [(ast.AstType.VarArgs name _) (doc-symbol-text name)]
    [(ast.AstType.Ptr elem)
      (doc-cat3 "(Ptr " (doc-ast-type-id-source type-segment-bases elem) ")")]
    [(ast.AstType.MutPtr elem)
      (doc-cat3 "(MutPtr " (doc-ast-type-id-source type-segment-bases elem) ")")]))

(define (doc-expand-escape-string-loop
  [text : String]
  [index : i64]
  [count : i64]
  [out : String]) : String
  (if (>= index count)
    out
    (let
      [c : char (string.string-ref text index)]
      [code : i64 (cast c : i64)]
      [piece : String
        (cond
          [(= code 34) "\\\""]
          [(= code 92) "\\\\"]
          [else (string.substring text index 1)])]
      (doc-expand-escape-string-loop
        text
        (+ index 1)
        count
        (doc-cat2 out piece)))))

(define (doc-expand-escape-string [text : String]) : String
  (doc-expand-escape-string-loop
    (owned_view.compiler-owned-shared-view text)
    0
    (string.string-length (owned_view.compiler-owned-shared-view text))
    ""))

(define (doc-ast-literal-source [lit : ast.AstLiteral]) : String
  (match (owned_view.compiler-owned-shared-view lit)
    [(ast.AstLiteral.Int _ _) (ast.ast-lit-int-text lit)]
    [(ast.AstLiteral.Float text) text]
    [(ast.AstLiteral.Bool value)
      (if value
        "true"
        "false")]
    [(ast.AstLiteral.Char _) "'?'"]
    [(ast.AstLiteral.String string-id)
      (doc-cat3 "\"" (doc-expand-escape-string (ci.intern-str string-id)) "\"")]
    [(ast.AstLiteral.Unit) "unit"]))

(define (doc-ast-expr-list-source-from
  [type-segment-bases : i64]
  [exprs : ast.AstExprList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      " "
      (doc-ast-expr-source
        type-segment-bases
        (ast.ast-expr-list-get (& exprs) index 0))
      (doc-ast-expr-list-source-from type-segment-bases exprs (+ index 1) count))))

(define (doc-ast-expr-list-source
  [type-segment-bases : i64]
  [exprs : ast.AstExprList]) : String
  (doc-ast-expr-list-source-from
    type-segment-bases
    (owned_view.compiler-owned-shared-view exprs)
    0
    (ast.ast-expr-list-len (& exprs))))

(define (doc-ast-expr-source [type-segment-bases : i64] [expr-id : i64]) : String
  (match (ast.ast-expr-unspan (ast.ast-node-get expr-id))
    [(ast.AstExpr.Literal lit) (doc-ast-literal-source lit)]
    [(ast.AstExpr.Var name) (ci.intern-str name)]
    [(ast.AstExpr.Call callee args)
      (doc-cat4
        "("
        (doc-ast-expr-source type-segment-bases callee)
        (doc-ast-expr-list-source type-segment-bases args)
        ")")]
    [(ast.AstExpr.TypeLiteral ty-id)
      (doc-cat3 "(type " (doc-ast-type-id-source type-segment-bases ty-id) ")")]
    [(ast.AstExpr.Ann inner _) (doc-ast-expr-source type-segment-bases inner)]
    [(ast.AstExpr.Spanned inner _)
      (doc-ast-expr-source type-segment-bases inner)]
    [_ "..."]))

(define (doc-macro-import-example-fallback) : DocMacroImportExample
  (DocMacroImportExample "" ""))

(define (doc-macro-import-example-push!
  [examples : (&mut examples doc_macro_import_example_vec.Vec)]
  [alias : String]
  [form : String]) : unit
  (doc_macro_import_example_vec.push-ref!
    examples
    (DocMacroImportExample alias form)))

(define (doc-macro-import-example-find-from
  [examples : (& examples doc_macro_import_example_vec.Vec)]
  [alias : String]
  [index : i64]) : String
  (if (< index 0)
    ""
    (let
      [example : DocMacroImportExample
        (doc_macro_import_example_vec.get
          examples
          index
          (doc-macro-import-example-fallback))]
      (if (string.eq example.alias alias)
        example.form
        (doc-macro-import-example-find-from examples alias (- index 1))))))

(define (doc-macro-import-example-find
  [examples : doc_macro_import_example_vec.Vec]
  [alias : String]) : String
  (doc-macro-import-example-find-from
    (& examples)
    alias
    (- (doc_macro_import_example_vec.len (& examples)) 1)))

(define (doc-macro-import-form
  [type-segment-bases : i64]
  [call-id : i64]
  [alias : ast.AstMaybeImportAlias]) : String
  (match alias
    [(ast.AstMaybeImportAlias.Some name)
      (doc-cat5
        "(import "
        (doc-ast-expr-source type-segment-bases call-id)
        " as "
        (ci.intern-str name)
        ")")]
    [(ast.AstMaybeImportAlias.No)
      (doc-cat3 "(import " (doc-ast-expr-source type-segment-bases call-id) ")")]))

(define (doc-macro-import-examples-from-decl
  [type-segment-bases : i64]
  [decl : ast.AstDecl]
  [examples : (&mut examples doc_macro_import_example_vec.Vec)]) : unit
  (match decl
    [(ast.AstDecl.Import decl-meta (ast.AstImportSpec.Spec kind _ _ alias _))
      (match kind
        [(ast.AstImportKind.Macro call-id _)
          (doc-macro-import-example-push!
            examples
            (doc-import-alias-string alias)
            (doc-macro-import-form type-segment-bases call-id alias))]
        [_ unit])]
    [(ast.AstDecl.Unsafe inner-box)
      (doc-macro-import-examples-from-decl
        type-segment-bases
        (owned_view.compiler-owned-box-shared-view inner-box)
        examples)]
    [(ast.AstDecl.ModuleBody _ body-box)
      (doc-macro-import-examples-from-decls-into
        type-segment-bases
        (owned_view.compiler-owned-box-shared-view body-box)
        examples)]
    [_ unit]))

(define (doc-macro-import-examples-from-decls-into
  [type-segment-bases : i64]
  [decls : ast.AstDeclList]
  [examples : (&mut examples doc_macro_import_example_vec.Vec)]) : unit
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) unit]
    [(ast.AstDeclListStep.Cons decl rest)
      (begin
        (doc-macro-import-examples-from-decl type-segment-bases decl examples)
        (doc-macro-import-examples-from-decls-into
          type-segment-bases
          rest
          examples))]))

(define (doc-macro-import-examples-from-decls
  [type-segment-bases : i64]
  [decls : ast.AstDeclList]) : doc_macro_import_example_vec.Vec
  (let
    [examples : doc_macro_import_example_vec.Vec
      (doc_macro_import_example_vec.new)]
    (begin
      (doc-macro-import-examples-from-decls-into
        type-segment-bases
        decls
        (&mut examples))
      examples)))

(define (doc-generated-target-example-fallback) : DocGeneratedTargetExample
  (DocGeneratedTargetExample "" ""))

(define (doc-generated-target-example-find-from
  [examples : (& examples doc_generated_target_example_vec.Vec)]
  [target : String]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (let
      [example : DocGeneratedTargetExample
        (doc_generated_target_example_vec.get
          examples
          index
          (doc-generated-target-example-fallback))]
      (if (string.eq example.target target)
        example.form
        (doc-generated-target-example-find-from
          examples
          target
          (+ index 1)
          count)))))

(define (doc-generated-target-example-find
  [examples : (& examples doc_generated_target_example_vec.Vec)]
  [target : String]) : String
  (doc-generated-target-example-find-from
    examples
    target
    0
    (doc_generated_target_example_vec.len examples)))

(define (doc-generated-target-example-mut-find-from
  [examples : (&mut examples doc_generated_target_example_vec.Vec)]
  [target : String]
  [index : i64]) : String
  (if (>= index examples.len)
    ""
    (let
      [example : DocGeneratedTargetExample
        (owned_view.compiler-owned-array-element-shared-view
          examples.slots
          index)]
      (if (string.eq example.target target)
        example.form
        (doc-generated-target-example-mut-find-from examples target (+ index 1))))))

(define (doc-generated-target-example-mut-find
  [examples : (&mut examples doc_generated_target_example_vec.Vec)]
  [target : String]) : String
  (doc-generated-target-example-mut-find-from examples target 0))

(define (doc-generated-target-example-add!
  [examples : (&mut examples doc_generated_target_example_vec.Vec)]
  [target : String]
  [form : String]) : unit
  (if (or
    (= (string.string-length target) 0)
    (= (string.string-length form) 0)
    (>
      (string.string-length
        (doc-generated-target-example-mut-find
          examples
          (owned_view.compiler-owned-shared-view target)))
      0))
    unit
    (doc_generated_target_example_vec.push-ref!
      examples
      (DocGeneratedTargetExample target form))))

(define (doc-generated-target-examples-from-decl
  [decl : ast.AstDecl]
  [macro-examples : doc_macro_import_example_vec.Vec]
  [targets : (&mut targets doc_generated_target_example_vec.Vec)]) : unit
  (match decl
    [(ast.AstDecl.Import
        decl-meta
        (ast.AstImportSpec.Spec kind _ expected alias _))
      (match kind
        [(ast.AstImportKind.Module)
          (match expected
            [(ast.AstMaybeModuleName.Some target-module)
              (let
                [form : String
                  (doc-macro-import-example-find
                    macro-examples
                    (doc-import-alias-string alias))]
                (doc-generated-target-example-add!
                  targets
                  (ci.intern-str target-module)
                  form))]
            [(ast.AstMaybeModuleName.No) unit])]
        [_ unit])]
    [(ast.AstDecl.Unsafe inner-box)
      (doc-generated-target-examples-from-decl
        (owned_view.compiler-owned-box-shared-view inner-box)
        macro-examples
        targets)]
    [(ast.AstDecl.ModuleBody _ body-box)
      (doc-generated-target-examples-from-decls-into
        (owned_view.compiler-owned-box-shared-view body-box)
        macro-examples
        targets)]
    [_ unit]))

(define (doc-generated-target-examples-from-decls-into
  [decls : ast.AstDeclList]
  [macro-examples : doc_macro_import_example_vec.Vec]
  [targets : (&mut targets doc_generated_target_example_vec.Vec)]) : unit
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) unit]
    [(ast.AstDeclListStep.Cons decl rest)
      (begin
        (doc-generated-target-examples-from-decl
          decl
          (owned_view.compiler-owned-shared-view macro-examples)
          targets)
        (doc-generated-target-examples-from-decls-into
          rest
          macro-examples
          targets))]))

(define (doc-generated-target-examples-from-decls
  [decls : ast.AstDeclList]
  [macro-examples : doc_macro_import_example_vec.Vec]) : doc_generated_target_example_vec.Vec
  (let
    [targets : doc_generated_target_example_vec.Vec
      (doc_generated_target_example_vec.new)]
    (begin
      (doc-generated-target-examples-from-decls-into
        decls
        macro-examples
        (&mut targets))
      targets)))

(define (doc-ast-maybe-type-source
  [type-segment-bases : i64]
  [maybe-ty : ast.AstMaybeType]) : String
  (match maybe-ty
    [(ast.AstMaybeType.No) ""]
    [(ast.AstMaybeType.Some ty)
      (doc-cat2 " : " (doc-ast-type-source type-segment-bases ty))]))

(define (doc-ast-param-source [type-segment-bases : i64] [param : ast.AstParam]) : String
  (match param
    [(ast.AstParam.Param name ty _)
      (doc-cat5
        "["
        (ci.intern-str name)
        " : "
        (doc-ast-type-source type-segment-bases ty)
        "]")]))

(define (doc-ast-param-list-source-from
  [type-segment-bases : i64]
  [params : ast.AstParamList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      " "
      (doc-ast-param-source
        type-segment-bases
        (ast.ast-param-list-get
          (& params)
          index
          (ast.AstParam.Param 0 (ast.AstType.Unit) false)))
      (doc-ast-param-list-source-from
        type-segment-bases
        params
        (+ index 1)
        count))))

(define (doc-ast-param-list-source
  [type-segment-bases : i64]
  [params : ast.AstParamList]) : String
  (doc-ast-param-list-source-from
    type-segment-bases
    (owned_view.compiler-owned-shared-view params)
    0
    (ast.ast-param-list-len (& params))))

(define (doc-ast-macro-type-kind-items-source-from
  [kinds : (& kinds ast.AstMacroTypeKindList)]
  [index : i64]) : String
  (if (>= index (ast.ast-macro-type-kind-list-len kinds))
    ""
    (doc-cat3
      " "
      (ci.intern-str (ast.ast-macro-type-kind-list-get kinds index 0))
      (doc-ast-macro-type-kind-items-source-from kinds (+ index 1)))))

(define (doc-ast-macro-type-kind-constraint-source
  [kinds : (& kinds ast.AstMacroTypeKindList)]) : String
  (if (ast.ast-macro-type-kind-list-empty? kinds)
    ""
    (doc-cat3 " (:kind" (doc-ast-macro-type-kind-items-source-from kinds 0) ")")))

(define (doc-ast-macro-param-source
  [type-segment-bases : i64]
  [param : ast.AstMacroParam]) : String
  (match param
    [(ast.AstMacroParam.Param name ty _ type-kinds)
      (doc-cat6
        "["
        (ci.intern-str name)
        " : "
        (doc-ast-type-source type-segment-bases ty)
        (doc-ast-macro-type-kind-constraint-source (& type-kinds))
        "]")]))

(define (doc-ast-macro-param-list-source-from
  [type-segment-bases : i64]
  [params : ast.AstMacroParamList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      " "
      (doc-ast-macro-param-source
        type-segment-bases
        (ast.ast-macro-param-list-get
          (& params)
          index
          (ast.ast-macro-param-fallback)))
      (doc-ast-macro-param-list-source-from
        type-segment-bases
        params
        (+ index 1)
        count))))

(define (doc-ast-macro-param-list-source
  [type-segment-bases : i64]
  [params : ast.AstMacroParamList]) : String
  (doc-ast-macro-param-list-source-from
    type-segment-bases
    (owned_view.compiler-owned-shared-view params)
    0
    (ast.ast-macro-param-list-len (& params))))

(define (doc-ast-field-source
  [type-segment-bases : i64]
  [field : ast.AstFieldDef]) : String
  (match field
    [(ast.AstFieldDef.Def name ty _)
      (doc-cat5
        "\n  ("
        (ci.intern-str (ci.intern-syntax-id-value name))
        " "
        (doc-ast-type-source type-segment-bases ty)
        ")")]))

(define (doc-ast-field-list-source-from
  [type-segment-bases : i64]
  [fields : ast.AstFieldDefList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat2
      (doc-ast-field-source
        type-segment-bases
        (ast.ast-field-def-list-get
          (& fields)
          index
          (ast.ast-field-def-fallback)))
      (doc-ast-field-list-source-from
        type-segment-bases
        fields
        (+ index 1)
        count))))

(define (doc-ast-field-list-source
  [type-segment-bases : i64]
  [fields : ast.AstFieldDefList]) : String
  (doc-ast-field-list-source-from
    type-segment-bases
    (owned_view.compiler-owned-shared-view fields)
    0
    (ast.ast-field-def-list-len (& fields))))

(define (doc-ast-variant-payload-source-from
  [type-segment-bases : i64]
  [fields : ast.AstTypeList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      " "
      (doc-ast-type-id-source
        type-segment-bases
        (ast.ast-type-list-get (& fields) index 0))
      (doc-ast-variant-payload-source-from
        type-segment-bases
        fields
        (+ index 1)
        count))))

(define (doc-ast-variant-source
  [type-segment-bases : i64]
  [variant : ast.AstVariantDef]) : String
  (match variant
    [(ast.AstVariantDef.Def name fields _)
      (doc-cat4
        "\n  ("
        (ci.intern-str name)
        (doc-ast-variant-payload-source-from
          type-segment-bases
          (owned_view.compiler-owned-shared-view fields)
          0
          (ast.ast-type-list-len (& fields)))
        ")")]))

(define (doc-ast-variant-list-source-from
  [type-segment-bases : i64]
  [variants : ast.AstVariantDefList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat2
      (doc-ast-variant-source
        type-segment-bases
        (ast.ast-variant-def-list-get
          (& variants)
          index
          (ast.AstVariantDef.Def
            0
            (ast.ast-type-list-new)
            (ast.ast-variant-payload-cleanup-list-new))))
      (doc-ast-variant-list-source-from
        type-segment-bases
        variants
        (+ index 1)
        count))))

(define (doc-ast-variant-list-source
  [type-segment-bases : i64]
  [variants : ast.AstVariantDefList]) : String
  (doc-ast-variant-list-source-from
    type-segment-bases
    (owned_view.compiler-owned-shared-view variants)
    0
    (ast.ast-variant-def-list-len (& variants))))

(define (doc-ast-define-signature
  [type-segment-bases : i64]
  [name : i64]
  [maybe-ty : ast.AstMaybeType]) : String
  (doc-cat4
    "(define "
    (ci.intern-str name)
    (doc-ast-maybe-type-source type-segment-bases maybe-ty)
    " ...)"))

(define (doc-ast-function-signature
  [type-segment-bases : i64]
  [name : i64]
  [params : ast.AstParamList]
  [ret : ast.AstType]) : String
  (doc-cat6
    "(define ("
    (ci.intern-str name)
    (doc-ast-param-list-source type-segment-bases params)
    ") : "
    (doc-ast-type-source type-segment-bases ret)
    " ...)"))

(define (doc-ast-macro-signature
  [type-segment-bases : i64]
  [name : i64]
  [params : ast.AstMacroParamList]
  [ret : ast.AstType]) : String
  (doc-cat6
    "(defmacro ("
    (ci.intern-str name)
    (doc-ast-macro-param-list-source type-segment-bases params)
    ") : "
    (doc-ast-type-source type-segment-bases ret)
    " ...)"))

(define (doc-ast-struct-signature
  [type-segment-bases : i64]
  [name : i64]
  [lifetimes : String]
  [fields : ast.AstFieldDefList]) : String
  (doc-cat5
    "(defstruct "
    (ci.intern-str name)
    lifetimes
    (doc-ast-field-list-source type-segment-bases fields)
    ")"))

(define (doc-ast-enum-signature
  [type-segment-bases : i64]
  [name : i64]
  [lifetimes : String]
  [variants : ast.AstVariantDefList]) : String
  (doc-cat5
    "(defenum "
    (ci.intern-str name)
    lifetimes
    (doc-ast-variant-list-source type-segment-bases variants)
    ")"))

(define (doc-ast-extern-signature
  [type-segment-bases : i64]
  [name : i64]
  [ty : ast.AstType]) : String
  (doc-cat5
    "(extern "
    (ci.intern-str name)
    " : "
    (doc-ast-type-source type-segment-bases ty)
    ")"))

(define (doc-ast-decl-item [type-segment-bases : i64] [decl : ast.AstDecl]) : DocMaybeItem
  (match decl
    [(ast.AstDecl.Def decl-meta name maybe-ty _)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.Define)
          (ci.intern-str name)
          ""
          (doc-ast-define-signature type-segment-bases name maybe-ty)))]
    [(ast.AstDecl.DefFn decl-meta name params ret _ _)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.Function)
          (ci.intern-str name)
          ""
          (doc-ast-function-signature type-segment-bases name params ret)))]
    [(ast.AstDecl.DefMacro decl-meta name params ret _)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefMacro)
          (ci.intern-str name)
          ""
          (doc-ast-macro-signature type-segment-bases name params ret)))]
    [(ast.AstDecl.Extern decl-meta name _ _ ty)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.Extern)
          (ci.intern-str name)
          ""
          (doc-ast-extern-signature type-segment-bases name ty)))]
    [(ast.AstDecl.DefEnum decl-meta name _ variants)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefEnum)
          (ci.intern-str name)
          ""
          (doc-ast-enum-signature type-segment-bases name "" variants)))]
    [(ast.AstDecl.DefEnumLifetimes decl-meta name lifetimes _ variants)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefEnum)
          (ci.intern-str name)
          ""
          (doc-ast-enum-signature
            type-segment-bases
            name
            (doc-ast-lifetime-list-source lifetimes)
            variants)))]
    [(ast.AstDecl.DefStruct decl-meta name _ _ fields)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefStruct)
          (ci.intern-str name)
          ""
          (doc-ast-struct-signature type-segment-bases name "" fields)))]
    [(ast.AstDecl.DefStructLifetimes decl-meta name lifetimes _ _ fields)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefStruct)
          (ci.intern-str name)
          ""
          (doc-ast-struct-signature
            type-segment-bases
            name
            (doc-ast-lifetime-list-source lifetimes)
            fields)))]
    [(ast.AstDecl.Unsafe inner-box)
      (doc-ast-decl-item
        type-segment-bases
        (owned_view.compiler-owned-box-shared-view inner-box))]
    [_ (DocMaybeItem.No)]))

(define (doc-ast-generated-decl-item
  [type-segment-bases : i64]
  [decl : ast.AstDecl]) : DocMaybeItem
  (match (ast.ast-decl-generated-meta
    (owned_view.compiler-owned-shared-view decl))
    [(ast.AstGeneratedDeclMeta.Some _ _ _ _)
      (doc-ast-decl-item type-segment-bases decl)]
    [(ast.AstGeneratedDeclMeta.No) (DocMaybeItem.No)]))

(define (doc-generated-import-item [form : String]) : doc_extract.DocItem
  (doc_extract.DocItem.Item
    (doc_extract.DocItemKind.GeneratedImport)
    "import"
    "Concrete generated-module import that produced this API."
    form))

(define (doc-generated-copy-items
  [out : (&mut out doc_item_vec.Vec)]
  [items : doc_item_vec.Vec]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (doc_item_vec.push-ref!
        out
        (doc_extract.doc-item-list-ref
          (owned_view.compiler-owned-shared-view items)
          index))
      (doc-generated-copy-items out items (+ index 1) count))))

(define (doc-generated-module-items [form : String] [items : doc_item_vec.Vec]) : doc_item_vec.Vec
  (let
    [count : i64
      (doc_extract.doc-item-list-count
        (owned_view.compiler-owned-shared-view items))]
    [out : doc_item_vec.Vec (doc_item_vec.with-capacity (+ count 1))]
    (begin
      (doc_item_vec.push-ref! (&mut out) (doc-generated-import-item form))
      (doc-generated-copy-items (&mut out) items 0 count)
      out)))

(define (doc-generated-flush-module!
  [module-name : String]
  [items : doc_item_vec.Vec]
  [has-generated : bool]
  [targets : doc_generated_target_example_vec.Vec]
  [modules : (&mut modules doc_module_vec.Vec)]) : unit
  (let
    [form : String
      (doc-generated-target-example-find
        (& targets)
        (owned_view.compiler-owned-shared-view module-name))]
    (if (and
      has-generated
      (> (string.string-length module-name) 0)
      (> (string.string-length form) 0))
      (doc_module_vec.push-ref!
        modules
        (doc_render.DocModule.Module
          module-name
          (doc_extract.DocExtraction.Extraction
            "Generated module API."
            (doc-generated-module-items form items))))
      unit)))

(define (doc-generated-modules-from-expanded-decls
  [type-segment-bases : i64]
  [decls : ast.AstDeclList]
  [targets : doc_generated_target_example_vec.Vec]) : doc_module_vec.Vec
  (let
    [cursor : ast.AstDeclList decls]
    [current-module : String ""]
    [items : doc_item_vec.Vec (doc_item_vec.new)]
    [has-generated : bool false]
    [modules : doc_module_vec.Vec (doc_module_vec.new)]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast.ast-decl-list-step
          (owned_view.compiler-owned-shared-view cursor))
          [(ast.AstDeclListStep.Nil)
            (begin
              (doc-generated-flush-module!
                (owned_view.compiler-owned-shared-view current-module)
                (owned_view.compiler-owned-shared-view items)
                has-generated
                (owned_view.compiler-owned-shared-view targets)
                (&mut modules))
              (set! done true))]
          [(ast.AstDeclListStep.Cons decl rest)
            (begin
              (match (owned_view.compiler-owned-shared-view decl)
                [(ast.AstDecl.Module next-module)
                  (begin
                    (doc-generated-flush-module!
                      (owned_view.compiler-owned-shared-view current-module)
                      (owned_view.compiler-owned-shared-view items)
                      has-generated
                      (owned_view.compiler-owned-shared-view targets)
                      (&mut modules))
                    (set!
                      current-module
                      (ci.intern-syntax-name-text-or
                        next-module
                        "<structural-module>"))
                    (set! items (doc_item_vec.new))
                    (set! has-generated false))]
                [_
                  (match (doc-ast-generated-decl-item type-segment-bases decl)
                    [(DocMaybeItem.Some item)
                      (begin
                        (doc_item_vec.push-ref! (&mut items) item)
                        (set! has-generated true))]
                    [(DocMaybeItem.No) unit])])
              (set! cursor rest))]))
      modules)))

(define (doc-expanded-generated-modules-from-loaded-decls
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : doc_svec.Vec]) : ResultDocExpandedModules
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [type-segment-bases : i64
      (ast.ast-node-pool-context-type-segment-bases pools)]
    [macro-examples : doc_macro_import_example_vec.Vec
      (doc-macro-import-examples-from-decls
        type-segment-bases
        (owned_view.compiler-owned-shared-view decls))]
    (match (compiler_typecheck_api.typecheck-compiler-doc-expand-program-with-paths-and-pools
      (ast.ast-program decls)
      paths
      stdlib-roots
      pools)
      [(compiler_typecheck_api.ResultCompilerDocExpand.Ok expanded _)
        (match expanded
          [(ast.AstProgram.Program expanded-box)
            (let
              [expanded-decls : ast.AstDeclList
                (ast.ast-decl-list-box-shared-view expanded-box)]
              [targets : doc_generated_target_example_vec.Vec
                (doc-generated-target-examples-from-decls
                  (owned_view.compiler-owned-shared-view expanded-decls)
                  macro-examples)]
              (ResultDocExpandedModules.Ok
                (doc-generated-modules-from-expanded-decls
                  type-segment-bases
                  expanded-decls
                  targets)))])]
      [(compiler_typecheck_api.ResultCompilerDocExpand.Err diag)
        (ResultDocExpandedModules.Err
          (cdiag.compiler-diagnostic-render
            (cdiag.compiler-diagnostic-box-shared-view diag)))])))

(define (doc-expand-find-prefix [text : String] [prefix : String] [from : i64]) : i64
  (let
    [i : i64 from]
    [n : i64 (string.string-length text)]
    [found : i64 n]
    (begin
      (while (and (< i n) (= found n))
        (begin
          (if (doc_extract.doc-string-prefix-at?
            (owned_view.compiler-owned-shared-view text)
            (owned_view.compiler-owned-shared-view prefix)
            i)
            (set! found i)
            unit)
          (set! i (+ i 1))))
      found)))

(define (doc-expand-fence-line-start
  [text : String]
  [line-start : i64]
  [line-end : i64]) : i64
  (let
    [first : i64
      (doc_extract.doc-first-nonspace
        (owned_view.compiler-owned-shared-view text)
        line-start
        line-end)]
    (if (doc_extract.doc-string-prefix-at? text "```" first)
      first
      line-end)))

(define (doc-expand-ignored-fence-line?
  [text : String]
  [line-start : i64]
  [line-end : i64]) : bool
  (let
    [fence : i64
      (doc-expand-fence-line-start
        (owned_view.compiler-owned-shared-view text)
        line-start
        line-end)]
    (if (< fence line-end)
      (doc_extract.doc-string-contains?
        (string.substring text fence (- line-end fence))
        "test=ignore")
      false)))

(define (doc-expand-next-ignored-fence [text : String] [cursor : i64] [n : i64]) : i64
  (let
    [pos : i64 cursor]
    [found : i64 n]
    (begin
      (while (and (< pos n) (= found n))
        (let
          [line-end : i64
            (doc_extract.doc-line-end
              (owned_view.compiler-owned-shared-view text)
              pos
              n)]
          (begin
            (if (doc-expand-ignored-fence-line?
              (owned_view.compiler-owned-shared-view text)
              pos
              line-end)
              (set! found pos)
              unit)
            (set!
              pos
              (doc_extract.doc-next-line-start
                (owned_view.compiler-owned-shared-view text)
                line-end
                n)))))
      found)))

(define (doc-expand-skip-fence [text : String] [cursor : i64] [n : i64]) : i64
  (let
    [open-end : i64
      (doc_extract.doc-line-end
        (owned_view.compiler-owned-shared-view text)
        cursor
        n)]
    [pos : i64
      (doc_extract.doc-next-line-start
        (owned_view.compiler-owned-shared-view text)
        open-end
        n)]
    [done : bool false]
    (begin
      (while (and (< pos n) (not done))
        (let
          [line-end : i64
            (doc_extract.doc-line-end
              (owned_view.compiler-owned-shared-view text)
              pos
              n)]
          (if (<
            (doc-expand-fence-line-start
              (owned_view.compiler-owned-shared-view text)
              pos
              line-end)
            line-end)
            (begin
              (set!
                pos
                (doc_extract.doc-next-line-start
                  (owned_view.compiler-owned-shared-view text)
                  line-end
                  n))
              (set! done true))
            (set!
              pos
              (doc_extract.doc-next-line-start
                (owned_view.compiler-owned-shared-view text)
                line-end
                n)))))
      pos)))

(define (doc-import-forms-from-doc-text [doc-text : String]) : DocImportFormScan
  (let
    [cursor : i64 0]
    [n : i64 (string.string-length doc-text)]
    [forms : doc_import_form_vec.Vec (doc_import_form_vec.new)]
    [has-macro : bool false]
    (begin
      (while (< cursor n)
        (let
          [ignored-fence : i64
            (doc-expand-next-ignored-fence
              (owned_view.compiler-owned-shared-view doc-text)
              cursor
              n)]
          [start : i64
            (doc-expand-find-prefix
              (owned_view.compiler-owned-shared-view doc-text)
              "(import "
              cursor)]
          (if (< ignored-fence start)
            (set!
              cursor
              (doc-expand-skip-fence
                (owned_view.compiler-owned-shared-view doc-text)
                ignored-fence
                n))
            (if (< start n)
              (let
                [end : i64
                  (doc_extract.doc-scan-form-end
                    (owned_view.compiler-owned-shared-view doc-text)
                    start
                    n)]
                [form : String (string.substring doc-text start (- end start))]
                (begin
                  (doc-import-form-list-push-unique! (&mut forms) form)
                  (if (doc_extract.doc-string-prefix-at?
                    (owned_view.compiler-owned-shared-view doc-text)
                    "(import ("
                    start)
                    (set! has-macro true)
                    unit)
                  (set! cursor end)))
              (set! cursor n)))))
      (DocImportFormScan forms has-macro))))

(define (doc-expanded-example-source [forms : doc_import_form_vec.Vec]) : String
  (doc-cat2
    "(module typelisp.docs.generated_examples)\n"
    (doc-import-form-list-source forms)))

(define (doc-expanded-generated-modules-from-source-docs
  [source-path : String]
  [docs : doc_extract.DocExtraction]
  [stdlib-roots : doc_svec.Vec]) : ResultDocExpandedModules
  (match docs
    [(doc_extract.DocExtraction.Extraction module-doc _)
      (let
        [scan : DocImportFormScan (doc-import-forms-from-doc-text module-doc)]
        (if (not scan.has-macro)
          (ResultDocExpandedModules.Ok (doc_module_vec.new))
          (match (compiler_load.compiler-load-source-with-paths-and-roots
            (doc-cat2 source-path ".doc-examples.tl")
            (doc-expanded-example-source scan.forms)
            (sym_i64_env.sym-i64-empty)
            (owned_view.compiler-owned-shared-view stdlib-roots))
            [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
              (doc-expanded-generated-modules-from-loaded-decls
                decls
                paths
                (owned_view.compiler-owned-shared-view stdlib-roots))]
            [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
              (ResultDocExpandedModules.Err
                (cdiag.compiler-diagnostic-render
                  (cdiag.compiler-diagnostic-box-shared-view diag)))])))]))

(define (doc-expand-smoke-source) : String
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

(import (boxmod i64) as ibox)")

(define (doc-expand-macro-type-kind-constraint-source-smoke?
  [type-segment-bases : i64]) : bool
  (match (parser.parse-ast-source
    "(defmacro (catalog [T : type (:kind i64 struct)]) : Module unit)")
    [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (match (ast.ast-decl-list-step
        (owned_view.compiler-owned-box-shared-view decls-box))
        [(ast.AstDeclListStep.Cons
            (ast.AstDecl.DefMacro decl-meta _ params _ _)
            rest)
          (and
            (match (ast.ast-decl-list-step rest)
              [(ast.AstDeclListStep.Nil) true]
              [_ false])
            (= (ast.ast-macro-param-list-len (& params)) 1)
            (string.eq
              (doc-ast-macro-param-source
                type-segment-bases
                (ast.ast-macro-param-list-get
                  (& params)
                  0
                  (ast.ast-macro-param-fallback)))
              "[T : type (:kind i64 struct)]"))]
        [_ false])]
    [(parser.ResultAstProgram.Err _) false]))

(test
  doc-macro-type-kind-constraint-source
  (unless
    (doc-expand-macro-type-kind-constraint-source-smoke?
      (ast.ast-node-pool-reader-type-segment-bases))
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
              ""))
          (doc_import_form_vec.push-ref!
            (&mut forms)
            (string.int->string index))
          (doc_macro_import_example_vec.push-ref!
            (&mut macro-examples)
            (DocMacroImportExample (string.int->string index) ""))
          (doc_generated_target_example_vec.push-ref!
            (&mut targets)
            (DocGeneratedTargetExample (string.int->string index) ""))
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
                (doc-macro-import-example-fallback))
              alias)
            "5")
          (string.eq
            (__tl-project-field
              (doc_generated_target_example_vec.get
                (& targets)
                5
                (doc-generated-target-example-fallback))
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

(define (doc-expand-smoke) : i64
  (let
    [roots : doc_svec.Vec (doc_svec.new)]
    (match (compiler_load.compiler-load-source-with-paths-and-roots
      "doc_expand_smoke.tl"
      (doc-expand-smoke-source)
      (sym_i64_env.sym-i64-empty)
      (owned_view.compiler-owned-shared-view roots))
      [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
        (match (doc-expanded-generated-modules-from-loaded-decls
          decls
          paths
          (owned_view.compiler-owned-shared-view roots))
          [(ResultDocExpandedModules.Ok modules)
            (let
              [rendered : String
                (doc_render.doc-render-module-graph-markdown modules)]
              (if (and
                (doc_extract.doc-string-contains?
                  (owned_view.compiler-owned-shared-view rendered)
                  "doc.generated.fixture.box\\_i64")
                (doc_extract.doc-string-contains?
                  (owned_view.compiler-owned-shared-view rendered)
                  "(import (boxmod i64) as ibox)")
                (doc_extract.doc-string-contains?
                  (owned_view.compiler-owned-shared-view rendered)
                  "### Box")
                (doc_extract.doc-string-contains?
                  (owned_view.compiler-owned-shared-view rendered)
                  "### Status")
                (doc_extract.doc-string-contains?
                  (owned_view.compiler-owned-shared-view rendered)
                  "### new"))
                42
                (io.panic "doc-expand: generated module docs smoke mismatch")))]
          [(ResultDocExpandedModules.Err message)
            (io.panic (doc-cat2 "doc-expand: expansion failed: " message))])]
      [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
        (io.panic
          (doc-cat2
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
    [ignored-scan : DocImportFormScan (doc-import-forms-from-doc-text ignored)]
    [active-scan : DocImportFormScan (doc-import-forms-from-doc-text active)]
    (if (and (not ignored-scan.has-macro) active-scan.has-macro)
      42
      (io.panic "doc-expand: ignored fence import scan mismatch"))))