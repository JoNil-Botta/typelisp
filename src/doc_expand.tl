;; doc_expand.tl - Expansion-aware generated-module docs.
(import stdlib.io)
(import stdlib.string)
(import sym_i64_env)
(import (vector.vector String) as doc_svec)
(import doc_render)
(import doc_extract)
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

(defstruct DocImportFormList
  (slots (Array String))
  (len i64))

(defstruct DocImportFormScan
  (forms DocImportFormList)
  (has-macro bool))

(defstruct DocMacroImportExample
  (alias String)
  (form String))

(defstruct DocMacroImportExampleList
  (slots (Array DocMacroImportExample))
  (len i64))

(defstruct DocGeneratedTargetExample
  (target String)
  (form String))

(defstruct DocGeneratedTargetExampleList
  (slots (Array DocGeneratedTargetExample))
  (len i64))

(defenum ResultDocExpandedModules
  (Ok doc_render.DocModuleList)
  (Err String))

(define (doc-import-form-list-slots [forms : (& forms DocImportFormList)]) : (&
    forms
    (Array String))
  (& (struct-get forms slots)))

(define (doc-import-form-list-len [forms : (& forms DocImportFormList)]) : i64
  (struct-get forms len))

(define (doc-import-form-list-with-capacity [capacity : i64]) : DocImportFormList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (DocImportFormList (make-array String cap) 0)))

(define (doc-import-form-list-new) : DocImportFormList
  (doc-import-form-list-with-capacity 4))

(define (doc-import-form-list-get
  [forms : (& forms DocImportFormList)]
  [index : i64]
  [fallback : String]) : String
  (if (if (>= index 0)
    (< index (doc-import-form-list-len forms))
    false)
    (array-ref (doc-import-form-list-slots forms) index)
    fallback))

(define (doc-import-form-list-copy-range
  [dst : (&mut dst (Array String))]
  [src : (& src (Array String))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (doc-import-form-list-copy-range dst src (+ index 1) count))))

(define (doc-import-form-list-grow [forms : (&mut forms DocImportFormList)]) : unit
  (let
    [n : i64 (struct-get forms len)]
    [old-cap : i64 (array-length (struct-get forms slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array String) (make-array String new-cap)]
    (begin
      (doc-import-form-list-copy-range
        (&mut bigger)
        (& (struct-get forms slots))
        0
        n)
      (set! (struct-get forms slots) bigger))))

(define (doc-import-form-list-push
  [forms : (&mut forms DocImportFormList)]
  [form : String]) : unit
  (begin
    (if (< (struct-get forms len) (array-length (struct-get forms slots)))
      unit
      (doc-import-form-list-grow forms))
    (let
      [index : i64 (struct-get forms len)]
      (begin
        (array-set! (struct-get forms slots) index form)
        (set! (struct-get forms len) (+ index 1))))))

(define (doc-macro-import-example-list-slots
  [examples : (& examples DocMacroImportExampleList)]) : (&
    examples
    (Array DocMacroImportExample))
  (& (struct-get examples slots)))

(define (doc-macro-import-example-list-len
  [examples : (& examples DocMacroImportExampleList)]) : i64
  (struct-get examples len))

(define (doc-macro-import-example-list-with-capacity [capacity : i64]) : DocMacroImportExampleList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (DocMacroImportExampleList (make-array DocMacroImportExample cap) 0)))

(define (doc-macro-import-example-list-new) : DocMacroImportExampleList
  (doc-macro-import-example-list-with-capacity 4))

(define (doc-macro-import-example-list-get
  [examples : (& examples DocMacroImportExampleList)]
  [index : i64]
  [fallback : DocMacroImportExample]) : DocMacroImportExample
  (if (if (>= index 0)
    (< index (doc-macro-import-example-list-len examples))
    false)
    (array-ref (doc-macro-import-example-list-slots examples) index)
    fallback))

(define (doc-macro-import-example-list-copy-range
  [dst : (&mut dst (Array DocMacroImportExample))]
  [src : (& src (Array DocMacroImportExample))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (doc-macro-import-example-list-copy-range dst src (+ index 1) count))))

