;; doc_expand.tl - Expansion-aware generated-module docs.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import sym_i64_env)
(import (vector.vector String) as doc_svec)
(import doc_render)
(import doc_extract)
(import (vector.vector doc_render.DocModule core) as doc_module_vec)
(import (vector.vector doc_extract.DocItem core) as doc_item_vec)
(import "compiler_load.tl")
(import "compiler_typecheck_api.tl")

(define (doc-cat2 [a : String] [b : String]) : String
  (string.concat3 a b ""))

(define (doc-cat3 [a : String] [b : String] [c : String]) : String
  (string.concat3 a b c))

(define (doc-cat4 [a : String] [b : String] [c : String] [d : String]) : String
  (string.concat3 a b (string.concat3 c d "")))

(define (doc-cat5
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]) : String
  (string.concat3 a b (string.concat3 c d e)))

(define (doc-cat6
  [a : String]
  [b : String]
  [c : String]
  [d : String]
  [e : String]
  [f : String]) : String
  (string.concat3 a b (string.concat3 c d (string.concat3 e f ""))))

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

(define (doc-import-form-list-contains-from?
  [forms : (& forms doc_import_form_vec.Vec)]
  [form : String]
  [index : i64]
  [count : i64]) : bool
  (if (>= index count)
    false
    (if (string.eq (doc_import_form_vec.get forms index "") form)
      true
      (doc-import-form-list-contains-from? forms form (+ index 1) count))))

(define (doc-import-form-list-contains?
  [forms : (& forms doc_import_form_vec.Vec)]
  [form : String]) : bool
  (doc-import-form-list-contains-from?
    forms
    form
    0
    (doc_import_form_vec.len forms)))

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
  (if (doc-import-form-list-mut-contains? forms form)
    unit
    (doc_import_form_vec.push forms form)))

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
  (doc-import-form-list-source-from forms 0 (doc_import_form_vec.len (& forms))))

(define (doc-import-alias-string [alias : AstMaybeImportAlias]) : String
  (match alias
    [(AstMaybeImportAlias.Some name) (intern-str name)]
    [(AstMaybeImportAlias.No) ""]))

(define (doc-symbol-text [name-id : i64]) : String
  (tc-hygiene-name-text-id name-id))

(define (doc-ast-type-id-source [type-segment-bases : i64] [ty-id : i64]) : String
  (doc-ast-type-source
    type-segment-bases
    (ast-type-segment-bases-get type-segment-bases ty-id)))

(define (doc-ast-type-list-source-from
  [type-segment-bases : i64]
  [types : AstTypeList]
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
        (ast-type-list-get (& types) index 0))
      (doc-ast-type-list-source-from type-segment-bases types (+ index 1) count))))

(define (doc-ast-type-list-source
  [type-segment-bases : i64]
  [types : AstTypeList]) : String
  (doc-ast-type-list-source-from
    type-segment-bases
    types
    0
    (ast-type-list-len (& types))))

(define (doc-ast-lifetime-list-source-from
  [lifetimes : AstLifetimeList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      (if (= index 0)
        ""
        " ")
      (doc-symbol-text
        (ast-lifetime-list-get (& lifetimes) index (ast-lifetime-fallback)))
      (doc-ast-lifetime-list-source-from lifetimes (+ index 1) count))))

(define (doc-ast-lifetime-list-source [lifetimes : AstLifetimeList]) : String
  (let
    [count : i64 (ast-lifetime-list-len (& lifetimes))]
    (if (= count 0)
      ""
      (doc-cat3
        " (:lifetimes "
        (doc-ast-lifetime-list-source-from lifetimes 0 count)
        ")"))))

