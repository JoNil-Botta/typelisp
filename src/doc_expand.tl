;; doc_expand.tl - Expansion-aware generated-module docs.
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
(import compiler_intern_state as cis)
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

;; Compact, immutable view of the pool/interner owners needed while rendering
;; expanded declarations. Keeping these handles explicit prevents a nested or
;; interleaved compile from redirecting documentation reads through the active
;; compatibility globals.
(defstruct DocExpandContext
  (expr-segment-bases i64)
  (type-segment-bases i64)
  (source-names ci.InternSourceNameSessionHandle))

(define (doc-expand-context-from-pools-and-intern-state
  [pools : ast.AstNodePoolContext]
  [intern-state : ci.InternCompatState]) : DocExpandContext
  (DocExpandContext
    (ast.ast-node-pool-context-expr-segment-bases pools)
    (ast.ast-node-pool-context-type-segment-bases pools)
    (ci.intern-source-name-session-handle-from-state intern-state)))

(define (doc-expand-source-name [ctx : DocExpandContext] [id : i64]) : String
  (ci.intern-source-name-session-handle-str ctx.source-names id))

(define (doc-expand-structural-name
  [ctx : DocExpandContext]
  [session : cis.InternStructuralSessionHandle]
  [name-id : i64]) : String
  (match (cis.intern-structural-session-record-for-raw session name-id)
    [(cis.InternMaybeStructuralRecord.Some record)
      (cond
        [(and
            (= record.kind (ci.intern-structural-kind-macro-global))
            (or (= record.left-id 0) (= record.left-id 1)))
          (doc-expand-source-name ctx record.right-id)]
        [(and
            (= record.kind (ci.intern-structural-kind-macro-local))
            (=
              (cis.intern-structural-session-record-kind-for-structural-or
                session
                record.left-id
                -1)
              (ci.intern-structural-kind-macro-definition)))
          (doc-expand-source-name ctx record.right-id)]
        [(= record.kind (ci.intern-structural-kind-pair))
          (let
            [cached : String
              (cis.intern-structural-session-composite-rendered-name-unchecked
                session
                name-id)]
            (if (> (string.string-length cached) 0)
              cached
              (cis.intern-structural-session-composite-rendered-name-record-unchecked!
                session
                name-id
                (doc-cat3
                  (doc-expand-name-text ctx record.left-id)
                  "/"
                  (doc-expand-name-text ctx record.right-id)))))]
        [(= record.kind (ci.intern-structural-kind-triple))
          (let
            [cached : String
              (cis.intern-structural-session-composite-rendered-name-unchecked
                session
                name-id)]
            (if (> (string.string-length cached) 0)
              cached
              (cis.intern-structural-session-composite-rendered-name-record-unchecked!
                session
                name-id
                (doc-cat5
                  (doc-expand-name-text ctx record.left-id)
                  "/"
                  (doc-expand-name-text ctx record.middle-id)
                  "."
                  (doc-expand-name-text ctx record.right-id)))))]
        [else (doc-cat3 "<structural-id:" (string.int->string name-id) ">")])]
    [(cis.InternMaybeStructuralRecord.No)
      (doc-cat3 "<structural-id:" (string.int->string name-id) ">")]))

(define (doc-expand-name-text [ctx : DocExpandContext] [name-id : i64]) : String
  (cond
    [(and
        (>= name-id 0)
        (<
          name-id
          (ci.intern-source-name-session-handle-capacity ctx.source-names)))
      (doc-expand-source-name ctx name-id)]
    [(ci.intern-structural-local-id? name-id)
      (doc-expand-source-name
        ctx
        (ci.intern-structural-local-source-name-id name-id))]
    [(ci.intern-template-source-id? name-id)
      (doc-expand-source-name ctx (ci.intern-template-source-name-id name-id))]
    [(>= name-id (ci.intern-structural-key-base))
      (doc-expand-structural-name
        ctx
        (cis.intern-structural-session-handle-from-source-names
          ctx.source-names)
        name-id)]
    [else
      (let
        [source-id : i64 (ci.intern-syntax-source-name-id-or name-id -1)]
        (if (>= source-id 0)
          (doc-expand-source-name ctx source-id)
          (doc-cat3 "<id:" (string.int->string name-id) ">")))]))

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
  (doc-import-form-list-source-from forms 0 (doc_import_form_vec.len (& forms))))

