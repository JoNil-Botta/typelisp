;; doc_expand.tl - Expansion-aware generated-module docs.
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import sym_i64_env)
(import "string_vec_core.tl" module string_vec_core as svec)
(import "doc_render.tl")
(import "compiler_load.tl")
(import "compiler_typecheck.tl")

(defenum DocMaybeItem
  (No)
  (Some DocItem))

(defenum DocImportFormList
  (Nil)
  (Cons String (Box DocImportFormList)))

(defstruct DocImportFormScan
  (forms DocImportFormList)
  (has-macro bool))

(defenum DocMacroImportExampleList
  (Nil)
  (Cons String String (Box DocMacroImportExampleList)))

(defenum DocGeneratedTargetExampleList
  (Nil)
  (Cons String String (Box DocGeneratedTargetExampleList)))

(defenum ResultDocExpandedModules
  (Ok DocModuleList)
  (Err String))

(define (doc-import-form-list-cons [form : String] [rest : DocImportFormList]) : DocImportFormList
  (DocImportFormList.Cons form (box rest)))

(define (doc-import-form-list-contains?
  [forms : DocImportFormList]
  [form : String]) : bool
  (match forms
    [(DocImportFormList.Nil) false]
    [(DocImportFormList.Cons existing rest)
      (if (string.eq existing form)
        true
        (doc-import-form-list-contains? (box-get rest) form))]))

(define (doc-import-form-list-cons-unique
  [form : String]
  [rest : DocImportFormList]) : DocImportFormList
  (if (doc-import-form-list-contains? rest form)
    rest
    (doc-import-form-list-cons form rest)))

(define (doc-import-form-list-reverse-into
  [forms : DocImportFormList]
  [acc : DocImportFormList]) : DocImportFormList
  (match forms
    [(DocImportFormList.Nil) acc]
    [(DocImportFormList.Cons form rest)
      (doc-import-form-list-reverse-into
        (box-get rest)
        (doc-import-form-list-cons form acc))]))

(define (doc-import-form-list-reverse [forms : DocImportFormList]) : DocImportFormList
  (doc-import-form-list-reverse-into forms DocImportFormList.Nil))

(define (doc-import-form-list-source [forms : DocImportFormList]) : String
  (match forms
    [(DocImportFormList.Nil) ""]
    [(DocImportFormList.Cons form rest)
      (str_cat.str-cat form "\n" (doc-import-form-list-source (box-get rest)))]))

(define (doc-import-alias-string [alias : AstMaybeImportAlias]) : String
  (match alias
    [(AstMaybeImportAlias.Some name) name]
    [(AstMaybeImportAlias.No) ""]))

(define (doc-ast-type-id-source [ty-id : i64]) : String
  (doc-ast-type-source (ast-node-pool-reader-type-get ty-id)))

(define (doc-ast-type-list-source-from
  [types : AstTypeList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      (if (= index 0)
        ""
        " ")
      (doc-ast-type-id-source (ast-type-list-get (& types) index 0))
      (doc-ast-type-list-source-from types (+ index 1) count))))

(define (doc-ast-type-list-source [types : AstTypeList]) : String
  (doc-ast-type-list-source-from types 0 (ast-type-list-len (& types))))

(define (doc-ast-lifetime-list-source-from
  [lifetimes : AstLifetimeList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      (if (= index 0)
        ""
        " ")
      (ast-lifetime-list-get (& lifetimes) index "")
      (doc-ast-lifetime-list-source-from lifetimes (+ index 1) count))))

(define (doc-ast-lifetime-list-source [lifetimes : AstLifetimeList]) : String
  (let
    [count : i64 (ast-lifetime-list-len (& lifetimes))]
    (if (= count 0)
      ""
      (str_cat.str-cat
        " (:lifetimes "
        (doc-ast-lifetime-list-source-from lifetimes 0 count)
        ")"))))