(define (doc-ast-type-source [type-segment-bases : i64] [ty : AstType]) : String
  (match ty
    [(AstType.I64) "i64"]
    [(AstType.I32) "i32"]
    [(AstType.I16) "i16"]
    [(AstType.I8) "i8"]
    [(AstType.U64) "u64"]
    [(AstType.U32) "u32"]
    [(AstType.U16) "u16"]
    [(AstType.U8) "u8"]
    [(AstType.F64) "f64"]
    [(AstType.F32) "f32"]
    [(AstType.Bool) "bool"]
    [(AstType.Char) "char"]
    [(AstType.String) "String"]
    [(AstType.Str) "str"]
    [(AstType.Bytes) "bytes"]
    [(AstType.Unit) "unit"]
    [(AstType.Never) "never"]
    [(AstType.Expr) "Expr"]
    [(AstType.ExprList) "ExprList"]
    [(AstType.Func args-box ret)
      (doc-cat5
        "(-> "
        (doc-ast-type-list-source type-segment-bases (box-get args-box))
        " "
        (doc-ast-type-id-source type-segment-bases ret)
        ")")]
    [(AstType.Tuple elems-box)
      (doc-cat3
        "(Tuple "
        (doc-ast-type-list-source type-segment-bases (box-get elems-box))
        ")")]
    [(AstType.Array elem size)
      (doc-cat5
        "(Array "
        (doc-ast-type-id-source type-segment-bases elem)
        " "
        (string.int->string size)
        ")")]
    [(AstType.DynArray elem)
      (doc-cat3 "(Array " (doc-ast-type-id-source type-segment-bases elem) ")")]
    [(AstType.Box elem)
      (doc-cat3 "(Box " (doc-ast-type-id-source type-segment-bases elem) ")")]
    [(AstType.Region region elem)
      (doc-cat5
        "(Region "
        (doc-symbol-text region)
        " "
        (doc-ast-type-id-source type-segment-bases elem)
        ")")]
    [(AstType.Ref lifetime elem)
      (doc-cat5
        "(& "
        (doc-symbol-text lifetime)
        " "
        (doc-ast-type-id-source type-segment-bases elem)
        ")")]
    [(AstType.MutRef lifetime elem)
      (doc-cat5
        "(&mut "
        (doc-symbol-text lifetime)
        " "
        (doc-ast-type-id-source type-segment-bases elem)
        ")")]
    [(AstType.Enum name) (doc-symbol-text name)]
    [(AstType.EnumArgs name _) (doc-symbol-text name)]
    [(AstType.Struct name) (doc-symbol-text name)]
    [(AstType.StructArgs name _) (doc-symbol-text name)]
    [(AstType.Var name) (doc-symbol-text name)]
    [(AstType.VarArgs name _) (doc-symbol-text name)]
    [(AstType.Ptr elem)
      (doc-cat3 "(Ptr " (doc-ast-type-id-source type-segment-bases elem) ")")]
    [(AstType.MutPtr elem)
      (doc-cat3 "(MutPtr " (doc-ast-type-id-source type-segment-bases elem) ")")]
    [(AstType.Consume inner)
      (doc-cat3
        "(:consume "
        (doc-ast-type-id-source type-segment-bases inner)
        ")")]))

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
  (doc-expand-escape-string-loop text 0 (string.string-length text) ""))

(define (doc-ast-literal-source [lit : AstLiteral]) : String
  (match lit
    [(AstLiteral.Int _ _) (ast-lit-int-text lit)]
    [(AstLiteral.Float text) text]
    [(AstLiteral.Bool value)
      (if value
        "true"
        "false")]
    [(AstLiteral.Char _) "'?'"]
    [(AstLiteral.String string-id)
      (doc-cat3 "\"" (doc-expand-escape-string (intern-str string-id)) "\"")]
    [(AstLiteral.Unit) "unit"]))

(define (doc-ast-expr-list-source-from
  [type-segment-bases : i64]
  [exprs : AstExprList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      " "
      (doc-ast-expr-source
        type-segment-bases
        (ast-expr-list-get (& exprs) index 0))
      (doc-ast-expr-list-source-from type-segment-bases exprs (+ index 1) count))))

(define (doc-ast-expr-list-source
  [type-segment-bases : i64]
  [exprs : AstExprList]) : String
  (doc-ast-expr-list-source-from
    type-segment-bases
    exprs
    0
    (ast-expr-list-len (& exprs))))

(define (doc-ast-expr-source [type-segment-bases : i64] [expr-id : i64]) : String
  (match (ast-expr-unspan (ast-node-get expr-id))
    [(AstExpr.Literal lit) (doc-ast-literal-source lit)]
    [(AstExpr.Var name) (intern-str name)]
    [(AstExpr.Call callee args)
      (doc-cat4
        "("
        (doc-ast-expr-source type-segment-bases callee)
        (doc-ast-expr-list-source type-segment-bases args)
        ")")]
    [(AstExpr.TypeLiteral ty)
      (doc-cat3 "(type " (doc-ast-type-source type-segment-bases ty) ")")]
    [(AstExpr.Ann inner _) (doc-ast-expr-source type-segment-bases inner)]
    [(AstExpr.Spanned inner _) (doc-ast-expr-source type-segment-bases inner)]
    [_ "..."]))