(define (doc-import-alias-string
  [ctx : DocExpandContext]
  [alias : ast.AstMaybeImportAlias]) : String
  (match alias
    [(ast.AstMaybeImportAlias.Some name) (doc-expand-source-name ctx name)]
    [(ast.AstMaybeImportAlias.No) ""]))

(define (doc-symbol-text [ctx : DocExpandContext] [name-id : i64]) : String
  (doc-expand-name-text ctx name-id))

(define (doc-ast-type-id-source [ctx : DocExpandContext] [ty-id : i64]) : String
  (doc-ast-type-source
    ctx
    (ast.ast-type-segment-bases-get ctx.type-segment-bases ty-id)))

(define (doc-ast-type-list-source-from
  [ctx : DocExpandContext]
  [types : ast.AstTypeList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      (if (= index 0)
        ""
        " ")
      (doc-ast-type-id-source ctx (ast.ast-type-list-get (& types) index 0))
      (doc-ast-type-list-source-from ctx types (+ index 1) count))))

(define (doc-ast-type-list-source
  [ctx : DocExpandContext]
  [types : ast.AstTypeList]) : String
  (doc-ast-type-list-source-from ctx types 0 (ast.ast-type-list-len (& types))))

(define (doc-ast-lifetime-list-source-from
  [ctx : DocExpandContext]
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
        ctx
        (ast.ast-lifetime-list-get
          (& lifetimes)
          index
          (ast.ast-lifetime-fallback)))
      (doc-ast-lifetime-list-source-from ctx lifetimes (+ index 1) count))))

(define (doc-ast-lifetime-list-source
  [ctx : DocExpandContext]
  [lifetimes : ast.AstLifetimeList]) : String
  (let
    [count : i64 (ast.ast-lifetime-list-len (& lifetimes))]
    (if (= count 0)
      ""
      (doc-cat3
        " (:lifetimes "
        (doc-ast-lifetime-list-source-from ctx lifetimes 0 count)
        ")"))))

(define (doc-ast-type-source [ctx : DocExpandContext] [ty : ast.AstType]) : String
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
        (doc-ast-type-list-source ctx (__tl-box-place args-box))
        " "
        (doc-ast-type-id-source ctx ret)
        ")")]
    [(ast.AstType.Tuple elems-box)
      (doc-cat3
        "(Tuple "
        (doc-ast-type-list-source ctx (__tl-box-place elems-box))
        ")")]
    [(ast.AstType.Array elem size)
      (doc-cat5
        "(Array "
        (doc-ast-type-id-source ctx elem)
        " "
        (string.int->string size)
        ")")]
    [(ast.AstType.DynArray elem)
      (doc-cat3 "(__tl_dyn-array " (doc-ast-type-id-source ctx elem) ")")]
    [(ast.AstType.Slice elem)
      (doc-cat3 "(Slice " (doc-ast-type-id-source ctx elem) ")")]
    [(ast.AstType.Box elem)
      (doc-cat3 "(Box " (doc-ast-type-id-source ctx elem) ")")]
    [(ast.AstType.Region region elem)
      (doc-cat5
        "(Region "
        (doc-symbol-text ctx region)
        " "
        (doc-ast-type-id-source ctx elem)
        ")")]
    [(ast.AstType.Ref lifetime elem)
      (doc-cat5
        "(& "
        (doc-symbol-text ctx lifetime)
        " "
        (doc-ast-type-id-source ctx elem)
        ")")]
    [(ast.AstType.MutRef lifetime elem)
      (doc-cat5
        "(&mut "
        (doc-symbol-text ctx lifetime)
        " "
        (doc-ast-type-id-source ctx elem)
        ")")]
    [(ast.AstType.Enum name) (doc-symbol-text ctx name)]
    [(ast.AstType.EnumArgs name _) (doc-symbol-text ctx name)]
    [(ast.AstType.Struct name) (doc-symbol-text ctx name)]
    [(ast.AstType.StructArgs name _) (doc-symbol-text ctx name)]
    [(ast.AstType.Var name) (doc-symbol-text ctx name)]
    [(ast.AstType.VarArgs name _) (doc-symbol-text ctx name)]
    [(ast.AstType.Ptr elem)
      (doc-cat3 "(Ptr " (doc-ast-type-id-source ctx elem) ")")]
    [(ast.AstType.MutPtr elem)
      (doc-cat3 "(MutPtr " (doc-ast-type-id-source ctx elem) ")")]
    [(ast.AstType.Consume inner)
      (doc-cat3 "(:consume " (doc-ast-type-id-source ctx inner) ")")]))

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