(define (doc-macro-import-example-list-grow
  [examples : (&mut examples DocMacroImportExampleList)]) : unit
  (let
    [n : i64 (struct-get examples len)]
    [old-cap : i64 (array-length (struct-get examples slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array DocMacroImportExample)
      (make-array DocMacroImportExample new-cap)]
    (begin
      (doc-macro-import-example-list-copy-range
        (&mut bigger)
        (& (struct-get examples slots))
        0
        n)
      (set! (struct-get examples slots) bigger))))

(define (doc-macro-import-example-list-push
  [examples : (&mut examples DocMacroImportExampleList)]
  [example : DocMacroImportExample]) : unit
  (begin
    (if (< (struct-get examples len) (array-length (struct-get examples slots)))
      unit
      (doc-macro-import-example-list-grow examples))
    (let
      [index : i64 (struct-get examples len)]
      (begin
        (array-set! (struct-get examples slots) index example)
        (set! (struct-get examples len) (+ index 1))))))

(define (doc-generated-target-example-list-slots
  [examples : (& examples DocGeneratedTargetExampleList)]) : (&
    examples
    (Array DocGeneratedTargetExample))
  (& (struct-get examples slots)))

(define (doc-generated-target-example-list-len
  [examples : (& examples DocGeneratedTargetExampleList)]) : i64
  (struct-get examples len))

(define (doc-generated-target-example-list-with-capacity [capacity : i64]) : DocGeneratedTargetExampleList
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (DocGeneratedTargetExampleList (make-array DocGeneratedTargetExample cap) 0)))

(define (doc-generated-target-example-list-new) : DocGeneratedTargetExampleList
  (doc-generated-target-example-list-with-capacity 4))

(define (doc-generated-target-example-list-get
  [examples : (& examples DocGeneratedTargetExampleList)]
  [index : i64]
  [fallback : DocGeneratedTargetExample]) : DocGeneratedTargetExample
  (if (if (>= index 0)
    (< index (doc-generated-target-example-list-len examples))
    false)
    (array-ref (doc-generated-target-example-list-slots examples) index)
    fallback))

(define (doc-generated-target-example-list-copy-range
  [dst : (&mut dst (Array DocGeneratedTargetExample))]
  [src : (& src (Array DocGeneratedTargetExample))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! dst index (array-ref src index))
      (doc-generated-target-example-list-copy-range dst src (+ index 1) count))))

(define (doc-generated-target-example-list-grow
  [examples : (&mut examples DocGeneratedTargetExampleList)]) : unit
  (let
    [n : i64 (struct-get examples len)]
    [old-cap : i64 (array-length (struct-get examples slots))]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (Array DocGeneratedTargetExample)
      (make-array DocGeneratedTargetExample new-cap)]
    (begin
      (doc-generated-target-example-list-copy-range
        (&mut bigger)
        (& (struct-get examples slots))
        0
        n)
      (set! (struct-get examples slots) bigger))))

(define (doc-generated-target-example-list-push
  [examples : (&mut examples DocGeneratedTargetExampleList)]
  [example : DocGeneratedTargetExample]) : unit
  (begin
    (if (< (struct-get examples len) (array-length (struct-get examples slots)))
      unit
      (doc-generated-target-example-list-grow examples))
    (let
      [index : i64 (struct-get examples len)]
      (begin
        (array-set! (struct-get examples slots) index example)
        (set! (struct-get examples len) (+ index 1))))))

(define (doc-import-form-list-contains-from?
  [forms : (& forms DocImportFormList)]
  [form : String]
  [index : i64]
  [count : i64]) : bool
  (if (>= index count)
    false
    (if (string.eq (doc-import-form-list-get forms index "") form)
      true
      (doc-import-form-list-contains-from? forms form (+ index 1) count))))

(define (doc-import-form-list-contains?
  [forms : (& forms DocImportFormList)]
  [form : String]) : bool
  (doc-import-form-list-contains-from?
    forms
    form
    0
    (doc-import-form-list-len forms)))