(define (doc-macro-import-example-fallback) : DocMacroImportExample
  (DocMacroImportExample "" ""))

(define (doc-macro-import-example-push!
  [examples : (&mut examples doc_macro_import_example_vec.Vec)]
  [alias : String]
  [form : String]) : unit
  (doc_macro_import_example_vec.push
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
      (if (string.eq (struct-get example alias) alias)
        (struct-get example form)
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
  [alias : AstMaybeImportAlias]) : String
  (match alias
    [(AstMaybeImportAlias.Some name)
      (doc-cat5
        "(import "
        (doc-ast-expr-source type-segment-bases call-id)
        " as "
        (intern-str name)
        ")")]
    [(AstMaybeImportAlias.No)
      (doc-cat3 "(import " (doc-ast-expr-source type-segment-bases call-id) ")")]))

(define (doc-macro-import-examples-from-decl
  [type-segment-bases : i64]
  [decl : AstDecl]
  [examples : (&mut examples doc_macro_import_example_vec.Vec)]) : unit
  (match decl
    [(AstDecl.Import decl-meta (AstImportSpec.Spec kind _ _ alias _))
      (match kind
        [(AstImportKind.Macro call-id _)
          (doc-macro-import-example-push!
            examples
            (doc-import-alias-string alias)
            (doc-macro-import-form type-segment-bases call-id alias))]
        [_ unit])]
    [(AstDecl.Unsafe inner-box)
      (doc-macro-import-examples-from-decl
        type-segment-bases
        (box-get inner-box)
        examples)]
    [(AstDecl.ModuleBody _ body-box)
      (doc-macro-import-examples-from-decls-into
        type-segment-bases
        (box-get body-box)
        examples)]
    [_ unit]))

(define (doc-macro-import-examples-from-decls-into
  [type-segment-bases : i64]
  [decls : AstDeclList]
  [examples : (&mut examples doc_macro_import_example_vec.Vec)]) : unit
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) unit]
    [(AstDeclListStep.Cons decl rest)
      (begin
        (doc-macro-import-examples-from-decl type-segment-bases decl examples)
        (doc-macro-import-examples-from-decls-into
          type-segment-bases
          rest
          examples))]))

(define (doc-macro-import-examples-from-decls
  [type-segment-bases : i64]
  [decls : AstDeclList]) : doc_macro_import_example_vec.Vec
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
      (if (string.eq (struct-get example target) target)
        (struct-get example form)
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
  (if (>= index (struct-get examples len))
    ""
    (let
      [example : DocGeneratedTargetExample
        (array-ref (struct-get examples slots) index)]
      (if (string.eq (struct-get example target) target)
        (struct-get example form)
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
        (doc-generated-target-example-mut-find examples target))
      0))
    unit
    (doc_generated_target_example_vec.push
      examples
      (DocGeneratedTargetExample target form))))

(define (doc-generated-target-examples-from-decl
  [decl : AstDecl]
  [macro-examples : doc_macro_import_example_vec.Vec]
  [targets : (&mut targets doc_generated_target_example_vec.Vec)]) : unit
  (match decl
    [(AstDecl.Import decl-meta (AstImportSpec.Spec kind _ expected alias _))
      (match kind
        [(AstImportKind.Module)
          (match expected
            [(AstMaybeModuleName.Some target-module)
              (let
                [form : String
                  (doc-macro-import-example-find
                    macro-examples
                    (doc-import-alias-string alias))]
                (doc-generated-target-example-add!
                  targets
                  (intern-str target-module)
                  form))]
            [(AstMaybeModuleName.No) unit])]
        [_ unit])]
    [(AstDecl.Unsafe inner-box)
      (doc-generated-target-examples-from-decl
        (box-get inner-box)
        macro-examples
        targets)]
    [(AstDecl.ModuleBody _ body-box)
      (doc-generated-target-examples-from-decls-into
        (box-get body-box)
        macro-examples
        targets)]
    [_ unit]))

(define (doc-generated-target-examples-from-decls-into
  [decls : AstDeclList]
  [macro-examples : doc_macro_import_example_vec.Vec]
  [targets : (&mut targets doc_generated_target_example_vec.Vec)]) : unit
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) unit]
    [(AstDeclListStep.Cons decl rest)
      (begin
        (doc-generated-target-examples-from-decl decl macro-examples targets)
        (doc-generated-target-examples-from-decls-into
          rest
          macro-examples
          targets))]))