(define (doc-ast-literal-source [ctx : DocExpandContext] [lit : ast.AstLiteral]) : String
  (match lit
    [(ast.AstLiteral.Int _ _) (ast.ast-lit-int-text lit)]
    [(ast.AstLiteral.Float text) text]
    [(ast.AstLiteral.Bool value)
      (if value
        "true"
        "false")]
    [(ast.AstLiteral.Char _) "'?'"]
    [(ast.AstLiteral.String string-id)
      (doc-cat3
        "\""
        (doc-expand-escape-string (doc-expand-source-name ctx string-id))
        "\"")]
    [(ast.AstLiteral.Unit) "unit"]))

(define (doc-ast-expr-list-source-from
  [ctx : DocExpandContext]
  [exprs : ast.AstExprList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      " "
      (doc-ast-expr-source ctx (ast.ast-expr-list-get (& exprs) index 0))
      (doc-ast-expr-list-source-from ctx exprs (+ index 1) count))))

(define (doc-ast-expr-list-source
  [ctx : DocExpandContext]
  [exprs : ast.AstExprList]) : String
  (doc-ast-expr-list-source-from ctx exprs 0 (ast.ast-expr-list-len (& exprs))))

(define (doc-ast-expr-source [ctx : DocExpandContext] [expr-id : i64]) : String
  (match (ast.ast-expr-unspan
    (ast.ast-expr-segment-bases-get ctx.expr-segment-bases expr-id))
    [(ast.AstExpr.Literal lit) (doc-ast-literal-source ctx lit)]
    [(ast.AstExpr.Var name) (doc-expand-source-name ctx name)]
    [(ast.AstExpr.Call callee args)
      (doc-cat4
        "("
        (doc-ast-expr-source ctx callee)
        (doc-ast-expr-list-source ctx args)
        ")")]
    [(ast.AstExpr.TypeLiteral ty-id)
      (doc-cat3 "(type " (doc-ast-type-id-source ctx ty-id) ")")]
    [(ast.AstExpr.Ann inner _) (doc-ast-expr-source ctx inner)]
    [(ast.AstExpr.Spanned inner _) (doc-ast-expr-source ctx inner)]
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
  [ctx : DocExpandContext]
  [call-id : i64]
  [alias : ast.AstMaybeImportAlias]) : String
  (match alias
    [(ast.AstMaybeImportAlias.Some name)
      (doc-cat5
        "(import "
        (doc-ast-expr-source ctx call-id)
        " as "
        (doc-expand-source-name ctx name)
        ")")]
    [(ast.AstMaybeImportAlias.No)
      (doc-cat3 "(import " (doc-ast-expr-source ctx call-id) ")")]))

(define (doc-macro-import-examples-from-decl
  [ctx : DocExpandContext]
  [decl : ast.AstDecl]
  [examples : (&mut examples doc_macro_import_example_vec.Vec)]) : unit
  (match decl
    [(ast.AstDecl.Import decl-meta (ast.AstImportSpec.Spec kind _ _ alias _))
      (match kind
        [(ast.AstImportKind.Macro call-id _)
          (doc-macro-import-example-push!
            examples
            (doc-import-alias-string ctx alias)
            (doc-macro-import-form ctx call-id alias))]
        [_ unit])]
    [(ast.AstDecl.Unsafe inner-box)
      (doc-macro-import-examples-from-decl
        ctx
        (__tl-box-place inner-box)
        examples)]
    [(ast.AstDecl.ModuleBody _ body-box)
      (doc-macro-import-examples-from-decls-into
        ctx
        (__tl-box-place body-box)
        examples)]
    [_ unit]))

(define (doc-macro-import-examples-from-decls-into
  [ctx : DocExpandContext]
  [decls : ast.AstDeclList]
  [examples : (&mut examples doc_macro_import_example_vec.Vec)]) : unit
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) unit]
    [(ast.AstDeclListStep.Cons decl rest)
      (begin
        (doc-macro-import-examples-from-decl ctx decl examples)
        (doc-macro-import-examples-from-decls-into ctx rest examples))]))

(define (doc-macro-import-examples-from-decls
  [ctx : DocExpandContext]
  [decls : ast.AstDeclList]) : doc_macro_import_example_vec.Vec
  (let
    [examples : doc_macro_import_example_vec.Vec
      (doc_macro_import_example_vec.new)]
    (begin
      (doc-macro-import-examples-from-decls-into ctx decls (&mut examples))
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
      [example : DocGeneratedTargetExample (array-ref examples.slots index)]
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
        (doc-generated-target-example-mut-find examples target))
      0))
    unit
    (doc_generated_target_example_vec.push-ref!
      examples
      (DocGeneratedTargetExample target form))))