(define (doc-ast-type-source [ty : AstType]) : String
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
      (str_cat.str-cat
        "(-> "
        (doc-ast-type-list-source (box-get args-box))
        " "
        (doc-ast-type-id-source ret)
        ")")]
    [(AstType.Tuple elems-box)
      (str_cat.str-cat
        "(Tuple "
        (doc-ast-type-list-source (box-get elems-box))
        ")")]
    [(AstType.Array elem size)
      (str_cat.str-cat
        "(Array "
        (doc-ast-type-id-source elem)
        " "
        (string.int->string size)
        ")")]
    [(AstType.DynArray elem)
      (str_cat.str-cat "(Array " (doc-ast-type-id-source elem) ")")]
    [(AstType.Box elem)
      (str_cat.str-cat "(Box " (doc-ast-type-id-source elem) ")")]
    [(AstType.Region region elem)
      (str_cat.str-cat "(Region " region " " (doc-ast-type-id-source elem) ")")]
    [(AstType.Ref lifetime elem)
      (str_cat.str-cat "(& " lifetime " " (doc-ast-type-id-source elem) ")")]
    [(AstType.MutRef lifetime elem)
      (str_cat.str-cat "(&mut " lifetime " " (doc-ast-type-id-source elem) ")")]
    [(AstType.Enum name) (intern-str name)]
    [(AstType.EnumArgs name _) (intern-str name)]
    [(AstType.Struct name) (intern-str name)]
    [(AstType.StructArgs name _) (intern-str name)]
    [(AstType.Var name) (intern-str name)]
    [(AstType.VarArgs name _) (intern-str name)]
    [(AstType.Ptr elem)
      (str_cat.str-cat "(Ptr " (doc-ast-type-id-source elem) ")")]
    [(AstType.MutPtr elem)
      (str_cat.str-cat "(MutPtr " (doc-ast-type-id-source elem) ")")]))

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
        (str_cat.str-cat out piece "")))))

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
    [(AstLiteral.String text)
      (str_cat.str-cat "\"" (doc-expand-escape-string text) "\"")]
    [(AstLiteral.Unit) "unit"]))

(define (doc-ast-expr-list-source-from
  [exprs : AstExprList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      " "
      (doc-ast-expr-source (ast-expr-list-get (& exprs) index 0))
      (doc-ast-expr-list-source-from exprs (+ index 1) count))))

(define (doc-ast-expr-list-source [exprs : AstExprList]) : String
  (doc-ast-expr-list-source-from exprs 0 (ast-expr-list-len (& exprs))))

(define (doc-ast-expr-source [expr-id : i64]) : String
  (match (ast-expr-unspan (ast-node-get expr-id))
    [(AstExpr.Literal lit) (doc-ast-literal-source lit)]
    [(AstExpr.Var name) (intern-str name)]
    [(AstExpr.Call callee args)
      (str_cat.str-cat
        "("
        (doc-ast-expr-source callee)
        (doc-ast-expr-list-source args)
        ")")]
    [(AstExpr.TypeLiteral ty)
      (str_cat.str-cat "(type " (doc-ast-type-source ty) ")")]
    [(AstExpr.Ann inner _) (doc-ast-expr-source inner)]
    [(AstExpr.Spanned inner _) (doc-ast-expr-source inner)]
    [_ "..."]))

(define (doc-macro-import-example-cons
  [alias : String]
  [form : String]
  [rest : DocMacroImportExampleList]) : DocMacroImportExampleList
  (DocMacroImportExampleList.Cons alias form (box rest)))

(define (doc-macro-import-example-find
  [examples : DocMacroImportExampleList]
  [alias : String]) : String
  (match examples
    [(DocMacroImportExampleList.Nil) ""]
    [(DocMacroImportExampleList.Cons example-alias form rest)
      (if (string.eq example-alias alias)
        form
        (doc-macro-import-example-find (box-get rest) alias))]))

(define (doc-macro-import-form [call-id : i64] [alias : AstMaybeImportAlias]) : String
  (match alias
    [(AstMaybeImportAlias.Some name)
      (str_cat.str-cat "(import " (doc-ast-expr-source call-id) " as " name ")")]
    [(AstMaybeImportAlias.No)
      (str_cat.str-cat "(import " (doc-ast-expr-source call-id) ")")]))