(define (doc-generated-target-examples-from-decls
  [decls : AstDeclList]
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
  [maybe-ty : AstMaybeType]) : String
  (match maybe-ty
    [(AstMaybeType.No) ""]
    [(AstMaybeType.Some ty)
      (doc-cat2 " : " (doc-ast-type-source type-segment-bases ty))]))

(define (doc-ast-param-source [type-segment-bases : i64] [param : AstParam]) : String
  (match param
    [(AstParam.Param name ty _ consume?)
      (if consume?
        (doc-cat6
          "["
          (intern-str name)
          " : "
          (doc-ast-type-source type-segment-bases ty)
          " (:consume)"
          "]")
        (doc-cat5
          "["
          (intern-str name)
          " : "
          (doc-ast-type-source type-segment-bases ty)
          "]"))]))

(define (doc-ast-param-list-source-from
  [type-segment-bases : i64]
  [params : AstParamList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      " "
      (doc-ast-param-source
        type-segment-bases
        (ast-param-list-get
          (& params)
          index
          (AstParam.Param 0 (AstType.Unit) false false)))
      (doc-ast-param-list-source-from
        type-segment-bases
        params
        (+ index 1)
        count))))

(define (doc-ast-param-list-source
  [type-segment-bases : i64]
  [params : AstParamList]) : String
  (doc-ast-param-list-source-from
    type-segment-bases
    params
    0
    (ast-param-list-len (& params))))

(define (doc-ast-macro-type-kind-items-source [kinds : AstMacroTypeKindList]) : String
  (match kinds
    [(AstMacroTypeKindList.Nil) ""]
    [(AstMacroTypeKindList.Cons kind rest)
      (doc-cat3
        " "
        (intern-str kind)
        (doc-ast-macro-type-kind-items-source (box-get rest)))]))

(define (doc-ast-macro-type-kind-constraint-source
  [kinds : AstMacroTypeKindList]) : String
  (match kinds
    [(AstMacroTypeKindList.Nil) ""]
    [_ (doc-cat3 " (:kind" (doc-ast-macro-type-kind-items-source kinds) ")")]))

(define (doc-ast-macro-param-source
  [type-segment-bases : i64]
  [param : AstMacroParam]) : String
  (match param
    [(AstMacroParam.Param name ty _ type-kinds)
      (doc-cat6
        "["
        (intern-str name)
        " : "
        (doc-ast-type-source type-segment-bases ty)
        (doc-ast-macro-type-kind-constraint-source type-kinds)
        "]")]))

(define (doc-ast-macro-param-list-source-from
  [type-segment-bases : i64]
  [params : AstMacroParamList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      " "
      (doc-ast-macro-param-source
        type-segment-bases
        (ast-macro-param-list-get (& params) index (ast-macro-param-fallback)))
      (doc-ast-macro-param-list-source-from
        type-segment-bases
        params
        (+ index 1)
        count))))

(define (doc-ast-macro-param-list-source
  [type-segment-bases : i64]
  [params : AstMacroParamList]) : String
  (doc-ast-macro-param-list-source-from
    type-segment-bases
    params
    0
    (ast-macro-param-list-len (& params))))

(define (doc-ast-field-source [type-segment-bases : i64] [field : AstFieldDef]) : String
  (match field
    [(AstFieldDef.Def name ty _)
      (doc-cat5
        "\n  ("
        (intern-str name)
        " "
        (doc-ast-type-source type-segment-bases ty)
        ")")]))

(define (doc-ast-field-list-source-from
  [type-segment-bases : i64]
  [fields : AstFieldDefList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat2
      (doc-ast-field-source
        type-segment-bases
        (ast-field-def-list-get
          (& fields)
          index
          (AstFieldDef.Def 0 (AstType.Unit) AstFieldCleanup.No)))
      (doc-ast-field-list-source-from
        type-segment-bases
        fields
        (+ index 1)
        count))))

(define (doc-ast-field-list-source
  [type-segment-bases : i64]
  [fields : AstFieldDefList]) : String
  (doc-ast-field-list-source-from
    type-segment-bases
    fields
    0
    (ast-field-def-list-len (& fields))))

(define (doc-ast-variant-payload-source-from
  [type-segment-bases : i64]
  [fields : AstTypeList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      " "
      (doc-ast-type-id-source
        type-segment-bases
        (ast-type-list-get (& fields) index 0))
      (doc-ast-variant-payload-source-from
        type-segment-bases
        fields
        (+ index 1)
        count))))