(define (doc-generated-target-examples-from-decl
  [ctx : DocExpandContext]
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
                    (doc-import-alias-string ctx alias))]
                (doc-generated-target-example-add!
                  targets
                  (doc-expand-source-name ctx target-module)
                  form))]
            [(ast.AstMaybeModuleName.No) unit])]
        [_ unit])]
    [(ast.AstDecl.Unsafe inner-box)
      (doc-generated-target-examples-from-decl
        ctx
        (__tl-box-place inner-box)
        macro-examples
        targets)]
    [(ast.AstDecl.ModuleBody _ body-box)
      (doc-generated-target-examples-from-decls-into
        ctx
        (__tl-box-place body-box)
        macro-examples
        targets)]
    [_ unit]))

(define (doc-generated-target-examples-from-decls-into
  [ctx : DocExpandContext]
  [decls : ast.AstDeclList]
  [macro-examples : doc_macro_import_example_vec.Vec]
  [targets : (&mut targets doc_generated_target_example_vec.Vec)]) : unit
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) unit]
    [(ast.AstDeclListStep.Cons decl rest)
      (begin
        (doc-generated-target-examples-from-decl
          ctx
          decl
          macro-examples
          targets)
        (doc-generated-target-examples-from-decls-into
          ctx
          rest
          macro-examples
          targets))]))

(define (doc-generated-target-examples-from-decls
  [ctx : DocExpandContext]
  [decls : ast.AstDeclList]
  [macro-examples : doc_macro_import_example_vec.Vec]) : doc_generated_target_example_vec.Vec
  (let
    [targets : doc_generated_target_example_vec.Vec
      (doc_generated_target_example_vec.new)]
    (begin
      (doc-generated-target-examples-from-decls-into
        ctx
        decls
        macro-examples
        (&mut targets))
      targets)))

(define (doc-ast-maybe-type-source
  [ctx : DocExpandContext]
  [maybe-ty : ast.AstMaybeType]) : String
  (match maybe-ty
    [(ast.AstMaybeType.No) ""]
    [(ast.AstMaybeType.Some ty) (doc-cat2 " : " (doc-ast-type-source ctx ty))]))

(define (doc-ast-param-source [ctx : DocExpandContext] [param : ast.AstParam]) : String
  (match param
    [(ast.AstParam.Param name ty _ consume?)
      (if consume?
        (doc-cat6
          "["
          (doc-expand-source-name ctx name)
          " : "
          (doc-ast-type-source ctx ty)
          " (:consume)"
          "]")
        (doc-cat5
          "["
          (doc-expand-source-name ctx name)
          " : "
          (doc-ast-type-source ctx ty)
          "]"))]))

(define (doc-ast-param-list-source-from
  [ctx : DocExpandContext]
  [params : ast.AstParamList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      " "
      (doc-ast-param-source
        ctx
        (ast.ast-param-list-get
          (& params)
          index
          (ast.AstParam.Param 0 (ast.AstType.Unit) false false)))
      (doc-ast-param-list-source-from ctx params (+ index 1) count))))

(define (doc-ast-param-list-source
  [ctx : DocExpandContext]
  [params : ast.AstParamList]) : String
  (doc-ast-param-list-source-from
    ctx
    params
    0
    (ast.ast-param-list-len (& params))))

(define (doc-ast-macro-type-kind-items-source-from
  [ctx : DocExpandContext]
  [kinds : (& kinds ast.AstMacroTypeKindList)]
  [index : i64]) : String
  (if (>= index (ast.ast-macro-type-kind-list-len kinds))
    ""
    (doc-cat3
      " "
      (doc-expand-source-name
        ctx
        (ast.ast-macro-type-kind-list-get kinds index 0))
      (doc-ast-macro-type-kind-items-source-from ctx kinds (+ index 1)))))

(define (doc-ast-macro-type-kind-constraint-source
  [ctx : DocExpandContext]
  [kinds : (& kinds ast.AstMacroTypeKindList)]) : String
  (if (ast.ast-macro-type-kind-list-empty? kinds)
    ""
    (doc-cat3
      " (:kind"
      (doc-ast-macro-type-kind-items-source-from ctx kinds 0)
      ")")))