(define (doc-macro-import-examples-from-decl
  [decl : AstDecl]
  [acc : DocMacroImportExampleList]) : DocMacroImportExampleList
  (match decl
    [(AstDecl.Import (AstImportSpec.Spec kind _ _ alias _))
      (match kind
        [(AstImportKind.Macro call-id _)
          (doc-macro-import-example-cons
            (doc-import-alias-string alias)
            (doc-macro-import-form call-id alias)
            acc)]
        [_ acc])]
    [(AstDecl.ComptimeDecl _ inner-box)
      (doc-macro-import-examples-from-decl (box-get inner-box) acc)]
    [(AstDecl.Unsafe inner-box)
      (doc-macro-import-examples-from-decl (box-get inner-box) acc)]
    [(AstDecl.ModuleBody _ body-box)
      (doc-macro-import-examples-from-decls (box-get body-box) acc)]
    [_ acc]))

(define (doc-macro-import-examples-from-decls
  [decls : AstDeclList]
  [acc : DocMacroImportExampleList]) : DocMacroImportExampleList
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) acc]
    [(AstDeclListStep.Cons decl rest)
      (doc-macro-import-examples-from-decls
        rest
        (doc-macro-import-examples-from-decl decl acc))]))

(define (doc-generated-target-example-cons
  [target : String]
  [form : String]
  [rest : DocGeneratedTargetExampleList]) : DocGeneratedTargetExampleList
  (DocGeneratedTargetExampleList.Cons target form (box rest)))

(define (doc-generated-target-example-find
  [examples : DocGeneratedTargetExampleList]
  [target : String]) : String
  (match examples
    [(DocGeneratedTargetExampleList.Nil) ""]
    [(DocGeneratedTargetExampleList.Cons example-target form rest)
      (if (string.eq example-target target)
        form
        (doc-generated-target-example-find (box-get rest) target))]))

(define (doc-generated-target-example-add
  [examples : DocGeneratedTargetExampleList]
  [target : String]
  [form : String]) : DocGeneratedTargetExampleList
  (if (or
    (= (string.string-length target) 0)
    (= (string.string-length form) 0)
    (>
      (string.string-length (doc-generated-target-example-find examples target))
      0))
    examples
    (doc-generated-target-example-cons target form examples)))

(define (doc-generated-target-examples-from-decl
  [decl : AstDecl]
  [macro-examples : DocMacroImportExampleList]
  [targets : DocGeneratedTargetExampleList]) : DocGeneratedTargetExampleList
  (match decl
    [(AstDecl.Import (AstImportSpec.Spec kind _ expected alias _))
      (match kind
        [(AstImportKind.Module)
          (match expected
            [(AstMaybeModuleName.Some target-module)
              (let
                [form : String
                  (doc-macro-import-example-find
                    macro-examples
                    (doc-import-alias-string alias))]
                (doc-generated-target-example-add targets target-module form))]
            [(AstMaybeModuleName.No) targets])]
        [_ targets])]
    [(AstDecl.ComptimeDecl _ inner-box)
      (doc-generated-target-examples-from-decl
        (box-get inner-box)
        macro-examples
        targets)]
    [(AstDecl.Unsafe inner-box)
      (doc-generated-target-examples-from-decl
        (box-get inner-box)
        macro-examples
        targets)]
    [(AstDecl.ModuleBody _ body-box)
      (doc-generated-target-examples-from-decls
        (box-get body-box)
        macro-examples
        targets)]
    [_ targets]))

(define (doc-generated-target-examples-from-decls
  [decls : AstDeclList]
  [macro-examples : DocMacroImportExampleList]
  [targets : DocGeneratedTargetExampleList]) : DocGeneratedTargetExampleList
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) targets]
    [(AstDeclListStep.Cons decl rest)
      (doc-generated-target-examples-from-decls
        rest
        macro-examples
        (doc-generated-target-examples-from-decl decl macro-examples targets))]))