(define (doc-ast-variant-source
  [type-segment-bases : i64]
  [variant : AstVariantDef]) : String
  (match variant
    [(AstVariantDef.Def name fields _)
      (doc-cat4
        "\n  ("
        (intern-str name)
        (doc-ast-variant-payload-source-from
          type-segment-bases
          fields
          0
          (ast-type-list-len (& fields)))
        ")")]))

(define (doc-ast-variant-list-source-from
  [type-segment-bases : i64]
  [variants : AstVariantDefList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat2
      (doc-ast-variant-source
        type-segment-bases
        (ast-variant-def-list-get
          (& variants)
          index
          (AstVariantDef.Def
            0
            (ast-type-list-new)
            (ast-variant-payload-cleanup-list-new))))
      (doc-ast-variant-list-source-from
        type-segment-bases
        variants
        (+ index 1)
        count))))

(define (doc-ast-variant-list-source
  [type-segment-bases : i64]
  [variants : AstVariantDefList]) : String
  (doc-ast-variant-list-source-from
    type-segment-bases
    variants
    0
    (ast-variant-def-list-len (& variants))))

(define (doc-ast-define-signature
  [type-segment-bases : i64]
  [name : i64]
  [maybe-ty : AstMaybeType]) : String
  (doc-cat4
    "(define "
    (intern-str name)
    (doc-ast-maybe-type-source type-segment-bases maybe-ty)
    " ...)"))

(define (doc-ast-function-signature
  [type-segment-bases : i64]
  [name : i64]
  [params : AstParamList]
  [ret : AstType]) : String
  (doc-cat6
    "(define ("
    (intern-str name)
    (doc-ast-param-list-source type-segment-bases params)
    ") : "
    (doc-ast-type-source type-segment-bases ret)
    " ...)"))

(define (doc-ast-macro-signature
  [type-segment-bases : i64]
  [name : i64]
  [params : AstMacroParamList]
  [ret : AstType]) : String
  (doc-cat6
    "(defmacro ("
    (intern-str name)
    (doc-ast-macro-param-list-source type-segment-bases params)
    ") : "
    (doc-ast-type-source type-segment-bases ret)
    " ...)"))

(define (doc-ast-struct-signature
  [type-segment-bases : i64]
  [name : i64]
  [lifetimes : String]
  [fields : AstFieldDefList]) : String
  (doc-cat5
    "(defstruct "
    (intern-str name)
    lifetimes
    (doc-ast-field-list-source type-segment-bases fields)
    ")"))

(define (doc-ast-enum-signature
  [type-segment-bases : i64]
  [name : i64]
  [lifetimes : String]
  [variants : AstVariantDefList]) : String
  (doc-cat5
    "(defenum "
    (intern-str name)
    lifetimes
    (doc-ast-variant-list-source type-segment-bases variants)
    ")"))

(define (doc-ast-extern-signature
  [type-segment-bases : i64]
  [name : i64]
  [ty : AstType]) : String
  (doc-cat5
    "(extern "
    (intern-str name)
    " : "
    (doc-ast-type-source type-segment-bases ty)
    ")"))

(define (doc-ast-decl-item [type-segment-bases : i64] [decl : AstDecl]) : DocMaybeItem
  (match decl
    [(AstDecl.Def decl-meta name maybe-ty _)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.Define)
          (intern-str name)
          ""
          (doc-ast-define-signature type-segment-bases name maybe-ty)))]
    [(AstDecl.DefFn decl-meta name params ret _ _)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.Function)
          (intern-str name)
          ""
          (doc-ast-function-signature type-segment-bases name params ret)))]
    [(AstDecl.DefMacro decl-meta name params ret _)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefMacro)
          (intern-str name)
          ""
          (doc-ast-macro-signature type-segment-bases name params ret)))]
    [(AstDecl.Extern decl-meta name _ _ ty)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.Extern)
          (intern-str name)
          ""
          (doc-ast-extern-signature type-segment-bases name ty)))]
    [(AstDecl.DefEnum decl-meta name _ variants)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefEnum)
          (intern-str name)
          ""
          (doc-ast-enum-signature type-segment-bases name "" variants)))]
    [(AstDecl.DefEnumLifetimes decl-meta name lifetimes _ variants)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefEnum)
          (intern-str name)
          ""
          (doc-ast-enum-signature
            type-segment-bases
            name
            (doc-ast-lifetime-list-source lifetimes)
            variants)))]
    [(AstDecl.DefStruct decl-meta name _ _ fields)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefStruct)
          (intern-str name)
          ""
          (doc-ast-struct-signature type-segment-bases name "" fields)))]
    [(AstDecl.DefStructLifetimes decl-meta name lifetimes _ _ fields)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefStruct)
          (intern-str name)
          ""
          (doc-ast-struct-signature
            type-segment-bases
            name
            (doc-ast-lifetime-list-source lifetimes)
            fields)))]
    [(AstDecl.Unsafe inner-box)
      (doc-ast-decl-item type-segment-bases (box-get inner-box))]
    [_ (DocMaybeItem.No)]))