(define (doc-ast-macro-param-source
  [ctx : DocExpandContext]
  [param : ast.AstMacroParam]) : String
  (match param
    [(ast.AstMacroParam.Param name ty _ type-kinds)
      (doc-cat6
        "["
        (doc-expand-source-name ctx name)
        " : "
        (doc-ast-type-source ctx ty)
        (doc-ast-macro-type-kind-constraint-source ctx (& type-kinds))
        "]")]))

(define (doc-ast-macro-param-list-source-from
  [ctx : DocExpandContext]
  [params : ast.AstMacroParamList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      " "
      (doc-ast-macro-param-source
        ctx
        (ast.ast-macro-param-list-get
          (& params)
          index
          (ast.ast-macro-param-fallback)))
      (doc-ast-macro-param-list-source-from ctx params (+ index 1) count))))

(define (doc-ast-macro-param-list-source
  [ctx : DocExpandContext]
  [params : ast.AstMacroParamList]) : String
  (doc-ast-macro-param-list-source-from
    ctx
    params
    0
    (ast.ast-macro-param-list-len (& params))))

(define (doc-ast-field-source
  [ctx : DocExpandContext]
  [field : ast.AstFieldDef]) : String
  (match field
    [(ast.AstFieldDef.Def name ty _)
      (doc-cat5
        "\n  ("
        (doc-expand-source-name ctx (ci.intern-syntax-id-value name))
        " "
        (doc-ast-type-source ctx ty)
        ")")]))

(define (doc-ast-field-list-source-from
  [ctx : DocExpandContext]
  [fields : ast.AstFieldDefList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat2
      (doc-ast-field-source
        ctx
        (ast.ast-field-def-list-get
          (& fields)
          index
          (ast.ast-field-def-fallback)))
      (doc-ast-field-list-source-from ctx fields (+ index 1) count))))

(define (doc-ast-field-list-source
  [ctx : DocExpandContext]
  [fields : ast.AstFieldDefList]) : String
  (doc-ast-field-list-source-from
    ctx
    fields
    0
    (ast.ast-field-def-list-len (& fields))))

(define (doc-ast-variant-payload-source-from
  [ctx : DocExpandContext]
  [fields : ast.AstTypeList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      " "
      (doc-ast-type-id-source ctx (ast.ast-type-list-get (& fields) index 0))
      (doc-ast-variant-payload-source-from ctx fields (+ index 1) count))))

(define (doc-ast-variant-source
  [ctx : DocExpandContext]
  [variant : ast.AstVariantDef]) : String
  (match variant
    [(ast.AstVariantDef.Def name fields _)
      (doc-cat4
        "\n  ("
        (doc-expand-source-name ctx name)
        (doc-ast-variant-payload-source-from
          ctx
          fields
          0
          (ast.ast-type-list-len (& fields)))
        ")")]))

(define (doc-ast-variant-list-source-from
  [ctx : DocExpandContext]
  [variants : ast.AstVariantDefList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat2
      (doc-ast-variant-source
        ctx
        (ast.ast-variant-def-list-get
          (& variants)
          index
          (ast.AstVariantDef.Def
            0
            (ast.ast-type-list-new)
            (ast.ast-variant-payload-cleanup-list-new))))
      (doc-ast-variant-list-source-from ctx variants (+ index 1) count))))

(define (doc-ast-variant-list-source
  [ctx : DocExpandContext]
  [variants : ast.AstVariantDefList]) : String
  (doc-ast-variant-list-source-from
    ctx
    variants
    0
    (ast.ast-variant-def-list-len (& variants))))

(define (doc-ast-define-signature
  [ctx : DocExpandContext]
  [name : i64]
  [maybe-ty : ast.AstMaybeType]) : String
  (doc-cat4
    "(define "
    (doc-expand-source-name ctx name)
    (doc-ast-maybe-type-source ctx maybe-ty)
    " ...)"))

(define (doc-ast-function-signature
  [ctx : DocExpandContext]
  [name : i64]
  [params : ast.AstParamList]
  [ret : ast.AstType]) : String
  (doc-cat6
    "(define ("
    (doc-expand-source-name ctx name)
    (doc-ast-param-list-source ctx params)
    ") : "
    (doc-ast-type-source ctx ret)
    " ...)"))

(define (doc-ast-macro-signature
  [ctx : DocExpandContext]
  [name : i64]
  [params : ast.AstMacroParamList]
  [ret : ast.AstType]) : String
  (doc-cat6
    "(defmacro ("
    (doc-expand-source-name ctx name)
    (doc-ast-macro-param-list-source ctx params)
    ") : "
    (doc-ast-type-source ctx ret)
    " ...)"))