(define (doc-ast-maybe-type-source [maybe-ty : AstMaybeType]) : String
  (match maybe-ty
    [(AstMaybeType.No) ""]
    [(AstMaybeType.Some ty) (str_cat.str-cat " : " (doc-ast-type-source ty) "")]))

(define (doc-ast-param-source [param : AstParam]) : String
  (match param
    [(AstParam.Param name ty _)
      (str_cat.str-cat "[" (intern-str name) " : " (doc-ast-type-source ty) "]")]))

(define (doc-ast-param-list-source-from
  [params : AstParamList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      " "
      (doc-ast-param-source
        (ast-param-list-get
          (& params)
          index
          (AstParam.Param 0 (AstType.Unit) false)))
      (doc-ast-param-list-source-from params (+ index 1) count))))

(define (doc-ast-param-list-source [params : AstParamList]) : String
  (doc-ast-param-list-source-from params 0 (ast-param-list-len (& params))))

(define (doc-ast-macro-param-source [param : AstMacroParam]) : String
  (match param
    [(AstMacroParam.Param name ty _)
      (str_cat.str-cat "[" (intern-str name) " : " (doc-ast-type-source ty) "]")]))

(define (doc-ast-macro-param-list-source-from
  [params : AstMacroParamList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      " "
      (doc-ast-macro-param-source
        (ast-macro-param-list-get
          (& params)
          index
          (AstMacroParam.Param 0 (AstType.Unit) false)))
      (doc-ast-macro-param-list-source-from params (+ index 1) count))))

(define (doc-ast-macro-param-list-source [params : AstMacroParamList]) : String
  (doc-ast-macro-param-list-source-from
    params
    0
    (ast-macro-param-list-len (& params))))

(define (doc-ast-field-source [field : AstFieldDef]) : String
  (match field
    [(AstFieldDef.Def name ty _)
      (str_cat.str-cat
        "\n  ("
        (intern-str name)
        " "
        (doc-ast-type-source ty)
        ")")]))

(define (doc-ast-field-list-source-from
  [fields : AstFieldDefList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      (doc-ast-field-source
        (ast-field-def-list-get
          (& fields)
          index
          (AstFieldDef.Def 0 (AstType.Unit) AstFieldCleanup.No)))
      (doc-ast-field-list-source-from fields (+ index 1) count))))

(define (doc-ast-field-list-source [fields : AstFieldDefList]) : String
  (doc-ast-field-list-source-from fields 0 (ast-field-def-list-len (& fields))))

(define (doc-ast-variant-payload-source-from
  [fields : AstTypeList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      " "
      (doc-ast-type-id-source (ast-type-list-get (& fields) index 0))
      (doc-ast-variant-payload-source-from fields (+ index 1) count))))

(define (doc-ast-variant-source [variant : AstVariantDef]) : String
  (match variant
    [(AstVariantDef.Def name fields _)
      (str_cat.str-cat
        "\n  ("
        (intern-str name)
        (doc-ast-variant-payload-source-from
          fields
          0
          (ast-type-list-len (& fields)))
        ")")]))