(define (doc-import-form-list-mut-contains-from?
  [forms : (&mut forms DocImportFormList)]
  [form : String]
  [index : i64]) : bool
  (if (>= index (struct-get forms len))
    false
    (if (string.eq (array-ref (struct-get forms slots) index) form)
      true
      (doc-import-form-list-mut-contains-from? forms form (+ index 1)))))

(define (doc-import-form-list-mut-contains?
  [forms : (&mut forms DocImportFormList)]
  [form : String]) : bool
  (doc-import-form-list-mut-contains-from? forms form 0))

(define (doc-import-form-list-push-unique!
  [forms : (&mut forms DocImportFormList)]
  [form : String]) : unit
  (if (doc-import-form-list-mut-contains? forms form)
    unit
    (doc-import-form-list-push forms form)))

(define (doc-import-form-list-source-from
  [forms : DocImportFormList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
      (doc-import-form-list-get (& forms) index "")
      "\n"
      (doc-import-form-list-source-from forms (+ index 1) count))))

(define (doc-import-form-list-source [forms : DocImportFormList]) : String
  (doc-import-form-list-source-from
    forms
    0
    (doc-import-form-list-len (& forms))))

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
    (doc-cat3
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
    (doc-cat3
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
      (doc-cat3
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
      (doc-cat5
        "(-> "
        (doc-ast-type-list-source (box-get args-box))
        " "
        (doc-ast-type-id-source ret)
        ")")]
    [(AstType.Tuple elems-box)
      (doc-cat3 "(Tuple " (doc-ast-type-list-source (box-get elems-box)) ")")]
    [(AstType.Array elem size)
      (doc-cat5
        "(Array "
        (doc-ast-type-id-source elem)
        " "
        (string.int->string size)
        ")")]
    [(AstType.DynArray elem)
      (doc-cat3 "(Array " (doc-ast-type-id-source elem) ")")]
    [(AstType.Box elem) (doc-cat3 "(Box " (doc-ast-type-id-source elem) ")")]
    [(AstType.Region region elem)
      (doc-cat5 "(Region " region " " (doc-ast-type-id-source elem) ")")]
    [(AstType.Ref lifetime elem)
      (doc-cat5 "(& " lifetime " " (doc-ast-type-id-source elem) ")")]
    [(AstType.MutRef lifetime elem)
      (doc-cat5 "(&mut " lifetime " " (doc-ast-type-id-source elem) ")")]
    [(AstType.Enum name) (intern-str name)]
    [(AstType.EnumArgs name _) (intern-str name)]
    [(AstType.Struct name) (intern-str name)]
    [(AstType.StructArgs name _) (intern-str name)]
    [(AstType.Var name) (intern-str name)]
    [(AstType.VarArgs name _) (intern-str name)]
    [(AstType.Ptr elem) (doc-cat3 "(Ptr " (doc-ast-type-id-source elem) ")")]
    [(AstType.MutPtr elem)
      (doc-cat3 "(MutPtr " (doc-ast-type-id-source elem) ")")]))

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
    [(AstLiteral.String text)
      (doc-cat3 "\"" (doc-expand-escape-string text) "\"")]
    [(AstLiteral.Unit) "unit"]))

(define (doc-ast-expr-list-source-from
  [exprs : AstExprList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
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
      (doc-cat4
        "("
        (doc-ast-expr-source callee)
        (doc-ast-expr-list-source args)
        ")")]
    [(AstExpr.TypeLiteral ty) (doc-cat3 "(type " (doc-ast-type-source ty) ")")]
    [(AstExpr.Ann inner _) (doc-ast-expr-source inner)]
    [(AstExpr.Spanned inner _) (doc-ast-expr-source inner)]
    [_ "..."]))

(define (doc-macro-import-example-fallback) : DocMacroImportExample
  (DocMacroImportExample "" ""))