(define (doc-ast-struct-signature
  [ctx : DocExpandContext]
  [name : i64]
  [lifetimes : String]
  [fields : ast.AstFieldDefList]) : String
  (doc-cat5
    "(defstruct "
    (doc-expand-source-name ctx name)
    lifetimes
    (doc-ast-field-list-source ctx fields)
    ")"))

(define (doc-ast-enum-signature
  [ctx : DocExpandContext]
  [name : i64]
  [lifetimes : String]
  [variants : ast.AstVariantDefList]) : String
  (doc-cat5
    "(defenum "
    (doc-expand-source-name ctx name)
    lifetimes
    (doc-ast-variant-list-source ctx variants)
    ")"))

(define (doc-ast-extern-signature
  [ctx : DocExpandContext]
  [name : i64]
  [ty : ast.AstType]) : String
  (doc-cat5
    "(extern "
    (doc-expand-source-name ctx name)
    " : "
    (doc-ast-type-source ctx ty)
    ")"))

(define (doc-ast-decl-item [ctx : DocExpandContext] [decl : ast.AstDecl]) : DocMaybeItem
  (match decl
    [(ast.AstDecl.Def decl-meta name maybe-ty _)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.Define)
          (doc-expand-source-name ctx name)
          ""
          (doc-ast-define-signature ctx name maybe-ty)))]
    [(ast.AstDecl.DefFn decl-meta name params ret _ _)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.Function)
          (doc-expand-source-name ctx name)
          ""
          (doc-ast-function-signature ctx name params ret)))]
    [(ast.AstDecl.DefMacro decl-meta name params ret _)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefMacro)
          (doc-expand-source-name ctx name)
          ""
          (doc-ast-macro-signature ctx name params ret)))]
    [(ast.AstDecl.Extern decl-meta name _ _ ty)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.Extern)
          (doc-expand-source-name ctx name)
          ""
          (doc-ast-extern-signature ctx name ty)))]
    [(ast.AstDecl.DefEnum decl-meta name _ variants)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefEnum)
          (doc-expand-source-name ctx name)
          ""
          (doc-ast-enum-signature ctx name "" variants)))]
    [(ast.AstDecl.DefEnumLifetimes decl-meta name lifetimes _ variants)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefEnum)
          (doc-expand-source-name ctx name)
          ""
          (doc-ast-enum-signature
            ctx
            name
            (doc-ast-lifetime-list-source ctx lifetimes)
            variants)))]
    [(ast.AstDecl.DefStruct decl-meta name _ _ fields)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefStruct)
          (doc-expand-source-name ctx name)
          ""
          (doc-ast-struct-signature ctx name "" fields)))]
    [(ast.AstDecl.DefStructLifetimes decl-meta name lifetimes _ _ fields)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefStruct)
          (doc-expand-source-name ctx name)
          ""
          (doc-ast-struct-signature
            ctx
            name
            (doc-ast-lifetime-list-source ctx lifetimes)
            fields)))]
    [(ast.AstDecl.Unsafe inner-box)
      (doc-ast-decl-item ctx (__tl-box-place inner-box))]
    [_ (DocMaybeItem.No)]))

(define (doc-ast-generated-decl-item
  [ctx : DocExpandContext]
  [decl : ast.AstDecl]) : DocMaybeItem
  (match (ast.ast-decl-generated-meta decl)
    [(ast.AstGeneratedDeclMeta.Some _ _ _ _) (doc-ast-decl-item ctx decl)]
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
      (doc_item_vec.push-ref! out (doc_extract.doc-item-list-ref items index))
      (doc-generated-copy-items out items (+ index 1) count))))

(define (doc-generated-module-items [form : String] [items : doc_item_vec.Vec]) : doc_item_vec.Vec
  (let
    [count : i64 (doc_extract.doc-item-list-count items)]
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
    [form : String (doc-generated-target-example-find (& targets) module-name)]
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
  [ctx : DocExpandContext]
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
        (match (ast.ast-decl-list-step cursor)
          [(ast.AstDeclListStep.Nil)
            (begin
              (doc-generated-flush-module!
                current-module
                items
                has-generated
                targets
                (&mut modules))
              (set! done true))]
          [(ast.AstDeclListStep.Cons decl rest)
            (begin
              (match decl
                [(ast.AstDecl.Module next-module)
                  (begin
                    (doc-generated-flush-module!
                      current-module
                      items
                      has-generated
                      targets
                      (&mut modules))
                    (set!
                      current-module
                      (let
                        [source-id : i64
                          (ci.intern-syntax-source-name-id-or next-module -1)]
                        (if (>= source-id 0)
                          (doc-expand-source-name ctx source-id)
                          "<structural-module>")))
                    (set! items (doc_item_vec.new))
                    (set! has-generated false))]
                [_
                  (match (doc-ast-generated-decl-item ctx decl)
                    [(DocMaybeItem.Some item)
                      (begin
                        (doc_item_vec.push-ref! (&mut items) item)
                        (set! has-generated true))]
                    [(DocMaybeItem.No) unit])])
              (set! cursor rest))]))
      modules)))