(define (doc-ast-variant-list-source-from
  [variants : AstVariantDefList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (str_cat.str-cat
      (doc-ast-variant-source
        (ast-variant-def-list-get
          (& variants)
          index
          (AstVariantDef.Def
            0
            (ast-type-list-new)
            (ast-variant-payload-cleanup-list-new))))
      (doc-ast-variant-list-source-from variants (+ index 1) count))))

(define (doc-ast-variant-list-source [variants : AstVariantDefList]) : String
  (doc-ast-variant-list-source-from
    variants
    0
    (ast-variant-def-list-len (& variants))))

(define (doc-ast-define-signature [name : i64] [maybe-ty : AstMaybeType]) : String
  (str_cat.str-cat
    "(define "
    (intern-str name)
    (doc-ast-maybe-type-source maybe-ty)
    " ...)"))

(define (doc-ast-function-signature
  [name : i64]
  [params : AstParamList]
  [ret : AstType]) : String
  (str_cat.str-cat
    "(define ("
    (intern-str name)
    (doc-ast-param-list-source params)
    ") : "
    (doc-ast-type-source ret)
    " ...)"))

(define (doc-ast-macro-signature
  [name : i64]
  [params : AstMacroParamList]
  [ret : AstType]) : String
  (str_cat.str-cat
    "(defmacro ("
    (intern-str name)
    (doc-ast-macro-param-list-source params)
    ") : "
    (doc-ast-type-source ret)
    " ...)"))

(define (doc-ast-struct-signature
  [name : i64]
  [lifetimes : String]
  [fields : AstFieldDefList]) : String
  (str_cat.str-cat
    "(defstruct "
    (intern-str name)
    lifetimes
    (doc-ast-field-list-source fields)
    ")"))

(define (doc-ast-enum-signature
  [name : i64]
  [lifetimes : String]
  [variants : AstVariantDefList]) : String
  (str_cat.str-cat
    "(defenum "
    (intern-str name)
    lifetimes
    (doc-ast-variant-list-source variants)
    ")"))

(define (doc-ast-extern-signature [name : i64] [ty : AstType]) : String
  (str_cat.str-cat
    "(extern "
    (intern-str name)
    " : "
    (doc-ast-type-source ty)
    ")"))

(define (doc-ast-decl-item [decl : AstDecl]) : DocMaybeItem
  (match decl
    [(AstDecl.Def name maybe-ty _)
      (DocMaybeItem.Some
        (DocItem.Item
          (DocItemKind.Define)
          (intern-str name)
          ""
          (doc-ast-define-signature name maybe-ty)))]
    [(AstDecl.DefFn name params ret _ _)
      (DocMaybeItem.Some
        (DocItem.Item
          (DocItemKind.Function)
          (intern-str name)
          ""
          (doc-ast-function-signature name params ret)))]
    [(AstDecl.DefMacro name params ret _)
      (DocMaybeItem.Some
        (DocItem.Item
          (DocItemKind.DefMacro)
          (intern-str name)
          ""
          (doc-ast-macro-signature name params ret)))]
    [(AstDecl.Extern name _ _ ty)
      (DocMaybeItem.Some
        (DocItem.Item
          (DocItemKind.Extern)
          (intern-str name)
          ""
          (doc-ast-extern-signature name ty)))]
    [(AstDecl.DefEnum name _ variants)
      (DocMaybeItem.Some
        (DocItem.Item
          (DocItemKind.DefEnum)
          (intern-str name)
          ""
          (doc-ast-enum-signature name "" variants)))]
    [(AstDecl.DefEnumLifetimes name lifetimes _ variants)
      (DocMaybeItem.Some
        (DocItem.Item
          (DocItemKind.DefEnum)
          (intern-str name)
          ""
          (doc-ast-enum-signature
            name
            (doc-ast-lifetime-list-source lifetimes)
            variants)))]
    [(AstDecl.DefStruct name _ _ fields)
      (DocMaybeItem.Some
        (DocItem.Item
          (DocItemKind.DefStruct)
          (intern-str name)
          ""
          (doc-ast-struct-signature name "" fields)))]
    [(AstDecl.DefStructLifetimes name lifetimes _ _ fields)
      (DocMaybeItem.Some
        (DocItem.Item
          (DocItemKind.DefStruct)
          (intern-str name)
          ""
          (doc-ast-struct-signature
            name
            (doc-ast-lifetime-list-source lifetimes)
            fields)))]
    [(AstDecl.ComptimeDecl _ inner-box) (doc-ast-decl-item (box-get inner-box))]
    [(AstDecl.Unsafe inner-box) (doc-ast-decl-item (box-get inner-box))]
    [_ (DocMaybeItem.No)]))

(define (doc-ast-generated-decl-item [decl : AstDecl]) : DocMaybeItem
  (match decl
    [(AstDecl.ComptimeDecl meta inner-box)
      (match meta
        [(AstGeneratedDeclMeta.Some _ _ _ _)
          (doc-ast-decl-item (box-get inner-box))]
        [(AstGeneratedDeclMeta.No)
          (doc-ast-generated-decl-item (box-get inner-box))])]
    [(AstDecl.Unsafe inner-box)
      (doc-ast-generated-decl-item (box-get inner-box))]
    [_ (DocMaybeItem.No)]))

(define (doc-generated-import-item [form : String]) : DocItem
  (DocItem.Item
    (DocItemKind.GeneratedImport)
    "import"
    "Concrete generated-module import that produced this API."
    form))

(define (doc-generated-flush-module
  [module-name : String]
  [items-rev : DocItemList]
  [has-generated : bool]
  [targets : DocGeneratedTargetExampleList]
  [modules : DocModuleList]) : DocModuleList
  (let
    [form : String (doc-generated-target-example-find targets module-name)]
    (if (and
      has-generated
      (> (string.string-length module-name) 0)
      (> (string.string-length form) 0))
      (doc-module-list-cons
        (DocModule.Module
          module-name
          (DocExtraction.Extraction
            "Generated module API."
            (DocItemList.Cons
              (doc-generated-import-item form)
              (box (doc-item-list-reverse items-rev)))))
        modules)
      modules)))

(define (doc-generated-modules-from-expanded-decls
  [decls : AstDeclList]
  [targets : DocGeneratedTargetExampleList]) : DocModuleList
  (let
    [cursor : AstDeclList decls]
    [current-module : String ""]
    [items-rev : DocItemList DocItemList.Nil]
    [has-generated : bool false]
    [modules-rev : DocModuleList DocModuleList.Nil]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast-decl-list-step cursor)
          [(AstDeclListStep.Nil)
            (begin
              (set!
                modules-rev
                (doc-generated-flush-module
                  current-module
                  items-rev
                  has-generated
                  targets
                  modules-rev))
              (set! done true))]
          [(AstDeclListStep.Cons decl rest)
            (begin
              (match decl
                [(AstDecl.Module next-module)
                  (begin
                    (set!
                      modules-rev
                      (doc-generated-flush-module
                        current-module
                        items-rev
                        has-generated
                        targets
                        modules-rev))
                    (set! current-module (intern-str next-module))
                    (set! items-rev DocItemList.Nil)
                    (set! has-generated false))]
                [_
                  (match (doc-ast-generated-decl-item decl)
                    [(DocMaybeItem.Some item)
                      (begin
                        (set! items-rev (DocItemList.Cons item (box items-rev)))
                        (set! has-generated true))]
                    [(DocMaybeItem.No) unit])])
              (set! cursor rest))]))
      (doc-module-list-append modules-rev DocModuleList.Nil))))