(define (doc-ast-generated-decl-item
  [type-segment-bases : i64]
  [decl : AstDecl]) : DocMaybeItem
  (match (ast-decl-generated-meta decl)
    [(AstGeneratedDeclMeta.Some _ _ _ _)
      (doc-ast-decl-item type-segment-bases decl)]
    [(AstGeneratedDeclMeta.No) (DocMaybeItem.No)]))

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
      (doc_item_vec.push out (doc_extract.doc-item-list-ref items index))
      (doc-generated-copy-items out items (+ index 1) count))))

(define (doc-generated-module-items [form : String] [items : doc_item_vec.Vec]) : doc_item_vec.Vec
  (let
    [count : i64 (doc_extract.doc-item-list-count items)]
    [out : doc_item_vec.Vec (doc_item_vec.with-capacity (+ count 1))]
    (begin
      (doc_item_vec.push (&mut out) (doc-generated-import-item form))
      (doc-generated-copy-items (&mut out) items 0 count)
      out)))

(define (doc-generated-flush-module!
  [module-name : String]
  [items : doc_item_vec.Vec]
  [has-generated : bool]
  [targets : doc_generated_target_example_vec.Vec]
  [modules : (&mut modules doc_module_vec.Vec)]) : unit
  (let
    [form : String (doc-generated-target-example-find (& targets) module-name)]
    (if (and
      has-generated
      (> (string.string-length module-name) 0)
      (> (string.string-length form) 0))
      (doc_module_vec.push
        modules
        (doc_render.DocModule.Module
          module-name
          (doc_extract.DocExtraction.Extraction
            "Generated module API."
            (doc-generated-module-items form items))))
      unit)))

(define (doc-generated-modules-from-expanded-decls
  [type-segment-bases : i64]
  [decls : AstDeclList]
  [targets : doc_generated_target_example_vec.Vec]) : doc_module_vec.Vec
  (let
    [cursor : AstDeclList decls]
    [current-module : String ""]
    [items : doc_item_vec.Vec (doc_item_vec.new)]
    [has-generated : bool false]
    [modules : doc_module_vec.Vec (doc_module_vec.new)]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast-decl-list-step cursor)
          [(AstDeclListStep.Nil)
            (begin
              (doc-generated-flush-module!
                current-module
                items
                has-generated
                targets
                (&mut modules))
              (set! done true))]
          [(AstDeclListStep.Cons decl rest)
            (begin
              (match decl
                [(AstDecl.Module next-module)
                  (begin
                    (doc-generated-flush-module!
                      current-module
                      items
                      has-generated
                      targets
                      (&mut modules))
                    (set! current-module (intern-str next-module))
                    (set! items (doc_item_vec.new))
                    (set! has-generated false))]
                [_
                  (match (doc-ast-generated-decl-item type-segment-bases decl)
                    [(DocMaybeItem.Some item)
                      (begin
                        (doc_item_vec.push (&mut items) item)
                        (set! has-generated true))]
                    [(DocMaybeItem.No) unit])])
              (set! cursor rest))]))
      modules)))

(define (doc-expanded-generated-modules-from-loaded-decls
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [stdlib-roots : doc_svec.Vec]) : ResultDocExpandedModules
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [type-segment-bases : i64 (ast-node-pool-context-type-segment-bases pools)]
    [macro-examples : doc_macro_import_example_vec.Vec
      (doc-macro-import-examples-from-decls type-segment-bases decls)]
    (match (typecheck-compiler-doc-expand-program-with-paths-and-pools
      (ast-program decls)
      paths
      stdlib-roots
      pools)
      [(ResultCompilerDocExpand.Ok expanded _)
        (match expanded
          [(AstProgram.Program expanded-box)
            (let
              [expanded-decls : AstDeclList (box-get expanded-box)]
              [targets : doc_generated_target_example_vec.Vec
                (doc-generated-target-examples-from-decls
                  expanded-decls
                  macro-examples)]
              (ResultDocExpandedModules.Ok
                (doc-generated-modules-from-expanded-decls
                  type-segment-bases
                  expanded-decls
                  targets)))])]
      [(ResultCompilerDocExpand.Err diag)
        (ResultDocExpandedModules.Err
          (compiler-diagnostic-render (box-get diag)))])))