(define (doc-expanded-generated-modules-from-loaded-decls-with-state-and-pools-and-intern-state
  [load-state : compiler_load.CompilerLoadSessionState]
  [job-state : tc.TcJobState]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [stdlib-roots : doc_svec.Vec]
  [pools : ast.AstNodePoolContext]
  [intern-state : ci.InternCompatState]) : ResultDocExpandedModules
  (let
    [ctx : DocExpandContext
      (doc-expand-context-from-pools-and-intern-state pools intern-state)]
    [macro-examples : doc_macro_import_example_vec.Vec
      (doc-macro-import-examples-from-decls ctx decls)]
    (match (compiler_typecheck_api.typecheck-compiler-doc-expand-program-with-paths-and-load-state-and-job-state-and-pools-and-intern-state
      load-state
      job-state
      (ast.ast-program decls)
      paths
      stdlib-roots
      pools
      intern-state)
      [(compiler_typecheck_api.ResultCompilerDocExpand.Ok expanded _)
        (match expanded
          [(ast.AstProgram.Program expanded-box)
            (let
              [expanded-decls : ast.AstDeclList (__tl-box-place expanded-box)]
              [targets : doc_generated_target_example_vec.Vec
                (doc-generated-target-examples-from-decls
                  ctx
                  expanded-decls
                  macro-examples)]
              (ResultDocExpandedModules.Ok
                (doc-generated-modules-from-expanded-decls
                  ctx
                  expanded-decls
                  targets)))])]
      [(compiler_typecheck_api.ResultCompilerDocExpand.Err diag)
        (ResultDocExpandedModules.Err
          (cdiag.compiler-diagnostic-render (__tl-box-place diag)))])))

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

(define (doc-expanded-generated-modules-from-source-docs-with-state-and-pools-and-intern-state
  [load-state : compiler_load.CompilerLoadSessionState]
  [job-state : tc.TcJobState]
  [source-path : String]
  [docs : doc_extract.DocExtraction]
  [stdlib-roots : doc_svec.Vec]
  [pools : ast.AstNodePoolContext]
  [intern-state : ci.InternCompatState]) : ResultDocExpandedModules
  (match docs
    [(doc_extract.DocExtraction.Extraction module-doc _)
      (let
        [scan : DocImportFormScan (doc-import-forms-from-doc-text module-doc)]
        (if (not scan.has-macro)
          (ResultDocExpandedModules.Ok (doc_module_vec.new))
          (begin
            (compiler_load.compiler-load-session-state-use-with-intern-state!
              load-state
              intern-state)
            (ast.ast-node-pool-context-install! pools)
            (ci.intern-compat-state-install! intern-state)
            (let
              [loaded : compiler_load.ResultCompilerLoadWithPaths
                (compiler_load.compiler-load-source-with-paths-and-roots-expect-cfg-with-pools
                  load-state
                  (doc-cat2 source-path ".doc-examples.tl")
                  (doc-expanded-example-source scan.forms)
                  (sym_i64_env.sym-i64-empty)
                  stdlib-roots
                  ast.AstMaybeModuleName.No
                  (parser.compiler-cfg-empty)
                  pools)]
              (begin
                (ast.ast-node-pool-context-capture-active! pools)
                (ci.intern-compat-state-capture-from-globals! intern-state)
                (match loaded
                  [(compiler_load.ResultCompilerLoadWithPaths.Ok
                      decls
                      paths
                      _
                      _)
                    (doc-expanded-generated-modules-from-loaded-decls-with-state-and-pools-and-intern-state
                      load-state
                      job-state
                      decls
                      paths
                      stdlib-roots
                      pools
                      intern-state)]
                  [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
                    (ResultDocExpandedModules.Err
                      (cdiag.compiler-diagnostic-render (__tl-box-place diag)))]))))))]))

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