(define (doc-expanded-generated-modules-from-loaded-decls
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [stdlib-roots : svec.StringVector]) : ResultDocExpandedModules
  (let
    [macro-examples : DocMacroImportExampleList
      (doc-macro-import-examples-from-decls decls DocMacroImportExampleList.Nil)]
    (match (typecheck-compiler-doc-expand-program-with-paths
      (ast-program decls)
      paths
      stdlib-roots)
      [(ResultCompilerDocExpand.Ok expanded _)
        (match expanded
          [(AstProgram.Program expanded-box)
            (let
              [expanded-decls : AstDeclList (box-get expanded-box)]
              [targets : DocGeneratedTargetExampleList
                (doc-generated-target-examples-from-decls
                  expanded-decls
                  macro-examples
                  DocGeneratedTargetExampleList.Nil)]
              (ResultDocExpandedModules.Ok
                (doc-generated-modules-from-expanded-decls
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
          (if (doc-string-prefix-at? text prefix i)
            (set! found i)
            unit)
          (set! i (+ i 1))))
      found)))

(define (doc-expand-fence-line-start
  [text : String]
  [line-start : i64]
  [line-end : i64]) : i64
  (let
    [first : i64 (doc-first-nonspace text line-start line-end)]
    (if (doc-string-prefix-at? text "```" first)
      first
      line-end)))

(define (doc-expand-ignored-fence-line?
  [text : String]
  [line-start : i64]
  [line-end : i64]) : bool
  (let
    [fence : i64 (doc-expand-fence-line-start text line-start line-end)]
    (if (< fence line-end)
      (doc-string-contains?
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
          [line-end : i64 (doc-line-end text pos n)]
          (begin
            (if (doc-expand-ignored-fence-line? text pos line-end)
              (set! found pos)
              unit)
            (set! pos (doc-next-line-start text line-end n)))))
      found)))

(define (doc-expand-skip-fence [text : String] [cursor : i64] [n : i64]) : i64
  (let
    [open-end : i64 (doc-line-end text cursor n)]
    [pos : i64 (doc-next-line-start text open-end n)]
    [done : bool false]
    (begin
      (while (and (< pos n) (not done))
        (let
          [line-end : i64 (doc-line-end text pos n)]
          (if (< (doc-expand-fence-line-start text pos line-end) line-end)
            (begin
              (set! pos (doc-next-line-start text line-end n))
              (set! done true))
            (set! pos (doc-next-line-start text line-end n)))))
      pos)))

(define (doc-import-forms-from-doc-text [doc-text : String]) : DocImportFormScan
  (let
    [cursor : i64 0]
    [n : i64 (string.string-length doc-text)]
    [forms-rev : DocImportFormList DocImportFormList.Nil]
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
                [end : i64 (doc-scan-form-end doc-text start n)]
                [form : String (string.substring doc-text start (- end start))]
                (begin
                  (set!
                    forms-rev
                    (doc-import-form-list-cons-unique form forms-rev))
                  (if (doc-string-prefix-at? doc-text "(import (" start)
                    (set! has-macro true)
                    unit)
                  (set! cursor end)))
              (set! cursor n)))))
      (DocImportFormScan (doc-import-form-list-reverse forms-rev) has-macro))))