(define (doc-macro-import-example-push!
  [examples : (&mut examples DocMacroImportExampleList)]
  [alias : String]
  [form : String]) : unit
  (doc-macro-import-example-list-push
    examples
    (DocMacroImportExample alias form)))

(define (doc-macro-import-example-find-from
  [examples : (& examples DocMacroImportExampleList)]
  [alias : String]
  [index : i64]) : String
  (if (< index 0)
    ""
    (let
      [example : DocMacroImportExample
        (doc-macro-import-example-list-get
          examples
          index
          (doc-macro-import-example-fallback))]
      (if (string.eq (struct-get example alias) alias)
        (struct-get example form)
        (doc-macro-import-example-find-from examples alias (- index 1))))))

(define (doc-macro-import-example-find
  [examples : DocMacroImportExampleList]
  [alias : String]) : String
  (doc-macro-import-example-find-from
    (& examples)
    alias
    (- (doc-macro-import-example-list-len (& examples)) 1)))

(define (doc-macro-import-form [call-id : i64] [alias : AstMaybeImportAlias]) : String
  (match alias
    [(AstMaybeImportAlias.Some name)
      (doc-cat5 "(import " (doc-ast-expr-source call-id) " as " name ")")]
    [(AstMaybeImportAlias.No)
      (doc-cat3 "(import " (doc-ast-expr-source call-id) ")")]))

(define (doc-macro-import-examples-from-decl
  [decl : AstDecl]
  [examples : (&mut examples DocMacroImportExampleList)]) : unit
  (match decl
    [(AstDecl.Import (AstImportSpec.Spec kind _ _ alias _))
      (match kind
        [(AstImportKind.Macro call-id _)
          (doc-macro-import-example-push!
            examples
            (doc-import-alias-string alias)
            (doc-macro-import-form call-id alias))]
        [_ unit])]
    [(AstDecl.ComptimeDecl _ inner-box)
      (doc-macro-import-examples-from-decl (box-get inner-box) examples)]
    [(AstDecl.Unsafe inner-box)
      (doc-macro-import-examples-from-decl (box-get inner-box) examples)]
    [(AstDecl.ModuleBody _ body-box)
      (doc-macro-import-examples-from-decls-into (box-get body-box) examples)]
    [_ unit]))

(define (doc-macro-import-examples-from-decls-into
  [decls : AstDeclList]
  [examples : (&mut examples DocMacroImportExampleList)]) : unit
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) unit]
    [(AstDeclListStep.Cons decl rest)
      (begin
        (doc-macro-import-examples-from-decl decl examples)
        (doc-macro-import-examples-from-decls-into rest examples))]))

(define (doc-macro-import-examples-from-decls [decls : AstDeclList]) : DocMacroImportExampleList
  (let
    [examples : DocMacroImportExampleList (doc-macro-import-example-list-new)]
    (begin
      (doc-macro-import-examples-from-decls-into decls (&mut examples))
      examples)))

(define (doc-generated-target-example-fallback) : DocGeneratedTargetExample
  (DocGeneratedTargetExample "" ""))

(define (doc-generated-target-example-find-from
  [examples : (& examples DocGeneratedTargetExampleList)]
  [target : String]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (let
      [example : DocGeneratedTargetExample
        (doc-generated-target-example-list-get
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
  [examples : (& examples DocGeneratedTargetExampleList)]
  [target : String]) : String
  (doc-generated-target-example-find-from
    examples
    target
    0
    (doc-generated-target-example-list-len examples)))

(define (doc-generated-target-example-mut-find-from
  [examples : (&mut examples DocGeneratedTargetExampleList)]
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
  [examples : (&mut examples DocGeneratedTargetExampleList)]
  [target : String]) : String
  (doc-generated-target-example-mut-find-from examples target 0))

(define (doc-generated-target-example-add!
  [examples : (&mut examples DocGeneratedTargetExampleList)]
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
    (doc-generated-target-example-list-push
      examples
      (DocGeneratedTargetExample target form))))

(define (doc-generated-target-examples-from-decl
  [decl : AstDecl]
  [macro-examples : DocMacroImportExampleList]
  [targets : (&mut targets DocGeneratedTargetExampleList)]) : unit
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
                (doc-generated-target-example-add! targets target-module form))]
            [(AstMaybeModuleName.No) unit])]
        [_ unit])]
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
      (doc-generated-target-examples-from-decls-into
        (box-get body-box)
        macro-examples
        targets)]
    [_ unit]))