(define (doc-expand-find-prefix [text : String] [prefix : String] [from : i64]) : i64
  (let
    [i : i64 from]
    [n : i64 (string.string-length text)]
    [found : i64 n]
    (begin
      (while (and (< i n) (= found n))
        (begin
          (if (doc_extract.doc-string-prefix-at? text prefix i)
            (set! found i)
            unit)
          (set! i (+ i 1))))
      found)))

(define (doc-expand-fence-line-start
  [text : String]
  [line-start : i64]
  [line-end : i64]) : i64
  (let
    [first : i64 (doc_extract.doc-first-nonspace text line-start line-end)]
    (if (doc_extract.doc-string-prefix-at? text "```" first)
      first
      line-end)))

(define (doc-expand-ignored-fence-line?
  [text : String]
  [line-start : i64]
  [line-end : i64]) : bool
  (let
    [fence : i64 (doc-expand-fence-line-start text line-start line-end)]
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
          [line-end : i64 (doc_extract.doc-line-end text pos n)]
          (begin
            (if (doc-expand-ignored-fence-line? text pos line-end)
              (set! found pos)
              unit)
            (set! pos (doc_extract.doc-next-line-start text line-end n)))))
      found)))

(define (doc-expand-skip-fence [text : String] [cursor : i64] [n : i64]) : i64
  (let
    [open-end : i64 (doc_extract.doc-line-end text cursor n)]
    [pos : i64 (doc_extract.doc-next-line-start text open-end n)]
    [done : bool false]
    (begin
      (while (and (< pos n) (not done))
        (let
          [line-end : i64 (doc_extract.doc-line-end text pos n)]
          (if (< (doc-expand-fence-line-start text pos line-end) line-end)
            (begin
              (set! pos (doc_extract.doc-next-line-start text line-end n))
              (set! done true))
            (set! pos (doc_extract.doc-next-line-start text line-end n)))))
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
            (doc-expand-next-ignored-fence doc-text cursor n)]
          [start : i64 (doc-expand-find-prefix doc-text "(import " cursor)]
          (if (< ignored-fence start)
            (set! cursor (doc-expand-skip-fence doc-text ignored-fence n))
            (if (< start n)
              (let
                [end : i64 (doc_extract.doc-scan-form-end doc-text start n)]
                [form : String (string.substring doc-text start (- end start))]
                (begin
                  (doc-import-form-list-push-unique! (&mut forms) form)
                  (if (doc_extract.doc-string-prefix-at?
                    doc-text
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
        (if (not (struct-get scan has-macro))
          (ResultDocExpandedModules.Ok (doc_module_vec.new))
          (match (compiler-load-source-with-paths-and-roots
            (doc-cat2 source-path ".doc-examples.tl")
            (doc-expanded-example-source (struct-get scan forms))
            (sym_i64_env.sym-i64-empty)
            stdlib-roots)
            [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
              (doc-expanded-generated-modules-from-loaded-decls
                decls
                paths
                stdlib-roots)]
            [(ResultCompilerLoadWithPaths.Err diag)
              (ResultDocExpandedModules.Err
                (compiler-diagnostic-render (box-get diag)))])))]))

(define (doc-expanded-generated-modules-from-source-docs-default
  [source-path : String]
  [docs : doc_extract.DocExtraction]) : ResultDocExpandedModules
  (doc-expanded-generated-modules-from-source-docs
    source-path
    docs
    (doc_svec.new)))

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
        (struct-get b value)))))

(import (boxmod i64) as ibox)")