(define (doc-expand-macro-type-kind-constraint-source-smoke?) : bool
  (let
    [parsed : parser.ResultAstProgram
      (parser.parse-ast-source
        "(defmacro (catalog [T : type (:kind i64 struct)]) : Module unit)")]
    [ctx : DocExpandContext
      (doc-expand-context-from-pools-and-intern-state
        (ast.ast-node-pool-context-capture-active)
        (ci.intern-compat-state-capture-active))]
    (match parsed
      [(parser.ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
        (match (ast.ast-decl-list-step (__tl-box-place decls-box))
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
                  ctx
                  (ast.ast-macro-param-list-get
                    (& params)
                    0
                    (ast.ast-macro-param-fallback)))
                "[T : type (:kind i64 struct)]"))]
          [_ false])]
      [(parser.ResultAstProgram.Err _) false])))

(test
  doc-macro-type-kind-constraint-source
  (unless
    (doc-expand-macro-type-kind-constraint-source-smoke?)
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
              (doc_render.doc-module-list-ref modules 0))
            "0")
          (string.eq
            (doc_render.doc-module-path
              (doc_render.doc-module-list-ref modules 5))
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
    [name-a : i64 (ci.intern-compat-state-intern intern-a "owner-a-name")]
    [name-b : i64 (ci.intern-compat-state-intern intern-b "decoy-b-name")]
    [pools-a : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 2)]
    [pools-b : ast.AstNodePoolContext
      (ast.ast-node-pool-context-new-with-capacities 4 2)]
    [type-a : i64
      (ast.ast-node-pool-context-type-push pools-a (ast.AstType.Struct name-a))]
    [type-b : i64
      (ast.ast-node-pool-context-type-push pools-b (ast.AstType.I64))]
    [expr-a : i64
      (ast.ast-node-pool-context-expr-push
        pools-a
        (ast.AstExpr.TypeLiteral type-a))]
    [expr-b : i64
      (ast.ast-node-pool-context-expr-push
        pools-b
        (ast.AstExpr.Literal (ast.ast-lit-int 99)))]
    [ctx-a : DocExpandContext
      (doc-expand-context-from-pools-and-intern-state pools-a intern-a)]
    [decoy-intern-before : i64 (ci.intern-compat-state-pool-len intern-b)]
    [decoy-exprs-before : i64 (ast.ast-node-pool-context-expr-len pools-b)]
    [decoy-types-before : i64 (ast.ast-node-pool-context-type-len pools-b)]
    [ok : bool false]
    (begin
      (ci.intern-compat-state-install! intern-b)
      (ast.ast-node-pool-context-install! pools-b)
      (set!
        ok
        (and
          (= name-a name-b)
          (= type-a type-b)
          (= expr-a expr-b)
          (string.eq (doc-ast-expr-source ctx-a expr-a) "(type owner-a-name)")
          (= (ci.intern-compat-state-pool-len intern-b) decoy-intern-before)
          (= (ast.ast-node-pool-context-expr-len pools-b) decoy-exprs-before)
          (= (ast.ast-node-pool-context-type-len pools-b) decoy-types-before)
          (=
            (ci.intern-active-table-id)
            (ci.intern-compat-state-table-id intern-b))
          (=
            (ast.ast-node-pool-active-expr-segment-bases)
            (ast.ast-node-pool-context-expr-segment-bases pools-b))
          (=
            (ast.ast-node-pool-reader-type-segment-bases)
            (ast.ast-node-pool-context-type-segment-bases pools-b))))
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
      (doc-expand-smoke-source)
      (sym_i64_env.sym-i64-empty)
      roots)
      [(compiler_load.ResultCompilerLoadWithPaths.Ok decls paths _ _)
        (let
          [pools : ast.AstNodePoolContext
            (ast.ast-node-pool-context-capture-active)]
          [intern-state : ci.InternCompatState
            (ci.intern-compat-state-capture-active)]
          (match (doc-expanded-generated-modules-from-loaded-decls-with-state-and-pools-and-intern-state
            (compiler_load.compiler-load-serial-test-session-state)
            (tc.tc-serial-job-state)
            decls
            paths
            roots
            pools
            intern-state)
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
              (io.panic (doc-cat2 "doc-expand: expansion failed: " message))]))]
      [(compiler_load.ResultCompilerLoadWithPaths.Err diag)
        (io.panic
          (doc-cat2
            "doc-expand: load failed: "
            (cdiag.compiler-diagnostic-render (__tl-box-place diag))))])))

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