(define (doc-generated-target-examples-from-decls-into
  [decls : AstDeclList]
  [macro-examples : DocMacroImportExampleList]
  [targets : (&mut targets DocGeneratedTargetExampleList)]) : unit
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
  [macro-examples : DocMacroImportExampleList]) : DocGeneratedTargetExampleList
  (let
    [targets : DocGeneratedTargetExampleList
      (doc-generated-target-example-list-new)]
    (begin
      (doc-generated-target-examples-from-decls-into
        decls
        macro-examples
        (&mut targets))
      targets)))

(define (doc-ast-maybe-type-source [maybe-ty : AstMaybeType]) : String
  (match maybe-ty
    [(AstMaybeType.No) ""]
    [(AstMaybeType.Some ty) (doc-cat2 " : " (doc-ast-type-source ty))]))

(define (doc-ast-param-source [param : AstParam]) : String
  (match param
    [(AstParam.Param name ty _)
      (doc-cat5 "[" (intern-str name) " : " (doc-ast-type-source ty) "]")]))

(define (doc-ast-param-list-source-from
  [params : AstParamList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
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
      (doc-cat5 "[" (intern-str name) " : " (doc-ast-type-source ty) "]")]))

(define (doc-ast-macro-param-list-source-from
  [params : AstMacroParamList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat3
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
      (doc-cat5 "\n  (" (intern-str name) " " (doc-ast-type-source ty) ")")]))