(define (doc-expand-macro-type-kind-constraint-source-smoke?
  [type-segment-bases : i64]) : bool
  (match (parse-ast-source
    "(defmacro (catalog [T : type (:kind i64 struct)]) : Module unit)")
    [(ResultAstProgram.Ok (AstProgram.Program decls-box))
      (match (ast-decl-list-step (box-get decls-box))
        [(AstDeclListStep.Cons (AstDecl.DefMacro decl-meta _ params _ _) rest)
          (and
            (match (ast-decl-list-step rest)
              [(AstDeclListStep.Nil) true]
              [_ false])
            (= (ast-macro-param-list-len (& params)) 1)
            (string.eq
              (doc-ast-macro-param-source
                type-segment-bases
                (ast-macro-param-list-get
                  (& params)
                  0
                  (ast-macro-param-fallback)))
              "[T : type (:kind i64 struct)]"))]
        [_ false])]
    [(ResultAstProgram.Err _) false]))

(test
  doc-macro-type-kind-constraint-source
  (unless
    (doc-expand-macro-type-kind-constraint-source-smoke?
      (ast-node-pool-reader-type-segment-bases))
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
          (doc_item_vec.push
            (&mut items)
            (doc_extract.DocItem.Item
              (doc_extract.DocItemKind.Define)
              (string.int->string index)
              ""
              ""))
          (doc_import_form_vec.push (&mut forms) (string.int->string index))
          (doc_macro_import_example_vec.push
            (&mut macro-examples)
            (DocMacroImportExample (string.int->string index) ""))
          (doc_generated_target_example_vec.push
            (&mut targets)
            (DocGeneratedTargetExample (string.int->string index) ""))
          (doc_module_vec.push
            (&mut modules)
            (doc_render.DocModule.Module
              (string.int->string index)
              (doc_extract.doc-extraction-empty)))
          (set! index (+ index 1))))
      (unless
        (and
          (= (doc_extract.doc-item-list-count items) 6)
          (= (doc_import_form_vec.len (& forms)) 6)
          (= (doc_macro_import_example_vec.len (& macro-examples)) 6)
          (= (doc_generated_target_example_vec.len (& targets)) 6)
          (= (doc_render.doc-module-list-count modules) 6)
          (string.eq
            (doc_extract.doc-item-name (doc_extract.doc-item-list-ref items 0))
            "0")
          (string.eq
            (doc_extract.doc-item-name (doc_extract.doc-item-list-ref items 5))
            "5")
          (string.eq (doc_import_form_vec.get (& forms) 0 "") "0")
          (string.eq (doc_import_form_vec.get (& forms) 5 "") "5")
          (string.eq
            (struct-get
              (doc_macro_import_example_vec.get
                (& macro-examples)
                5
                (doc-macro-import-example-fallback))
              alias)
            "5")
          (string.eq
            (struct-get
              (doc_generated_target_example_vec.get
                (& targets)
                5
                (doc-generated-target-example-fallback))
              target)
            "5")
          (string.eq
            (doc_render.doc-module-path
              (doc_render.doc-module-list-ref modules 0))
            "0")
          (string.eq
            (doc_render.doc-module-path
              (doc_render.doc-module-list-ref modules 5))
            "5"))
        (io.panic "doc-expand: generated vector growth/order mismatch")))))

(define (doc-expand-smoke) : i64
  (let
    [roots : doc_svec.Vec (doc_svec.new)]
    (match (compiler-load-source-with-paths-and-roots
      "doc_expand_smoke.tl"
      (doc-expand-smoke-source)
      (sym_i64_env.sym-i64-empty)
      roots)
      [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
        (match (doc-expanded-generated-modules-from-loaded-decls
          decls
          paths
          roots)
          [(ResultDocExpandedModules.Ok modules)
            (let
              [rendered : String
                (doc_render.doc-render-module-graph-markdown modules)]
              (if (and
                (doc_extract.doc-string-contains?
                  rendered
                  "doc.generated.fixture.box\\_i64")
                (doc_extract.doc-string-contains?
                  rendered
                  "(import (boxmod i64) as ibox)")
                (doc_extract.doc-string-contains? rendered "### Box")
                (doc_extract.doc-string-contains? rendered "### Status")
                (doc_extract.doc-string-contains? rendered "### new"))
                42
                (io.panic "doc-expand: generated module docs smoke mismatch")))]
          [(ResultDocExpandedModules.Err message)
            (io.panic (doc-cat2 "doc-expand: expansion failed: " message))])]
      [(ResultCompilerLoadWithPaths.Err diag)
        (io.panic
          (doc-cat2
            "doc-expand: load failed: "
            (compiler-diagnostic-render (box-get diag))))])))

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
    (if (and
      (not (struct-get ignored-scan has-macro))
      (struct-get active-scan has-macro))
      42
      (io.panic "doc-expand: ignored fence import scan mismatch"))))