(define (doc-expanded-example-source [forms : DocImportFormList]) : String
  (str_cat.str-cat
    "(module typelisp.docs.generated_examples)\n"
    (doc-import-form-list-source forms)
    ""))

(define (doc-expanded-generated-modules-from-source-docs
  [source-path : String]
  [docs : DocExtraction]
  [stdlib-roots : svec.StringVector]) : ResultDocExpandedModules
  (match docs
    [(DocExtraction.Extraction module-doc _)
      (let
        [scan : DocImportFormScan (doc-import-forms-from-doc-text module-doc)]
        (if (not (struct-get scan has-macro))
          (ResultDocExpandedModules.Ok DocModuleList.Nil)
          (match (compiler-load-source-with-paths-and-roots
            (str_cat.str-cat source-path ".doc-examples.tl")
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
  [docs : DocExtraction]) : ResultDocExpandedModules
  (doc-expanded-generated-modules-from-source-docs source-path docs (svec.new)))

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

(define (doc-expand-smoke) : i64
  (match (compiler-load-source-with-paths-and-roots
    "doc_expand_smoke.tl"
    (doc-expand-smoke-source)
    (sym_i64_env.sym-i64-empty)
    (svec.new))
    [(ResultCompilerLoadWithPaths.Ok decls paths _ _)
      (match (doc-expanded-generated-modules-from-loaded-decls
        decls
        paths
        (svec.new))
        [(ResultDocExpandedModules.Ok modules)
          (let
            [rendered : String (doc-render-module-graph-markdown modules)]
            (if (and
              (doc-string-contains? rendered "doc.generated.fixture.box\\_i64")
              (doc-string-contains? rendered "(import (boxmod i64) as ibox)")
              (doc-string-contains? rendered "### Box")
              (doc-string-contains? rendered "### Status")
              (doc-string-contains? rendered "### new"))
              42
              (io.panic "doc-expand: generated module docs smoke mismatch")))]
        [(ResultDocExpandedModules.Err message)
          (io.panic
            (str_cat.str-cat "doc-expand: expansion failed: " message ""))])]
    [(ResultCompilerLoadWithPaths.Err diag)
      (io.panic
        (str_cat.str-cat
          "doc-expand: load failed: "
          (compiler-diagnostic-render (box-get diag))
          ""))]))

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