(define (doc-ast-field-list-source-from
  [fields : AstFieldDefList]
  [index : i64]
  [count : i64]) : String
  (if (>= index count)
    ""
    (doc-cat2
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
    (doc-cat3
      " "
      (doc-ast-type-id-source (ast-type-list-get (& fields) index 0))
      (doc-ast-variant-payload-source-from fields (+ index 1) count))))

(define (doc-ast-variant-source [variant : AstVariantDef]) : String
  (match variant
    [(AstVariantDef.Def name fields _)
      (doc-cat4
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
    (doc-cat2
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
  (doc-cat4
    "(define "
    (intern-str name)
    (doc-ast-maybe-type-source maybe-ty)
    " ...)"))

(define (doc-ast-function-signature
  [name : i64]
  [params : AstParamList]
  [ret : AstType]) : String
  (doc-cat6
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
  (doc-cat6
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
  (doc-cat5
    "(defstruct "
    (intern-str name)
    lifetimes
    (doc-ast-field-list-source fields)
    ")"))

(define (doc-ast-enum-signature
  [name : i64]
  [lifetimes : String]
  [variants : AstVariantDefList]) : String
  (doc-cat5
    "(defenum "
    (intern-str name)
    lifetimes
    (doc-ast-variant-list-source variants)
    ")"))

(define (doc-ast-extern-signature [name : i64] [ty : AstType]) : String
  (doc-cat5 "(extern " (intern-str name) " : " (doc-ast-type-source ty) ")"))

(define (doc-ast-decl-item [decl : AstDecl]) : DocMaybeItem
  (match decl
    [(AstDecl.Def name maybe-ty _)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.Define)
          (intern-str name)
          ""
          (doc-ast-define-signature name maybe-ty)))]
    [(AstDecl.DefFn name params ret _ _)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.Function)
          (intern-str name)
          ""
          (doc-ast-function-signature name params ret)))]
    [(AstDecl.DefMacro name params ret _)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefMacro)
          (intern-str name)
          ""
          (doc-ast-macro-signature name params ret)))]
    [(AstDecl.Extern name _ _ ty)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.Extern)
          (intern-str name)
          ""
          (doc-ast-extern-signature name ty)))]
    [(AstDecl.DefEnum name _ variants)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefEnum)
          (intern-str name)
          ""
          (doc-ast-enum-signature name "" variants)))]
    [(AstDecl.DefEnumLifetimes name lifetimes _ variants)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefEnum)
          (intern-str name)
          ""
          (doc-ast-enum-signature
            name
            (doc-ast-lifetime-list-source lifetimes)
            variants)))]
    [(AstDecl.DefStruct name _ _ fields)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefStruct)
          (intern-str name)
          ""
          (doc-ast-struct-signature name "" fields)))]
    [(AstDecl.DefStructLifetimes name lifetimes _ _ fields)
      (DocMaybeItem.Some
        (doc_extract.DocItem.Item
          (doc_extract.DocItemKind.DefStruct)
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

(define (doc-generated-import-item [form : String]) : doc_extract.DocItem
  (doc_extract.DocItem.Item
    (doc_extract.DocItemKind.GeneratedImport)
    "import"
    "Concrete generated-module import that produced this API."
    form))

(define (doc-generated-copy-items
  [out : (&mut out doc_extract.DocItemList)]
  [items : doc_extract.DocItemList]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (doc_extract.doc-item-list-push
        out
        (doc_extract.doc-item-list-ref items index))
      (doc-generated-copy-items out items (+ index 1) count))))

(define (doc-generated-module-items
  [form : String]
  [items : doc_extract.DocItemList]) : doc_extract.DocItemList
  (let
    [count : i64 (doc_extract.doc-item-list-count items)]
    [out : doc_extract.DocItemList
      (doc_extract.doc-item-list-with-capacity (+ count 1))]
    (begin
      (doc_extract.doc-item-list-push
        (&mut out)
        (doc-generated-import-item form))
      (doc-generated-copy-items (&mut out) items 0 count)
      out)))

(define (doc-generated-flush-module!
  [module-name : String]
  [items : doc_extract.DocItemList]
  [has-generated : bool]
  [targets : DocGeneratedTargetExampleList]
  [modules : (&mut modules doc_render.DocModuleList)]) : unit
  (let
    [form : String (doc-generated-target-example-find (& targets) module-name)]
    (if (and
      has-generated
      (> (string.string-length module-name) 0)
      (> (string.string-length form) 0))
      (doc_render.doc-module-list-push
        modules
        (doc_render.DocModule.Module
          module-name
          (doc_extract.DocExtraction.Extraction
            "Generated module API."
            (doc-generated-module-items form items))))
      unit)))

(define (doc-generated-modules-from-expanded-decls
  [decls : AstDeclList]
  [targets : DocGeneratedTargetExampleList]) : doc_render.DocModuleList
  (let
    [cursor : AstDeclList decls]
    [current-module : String ""]
    [items : doc_extract.DocItemList (doc_extract.doc-item-list-new)]
    [has-generated : bool false]
    [modules : doc_render.DocModuleList (doc_render.doc-module-list-new)]
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
                    (set! items (doc_extract.doc-item-list-new))
                    (set! has-generated false))]
                [_
                  (match (doc-ast-generated-decl-item decl)
                    [(DocMaybeItem.Some item)
                      (begin
                        (doc_extract.doc-item-list-push (&mut items) item)
                        (set! has-generated true))]
                    [(DocMaybeItem.No) unit])])
              (set! cursor rest))]))
      modules)))

(define (doc-expanded-generated-modules-from-loaded-decls
  [decls : AstDeclList]
  [paths : AstDeclPathList]
  [stdlib-roots : doc_svec.Vec]) : ResultDocExpandedModules
  (let
    [macro-examples : DocMacroImportExampleList
      (doc-macro-import-examples-from-decls decls)]
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
                  macro-examples)]
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
    [forms : DocImportFormList (doc-import-form-list-new)]
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

(define (doc-expanded-example-source [forms : DocImportFormList]) : String
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
          (ResultDocExpandedModules.Ok (doc_render.doc-module-list-new))
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