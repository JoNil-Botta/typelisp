;; compiler_parse_core.tl - reader.Sexpr -> real compiler AST parser.
;;
;; This module targets `compiler_ast_types.tl`, not the smaller
;; compile_smoke AST. It stays parser-only: the later selfhost passes consume
;; the parsed `AstProgram` for typechecking/lowering.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.io)
(import compiler_intern as ci)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_cfg_core as cfg_core)
(import compiler_diagnostic as cdiag)
(import lex as lexer)
(import read as reader)
(import sym_i64_env)
(import stdlib.string)
(import stdlib.option)
(import stdlib.arena)
(import token)
(import (option.option i64) as option_i64)

(unsafe
  (extern (compiler-parse-runtime-copy-bytes!
    [dst : (MutPtr u8)]
    [src : (Ptr u8)]
    [count : i64]) : unit (:symbol "tl_memcpy")))

(defenum CompilerParseMaybeDeclSpan
  (Some ast.AstSourceSpan)
  (None))

(defenum CompilerParseSemanticOriginKind
  (TypeDefinition)
  (TypeName)
  (StructFieldDefinition)
  (EnumVariantDefinition)
  (StructFieldUse)
  (EnumVariantPattern)
  (DispatchFunction)
  (ModuleDefinition)
  (ModulePath)
  (ImportAlias)
  (ValueQualifier)
  (ValueName))

(defstruct CompilerParseSemanticOrigin
  (kind CompilerParseSemanticOriginKind)
  (written-name i64)
  (span ast.AstSourceSpan)
  (ordinal i64))

(defstruct CompilerParseSemanticOriginRun
  (start i64)
  (count i64))

(defenum CompilerParseMaybeSemanticOriginRun
  (Some CompilerParseSemanticOriginRun)
  (None))

(defstruct ParseSemanticOriginRecord
  (decl-slot i64)
  (kind-tag i64)
  (written-name i64)
  (start-line i64)
  (start-col i64)
  (end-line i64)
  (end-col i64))

(defstruct ParseSemanticOriginVec
  (items (__tl_dyn-array ParseSemanticOriginRecord))
  (len i64))

(define (parse-semantic-origin-vec-with-capacity [capacity : i64]) : ParseSemanticOriginVec
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (ParseSemanticOriginVec (__tl_make-array ParseSemanticOriginRecord cap) 0)))

(define (parse-semantic-origin-vec-grow!
  [items : (&mut items ParseSemanticOriginVec)]) : unit
  (let
    [old : (__tl_dyn-array ParseSemanticOriginRecord) items.items]
    [old-cap : i64 (array-length old)]
    [next : (__tl_dyn-array ParseSemanticOriginRecord)
      (__tl_make-array
        ParseSemanticOriginRecord
        (if (< old-cap 1)
          1
          (* old-cap 2)))]
    (begin
      (if (> items.len 0)
        (unsafe
          (compiler-parse-runtime-copy-bytes!
            (ptr-cast (__tl_array-data next) : (MutPtr u8))
            (ptr-cast (__tl_array-data old) : (Ptr u8))
            (* items.len 56)))
        unit)
      (set! items.items next))))

(define (parse-semantic-origin-vec-push!
  [items : (&mut items ParseSemanticOriginVec)]
  [origin : ParseSemanticOriginRecord]) : unit
  (begin
    (if (>= items.len (array-length items.items))
      (parse-semantic-origin-vec-grow! items)
      unit)
    (set! (array-ref items.items items.len) origin)
    (set! items.len (+ items.len 1))))

(defstruct CompilerParseSemanticOriginCaptureState
  (active bool)
  (vec-addr i64)
  (decl-slot i64)
  (name-view ci.InternSemanticNameView))

(define compiler-parse-semantic-origin-capture-active : bool
  false)
(define compiler-parse-semantic-origin-capture-vec-addr : i64
  0)
(define compiler-parse-semantic-origin-capture-decl-slot : i64
  0)
(define compiler-parse-semantic-origin-empty-name-view : (__tl_dyn-array
    ci.InternSemanticNameView)
  (__tl_make-array (ci.intern-semantic-name-view-empty)))
(define compiler-parse-semantic-origin-capture-name-view : (__tl_dyn-array
    ci.InternSemanticNameView)
  (__tl_make-array (ci.intern-semantic-name-view-empty)))
(define compiler-parse-semantic-quote-depth : i64
  0)

(define (compiler-parse-semantic-origin-empty-name-view-shared) : ci.InternSemanticNameView
  (unsafe
    (ptr-read
      (ptr-cast
        (__tl_array-data compiler-parse-semantic-origin-empty-name-view)
        : (Ptr ci.InternSemanticNameView)))))

(define (compiler-parse-semantic-origin-capture-name-view-shared) : ci.InternSemanticNameView
  (unsafe
    (ptr-read
      (ptr-cast
        (__tl_array-data compiler-parse-semantic-origin-capture-name-view)
        : (Ptr ci.InternSemanticNameView)))))

(define (compiler-parse-decl-origin-cache-reset!) : unit
  (begin
    (set! compiler-parse-semantic-origin-capture-active false)
    (set! compiler-parse-semantic-origin-capture-vec-addr 0)
    (set! compiler-parse-semantic-origin-capture-decl-slot 0)
    (set!
      (array-ref compiler-parse-semantic-origin-capture-name-view 0)
      (compiler-parse-semantic-origin-empty-name-view-shared))
    (set! compiler-parse-semantic-quote-depth 0)))

(define (compiler-parse-token-span-from-ast-span [span : ast.AstSourceSpan]) : token.SourceSpan
  (token.SourceSpan
    (ast.ast-source-span-start-line span)
    (ast.ast-source-span-start-col span)
    (ast.ast-source-span-end-line span)
    (ast.ast-source-span-end-col span)))

(define (compiler-parse-semantic-origin-kind-marker
  [kind : CompilerParseSemanticOriginKind]) : String
  (match kind
    [(CompilerParseSemanticOriginKind.TypeName)
      "__tl_semantic_origin_type_name"]
    [(CompilerParseSemanticOriginKind.TypeDefinition)
      "__tl_semantic_origin_type_definition"]
    [(CompilerParseSemanticOriginKind.StructFieldDefinition)
      "__tl_semantic_origin_struct_field_definition"]
    [(CompilerParseSemanticOriginKind.EnumVariantDefinition)
      "__tl_semantic_origin_enum_variant_definition"]
    [(CompilerParseSemanticOriginKind.StructFieldUse)
      "__tl_semantic_origin_struct_field_use"]
    [(CompilerParseSemanticOriginKind.EnumVariantPattern)
      "__tl_semantic_origin_enum_variant_pattern"]
    [(CompilerParseSemanticOriginKind.DispatchFunction)
      "__tl_semantic_origin_dispatch_function"]
    [(CompilerParseSemanticOriginKind.ModuleDefinition)
      "__tl_semantic_origin_module_definition"]
    [(CompilerParseSemanticOriginKind.ModulePath)
      "__tl_semantic_origin_module_path"]
    [(CompilerParseSemanticOriginKind.ImportAlias)
      "__tl_semantic_origin_import_alias"]
    [(CompilerParseSemanticOriginKind.ValueQualifier)
      "__tl_semantic_origin_value_qualifier"]
    [(CompilerParseSemanticOriginKind.ValueName)
      "__tl_semantic_origin_value_name"]))

(define (compiler-parse-semantic-origin-kind-tag
  [kind : CompilerParseSemanticOriginKind]) : i64
  (match kind
    [(CompilerParseSemanticOriginKind.TypeName) 1]
    [(CompilerParseSemanticOriginKind.TypeDefinition) 0]
    [(CompilerParseSemanticOriginKind.StructFieldDefinition) 2]
    [(CompilerParseSemanticOriginKind.EnumVariantDefinition) 3]
    [(CompilerParseSemanticOriginKind.StructFieldUse) 4]
    [(CompilerParseSemanticOriginKind.EnumVariantPattern) 5]
    [(CompilerParseSemanticOriginKind.DispatchFunction) 6]
    [(CompilerParseSemanticOriginKind.ModuleDefinition) 7]
    [(CompilerParseSemanticOriginKind.ModulePath) 8]
    [(CompilerParseSemanticOriginKind.ImportAlias) 9]
    [(CompilerParseSemanticOriginKind.ValueQualifier) 10]
    [(CompilerParseSemanticOriginKind.ValueName) 11]))

(define (compiler-parse-semantic-origin-kind-tag-from-marker [marker : String]) : i64
  (cond
    [(string.eq marker "__tl_semantic_origin_type_name") 1]
    [(string.eq marker "__tl_semantic_origin_type_definition") 0]
    [(string.eq marker "__tl_semantic_origin_struct_field_definition") 2]
    [(string.eq marker "__tl_semantic_origin_enum_variant_definition") 3]
    [(string.eq marker "__tl_semantic_origin_struct_field_use") 4]
    [(string.eq marker "__tl_semantic_origin_enum_variant_pattern") 5]
    [(string.eq marker "__tl_semantic_origin_dispatch_function") 6]
    [(string.eq marker "__tl_semantic_origin_module_definition") 7]
    [(string.eq marker "__tl_semantic_origin_module_path") 8]
    [(string.eq marker "__tl_semantic_origin_import_alias") 9]
    [(string.eq marker "__tl_semantic_origin_value_qualifier") 10]
    [(string.eq marker "__tl_semantic_origin_value_name") 11]
    [else -1]))

(define (compiler-parse-semantic-origin-kind-from-tag [tag : i64]) : CompilerParseSemanticOriginKind
  (cond
    [(= tag 1) (CompilerParseSemanticOriginKind.TypeName)]
    [(= tag 0) (CompilerParseSemanticOriginKind.TypeDefinition)]
    [(= tag 2) (CompilerParseSemanticOriginKind.StructFieldDefinition)]
    [(= tag 3) (CompilerParseSemanticOriginKind.EnumVariantDefinition)]
    [(= tag 4) (CompilerParseSemanticOriginKind.StructFieldUse)]
    [(= tag 5) (CompilerParseSemanticOriginKind.EnumVariantPattern)]
    [(= tag 6) (CompilerParseSemanticOriginKind.DispatchFunction)]
    [(= tag 7) (CompilerParseSemanticOriginKind.ModuleDefinition)]
    [(= tag 8) (CompilerParseSemanticOriginKind.ModulePath)]
    [(= tag 9) (CompilerParseSemanticOriginKind.ImportAlias)]
    [(= tag 10) (CompilerParseSemanticOriginKind.ValueQualifier)]
    [else (CompilerParseSemanticOriginKind.ValueName)]))

(define (compiler-parse-semantic-origin-capture-current) : CompilerParseSemanticOriginCaptureState
  (CompilerParseSemanticOriginCaptureState
    compiler-parse-semantic-origin-capture-active
    compiler-parse-semantic-origin-capture-vec-addr
    compiler-parse-semantic-origin-capture-decl-slot
    (compiler-parse-semantic-origin-capture-name-view-shared)))

(define (compiler-parse-semantic-origin-capture-select!
  [items : (MutPtr ParseSemanticOriginVec)]
  [decl-slot : i64]) : unit
  (begin
    (set!
      compiler-parse-semantic-origin-capture-vec-addr
      (unsafe
        (cast (ptr->int (ptr-cast items : (Ptr u8))) : i64)))
    (set! compiler-parse-semantic-origin-capture-decl-slot decl-slot)))

(define (compiler-parse-semantic-origin-capture-begin!
  [name-view : ci.InternSemanticNameView]
  [items : (MutPtr ParseSemanticOriginVec)]
  [decl-slot : i64]) : unit
  (begin
    (set! compiler-parse-semantic-origin-capture-active true)
    (set!
      (array-ref compiler-parse-semantic-origin-capture-name-view 0)
      name-view)
    (compiler-parse-semantic-origin-capture-select! items decl-slot)))

(define (compiler-parse-semantic-origin-capture-restore!
  [state : CompilerParseSemanticOriginCaptureState]) : unit
  (begin
    (set! compiler-parse-semantic-origin-capture-active state.active)
    (set! compiler-parse-semantic-origin-capture-vec-addr state.vec-addr)
    (set! compiler-parse-semantic-origin-capture-decl-slot state.decl-slot)
    (set!
      (array-ref compiler-parse-semantic-origin-capture-name-view 0)
      state.name-view)))

(define (compiler-parse-semantic-origin-capture-end!) : unit
  (begin
    (set! compiler-parse-semantic-origin-capture-active false)
    (set! compiler-parse-semantic-origin-capture-vec-addr 0)
    (set! compiler-parse-semantic-origin-capture-decl-slot 0)
    (set!
      (array-ref compiler-parse-semantic-origin-capture-name-view 0)
      (compiler-parse-semantic-origin-empty-name-view-shared))))

(define (compiler-parse-semantic-origin-push-active!
  [kind : CompilerParseSemanticOriginKind]
  [written-name : i64]
  [span : token.SourceSpan]) : unit
  (if (> compiler-parse-semantic-quote-depth 0)
    unit
    (unsafe
      (let
        [items-ptr : (MutPtr ParseSemanticOriginVec)
          (int->ptr
            (cast compiler-parse-semantic-origin-capture-vec-addr : u64)
            : (MutPtr ParseSemanticOriginVec))]
        [items : ParseSemanticOriginVec (ptr-read items-ptr)]
        (begin
          (parse-semantic-origin-vec-push!
            (&mut items)
            (ParseSemanticOriginRecord
              compiler-parse-semantic-origin-capture-decl-slot
              (compiler-parse-semantic-origin-kind-tag kind)
              written-name
              (token.span-start-line span)
              (token.span-start-col span)
              (token.span-end-line span)
              (token.span-end-col span)))
          (ptr-write! items-ptr items))))))

(define (compiler-parse-semantic-origin-push!
  [kind : CompilerParseSemanticOriginKind]
  [written-name : i64]
  [span : token.SourceSpan]) : unit
  (if compiler-parse-semantic-origin-capture-active
    (compiler-parse-semantic-origin-push-active! kind written-name span)
    unit))

;; Dotted identifiers are one lexer token. Split their already-known token span
;; by byte offset (the lexer uses byte columns) without searching source text.
(define (compiler-parse-semantic-origin-push-components-with-view!
  [name-view : (& name-view ci.InternSemanticNameView)]
  [name : ci.InternSyntaxId]
  [span : token.SourceSpan]
  [prefix-kind : CompilerParseSemanticOriginKind]
  [final-kind : CompilerParseSemanticOriginKind]) : unit
  (let
    [syntax-name : i64 (ci.intern-syntax-id-value name)]
    [resolved-name : i64
      (if (ci.intern-renderable-id? syntax-name)
        syntax-name
        (ci.intern-syntax-source-name-id-or syntax-name -1))]
    ;; Loader dispatch qualifies resolved names as `module/base`, while the
    ;; span still covers only the source-written base. Dots in the internal
    ;; module path are therefore not semantic source components.
    [written-name : i64
      (if (and
        (>= resolved-name 0)
        (ci.intern-semantic-name-view-qualified? name-view resolved-name))
        (ci.intern-semantic-name-view-qualified-base-id name-view resolved-name)
        resolved-name)]
    (if (< written-name 0)
      unit
      (let
        [current : i64 written-name]
        [start-col : i64 (token.span-start-col span)]
        [first-dot : i64
          (ci.intern-semantic-name-view-first-dot name-view current)]
        (if (< first-dot 0)
          (let
            [text : String (ci.intern-semantic-name-view-str name-view current)]
            [n : i64 (string.string-length text)]
            (compiler-parse-semantic-origin-push-active!
              final-kind
              current
              (token.SourceSpan
                (token.span-start-line span)
                start-col
                (token.span-end-line span)
                (+ start-col n))))
          (let
            [done : bool false]
            (while (not done)
              (let
                [dot : i64
                  (ci.intern-semantic-name-view-first-dot name-view current)]
                (if (>= dot 0)
                  (begin
                    (compiler-parse-semantic-origin-push-active!
                      prefix-kind
                      (ci.intern-semantic-name-view-leading-dot-id
                        name-view
                        current)
                      (token.SourceSpan
                        (token.span-start-line span)
                        start-col
                        (token.span-end-line span)
                        (+ start-col dot)))
                    (set! start-col (+ (+ start-col dot) 1))
                    (set!
                      current
                      (ci.intern-semantic-name-view-dotted-tail-id
                        name-view
                        current)))
                  (let
                    [text : String
                      (ci.intern-semantic-name-view-str name-view current)]
                    [n : i64 (string.string-length text)]
                    (begin
                      (compiler-parse-semantic-origin-push-active!
                        final-kind
                        current
                        (token.SourceSpan
                          (token.span-start-line span)
                          start-col
                          (token.span-end-line span)
                          (+ start-col n)))
                      (set! done true))))))))))))

(define (compiler-parse-semantic-origin-push-components!
  [name : ci.InternSyntaxId]
  [span : token.SourceSpan]
  [prefix-kind : CompilerParseSemanticOriginKind]
  [final-kind : CompilerParseSemanticOriginKind]) : unit
  (if compiler-parse-semantic-origin-capture-active
    (let
      [name-view : ci.InternSemanticNameView
        (compiler-parse-semantic-origin-capture-name-view-shared)]
      (compiler-parse-semantic-origin-push-components-with-view!
        (& name-view)
        name
        span
        prefix-kind
        final-kind))
    unit))

(define (compiler-parse-semantic-dotted-field-origins!
  [name : ci.InternSyntaxId]
  [span : token.SourceSpan]) : unit
  (if compiler-parse-semantic-origin-capture-active
    (let
      [name-view : ci.InternSemanticNameView
        (compiler-parse-semantic-origin-capture-name-view-shared)]
      [syntax-name : i64 (ci.intern-syntax-id-value name)]
      [resolved-name : i64
        (if (ci.intern-renderable-id? syntax-name)
          syntax-name
          (ci.intern-syntax-source-name-id-or syntax-name -1))]
      [written-name : i64
        (if (and
          (>= resolved-name 0)
          (ci.intern-semantic-name-view-qualified? (& name-view) resolved-name))
          (ci.intern-semantic-name-view-qualified-base-id
            (& name-view)
            resolved-name)
          resolved-name)]
      (if (< written-name 0)
        unit
        (let
          [first-dot : i64
            (ci.intern-semantic-name-view-first-dot (& name-view) written-name)]
          (if (< first-dot 0)
            unit
            (let
              [fields-id : i64
                (ci.intern-semantic-name-view-dotted-tail-id
                  (& name-view)
                  written-name)]
              [fields-text : String
                (ci.intern-semantic-name-view-str (& name-view) fields-id)]
              [start-col : i64 (+ (token.span-start-col span) first-dot 1)]
              (begin
                (compiler-parse-semantic-origin-push-components!
                  name
                  span
                  (CompilerParseSemanticOriginKind.ValueQualifier)
                  (CompilerParseSemanticOriginKind.ValueName))
                (compiler-parse-semantic-origin-push-components!
                  (ci.intern-syntax-id-from-raw fields-id)
                  (token.SourceSpan
                    (token.span-start-line span)
                    start-col
                    (token.span-start-line span)
                    (+ start-col (string.string-length fields-text)))
                  (CompilerParseSemanticOriginKind.StructFieldUse)
                  (CompilerParseSemanticOriginKind.StructFieldUse))))))))
    unit))

(define (compiler-parse-decl-list-storage-key
  [decls : (& decls ast.AstDeclList)]) : i64
  (unsafe
    (cast (ptr->int (ptr-cast (__tl_array-data decls.slots) : (Ptr u8))) : i64)))

;; Every cold-pool scanner must jump over a semantic run as one record. Walking
;; its occurrence payload made the existing declaration/member-origin queries
;; proportional to every semantic token in the compilation and turned the
;; self-host bootstrap quadratic.
(define (compiler-parse-semantic-origin-next-record
  [cursor : i64]
  [limit : i64]) : i64
  (if (< (+ cursor 1) limit)
    (match (reader.spanned-sexpr-view (reader.sp-node-get cursor))
      [(reader.SpannedSexprView.Int _ marker _)
        (if (string.eq marker "__tl_semantic_origin")
          (match (reader.spanned-sexpr-view (reader.sp-node-get (+ cursor 1)))
            [(reader.SpannedSexprView.Int _ run-marker run-span)
              (let
                [count : i64 (token.span-start-line run-span)]
                [next : i64 (+ (+ cursor 2) count)]
                (if (and
                  (string.eq run-marker "__tl_semantic_origin_start")
                  (>= count 0)
                  (<= next limit))
                  next
                  (+ cursor 1)))]
            [_ (+ cursor 1)])
          (+ cursor 1))]
      [_ (+ cursor 1)])
    (+ cursor 1)))

;; Declaration origins are cold records in the transient spanned-node pool.
;; A run is marker(key), marker(start slot), then one Nil(span) per slot.
(define (compiler-parse-decl-origin-span-key-slot-depth
  [key : i64]
  [target : i64]
  [depth : i64]) : CompilerParseMaybeDeclSpan
  (let
    [cursor : i64 0]
    [limit : i64 (reader.sp-node-pool-len)]
    [result : CompilerParseMaybeDeclSpan (CompilerParseMaybeDeclSpan.None)]
    [alias-key : i64 0]
    [alias-slot : i64 0]
    [alias-found : bool false]
    (begin
      (while (< cursor limit)
        (begin
          (match (reader.spanned-sexpr-view (reader.sp-node-get cursor))
            [(reader.SpannedSexprView.Int record-key marker marker-span)
              (if (= record-key key)
                (if (and
                  (string.eq marker "__tl_decl_origin")
                  (< (+ cursor 2) limit))
                  (match (reader.spanned-sexpr-view
                    (reader.sp-node-get (+ cursor 1)))
                    [(reader.SpannedSexprView.Int run-start run-marker _)
                      (if (and
                        (= run-start target)
                        (string.eq run-marker "__tl_decl_origin_start"))
                        (match (reader.spanned-sexpr-view
                          (reader.sp-node-get (+ cursor 2)))
                          [(reader.SpannedSexprView.Nil span)
                            (begin
                              (set!
                                result
                                (CompilerParseMaybeDeclSpan.Some
                                  (ast-source-span-from-source-span span)))
                              (set! alias-found false))]
                          [_ unit])
                        unit)]
                    [_ unit])
                  (if (or
                    (string.eq marker "__tl_decl_origin_alias")
                    (string.eq marker "__tl_decl_origin_alias_repeat"))
                    (let
                      [alias-start : i64 (token.span-start-line marker-span)]
                      [alias-count : i64 (token.span-start-col marker-span)]
                      (if (and
                        (>= target alias-start)
                        (< target (+ alias-start alias-count)))
                        (begin
                          (set! alias-key (token.span-end-line marker-span))
                          (set!
                            alias-slot
                            (if (string.eq
                              marker
                              "__tl_decl_origin_alias_repeat")
                              (token.span-end-col marker-span)
                              (+
                                (token.span-end-col marker-span)
                                (- target alias-start))))
                          (set! alias-found true))
                        unit))
                    unit))
                unit)]
            [_ unit])
          (set!
            cursor
            (compiler-parse-semantic-origin-next-record cursor limit))))
      (if (and alias-found (< depth 64))
        (compiler-parse-decl-origin-span-key-slot-depth
          alias-key
          alias-slot
          (+ depth 1))
        result))))

(define (compiler-parse-decl-origin-span-key-slot [key : i64] [target : i64]) : CompilerParseMaybeDeclSpan
  (compiler-parse-decl-origin-span-key-slot-depth key target 0))

(define (compiler-parse-decl-origin-span
  [decls : (& decls ast.AstDeclList)]
  [slot : i64]) : CompilerParseMaybeDeclSpan
  (compiler-parse-decl-origin-span-key-slot
    (compiler-parse-decl-list-storage-key decls)
    (+ decls.offset slot)))

(define (compiler-parse-decl-origin-register-key-maybe!
  [key : i64]
  [slot : i64]
  [origin : CompilerParseMaybeDeclSpan]) : unit
  (match origin
    [(CompilerParseMaybeDeclSpan.Some span)
      (let
        [marker-span : token.SourceSpan
          (compiler-parse-token-span-from-ast-span span)]
        (begin
          (reader.sp-node-push
            (reader.SpannedSexpr.Int key "__tl_decl_origin" marker-span))
          (reader.sp-node-push
            (reader.SpannedSexpr.Int slot "__tl_decl_origin_start" marker-span))
          (reader.sp-node-push (reader.spanned-sexpr-empty marker-span))
          unit))]
    [(CompilerParseMaybeDeclSpan.None) unit]))

(define (compiler-parse-decl-origin-register-maybe!
  [decls : (& decls ast.AstDeclList)]
  [slot : i64]
  [origin : CompilerParseMaybeDeclSpan]) : unit
  (compiler-parse-decl-origin-register-key-maybe!
    (compiler-parse-decl-list-storage-key decls)
    (+ decls.offset slot)
    origin))

(define (compiler-parse-decl-origin-register-alias-record!
  [decls : (& decls ast.AstDeclList)]
  [decl-slot : i64]
  [count : i64]
  [source-key : i64]
  [source-slot : i64]
  [repeat : bool]) : unit
  (if (<= count 0)
    unit
    (begin
      (reader.sp-node-push
        (reader.SpannedSexpr.Int
          (compiler-parse-decl-list-storage-key decls)
          (if repeat
            "__tl_decl_origin_alias_repeat"
            "__tl_decl_origin_alias")
          (token.SourceSpan
            (+ decls.offset decl-slot)
            count
            source-key
            source-slot)))
      unit)))

(define (compiler-parse-decl-origin-copy-direct-records!
  [source : ast.AstDeclList]
  [dest : (& dest ast.AstDeclList)]
  [dest-slot : i64]
  [scan-start : i64]
  [scan-end : i64]) : unit
  (let
    [source-key : i64 (compiler-parse-decl-list-storage-key (& source))]
    [source-start : i64 source.offset]
    [source-end : i64 (+ source-start (ast.ast-decl-list-len (& source)))]
    [dest-key : i64 (compiler-parse-decl-list-storage-key dest)]
    [dest-start : i64 (+ dest.offset dest-slot)]
    [cursor : i64 scan-start]
    [limit : i64 scan-end]
    (while (< cursor limit)
      (begin
        (match (reader.spanned-sexpr-view (reader.sp-node-get cursor))
          [(reader.SpannedSexprView.Int record-key marker _)
            (if (= record-key source-key)
              (cond
                [(and
                    (string.eq marker "__tl_decl_origin")
                    (< (+ cursor 2) limit))
                  (match (reader.spanned-sexpr-view
                    (reader.sp-node-get (+ cursor 1)))
                    [(reader.SpannedSexprView.Int
                        record-slot
                        run-marker
                        marker-span)
                      (if (and
                        (string.eq run-marker "__tl_decl_origin_start")
                        (>= record-slot source-start)
                        (< record-slot source-end))
                        (begin
                          (reader.sp-node-push
                            (reader.SpannedSexpr.Int
                              dest-key
                              "__tl_decl_origin"
                              marker-span))
                          (reader.sp-node-push
                            (reader.SpannedSexpr.Int
                              (+ dest-start (- record-slot source-start))
                              "__tl_decl_origin_start"
                              marker-span))
                          (reader.sp-node-push
                            (reader.sp-node-get (+ cursor 2)))
                          unit)
                        unit)]
                    [_ unit])]
                [(and
                    (string.eq marker "__tl_semantic_origin")
                    (< (+ cursor 1) limit))
                  (match (reader.spanned-sexpr-view
                    (reader.sp-node-get (+ cursor 1)))
                    [(reader.SpannedSexprView.Int
                        record-slot
                        run-marker
                        run-span)
                      (let
                        [count : i64 (token.span-start-line run-span)]
                        (if (and
                          (string.eq run-marker "__tl_semantic_origin_start")
                          (>= record-slot source-start)
                          (< record-slot source-end)
                          (>= count 0)
                          (<= (+ (+ cursor 2) count) limit))
                          (let
                            [record-index : i64 0]
                            (begin
                              (reader.sp-node-push
                                (reader.SpannedSexpr.Int
                                  dest-key
                                  "__tl_semantic_origin"
                                  run-span))
                              (reader.sp-node-push
                                (reader.SpannedSexpr.Int
                                  (+ dest-start (- record-slot source-start))
                                  "__tl_semantic_origin_start"
                                  run-span))
                              (while (< record-index count)
                                (begin
                                  (reader.sp-node-push
                                    (reader.sp-node-get
                                      (+ (+ cursor 2) record-index)))
                                  (set! record-index (+ record-index 1))))))
                          unit))]
                    [_ unit])]
                [else unit])
              unit)]
          [_ unit])
        (set! cursor (compiler-parse-semantic-origin-next-record cursor limit))))))

(define (compiler-parse-decl-origin-register-list-aliases!
  [decls : (& decls ast.AstDeclList)]
  [decl-slot : i64]
  [source : ast.AstDeclList]) : unit
  (compiler-parse-decl-origin-register-alias-record!
    decls
    decl-slot
    (ast.ast-decl-list-len (& source))
    (compiler-parse-decl-list-storage-key (& source))
    source.offset
    false))

(defstruct CompilerParseDeclOriginAlias
  (target-start i64)
  (count i64)
  (source-key i64)
  (source-slot i64))

(defstruct CompilerParseDeclOriginAliasVec
  (items (__tl_dyn-array CompilerParseDeclOriginAlias))
  (len i64))

(define (compiler-parse-decl-origin-alias-vec-with-capacity [capacity : i64]) : CompilerParseDeclOriginAliasVec
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (CompilerParseDeclOriginAliasVec
      (__tl_make-array CompilerParseDeclOriginAlias cap)
      0)))

(define (compiler-parse-decl-origin-alias-vec-grow!
  [aliases : (&mut aliases CompilerParseDeclOriginAliasVec)]) : unit
  (let
    [old-items : (__tl_dyn-array CompilerParseDeclOriginAlias) aliases.items]
    [len : i64 aliases.len]
    [next-items : (__tl_dyn-array CompilerParseDeclOriginAlias)
      (__tl_make-array
        CompilerParseDeclOriginAlias
        (* (array-length old-items) 2))]
    [index : i64 0]
    (begin
      (while (< index len)
        (let
          [item : CompilerParseDeclOriginAlias (array-ref old-items index)]
          (begin
            (set!
              (array-ref next-items index)
              (CompilerParseDeclOriginAlias
                item.target-start
                item.count
                item.source-key
                item.source-slot))
            (set! index (+ index 1)))))
      (set! aliases.items next-items))))

(define (compiler-parse-decl-origin-alias-vec-extend-last?
  [aliases : (&mut aliases CompilerParseDeclOriginAliasVec)]
  [target-start : i64]
  [count : i64]
  [source-key : i64]
  [source-slot : i64]
  [repeat : bool]) : bool
  (if (or repeat (<= aliases.len 0))
    false
    (let
      [index : i64 (- aliases.len 1)]
      [last : CompilerParseDeclOriginAlias (array-ref aliases.items index)]
      (if (and
        (>= last.source-slot 0)
        (= last.source-key source-key)
        (= (+ last.target-start last.count) target-start)
        (= (+ last.source-slot last.count) source-slot))
        (begin
          (set!
            (array-ref aliases.items index)
            (CompilerParseDeclOriginAlias
              last.target-start
              (+ last.count count)
              last.source-key
              last.source-slot))
          true)
        false))))

(define (compiler-parse-decl-origin-alias-vec-push-key-slot!
  [aliases : (&mut aliases CompilerParseDeclOriginAliasVec)]
  [target-start : i64]
  [count : i64]
  [source-key : i64]
  [source-slot : i64]
  [source-decl : ast.AstDecl]
  [repeat : bool]) : unit
  (if (and
    (> count 0)
    (or
      (compiler-parse-decl-origin-needs-record? source-decl)
      ;; A normal alias may carry a semantic sidecar even when this declaration
      ;; kind has no declaration-span record. Register it conservatively: runs
      ;; are queried lazily, contiguous aliases coalesce below, and this avoids
      ;; an O(declarations^2) pool scan while constructing compiler programs.
      (not repeat)))
    (if (compiler-parse-decl-origin-alias-vec-extend-last?
      aliases
      target-start
      count
      source-key
      source-slot
      repeat)
      unit
      (begin
        (if (>= aliases.len (array-length aliases.items))
          (compiler-parse-decl-origin-alias-vec-grow! aliases)
          unit)
        (let
          [index : i64 aliases.len]
          (begin
            (set!
              (array-ref aliases.items index)
              (CompilerParseDeclOriginAlias
                target-start
                count
                source-key
                (if repeat
                  (- (- 0 source-slot) 1)
                  source-slot)))
            (set! aliases.len (+ index 1))))))
    unit))

(define (compiler-parse-decl-origin-alias-vec-register!
  [decls : (& decls ast.AstDeclList)]
  [aliases : (& aliases CompilerParseDeclOriginAliasVec)]) : unit
  (let
    [index : i64 0]
    (while (< index aliases.len)
      (let
        [alias : CompilerParseDeclOriginAlias (array-ref aliases.items index)]
        (begin
          (compiler-parse-decl-origin-register-alias-record!
            decls
            alias.target-start
            alias.count
            alias.source-key
            (if (< alias.source-slot 0)
              (- (- 0 alias.source-slot) 1)
              alias.source-slot)
            (< alias.source-slot 0))
          (set! index (+ index 1)))))))

;; Semantic occurrence runs are direct records keyed by declaration storage and
;; slot. A normal declaration-origin alias preserves the run; a repeat alias is
;; intentionally ignored because it represents a one-to-many generated rewrite
;; whose new declarations have no independent editable source occurrences.
(define (compiler-parse-semantic-origin-run-key-slot-depth
  [key : i64]
  [target : i64]
  [depth : i64]) : CompilerParseMaybeSemanticOriginRun
  (let
    [cursor : i64 0]
    [limit : i64 (reader.sp-node-pool-len)]
    [result : CompilerParseMaybeSemanticOriginRun
      (CompilerParseMaybeSemanticOriginRun.None)]
    [alias-key : i64 0]
    [alias-slot : i64 0]
    [alias-found : bool false]
    (begin
      (while (< cursor limit)
        (begin
          (match (reader.spanned-sexpr-view (reader.sp-node-get cursor))
            [(reader.SpannedSexprView.Int record-key marker marker-span)
              (if (= record-key key)
                (cond
                  [(and
                      (string.eq marker "__tl_semantic_origin")
                      (< (+ cursor 1) limit))
                    (match (reader.spanned-sexpr-view
                      (reader.sp-node-get (+ cursor 1)))
                      [(reader.SpannedSexprView.Int
                          run-slot
                          run-marker
                          run-span)
                        (if (and
                          (= run-slot target)
                          (string.eq run-marker "__tl_semantic_origin_start"))
                          (let
                            [count : i64 (token.span-start-line run-span)]
                            (if (and
                              (>= count 0)
                              (<= (+ (+ cursor 2) count) limit))
                              (begin
                                (set!
                                  result
                                  (CompilerParseMaybeSemanticOriginRun.Some
                                    (CompilerParseSemanticOriginRun
                                      (+ cursor 2)
                                      count)))
                                (set! alias-found false))
                              unit))
                          unit)]
                      [_ unit])]
                  [(string.eq marker "__tl_decl_origin_alias")
                    (let
                      [alias-start : i64 (token.span-start-line marker-span)]
                      [alias-count : i64 (token.span-start-col marker-span)]
                      (if (and
                        (>= target alias-start)
                        (< target (+ alias-start alias-count)))
                        (begin
                          (set! alias-key (token.span-end-line marker-span))
                          (set!
                            alias-slot
                            (+
                              (token.span-end-col marker-span)
                              (- target alias-start)))
                          (set! alias-found true))
                        unit))]
                  [else unit])
                unit)]
            [_ unit])
          (set!
            cursor
            (compiler-parse-semantic-origin-next-record cursor limit))))
      (if (and alias-found (< depth 64))
        (compiler-parse-semantic-origin-run-key-slot-depth
          alias-key
          alias-slot
          (+ depth 1))
        result))))

(define (compiler-parse-semantic-origin-run-key-slot [key : i64] [slot : i64]) : CompilerParseMaybeSemanticOriginRun
  (compiler-parse-semantic-origin-run-key-slot-depth key slot 0))

(define (compiler-parse-semantic-origin-run
  [decls : (& decls ast.AstDeclList)]
  [slot : i64]) : CompilerParseMaybeSemanticOriginRun
  (compiler-parse-semantic-origin-run-key-slot
    (compiler-parse-decl-list-storage-key decls)
    (+ decls.offset slot)))

(define (compiler-parse-semantic-origin-run-len
  [run : (& run CompilerParseSemanticOriginRun)]) : i64
  run.count)

(define (compiler-parse-semantic-origin-fallback) : CompilerParseSemanticOrigin
  (CompilerParseSemanticOrigin
    (CompilerParseSemanticOriginKind.TypeName)
    cbi.compiler-builtin-id-fix-empty
    (ast.ast-decl-span-fallback)
    -1))

(define (compiler-parse-semantic-origin-run-get
  [run : (& run CompilerParseSemanticOriginRun)]
  [index : i64]
  [fallback : CompilerParseSemanticOrigin]) : CompilerParseSemanticOrigin
  (if (and (>= index 0) (< index run.count))
    (match (reader.spanned-sexpr-view (reader.sp-node-get (+ run.start index)))
      [(reader.SpannedSexprView.Int written-name marker span)
        (let
          [kind-tag : i64
            (compiler-parse-semantic-origin-kind-tag-from-marker marker)]
          (if (>= kind-tag 0)
            (CompilerParseSemanticOrigin
              (compiler-parse-semantic-origin-kind-from-tag kind-tag)
              written-name
              (ast-source-span-from-source-span span)
              index)
            fallback))]
      [_ fallback])
    fallback))

;; Aggregate member origins reuse the transient spanned-node pool instead of
;; widening hot AST nodes. After each top-level form, only marker + span records
;; are compacted below the next form's pool mark; lookup is error-path-only.
(define (compiler-parse-member-origin-span
  [key : i64]
  [member-index : i64]
  [fallback : ast.AstSourceSpan]) : ast.AstSourceSpan
  (let
    [cursor : i64 0]
    [limit : i64 (reader.sp-node-pool-len)]
    [result : ast.AstSourceSpan fallback]
    (begin
      (while (< cursor limit)
        (begin
          (match (reader.spanned-sexpr-view (reader.sp-node-get cursor))
            [(reader.SpannedSexprView.Int record-key marker marker-span)
              (if (and
                (= record-key key)
                (string.eq marker "__tl_member_origin"))
                (let
                  [record-index : i64 (+ cursor 1)]
                  [record-offset : i64 0]
                  [done : bool false]
                  (begin
                    ;; The marker span is the aggregate name and remains a
                    ;; useful fallback if a later transform appends a member.
                    (set! result (ast-source-span-from-source-span marker-span))
                    (while (and (not done) (< record-index limit))
                      (match (reader.spanned-sexpr-view
                        (reader.sp-node-get record-index))
                        [(reader.SpannedSexprView.Nil span)
                          (if (= record-offset member-index)
                            (begin
                              (set!
                                result
                                (ast-source-span-from-source-span span))
                              (set! done true))
                            (begin
                              (set! record-index (+ record-index 1))
                              (set! record-offset (+ record-offset 1))))]
                        [_ (set! done true)]))))
                unit)]
            [_ unit])
          (set!
            cursor
            (compiler-parse-semantic-origin-next-record cursor limit))))
      result)))

(define (compiler-parse-field-def-list-span-get
  [fields : (& fields ast.AstFieldDefList)]
  [index : i64]
  [fallback : ast.AstSourceSpan]) : ast.AstSourceSpan
  (compiler-parse-member-origin-span
    (unsafe
      (cast
        (ptr->int (ptr-cast (__tl_array-data fields.slots) : (Ptr u8)))
        : i64))
    index
    fallback))

(define (compiler-parse-variant-def-list-span-get
  [variants : (& variants ast.AstVariantDefList)]
  [index : i64]
  [fallback : ast.AstSourceSpan]) : ast.AstSourceSpan
  (compiler-parse-member-origin-span
    (unsafe
      (cast
        (ptr->int (ptr-cast (__tl_array-data variants.slots) : (Ptr u8)))
        : i64))
    index
    fallback))

(define (compiler-parse-member-records-compact!
  [mark : i64]
  [records-start : i64]) : unit
  (let
    [read-index : i64 records-start]
    [write-index : i64 mark]
    [end : i64 (reader.sp-node-pool-len)]
    (begin
      (while (< read-index end)
        (begin
          (set!
            (array-ref reader.sp-node-pool-slots write-index)
            (reader.sp-node-get read-index))
          (set! write-index (+ write-index 1))
          (set! read-index (+ read-index 1))))
      (reader.sp-node-pool-truncate! write-index))))

(defenum ResultAstType
  (Ok ast.AstType)
  (Err String))

(defenum ResultAstReduceOp
  (Ok ast.AstReduceOp)
  (Err String))

(defenum ResultAstFuncTypeParts
  (Ok ast.AstTypeList ast.AstType)
  (Err String))

(defenum ResultAstTypeList
  (Ok ast.AstTypeList)
  (Err String))

(defenum ResultAstTypeListBuild
  (Ok)
  (Err String))

(defenum ResultAstLifetimeList
  (Ok ast.AstLifetimeList)
  (Err String))

(defenum ResultAstLifetimeListBuild
  (Ok)
  (Err String))

(defenum ResultAstParam
  (Ok ast.AstParam)
  (Err String))

(defenum ResultAstParamList
  (Ok ast.AstParamList)
  (Err String))

(defenum ResultAstParamListBuild
  (Ok)
  (Err String))

(defenum ResultAstMacroParam
  (Ok ast.AstMacroParam)
  (Err String))

(defenum ResultAstMacroTypeKindList
  (Ok ast.AstMacroTypeKindList)
  (Err String))

(defenum ResultAstMacroTypeKindCount
  (Ok i64)
  (Err String))

(defenum ResultAstMacroParamList
  (Ok ast.AstMacroParamList)
  (Err String))

(defenum ResultAstMacroParamListBuild
  (Ok)
  (Err String))

(defenum ResultAstFieldDef
  (Ok ast.AstFieldDef)
  (Err String))

(defenum ResultAstFieldDefList
  (Ok ast.AstFieldDefList)
  (Err String))

(defenum ResultAstFieldCleanup
  (Ok ast.AstFieldCleanup)
  (Err String))

(defenum ResultAstStructRepr
  (Ok ast.AstStructRepr)
  (Err String))

(defenum ResultAstStructCleanup
  (Ok ast.AstStructCleanup)
  (Err String))

(defenum ResultAstEnumCleanup
  (Ok ast.AstEnumCleanup)
  (Err String))

(defenum ResultAstVariantPayloadCleanup
  (Ok ast.AstVariantPayloadCleanup)
  (Err String))

(defenum ResultAstVariantPayloadParts
  (Ok ast.AstTypeList ast.AstVariantPayloadCleanupList)
  (Err String))

(defenum ResultAstStructDefParts
  (Ok
    ast.AstLifetimeList
    ast.AstStructRepr
    ast.AstStructCleanup
    ast.AstFieldDefList)
  (Err String))

(defenum ResultAstEnumDefParts
  (Ok ast.AstLifetimeList ast.AstEnumCleanup ast.AstVariantDefList)
  (Err String))

(defenum ResultAstExternAbi
  (Ok ast.AstExternAbi)
  (Err String))

(defenum ResultAstExternSymbol
  (Ok String ci.InternId)
  (Err String))

(defenum ResultAstFnExport
  (Ok ast.AstFnExport)
  (Err String))

(defenum ResultAstSpmdParamClassList
  (Ok ast.AstSpmdParamClassList)
  (Err String))

(defenum ResultAstSpmdResultClass
  (Ok ast.AstSpmdResultClass)
  (Err String))

(defenum ResultAstSpmdIndexParam
  (Ok i64)
  (Err String))

(defenum ResultAstSpmdSpecialization
  (Ok ast.AstSpmdSpecialization)
  (Err String))

(defenum ResultAstSpmdCallable
  (Ok ast.AstSpmdCallable)
  (Err String))

(defstruct AstSpmdSpecializationParseState
  (lanes i64)
  (args ast.AstSpmdParamClassList)
  (result ast.AstSpmdResultClass)
  (index-param i64)
  (seen-lanes bool)
  (seen-args bool)
  (seen-result bool)
  (seen-index-param bool))

(defenum ResultAstSpmdSpecializationParseState
  (Ok AstSpmdSpecializationParseState)
  (Err String))

(defenum ResultAstExternParts
  (Ok ast.AstExternAbi ci.InternId bool ast.AstType)
  (Err String))

(defenum AstExternHeadItem
  (Param ast.AstType)
  (VarargsOpen)
  (VarargsTyped ast.AstType))

(defenum ResultAstExternHeadItem
  (Ok AstExternHeadItem)
  (Err String))

(defenum ResultAstExternHeader
  (Ok i64 ast.AstTypeList ast.AstExternAbi)
  (Err String))

(defenum ResultAstVariantDef
  (Ok ast.AstVariantDef)
  (Err String))

(defenum ResultAstVariantDefList
  (Ok ast.AstVariantDefList)
  (Err String))

(defenum ResultAstDispatchIsa
  (Ok ast.AstDispatchIsa)
  (Err String))

(defenum ResultAstDispatchVariant
  (Ok ast.AstDispatchVariant)
  (Err String))

(defenum ResultAstDispatchVariantList
  (Ok ast.AstDispatchVariantList)
  (Err String))

(defenum ResultAstDispatchVariantListBuild
  (Ok)
  (Err String))

(defenum ResultAstPattern
  (Ok ast.AstPattern)
  (Err String))

(defenum ResultAstPatternList
  (Ok ast.AstPatternList)
  (Err String))

(defenum ResultAstPatternListBuild
  (Ok)
  (Err String))

(defenum ResultAstLetBinding
  (Ok ast.AstLetBinding)
  (Err String))

(defenum ResultAstResourceBinding
  (Ok ast.AstResourceBinding)
  (Err String))

(defenum ResultAstResourceBindingList
  (Ok ast.AstResourceBindingList)
  (Err String))

(defenum ResultAstResourceBindingListBuild
  (Ok)
  (Err String))

(defenum ResultAstLetParts
  (Ok ast.AstLetBindingList i64)
  (Err String))

(defenum ResultAstMatchArm
  (Ok ast.AstMatchArm)
  (Err String))

(defenum ResultAstMatchArmList
  (Ok ast.AstMatchArmList)
  (Err String))

(defenum ResultAstMatchArmListBuild
  (Ok)
  (Err String))

(defenum ResultAstExpr
  (Ok i64)
  (Err String))

(defstruct AstExprPair
  (first i64)
  (second i64))

(defenum ResultAstExprPair
  (Ok AstExprPair)
  (Err String))

(defenum ResultAstExprList
  (Ok ast.AstExprList)
  (Err String))

(defenum ResultAstExprListBuild
  (Ok)
  (Err String))

(defenum ResultAstDecl
  (Ok ast.AstDecl)
  (Err String))

(defenum ResultAstMaybeDecl
  (NoDecl)
  (SomeDecl ast.AstDecl)
  (Decls ast.AstDeclList)
  (Err String))

(defenum ResultAstDeclList
  (Ok ast.AstDeclList)
  (Err String))

(defenum ResultParseAstDeclVec
  (Ok)
  (Err String))

(defenum ResultParseAstDeclVecDiagnostic
  (Ok)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultAstMaybeExpr
  (NoExpr)
  (SomeExpr i64)
  (Err String))

(defenum ResultCompilerCfg
  (Ok bool)
  (Err String))

(defenum ResultAstProgram
  (Ok ast.AstProgram)
  (Err String))

(defenum AstReplItem
  (AstReplDecl ast.AstDecl)
  (AstReplExpr i64))

(defenum ResultAstReplItem
  (Ok AstReplItem)
  (Err String))

(defenum ResultAstDeclListDiagnostic
  (Ok ast.AstDeclList)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum ResultAstProgramDiagnostic
  (Ok ast.AstProgram)
  (Err (Box cdiag.CompilerDiagnostic)))

;; Recovery is explicit: Parsed may carry a partial program together with one
;; or more syntax diagnostics, while Fatal means lexing failed before a token
;; stream existed. Callers must not treat Parsed as successful unless the
;; diagnostic list is empty.
(defenum ResultAstProgramRecovery
  (Parsed ast.AstProgram (Box cdiag.CompilerDiagnosticList))
  (Fatal (Box cdiag.CompilerDiagnosticList)))

;; Mutable parser data belongs to one compiler driver. The fixed dispatch
;; arrays avoid arena-lifetime coupling in a state that survives individual
;; file parses; the cached immutable environment is rebuilt when its owning
;; intern table resets. Standalone parser helpers use the default state below
;; as a compatibility adapter, while production drivers attach their state to
;; cfgs with compiler-parse-state-cfgs.
(defstruct CompilerParseState
  (control (__tl_dyn-array i64))
  (dispatch-index-keys (__tl_dyn-array i64))
  (dispatch-index-tags (__tl_dyn-array i64))
  (dispatch-cache (__tl_dyn-array sym_i64_env.SymI64Env))
  (dispatch-cache-handle
    (__tl_dyn-array (__tl_dyn-array sym_i64_env.SymI64Env)))
  (intern-owner (__tl_dyn-array ci.InternCompatState)))

(define compiler-parse-state-control-keys-addr : i64
  0)
(define compiler-parse-state-control-tags-addr : i64
  1)
(define compiler-parse-state-control-cache-addr : i64
  2)
(define compiler-parse-state-control-owner-addr : i64
  3)
(define compiler-parse-state-control-cache-generation : i64
  4)
(define compiler-parse-state-control-cache-table-id : i64
  5)
(define compiler-parse-state-control-marker-id : i64
  6)
(define compiler-parse-state-control-ready : i64
  7)
(define compiler-parse-state-control-reserved : i64
  9)
(define compiler-parse-state-marker-id : i64
  -2)
(define compiler-parse-invocation-marker-id : i64
  -3)
(define compiler-parse-invocation-control-slot : i64
  5)

(define (compiler-parse-array-data-addr-i64 [items : (__tl_dyn-array i64)]) : i64
  (cast
    (unsafe
      (ptr->int (ptr-cast (__tl_array-data items) : (Ptr u8))))
    : i64))

(define (compiler-parse-intern-owner-data-addr
  [items : (__tl_dyn-array ci.InternCompatState)]) : i64
  (if (= (array-length items) 0)
    0
    (cast
      (unsafe
        (ptr->int (ptr-cast (__tl_array-data items) : (Ptr u8))))
      : i64)))

(define (compiler-parse-dispatch-cache-handle-data-addr
  [items : (__tl_dyn-array (__tl_dyn-array sym_i64_env.SymI64Env))]) : i64
  (cast
    (unsafe
      (ptr->int (ptr-cast (__tl_array-data items) : (Ptr u8))))
    : i64))

(define (compiler-parse-state-new-from-owner
  [owner : (__tl_dyn-array ci.InternCompatState)]) : CompilerParseState
  (let
    [control : (__tl_dyn-array i64) (__tl_make-array i64 10)]
    [keys : (__tl_dyn-array i64) (__tl_make-array i64 512)]
    [tags : (__tl_dyn-array i64) (__tl_make-array i64 512)]
    [cache : (__tl_dyn-array sym_i64_env.SymI64Env)
      (__tl_make-array sym_i64_env.SymI64Env 1)]
    [cache-handle : (__tl_dyn-array (__tl_dyn-array sym_i64_env.SymI64Env))
      (__tl_make-array (__tl_dyn-array sym_i64_env.SymI64Env) 1)]
    (begin
      (set! (array-ref cache 0) (sym_i64_env.sym-i64-empty))
      (set! (array-ref cache-handle 0) cache)
      (set!
        (array-ref control compiler-parse-state-control-keys-addr)
        (compiler-parse-array-data-addr-i64 keys))
      (set!
        (array-ref control compiler-parse-state-control-tags-addr)
        (compiler-parse-array-data-addr-i64 tags))
      (set!
        (array-ref control compiler-parse-state-control-cache-addr)
        (compiler-parse-dispatch-cache-handle-data-addr cache-handle))
      (set!
        (array-ref control compiler-parse-state-control-owner-addr)
        (compiler-parse-intern-owner-data-addr owner))
      (set!
        (array-ref control compiler-parse-state-control-cache-generation)
        -1)
      (set! (array-ref control compiler-parse-state-control-cache-table-id) -1)
      (set! (array-ref control compiler-parse-state-control-marker-id) -1)
      (set! (array-ref control compiler-parse-state-control-ready) 0)
      (set! (array-ref control compiler-parse-state-control-reserved) 0)
      (CompilerParseState control keys tags cache cache-handle owner))))

(define (compiler-parse-state-new) : CompilerParseState
  (compiler-parse-state-new-from-owner (__tl_make-array ci.InternCompatState 0)))

(define (compiler-parse-state-new-with-intern-state
  [intern-state : ci.InternCompatState]) : CompilerParseState
  (let
    [owner : (__tl_dyn-array ci.InternCompatState)
      (__tl_make-array ci.InternCompatState 1)]
    (begin
      (set! (array-ref owner 0) intern-state)
      (compiler-parse-state-new-from-owner owner))))

(define (compiler-parse-state-control-addr [state : CompilerParseState]) : i64
  (compiler-parse-array-data-addr-i64 state.control))

(define (compiler-parse-raw-i64-ref [address : i64] [index : i64]) : i64
  (unsafe
    (ptr-read (ptr-offset (int->ptr address : (Ptr i64)) index))))

(define (compiler-parse-raw-i64-set!
  [address : i64]
  [index : i64]
  [value : i64]) : unit
  (unsafe
    (ptr-write! (ptr-offset (int->ptr address : (MutPtr i64)) index) value)))

(define (compiler-parse-state-owner [control : i64]) : ci.InternCompatState
  (unsafe
    (ptr-read
      (int->ptr
        (compiler-parse-raw-i64-ref
          control
          compiler-parse-state-control-owner-addr)
        : (Ptr ci.InternCompatState)))))

(define (compiler-parse-state-owner-generation [control : i64]) : i64
  (if (=
    (compiler-parse-raw-i64-ref control compiler-parse-state-control-owner-addr)
    0)
    (ci.intern-generation)
    (ci.intern-compat-state-generation (compiler-parse-state-owner control))))

(define (compiler-parse-state-owner-table-id [control : i64]) : i64
  (if (=
    (compiler-parse-raw-i64-ref control compiler-parse-state-control-owner-addr)
    0)
    (ci.intern-active-table-id)
    (ci.intern-compat-state-table-id (compiler-parse-state-owner control))))

(define (compiler-parse-state-owner-persistent-arena [control : i64]) : i64
  (if (=
    (compiler-parse-raw-i64-ref control compiler-parse-state-control-owner-addr)
    0)
    (ci.intern-persistent-arena-handle)
    (ci.intern-compat-state-persistent-arena
      (compiler-parse-state-owner control))))

(define (compiler-parse-env-marker-value
  [dispatch : sym_i64_env.SymI64Env]
  [marker-id : i64]) : i64
  (let
    [cursor : sym_i64_env.SymI64Env dispatch]
    (begin
      (while true
        (match (sym_i64_env.sym-i64-view cursor)
          [(sym_i64_env.SymI64ViewNil) (return 0)]
          [(sym_i64_env.SymI64ViewBind name-id value rest)
            (if (= name-id marker-id)
              (return value)
              (set! cursor rest))]))
      0)))

(define (compiler-parse-dispatch-invocation-control
  [dispatch : sym_i64_env.SymI64Env]) : i64
  (match (sym_i64_env.sym-i64-view dispatch)
    [(sym_i64_env.SymI64ViewBind name-id value _)
      (if (= name-id compiler-parse-invocation-marker-id)
        (compiler-parse-raw-i64-ref
          value
          compiler-parse-invocation-control-slot)
        0)]
    [(sym_i64_env.SymI64ViewNil) 0]))

(define (compiler-parse-dispatch-intern-state
  [dispatch : sym_i64_env.SymI64Env]) : ci.InternCompatState
  (let
    [invocation-control : i64
      (compiler-parse-dispatch-invocation-control dispatch)]
    [control
      : i64
      ;; Production dispatches carry a one-node invocation frame. Reuse the
      ;; cached control instead of rescanning the full dispatch for
      ;; every source identifier that may contain semantic components.
      (if (not (= invocation-control 0))
        invocation-control
        (compiler-parse-env-marker-value
          dispatch
          compiler-parse-state-marker-id))]
    (if (or
      (= control 0)
      (=
        (compiler-parse-raw-i64-ref
          control
          compiler-parse-state-control-owner-addr)
        0))
      ;; Named compatibility branch for direct serial/test parser dispatches.
      (ci.intern-compat-state-capture-active)
      (compiler-parse-state-owner control))))

(define (compiler-parse-dispatch-syntax-id-text
  [dispatch : sym_i64_env.SymI64Env]
  [id : ci.InternSyntaxId]) : String
  (ci.intern-compat-state-syntax-id-text
    (compiler-parse-dispatch-intern-state dispatch)
    id))

(define (compiler-parse-dispatch-id-str
  [dispatch : sym_i64_env.SymI64Env]
  [id : ci.InternId]) : String
  (ci.intern-compat-state-id-str
    (compiler-parse-dispatch-intern-state dispatch)
    id))

(define (compiler-parse-cfg-intern-owner-control [cfgs : sym_i64_env.SymI64Env]) : i64
  (let
    [control : i64
      (compiler-parse-env-marker-value cfgs compiler-parse-state-marker-id)]
    (if (and
      (not (= control 0))
      (not
        (=
          (compiler-parse-raw-i64-ref
            control
            compiler-parse-state-control-owner-addr)
          0)))
      control
      0)))

(define (compiler-parse-spanned-result-with-cfg
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : lexer.ResultSpannedTokens
  (let
    [control : i64 (compiler-parse-cfg-intern-owner-control cfgs)]
    (if (= control 0)
      ;; Named compatibility branch for direct serial parser callers. Compile
      ;; jobs attach a state owner to cfgs and take the explicit branch below.
      (lexer.spanned-result src)
      (begin
        ;; Until #5754 retires the driver's installed-owner builtin bridge,
        ;; builtin seeding may have advanced the matching active scalar view.
        (compiler-parse-state-owner-capture-active! control)
        (let
          [result : lexer.ResultSpannedTokens
            (lexer.spanned-result-with-intern-state
              src
              (compiler-parse-state-owner control))]
          (begin
            ;; Keep that same temporary installed view monotone across files;
            ;; inactive owners do not match and are never published.
            (compiler-parse-state-owner-sync-active! control)
            result))))))

(define (compiler-parse-source-builtins-prepare!) : unit
  ;; The builtin-ID globals still follow the installed intern owner. Driver
  ;; preparation makes this a no-op for production jobs; deleting the bridge
  ;; waits for #5754 to provide the final state-owned builtin handoff.
  (cbi.compiler-builtin-initialize-for-parse!))

(define (compiler-parse-state-cfgs
  [state : CompilerParseState]
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (sym_i64_env.sym-i64-bind-id
    cfgs
    compiler-parse-state-marker-id
    (compiler-parse-state-control-addr state)))

;; Compatibility state for direct parser helpers and parser-only tests. Driver
;; paths always attach their own state with compiler-parse-state-cfgs.
(define compiler-parse-default-state : (__tl_dyn-array CompilerParseState)
  (__tl_make-array (compiler-parse-state-new)))

(define (compiler-parse-default-state-shared-view) : CompilerParseState
  (unsafe
    (ptr-read
      (ptr-cast
        (__tl_array-data compiler-parse-default-state)
        : (Ptr CompilerParseState)))))

(define (sexpr-colon? [s : reader.Sexpr]) : bool
  (match (reader.sexpr-view s)
    [(reader.SexprView.Sym name-id)
      (= (ci.intern-syntax-id-value name-id) cbi.compiler-builtin-id-fix-colon)]
    [_ false]))

;; ID-to-text is intentionally a boundary, not a classifier. Production
;; callers are limited to lazy unknown-name diagnostics, prefix/content syntax
;; (`:unknown`, typed `...T`, retired name families), and dotted import paths.
(define (compiler-parse-name-text-with-state
  [intern-state : ci.InternCompatState]
  [name-id : i64]) : String
  (cond
    [(ci.intern-compat-state-composite-pair-id? intern-state name-id)
      (str_cat.str-cat
        (ci.intern-compat-state-str
          intern-state
          (ci.intern-compat-state-composite-left-id-unchecked
            intern-state
            name-id))
        "/"
        (ci.intern-compat-state-str
          intern-state
          (ci.intern-compat-state-composite-right-id-unchecked
            intern-state
            name-id)))]
    [(ci.intern-compat-state-composite-triple-id? intern-state name-id)
      (str_cat.str-cat
        (ci.intern-compat-state-str
          intern-state
          (ci.intern-compat-state-composite-left-id-unchecked
            intern-state
            name-id))
        "/"
        (ci.intern-compat-state-str
          intern-state
          (ci.intern-compat-state-composite-middle-id-unchecked
            intern-state
            name-id))
        "."
        (ci.intern-compat-state-str
          intern-state
          (ci.intern-compat-state-composite-right-id-unchecked
            intern-state
            name-id)))]
    [else (ci.intern-compat-state-str intern-state name-id)]))

(define (compiler-parse-dispatch-name-text
  [dispatch : sym_i64_env.SymI64Env]
  [name-id : i64]) : String
  (compiler-parse-name-text-with-state
    (compiler-parse-dispatch-intern-state dispatch)
    name-id))

;; Named compatibility adapter for parser-only tests that deliberately exercise
;; the installed serial table. Production parse paths use the dispatch owner.
(define (compiler-parse-name-text [name-id : i64]) : String
  (compiler-parse-name-text-with-state
    (ci.intern-compat-state-capture-active)
    name-id))

(define (compiler-cfg-empty) : sym_i64_env.SymI64Env
  (cfg_core.compiler-cfg-empty))

(define (compiler-cfg-enable [cfgs : sym_i64_env.SymI64Env] [name : String]) : sym_i64_env.SymI64Env
  (cfg_core.compiler-cfg-enable cfgs name))

(define (compiler-cfg-union [cfgs : sym_i64_env.SymI64Env] [name : String]) : sym_i64_env.SymI64Env
  (cfg_core.compiler-cfg-union cfgs name))

(define (compiler-cfg-merge
  [base : sym_i64_env.SymI64Env]
  [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (cfg_core.compiler-cfg-merge base cfgs))

(define (compiler-cfg-enabled?
  [dispatch : sym_i64_env.SymI64Env]
  [name-id : i64]) : bool
  (cfg_core.compiler-cfg-enabled? dispatch name-id))

(define (compiler-cfg-union? [dispatch : sym_i64_env.SymI64Env] [name-id : i64]) : bool
  (cfg_core.compiler-cfg-union? dispatch name-id))

(define (compiler-cfg-predicate-union?
  [dispatch : sym_i64_env.SymI64Env]
  [predicate : reader.SpannedSexpr]) : bool
  (match (reader.spanned-sexpr-view predicate)
    [(reader.SpannedSexprView.Sym name _)
      (compiler-cfg-union? dispatch (ci.intern-syntax-id-value name))]
    [_ false]))

(define (compiler-cfg-eval-list-all
  [dispatch : sym_i64_env.SymI64Env]
  [predicates : reader.SpannedSexpr]) : ResultCompilerCfg
  (match (reader.spanned-sexpr-view predicates)
    [(reader.SpannedSexprView.Nil _) (ResultCompilerCfg.Ok true)]
    [(reader.SpannedSexprView.Cons head tail _)
      (match (compiler-cfg-eval dispatch head)
        [(ResultCompilerCfg.Ok enabled)
          (if enabled
            (compiler-cfg-eval-list-all dispatch tail)
            (ResultCompilerCfg.Ok false))]
        [(ResultCompilerCfg.Err message) (ResultCompilerCfg.Err message)])]
    [_ (ResultCompilerCfg.Err "parse: cfg all expects predicates")]))

(define (compiler-cfg-eval-list-any
  [dispatch : sym_i64_env.SymI64Env]
  [predicates : reader.SpannedSexpr]) : ResultCompilerCfg
  (match (reader.spanned-sexpr-view predicates)
    [(reader.SpannedSexprView.Nil _) (ResultCompilerCfg.Ok false)]
    [(reader.SpannedSexprView.Cons head tail _)
      (match (compiler-cfg-eval dispatch head)
        [(ResultCompilerCfg.Ok enabled)
          (if enabled
            (ResultCompilerCfg.Ok true)
            (compiler-cfg-eval-list-any dispatch tail))]
        [(ResultCompilerCfg.Err message) (ResultCompilerCfg.Err message)])]
    [_ (ResultCompilerCfg.Err "parse: cfg any expects predicates")]))

(define (compiler-cfg-eval-not
  [dispatch : sym_i64_env.SymI64Env]
  [predicates : reader.SpannedSexpr]) : ResultCompilerCfg
  (match (reader.spanned-sexpr-view predicates)
    [(reader.SpannedSexprView.Cons pred tail _)
      (match (reader.spanned-sexpr-view tail)
        [(reader.SpannedSexprView.Nil _)
          (match (compiler-cfg-eval dispatch pred)
            [(ResultCompilerCfg.Ok enabled)
              (ResultCompilerCfg.Ok (not enabled))]
            [(ResultCompilerCfg.Err message) (ResultCompilerCfg.Err message)])]
        [_
          (ResultCompilerCfg.Err "parse: cfg not expects exactly one predicate")])]
    [_ (ResultCompilerCfg.Err "parse: cfg not expects exactly one predicate")]))

(define (compiler-cfg-eval
  [dispatch : sym_i64_env.SymI64Env]
  [predicate : reader.SpannedSexpr]) : ResultCompilerCfg
  (match (reader.spanned-sexpr-view predicate)
    [(reader.SpannedSexprView.Sym name _)
      (ResultCompilerCfg.Ok
        (compiler-cfg-enabled? dispatch (ci.intern-syntax-id-value name)))]
    [(reader.SpannedSexprView.Cons head predicates _)
      (match (reader.spanned-sexpr-view head)
        [(reader.SpannedSexprView.Sym op _)
          (cond
            [(=
                (ci.intern-syntax-id-value op)
                (cbi.compiler-builtin-ctfe-ref 219))
              (compiler-cfg-eval-list-all dispatch predicates)]
            [(=
                (ci.intern-syntax-id-value op)
                (cbi.compiler-builtin-ctfe-ref 220))
              (compiler-cfg-eval-list-any dispatch predicates)]
            [(=
                (ci.intern-syntax-id-value op)
                (cbi.compiler-builtin-ctfe-ref 155))
              (compiler-cfg-eval-not dispatch predicates)]
            [else
              (ResultCompilerCfg.Err
                "parse: cfg predicate expects a name, all, any, or not")])]
        [_ (ResultCompilerCfg.Err "parse: malformed cfg predicate")])]
    [_ (ResultCompilerCfg.Err "parse: malformed cfg predicate")]))

(define (compiler-parse-abstraction-policy-message) : String
  "parse: TypeLisp does not support source-level generics or traits; use defmacro to generate concrete declarations instead")

(define (compiler-parse-generic-type-policy-message [name : String]) : String
  (cond
    [(string.eq name "varying")
      "parse: public SPMD varying source types are deferred; varying is inferred inside foreach"]
    [(string.eq name "Varying")
      "parse: public SPMD varying source types are deferred; varying is inferred inside foreach"]
    [(string.eq name "Vector")
      "parse: public SPMD vector source types are deferred; vector values remain compiler-internal"]
    [(string.eq name "vector")
      "parse: public SPMD vector source types are deferred; vector values remain compiler-internal"]
    [(string.eq name "Mask")
      "parse: public SPMD mask source types are deferred; masks remain compiler-internal"]
    [(string.eq name "mask")
      "parse: public SPMD mask source types are deferred; masks remain compiler-internal"]
    [else
      (str_cat.str-cat
        "parse: unknown type constructor "
        name
        "; TypeLisp has no source-level generic type constructors; use defmacro to generate concrete declarations instead")]))

(define (compiler-parse-policy-form? [name : i64]) : bool
  (or
    (cbi.compiler-builtin-id-any4?
      name
      (cbi.compiler-builtin-ctfe-ref 265)
      (cbi.compiler-builtin-ctfe-ref 266)
      (cbi.compiler-builtin-ctfe-ref 267)
      (cbi.compiler-builtin-ctfe-ref 268))
    (cbi.compiler-builtin-id-any3?
      name
      (cbi.compiler-builtin-ctfe-ref 269)
      (cbi.compiler-builtin-ctfe-ref 270)
      (cbi.compiler-builtin-ctfe-ref 271))))

(define (compiler-parse-removed-compressed-include-name) : String
  (str_cat.str-cat "include-str-comptime-" "lzss"))

(define (compiler-parse-removed-compressed-include-message) : String
  (str_cat.str-cat
    "parse: include-str-comptime-"
    "lzss is removed; use include-str-lzss"))

(define (ast-source-span-from-source-span [span : token.SourceSpan]) : ast.AstSourceSpan
  (ast.ast-source-span
    (token.span-start-line span)
    (token.span-start-col span)
    (token.span-end-line span)
    (token.span-end-col span)))

;; Parser result enums still carry message strings. Diagnostic parsing records
;; the first failing spanned subform in the invocation frame carried by this
;; dispatch, so nested and interleaved parser calls cannot overwrite it.
(define (parse-ast-error-span-clear! [dispatch : sym_i64_env.SymI64Env]) : unit
  (let
    [invocation : i64
      (compiler-parse-env-marker-value
        dispatch
        compiler-parse-invocation-marker-id)]
    (if (= invocation 0)
      unit
      (compiler-parse-raw-i64-set! invocation 0 0))))

(define (parse-ast-error-span-note!
  [dispatch : sym_i64_env.SymI64Env]
  [span : token.SourceSpan]) : unit
  (let
    [invocation : i64
      (compiler-parse-env-marker-value
        dispatch
        compiler-parse-invocation-marker-id)]
    (if (or
      (= invocation 0)
      (not (= (compiler-parse-raw-i64-ref invocation 0) 0)))
      unit
      (begin
        (compiler-parse-raw-i64-set! invocation 0 1)
        (compiler-parse-raw-i64-set! invocation 1 (token.span-start-line span))
        (compiler-parse-raw-i64-set! invocation 2 (token.span-start-col span))
        (compiler-parse-raw-i64-set! invocation 3 (token.span-end-line span))
        (compiler-parse-raw-i64-set! invocation 4 (token.span-end-col span))))))

(define (parse-ast-error-span-current
  [dispatch : sym_i64_env.SymI64Env]
  [fallback : token.SourceSpan]) : token.SourceSpan
  (let
    [invocation : i64
      (compiler-parse-env-marker-value
        dispatch
        compiler-parse-invocation-marker-id)]
    (if (and
      (not (= invocation 0))
      (not (= (compiler-parse-raw-i64-ref invocation 0) 0)))
      (token.SourceSpan
        (compiler-parse-raw-i64-ref invocation 1)
        (compiler-parse-raw-i64-ref invocation 2)
        (compiler-parse-raw-i64-ref invocation 3)
        (compiler-parse-raw-i64-ref invocation 4))
      fallback)))

(define (parse-ast-error-span-note-expr
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]
  [result : ResultAstExpr]) : ResultAstExpr
  (match result
    [(ResultAstExpr.Err _)
      (begin
        (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span s))
        result)]
    [_ result]))

(define (parse-ast-error-span-note-let-binding
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]
  [result : ResultAstLetBinding]) : ResultAstLetBinding
  (match result
    [(ResultAstLetBinding.Err _)
      (begin
        (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span s))
        result)]
    [_ result]))

(define (parse-ast-error-span-note-decl
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]
  [result : ResultAstDecl]) : ResultAstDecl
  (match result
    [(ResultAstDecl.Err _)
      (begin
        (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span s))
        result)]
    [_ result]))

(define (parse-ast-error-span-note-maybe-decl
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]
  [result : ResultAstMaybeDecl]) : ResultAstMaybeDecl
  (match result
    [(ResultAstMaybeDecl.Err _)
      (begin
        (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span s))
        result)]
    [_ result]))

(define (ast-expr-wrap-span
  [pools : ast.AstNodePoolContext]
  [expr : i64]
  [s : reader.SpannedSexpr]) : i64
  (ast.ast-expr-spanned-with-pools
    pools
    expr
    (ast-source-span-from-source-span (reader.spanned-sexpr-span s))))

(define (compiler-parse-tag-unknown) : i64
  0)

(define (compiler-parse-tag-bin-add) : i64
  10)

(define (compiler-parse-tag-bin-sub) : i64
  11)

(define (compiler-parse-tag-bin-mul) : i64
  12)

(define (compiler-parse-tag-bin-div) : i64
  13)

(define (compiler-parse-tag-bin-mod) : i64
  14)

(define (compiler-parse-tag-bin-eq) : i64
  15)

(define (compiler-parse-tag-bin-ne) : i64
  16)

(define (compiler-parse-tag-bin-lt) : i64
  17)

(define (compiler-parse-tag-bin-le) : i64
  18)

(define (compiler-parse-tag-bin-gt) : i64
  19)

(define (compiler-parse-tag-bin-ge) : i64
  20)

(define (compiler-parse-tag-bin-bit-and) : i64
  23)

(define (compiler-parse-tag-bin-bit-or) : i64
  24)

(define (compiler-parse-tag-bin-bit-xor) : i64
  25)

(define (compiler-parse-tag-bin-shl) : i64
  26)

(define (compiler-parse-tag-bin-shr) : i64
  27)

(define (compiler-parse-tag-un-not) : i64
  40)

(define (compiler-parse-tag-un-neg) : i64
  41)

(define (compiler-parse-tag-un-bit-not) : i64
  42)

(define (compiler-parse-tag-ty-i64) : i64
  100)

(define (compiler-parse-tag-ty-i32) : i64
  101)

(define (compiler-parse-tag-ty-i16) : i64
  102)

(define (compiler-parse-tag-ty-i8) : i64
  103)

(define (compiler-parse-tag-ty-u64) : i64
  104)

(define (compiler-parse-tag-ty-u32) : i64
  105)

(define (compiler-parse-tag-ty-u16) : i64
  106)

(define (compiler-parse-tag-ty-u8) : i64
  107)

(define (compiler-parse-tag-ty-f64) : i64
  108)

(define (compiler-parse-tag-ty-f32) : i64
  109)

(define (compiler-parse-tag-ty-bool) : i64
  110)

(define (compiler-parse-tag-ty-char) : i64
  111)

(define (compiler-parse-tag-ty-string) : i64
  112)

(define (compiler-parse-tag-ty-str) : i64
  116)

(define (compiler-parse-tag-ty-bytes) : i64
  117)

(define (compiler-parse-tag-unit) : i64
  113)

(define (compiler-parse-tag-ty-never) : i64
  114)

(define (compiler-parse-tag-ty-expr) : i64
  115)

(define (compiler-parse-tag-ty-func) : i64
  130)

(define (compiler-parse-tag-ty-tuple) : i64
  131)

(define (compiler-parse-tag-ty-array) : i64
  132)

(define (compiler-parse-tag-ty-region) : i64
  133)

(define (compiler-parse-tag-ty-ptr) : i64
  134)

(define (compiler-parse-tag-ty-mut-ptr) : i64
  135)

(define (compiler-parse-tag-ty-ref) : i64
  136)

(define (compiler-parse-tag-ty-mut-ref) : i64
  137)

(define (compiler-parse-tag-ty-box) : i64
  138)

(define (compiler-parse-tag-ty-dyn-array) : i64
  139)

;; Borrowed slices are deliberately assigned a fresh parser tag so the
;; existing type tags remain stable for macro/serialized AST consumers.
(define (compiler-parse-tag-ty-slice) : i64
  140)

(define (compiler-parse-tag-expr-if) : i64
  200)

(define (compiler-parse-tag-expr-let) : i64
  201)

(define (compiler-parse-tag-expr-lambda) : i64
  202)

(define (compiler-parse-tag-expr-while) : i64
  203)

(define (compiler-parse-tag-expr-begin) : i64
  204)

(define (compiler-parse-tag-expr-unsafe) : i64
  254)

(define (compiler-parse-tag-expr-set) : i64
  205)

(define (compiler-parse-tag-expr-ann) : i64
  206)

(define (compiler-parse-tag-expr-cast) : i64
  207)

(define (compiler-parse-tag-expr-tuple) : i64
  220)

(define (compiler-parse-tag-expr-tuple-ref) : i64
  221)

(define (compiler-parse-tag-expr-array) : i64
  222)

(define (compiler-parse-tag-expr-make-array) : i64
  223)

(define (compiler-parse-tag-expr-array-ref) : i64
  240)

(define (compiler-parse-tag-expr-array-set) : i64
  241)

(define (compiler-parse-tag-expr-array-push) : i64
  262)

(define (compiler-parse-tag-expr-array-take) : i64
  303)

(define (compiler-parse-tag-expr-fixed-array-take) : i64
  305)

(define (compiler-parse-tag-expr-replace) : i64
  314)

(define (compiler-parse-tag-expr-for-owned-state) : i64
  306)

(define (compiler-parse-tag-expr-for-owned-step) : i64
  307)

(define (compiler-parse-tag-expr-for-owned-step-typed) : i64
  308)

;; Removed public place spellings retain parser tags solely to produce focused
;; migration diagnostics. Private/internal aliases keep their existing tags.
(define (compiler-parse-tag-expr-retired-struct-get) : i64
  309)

(define (compiler-parse-tag-expr-retired-array-set) : i64
  310)

(define (compiler-parse-tag-expr-retired-box-get) : i64
  311)

(define (compiler-parse-tag-expr-retired-box-take) : i64
  312)

(define (compiler-parse-tag-expr-retired-struct-set) : i64
  313)

(define (compiler-parse-tag-expr-fixed-make-array) : i64
  315)

(define (compiler-parse-tag-expr-retired-array-push) : i64
  316)

(define (compiler-parse-tag-expr-retired-array-data) : i64
  317)

;; Legacy nodes remain available while parsing quoted seed templates. They are
;; not accepted as ordinary source expressions at depth zero.
(define compiler-parse-quote-depth : i64
  0)

(define (compiler-parse-tag-expr-match) : i64
  244)

(define (compiler-parse-tag-expr-foreach) : i64
  245)

(define (compiler-parse-tag-expr-struct-get) : i64
  246)

(define (compiler-parse-tag-expr-comptime) : i64
  247)

(define (compiler-parse-tag-expr-with-region) : i64
  248)

(define (compiler-parse-tag-expr-type-literal) : i64
  249)

(define (compiler-parse-tag-expr-init) : i64
  288)

(define (compiler-parse-tag-expr-spmd-reduce) : i64
  250)

(define (compiler-parse-tag-expr-spmd-scan) : i64
  294)

(define (compiler-parse-tag-expr-spmd-broadcast) : i64
  290)

(define (compiler-parse-tag-expr-spmd-shuffle) : i64
  297)

(define (compiler-parse-tag-expr-spmd-program-index) : i64
  295)

(define (compiler-parse-tag-expr-spmd-program-count) : i64
  296)

(define (compiler-parse-tag-expr-try) : i64
  251)

(define (compiler-parse-tag-expr-return) : i64
  270)

(define (compiler-parse-tag-expr-break) : i64
  298)

(define (compiler-parse-tag-expr-continue) : i64
  299)

(define (compiler-parse-tag-expr-ptr-null) : i64
  252)

(define (compiler-parse-tag-expr-ptr-null-check) : i64
  253)

(define (compiler-parse-tag-expr-with-resource) : i64
  255)

(define (compiler-parse-tag-expr-ptr-read) : i64
  256)

(define (compiler-parse-tag-expr-ptr-write) : i64
  257)

(define (compiler-parse-tag-expr-ptr-offset) : i64
  258)

(define (compiler-parse-tag-expr-ptr-cast) : i64
  259)

(define (compiler-parse-tag-expr-ptr-to-int) : i64
  260)

(define (compiler-parse-tag-expr-int-to-ptr) : i64
  261)

(define (compiler-parse-tag-expr-ptr-addr-of) : i64
  289)

(define (compiler-parse-tag-expr-box) : i64
  263)

(define (compiler-parse-tag-expr-box-get) : i64
  264)

(define (compiler-parse-tag-expr-box-take) : i64
  292)

(define (compiler-parse-tag-expr-deref) : i64
  304)

(define (compiler-parse-tag-expr-string-data) : i64
  276)

(define (compiler-parse-tag-expr-string-from-bytes) : i64
  277)

(define (compiler-parse-tag-expr-array-data) : i64
  278)

(define (compiler-parse-tag-expr-program-argc) : i64
  279)

(define (compiler-parse-tag-expr-program-argv) : i64
  280)

(define (compiler-parse-tag-expr-program-envp) : i64
  281)

(define (compiler-parse-tag-expr-cpuid-eax) : i64
  282)

(define (compiler-parse-tag-expr-cpuid-ebx) : i64
  283)

(define (compiler-parse-tag-expr-cpuid-ecx) : i64
  284)

(define (compiler-parse-tag-expr-cpuid-edx) : i64
  285)

(define (compiler-parse-tag-expr-xgetbv) : i64
  286)

(define (compiler-parse-tag-expr-syscall) : i64
  287)

(define (compiler-parse-tag-expr-quote) : i64
  265)

(define (compiler-parse-tag-expr-quasiquote) : i64
  266)

(define (compiler-parse-tag-expr-unquote) : i64
  267)

(define (compiler-parse-tag-expr-unquote-splicing) : i64
  268)

(define (compiler-parse-tag-expr-with-escape) : i64
  269)

(define (compiler-parse-tag-expr-with-scratch) : i64
  293)

(define (compiler-parse-tag-expr-in-arena) : i64
  291)

(define (compiler-parse-tag-lit-true) : i64
  300)

(define (compiler-parse-tag-lit-false) : i64
  301)

(define (compiler-parse-tag-pattern-wildcard) : i64
  302)

(define (compiler-parse-tag-decl-define) : i64
  400)

(define (compiler-parse-tag-decl-extern) : i64
  401)

(define (compiler-parse-tag-decl-defenum) : i64
  402)

(define (compiler-parse-tag-decl-defstruct) : i64
  403)

(define (compiler-parse-tag-decl-import) : i64
  404)

(define (compiler-parse-tag-decl-module) : i64
  406)

(define (compiler-parse-tag-decl-test) : i64
  407)

(define (compiler-parse-tag-decl-defmacro) : i64
  408)

(define (compiler-parse-tag-decl-include-str) : i64
  410)

(define (compiler-parse-tag-decl-include-str-comptime) : i64
  414)

(define (compiler-parse-tag-decl-include-str-lzss) : i64
  415)

(define (compiler-parse-tag-decl-removed-compressed-include) : i64
  416)

(define (compiler-parse-tag-decl-include-bin) : i64
  413)

(define (compiler-parse-tag-decl-defdispatch) : i64
  411)

;; Parser syntax is a closed set, but the scoped symbol environment stores it
;; as an immutable list. Keep that environment as the source of truth for cfg
;; evaluation and custom test dispatches, while indexing the canonical dispatch
;; by intern ID for constant-time syntax lookup.
(define compiler-parse-dispatch-index-capacity : i64
  512)

(define (compiler-parse-dispatch-index-current-control? [control : i64]) : bool
  (and
    (=
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-cache-generation)
      (compiler-parse-state-owner-generation control))
    (=
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-cache-table-id)
      (compiler-parse-state-owner-table-id control))))

(define (compiler-parse-dispatch-index-clear! [control : i64]) : unit
  (let
    [keys : i64
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-keys-addr)]
    [i : i64 0]
    (while (< i compiler-parse-dispatch-index-capacity)
      (begin
        (compiler-parse-raw-i64-set! keys i 0)
        (set! i (+ i 1))))))

(define (compiler-parse-dispatch-index-insert!
  [control : i64]
  [name-id : i64]
  [tag : i64]) : bool
  (let
    [keys : i64
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-keys-addr)]
    [tags : i64
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-tags-addr)]
    [encoded : i64 (+ name-id 1)]
    [slot : i64 (bit-and name-id (- compiler-parse-dispatch-index-capacity 1))]
    [steps : i64 0]
    (begin
      (while (< steps compiler-parse-dispatch-index-capacity)
        (let
          [present : i64 (compiler-parse-raw-i64-ref keys slot)]
          (if (or (= present 0) (= present encoded))
            (begin
              (compiler-parse-raw-i64-set! keys slot encoded)
              (compiler-parse-raw-i64-set! tags slot tag)
              (return true))
            (begin
              (set!
                slot
                (bit-and
                  (+ slot 1)
                  (- compiler-parse-dispatch-index-capacity 1)))
              (set! steps (+ steps 1))))))
      false)))

(define (compiler-parse-dispatch-index-populate!
  [control : i64]
  [dispatch : sym_i64_env.SymI64Env]) : unit
  (let
    [generation : i64 (compiler-parse-state-owner-generation control)]
    [table-id : i64 (compiler-parse-state-owner-table-id control)]
    [cursor : sym_i64_env.SymI64Env dispatch]
    [done : bool false]
    (begin
      (compiler-parse-dispatch-index-clear! control)
      (compiler-parse-raw-i64-set!
        control
        compiler-parse-state-control-marker-id
        -1)
      (compiler-parse-raw-i64-set! control compiler-parse-state-control-ready 1)
      (while (and
        (not done)
        (not
          (=
            (compiler-parse-raw-i64-ref
              control
              compiler-parse-state-control-ready)
            0)))
        (match (sym_i64_env.sym-i64-view cursor)
          [(sym_i64_env.SymI64ViewNil) (set! done true)]
          [(sym_i64_env.SymI64ViewBind name-id tag rest)
            (begin
              (if (and
                (>= name-id 0)
                (= tag (compiler-parse-tag-decl-defdispatch)))
                (compiler-parse-raw-i64-set!
                  control
                  compiler-parse-state-control-marker-id
                  name-id)
                unit)
              (if (or
                (< name-id 0)
                (compiler-parse-dispatch-index-insert! control name-id tag))
                (set! cursor rest)
                (compiler-parse-raw-i64-set!
                  control
                  compiler-parse-state-control-ready
                  0)))]))
      (if (<
        (compiler-parse-raw-i64-ref
          control
          compiler-parse-state-control-marker-id)
        0)
        (compiler-parse-raw-i64-set!
          control
          compiler-parse-state-control-ready
          0)
        unit)
      (compiler-parse-raw-i64-set!
        control
        compiler-parse-state-control-cache-generation
        generation)
      (compiler-parse-raw-i64-set!
        control
        compiler-parse-state-control-cache-table-id
        table-id))))

;; Return the owning control address only when the first non-capability binding
;; is this state's defdispatch marker. Partial/custom environments retain the
;; linked-list fallback.
(define (compiler-parse-dispatch-indexed-control
  [dispatch : sym_i64_env.SymI64Env]) : i64
  (let
    [invocation-control : i64
      (compiler-parse-dispatch-invocation-control dispatch)]
    [cursor : sym_i64_env.SymI64Env dispatch]
    [control : i64 0]
    [marker-id : i64 -1]
    [marker-tag : i64 -1]
    (begin
      ;; Invocation frames are created only after the complete base dispatch
      ;; has validated this control. Intern reset cannot occur during a parse,
      ;; so the frame is the constant-time production path; the scan below is
      ;; retained for derived and custom test environments.
      (when (not (= invocation-control 0)) (return invocation-control))
      (while (or (= control 0) (< marker-id 0))
        (match (sym_i64_env.sym-i64-view cursor)
          [(sym_i64_env.SymI64ViewNil) (return 0)]
          [(sym_i64_env.SymI64ViewBind name-id tag rest)
            (begin
              (if (= name-id compiler-parse-state-marker-id)
                (set! control tag)
                unit)
              (if (and (>= name-id 0) (< marker-id 0))
                (begin
                  (set! marker-id name-id)
                  (set! marker-tag tag))
                unit)
              (set! cursor rest))]))
      (if (and
        (not (= control 0))
        (= marker-tag (compiler-parse-tag-decl-defdispatch))
        (not
          (=
            (compiler-parse-raw-i64-ref
              control
              compiler-parse-state-control-ready)
            0))
        (compiler-parse-dispatch-index-current-control? control)
        (=
          marker-id
          (compiler-parse-raw-i64-ref
            control
            compiler-parse-state-control-marker-id)))
        control
        0))))

(define (compiler-parse-dispatch-index-mark [dispatch : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [control : i64
      (compiler-parse-env-marker-value dispatch compiler-parse-state-marker-id)]
    (if (and
      (not (= control 0))
      (not
        (=
          (compiler-parse-raw-i64-ref
            control
            compiler-parse-state-control-ready)
          0))
      (compiler-parse-dispatch-index-current-control? control))
      (sym_i64_env.sym-i64-bind-id
        dispatch
        (compiler-parse-raw-i64-ref
          control
          compiler-parse-state-control-marker-id)
        (compiler-parse-tag-decl-defdispatch))
      dispatch)))

(define (compiler-parse-dispatch-index-lookup-id
  [control : i64]
  [name-id : i64]) : i64
  (let
    [keys : i64
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-keys-addr)]
    [tags : i64
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-tags-addr)]
    [encoded : i64 (+ name-id 1)]
    [slot : i64 (bit-and name-id (- compiler-parse-dispatch-index-capacity 1))]
    [steps : i64 0]
    (begin
      (while (< steps compiler-parse-dispatch-index-capacity)
        (let
          [present : i64 (compiler-parse-raw-i64-ref keys slot)]
          (cond
            [(= present 0) (return (compiler-parse-tag-unknown))]
            [(= present encoded)
              (return (compiler-parse-raw-i64-ref tags slot))]
            [else
              (begin
                (set!
                  slot
                  (bit-and
                    (+ slot 1)
                    (- compiler-parse-dispatch-index-capacity 1)))
                (set! steps (+ steps 1)))])))
      (compiler-parse-tag-unknown))))

(define (compiler-parse-dispatch-bind
  [env : sym_i64_env.SymI64Env]
  [name : String]
  [tag : i64]) : sym_i64_env.SymI64Env
  (let
    [control : i64
      (compiler-parse-env-marker-value env compiler-parse-state-marker-id)]
    [owner-address : i64
      (if (= control 0)
        0
        (compiler-parse-raw-i64-ref
          control
          compiler-parse-state-control-owner-addr))]
    [name-id : i64
      (if (= owner-address 0)
        (reader.stable-symbol-id name)
        (ci.intern-compat-state-intern
          (compiler-parse-state-owner control)
          name))]
    (sym_i64_env.sym-i64-bind-id env name-id tag)))

(define (compiler-parse-dispatch-binops [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [e1 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e "+" (compiler-parse-tag-bin-add))]
    [e2 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e1 "-" (compiler-parse-tag-bin-sub))]
    [e3 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e2 "*" (compiler-parse-tag-bin-mul))]
    [e4 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e3 "/" (compiler-parse-tag-bin-div))]
    [e5 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e4 "%" (compiler-parse-tag-bin-mod))]
    [e6 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e5 "=" (compiler-parse-tag-bin-eq))]
    [e7 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e6 "!=" (compiler-parse-tag-bin-ne))]
    [e8 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e7 "<" (compiler-parse-tag-bin-lt))]
    [e9 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e8 "<=" (compiler-parse-tag-bin-le))]
    [e10 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e9 ">" (compiler-parse-tag-bin-gt))]
    [e11 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e10 ">=" (compiler-parse-tag-bin-ge))]
    [e12 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e11
        "bit-and"
        (compiler-parse-tag-bin-bit-and))]
    [e13 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e12
        "bit-or"
        (compiler-parse-tag-bin-bit-or))]
    [e14 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e13
        "bit-xor"
        (compiler-parse-tag-bin-bit-xor))]
    [e15 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e14 "shl" (compiler-parse-tag-bin-shl))]
    (compiler-parse-dispatch-bind e15 "shr" (compiler-parse-tag-bin-shr))))

(define (compiler-parse-dispatch-unops [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [e1 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e "not" (compiler-parse-tag-un-not))]
    [e2 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e1 "neg" (compiler-parse-tag-un-neg))]
    (compiler-parse-dispatch-bind e2 "bit-not" (compiler-parse-tag-un-bit-not))))

(define (compiler-parse-dispatch-types [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [out : sym_i64_env.SymI64Env e]
    (begin
      (set!
        out
        (compiler-parse-dispatch-bind out "i64" (compiler-parse-tag-ty-i64)))
      (set!
        out
        (compiler-parse-dispatch-bind out "i32" (compiler-parse-tag-ty-i32)))
      (set!
        out
        (compiler-parse-dispatch-bind out "i16" (compiler-parse-tag-ty-i16)))
      (set!
        out
        (compiler-parse-dispatch-bind out "i8" (compiler-parse-tag-ty-i8)))
      (set!
        out
        (compiler-parse-dispatch-bind out "u64" (compiler-parse-tag-ty-u64)))
      (set!
        out
        (compiler-parse-dispatch-bind out "u32" (compiler-parse-tag-ty-u32)))
      (set!
        out
        (compiler-parse-dispatch-bind out "u16" (compiler-parse-tag-ty-u16)))
      (set!
        out
        (compiler-parse-dispatch-bind out "u8" (compiler-parse-tag-ty-u8)))
      (set!
        out
        (compiler-parse-dispatch-bind out "f64" (compiler-parse-tag-ty-f64)))
      (set!
        out
        (compiler-parse-dispatch-bind out "f32" (compiler-parse-tag-ty-f32)))
      (set!
        out
        (compiler-parse-dispatch-bind out "bool" (compiler-parse-tag-ty-bool)))
      (set!
        out
        (compiler-parse-dispatch-bind out "char" (compiler-parse-tag-ty-char)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "String"
          (compiler-parse-tag-ty-string)))
      (set!
        out
        (compiler-parse-dispatch-bind out "str" (compiler-parse-tag-ty-str)))
      (set!
        out
        (compiler-parse-dispatch-bind out "bytes" (compiler-parse-tag-ty-bytes)))
      (set!
        out
        (compiler-parse-dispatch-bind out "unit" (compiler-parse-tag-unit)))
      (set!
        out
        (compiler-parse-dispatch-bind out "never" (compiler-parse-tag-ty-never)))
      (set!
        out
        (compiler-parse-dispatch-bind out "->" (compiler-parse-tag-ty-func)))
      (set!
        out
        (compiler-parse-dispatch-bind out "Tuple" (compiler-parse-tag-ty-tuple)))
      (set!
        out
        (compiler-parse-dispatch-bind out "Array" (compiler-parse-tag-ty-array)))
      (set!
        out
        (compiler-parse-dispatch-bind out "in" (compiler-parse-tag-ty-region)))
      (set!
        out
        (compiler-parse-dispatch-bind out "Ptr" (compiler-parse-tag-ty-ptr)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "MutPtr"
          (compiler-parse-tag-ty-mut-ptr)))
      (set!
        out
        (compiler-parse-dispatch-bind out "&" (compiler-parse-tag-ty-ref)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "&mut"
          (compiler-parse-tag-ty-mut-ref)))
      (set!
        out
        (compiler-parse-dispatch-bind out "Box" (compiler-parse-tag-ty-box)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_dyn-array"
          (compiler-parse-tag-ty-dyn-array)))
      (set!
        out
        (compiler-parse-dispatch-bind out "Slice" (compiler-parse-tag-ty-slice)))
      out)))

(define (compiler-parse-dispatch-exprs [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [out : sym_i64_env.SymI64Env e]
    (begin
      (set!
        out
        (compiler-parse-dispatch-bind out "if" (compiler-parse-tag-expr-if)))
      (set!
        out
        (compiler-parse-dispatch-bind out "let" (compiler-parse-tag-expr-let)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "lambda"
          (compiler-parse-tag-expr-lambda)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "while"
          (compiler-parse-tag-expr-while)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "begin"
          (compiler-parse-tag-expr-begin)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "unsafe"
          (compiler-parse-tag-expr-unsafe)))
      (set!
        out
        (compiler-parse-dispatch-bind out "set!" (compiler-parse-tag-expr-set)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "replace!"
          (compiler-parse-tag-expr-replace)))
      (set!
        out
        (compiler-parse-dispatch-bind out "ann" (compiler-parse-tag-expr-ann)))
      (set!
        out
        (compiler-parse-dispatch-bind out "cast" (compiler-parse-tag-expr-cast)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "tuple"
          (compiler-parse-tag-expr-tuple)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "tuple-ref"
          (compiler-parse-tag-expr-tuple-ref)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "array"
          (compiler-parse-tag-expr-array)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "make-array"
          (compiler-parse-tag-expr-fixed-make-array)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_make-array"
          (compiler-parse-tag-expr-make-array)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "array-ref"
          (compiler-parse-tag-expr-array-ref)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_array-ref"
          (compiler-parse-tag-expr-array-ref)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "array-set!"
          (compiler-parse-tag-expr-retired-array-set)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_array-set!"
          (compiler-parse-tag-expr-array-set)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "array-push!"
          (compiler-parse-tag-expr-retired-array-push)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_array-push!"
          (compiler-parse-tag-expr-array-push)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "array-take!"
          (compiler-parse-tag-expr-fixed-array-take)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_array-take!"
          (compiler-parse-tag-expr-array-take)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_for-owned-state"
          (compiler-parse-tag-expr-for-owned-state)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_for-owned-step"
          (compiler-parse-tag-expr-for-owned-step)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_for-owned-step-typed"
          (compiler-parse-tag-expr-for-owned-step-typed)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "match"
          (compiler-parse-tag-expr-match)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "foreach"
          (compiler-parse-tag-expr-foreach)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "spmd-reduce"
          (compiler-parse-tag-expr-spmd-reduce)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "spmd-scan"
          (compiler-parse-tag-expr-spmd-scan)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "spmd-broadcast"
          (compiler-parse-tag-expr-spmd-broadcast)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "spmd-shuffle"
          (compiler-parse-tag-expr-spmd-shuffle)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "program-index"
          (compiler-parse-tag-expr-spmd-program-index)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "program-count"
          (compiler-parse-tag-expr-spmd-program-count)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "struct-get"
          (compiler-parse-tag-expr-retired-struct-get)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_struct-get"
          (compiler-parse-tag-expr-struct-get)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "struct-set"
          (compiler-parse-tag-expr-retired-struct-set)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "struct-set!"
          (compiler-parse-tag-expr-retired-struct-set)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "comptime"
          (compiler-parse-tag-expr-comptime)))
      ;; `with-arena` is the canonical scoped-arena spelling.
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "with-arena"
          (compiler-parse-tag-expr-with-region)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "with-escape"
          (compiler-parse-tag-expr-with-escape)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "with-scratch"
          (compiler-parse-tag-expr-with-scratch)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "in-arena"
          (compiler-parse-tag-expr-in-arena)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "type"
          (compiler-parse-tag-expr-type-literal)))
      (set!
        out
        (compiler-parse-dispatch-bind out "init" (compiler-parse-tag-expr-init)))
      (set!
        out
        (compiler-parse-dispatch-bind out "try" (compiler-parse-tag-expr-try)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "return"
          (compiler-parse-tag-expr-return)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "break"
          (compiler-parse-tag-expr-break)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "continue"
          (compiler-parse-tag-expr-continue)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "ptr-null"
          (compiler-parse-tag-expr-ptr-null)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "ptr-null?"
          (compiler-parse-tag-expr-ptr-null-check)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "ptr-read"
          (compiler-parse-tag-expr-ptr-read)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "ptr-write!"
          (compiler-parse-tag-expr-ptr-write)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "ptr-offset"
          (compiler-parse-tag-expr-ptr-offset)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "ptr-cast"
          (compiler-parse-tag-expr-ptr-cast)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "ptr->int"
          (compiler-parse-tag-expr-ptr-to-int)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "int->ptr"
          (compiler-parse-tag-expr-int-to-ptr)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "ptr-addr-of"
          (compiler-parse-tag-expr-ptr-addr-of)))
      (set!
        out
        (compiler-parse-dispatch-bind out "box" (compiler-parse-tag-expr-box)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "box-get"
          (compiler-parse-tag-expr-retired-box-get)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_box-get"
          (compiler-parse-tag-expr-box-get)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "box-take"
          (compiler-parse-tag-expr-retired-box-take)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_box-take"
          (compiler-parse-tag-expr-box-take)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "deref"
          (compiler-parse-tag-expr-deref)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "string-data"
          (compiler-parse-tag-expr-string-data)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "string-from-bytes"
          (compiler-parse-tag-expr-string-from-bytes)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "array-data"
          (compiler-parse-tag-expr-retired-array-data)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "__tl_array-data"
          (compiler-parse-tag-expr-array-data)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "program-argc"
          (compiler-parse-tag-expr-program-argc)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "program-argv"
          (compiler-parse-tag-expr-program-argv)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "program-envp"
          (compiler-parse-tag-expr-program-envp)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "cpuid-eax"
          (compiler-parse-tag-expr-cpuid-eax)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "cpuid-ebx"
          (compiler-parse-tag-expr-cpuid-ebx)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "cpuid-ecx"
          (compiler-parse-tag-expr-cpuid-ecx)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "cpuid-edx"
          (compiler-parse-tag-expr-cpuid-edx)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "xgetbv"
          (compiler-parse-tag-expr-xgetbv)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "syscall"
          (compiler-parse-tag-expr-syscall)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "with"
          (compiler-parse-tag-expr-with-resource)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "quote"
          (compiler-parse-tag-expr-quote)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "quasiquote"
          (compiler-parse-tag-expr-quasiquote)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "unquote"
          (compiler-parse-tag-expr-unquote)))
      (set!
        out
        (compiler-parse-dispatch-bind
          out
          "unquote-splicing"
          (compiler-parse-tag-expr-unquote-splicing)))
      out)))

(define (compiler-parse-dispatch-patterns [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [e1 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e "true" (compiler-parse-tag-lit-true))]
    [e2 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e1 "false" (compiler-parse-tag-lit-false))]
    (compiler-parse-dispatch-bind e2 "_" (compiler-parse-tag-pattern-wildcard))))

(define (compiler-parse-dispatch-decls [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [e1 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e "define" (compiler-parse-tag-decl-define))]
    [e2 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e1
        "extern"
        (compiler-parse-tag-decl-extern))]
    [e3 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e2
        "defenum"
        (compiler-parse-tag-decl-defenum))]
    [e4 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e3
        "defstruct"
        (compiler-parse-tag-decl-defstruct))]
    [e5 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e4
        "import"
        (compiler-parse-tag-decl-import))]
    [e8 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e5
        "module"
        (compiler-parse-tag-decl-module))]
    [e9 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind e8 "test" (compiler-parse-tag-decl-test))]
    [e10 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e9
        "defmacro"
        (compiler-parse-tag-decl-defmacro))]
    [e12 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e10
        "include-str"
        (compiler-parse-tag-decl-include-str))]
    [e13 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e12
        "include-str-comptime"
        (compiler-parse-tag-decl-include-str-comptime))]
    [e14 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e13
        "include-str-lzss"
        (compiler-parse-tag-decl-include-str-lzss))]
    [e15 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e14
        (compiler-parse-removed-compressed-include-name)
        (compiler-parse-tag-decl-removed-compressed-include))]
    [e16 : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-bind
        e15
        "include-bin"
        (compiler-parse-tag-decl-include-bin))]
    (compiler-parse-dispatch-bind
      e16
      "defdispatch"
      (compiler-parse-tag-decl-defdispatch))))

(define (compiler-parse-dispatch-cache-ref [control : i64]) : sym_i64_env.SymI64Env
  (let
    [cache : (__tl_dyn-array sym_i64_env.SymI64Env)
      (unsafe
        (ptr-read
          (int->ptr
            (compiler-parse-raw-i64-ref
              control
              compiler-parse-state-control-cache-addr)
            : (Ptr (__tl_dyn-array sym_i64_env.SymI64Env)))))]
    (array-ref cache 0)))

(define (compiler-parse-dispatch-cache-set!
  [control : i64]
  [dispatch : sym_i64_env.SymI64Env]) : unit
  (let
    [cache : (__tl_dyn-array sym_i64_env.SymI64Env)
      (unsafe
        (ptr-read
          (int->ptr
            (compiler-parse-raw-i64-ref
              control
              compiler-parse-state-control-cache-addr)
            : (Ptr (__tl_dyn-array sym_i64_env.SymI64Env)))))]
    (set! (array-ref cache 0) dispatch)))

(define (compiler-parse-state-owner-floor-refresh! [control : i64]) : unit
  (if (=
    (compiler-parse-raw-i64-ref control compiler-parse-state-control-owner-addr)
    0)
    (ci.intern-persistent-arena-floor-refresh!)
    (ci.intern-compat-state-persistent-arena-floor-refresh!
      (compiler-parse-state-owner control))))

(define (compiler-parse-state-owner-sync-active! [control : i64]) : unit
  (let
    [owner-address : i64
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-owner-addr)]
    (if (or
      (= owner-address 0)
      (not
        (=
          (compiler-parse-state-owner-table-id control)
          (ci.intern-active-table-id))))
      unit
      (ci.intern-compat-state-install! (compiler-parse-state-owner control)))))

(define (compiler-parse-state-owner-capture-active! [control : i64]) : unit
  (let
    [owner-address : i64
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-owner-addr)]
    (if (or
      (= owner-address 0)
      (not
        (=
          (compiler-parse-state-owner-table-id control)
          (ci.intern-active-table-id))))
      unit
      (ci.intern-compat-state-capture-from-globals!
        (compiler-parse-state-owner control)))))

(define (compiler-parse-dispatch-env-for-control [control : i64]) : sym_i64_env.SymI64Env
  (begin
    ;; Builtin seeding may have advanced an already-installed owner's scalar
    ;; compatibility view. Capture it before direct state-owned interning.
    (compiler-parse-state-owner-capture-active! control)
    (if (and
      (not
        (=
          (compiler-parse-raw-i64-ref
            control
            compiler-parse-state-control-ready)
          0))
      (compiler-parse-dispatch-index-current-control? control))
      (compiler-parse-dispatch-cache-ref control)
      (let
        [persistent-arena : arena.Arena
          (arena.Arena (compiler-parse-state-owner-persistent-arena control))]
        (in-arena
          persistent-arena
          (let
            [seed : sym_i64_env.SymI64Env
              (sym_i64_env.sym-i64-bind-id
                (sym_i64_env.sym-i64-empty)
                compiler-parse-state-marker-id
                control)]
            [dispatch : sym_i64_env.SymI64Env
              (compiler-parse-dispatch-decls
                (compiler-parse-dispatch-patterns
                  (compiler-parse-dispatch-exprs
                    (compiler-parse-dispatch-types
                      (compiler-parse-dispatch-unops
                        (compiler-parse-dispatch-binops seed))))))]
            (begin
              (compiler-parse-dispatch-index-populate! control dispatch)
              (compiler-parse-dispatch-cache-set! control dispatch)
              (compiler-parse-state-owner-floor-refresh! control)
              ;; Direct owner interning advances the state's scalar pool count.
              ;; When that owner is already installed, publish those scalars once
              ;; after the immutable dispatch is complete so subsequent source
              ;; lexing continues after its syntax IDs. Inactive owners remain
              ;; untouched, preserving A/B state isolation.
              (compiler-parse-state-owner-sync-active! control)
              dispatch)))))))

(define (compiler-parse-dispatch-env-from-cfg [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [owned-cfgs : sym_i64_env.SymI64Env
      (if (=
        (compiler-parse-env-marker-value cfgs compiler-parse-state-marker-id)
        0)
        (compiler-parse-state-cfgs
          (compiler-parse-default-state-shared-view)
          cfgs)
        cfgs)]
    [control : i64
      (compiler-parse-env-marker-value
        owned-cfgs
        compiler-parse-state-marker-id)]
    (compiler-parse-dispatch-index-mark
      (compiler-cfg-merge
        (compiler-parse-dispatch-env-for-control control)
        owned-cfgs))))

(define (compiler-parse-dispatch-env) : sym_i64_env.SymI64Env
  (compiler-parse-dispatch-env-from-cfg (compiler-cfg-empty)))

(define (compiler-parse-dispatch-tag
  [dispatch : sym_i64_env.SymI64Env]
  [name-id : i64]) : i64
  (compiler-parse-dispatch-tag-id dispatch name-id))

(define (compiler-parse-dispatch-tag-id
  [dispatch : sym_i64_env.SymI64Env]
  [name-id : i64]) : i64
  (let
    [control : i64 (compiler-parse-dispatch-indexed-control dispatch)]
    (if (not (= control 0))
      (compiler-parse-dispatch-index-lookup-id control name-id)
      (match (sym_i64_env.sym-i64-lookup-id dispatch name-id)
        [(option_i64.Some tag) tag]
        [(option_i64.None) (compiler-parse-tag-unknown)]))))

(define (ast-binop-tag? [tag : i64]) : bool
  (or
    (= tag (compiler-parse-tag-bin-add))
    (= tag (compiler-parse-tag-bin-sub))
    (= tag (compiler-parse-tag-bin-mul))
    (= tag (compiler-parse-tag-bin-div))
    (= tag (compiler-parse-tag-bin-mod))
    (= tag (compiler-parse-tag-bin-eq))
    (= tag (compiler-parse-tag-bin-ne))
    (= tag (compiler-parse-tag-bin-lt))
    (= tag (compiler-parse-tag-bin-le))
    (= tag (compiler-parse-tag-bin-gt))
    (= tag (compiler-parse-tag-bin-ge))
    (= tag (compiler-parse-tag-bin-bit-and))
    (= tag (compiler-parse-tag-bin-bit-or))
    (= tag (compiler-parse-tag-bin-bit-xor))
    (= tag (compiler-parse-tag-bin-shl))
    (= tag (compiler-parse-tag-bin-shr))))

(define (ast-left-fold-binop-tag? [tag : i64]) : bool
  (or
    (= tag (compiler-parse-tag-bin-add))
    (= tag (compiler-parse-tag-bin-mul))
    (= tag (compiler-parse-tag-bin-bit-and))
    (= tag (compiler-parse-tag-bin-bit-or))
    (= tag (compiler-parse-tag-bin-bit-xor))))

(define (ast-binop-from-tag [tag : i64]) : ast.AstBinOp
  (cond
    [(= tag (compiler-parse-tag-bin-add)) (ast.AstBinOp.Add)]
    [(= tag (compiler-parse-tag-bin-sub)) (ast.AstBinOp.Sub)]
    [(= tag (compiler-parse-tag-bin-mul)) (ast.AstBinOp.Mul)]
    [(= tag (compiler-parse-tag-bin-div)) (ast.AstBinOp.Div)]
    [(= tag (compiler-parse-tag-bin-mod)) (ast.AstBinOp.Mod)]
    [(= tag (compiler-parse-tag-bin-eq)) (ast.AstBinOp.Eq)]
    [(= tag (compiler-parse-tag-bin-ne)) (ast.AstBinOp.Ne)]
    [(= tag (compiler-parse-tag-bin-lt)) (ast.AstBinOp.Lt)]
    [(= tag (compiler-parse-tag-bin-le)) (ast.AstBinOp.Le)]
    [(= tag (compiler-parse-tag-bin-gt)) (ast.AstBinOp.Gt)]
    [(= tag (compiler-parse-tag-bin-ge)) (ast.AstBinOp.Ge)]
    [(= tag (compiler-parse-tag-bin-bit-and)) (ast.AstBinOp.BitAnd)]
    [(= tag (compiler-parse-tag-bin-bit-or)) (ast.AstBinOp.BitOr)]
    [(= tag (compiler-parse-tag-bin-bit-xor)) (ast.AstBinOp.BitXor)]
    [(= tag (compiler-parse-tag-bin-shl)) (ast.AstBinOp.Shl)]
    [else (ast.AstBinOp.Shr)]))

(define (ast-unop-tag? [tag : i64]) : bool
  (if (= tag (compiler-parse-tag-un-not))
    true
    (if (= tag (compiler-parse-tag-un-neg))
      true
      (= tag (compiler-parse-tag-un-bit-not)))))

(define (ast-unop-from-tag [tag : i64]) : ast.AstUnOp
  (if (= tag (compiler-parse-tag-un-not))
    (ast.AstUnOp.Not)
    (if (= tag (compiler-parse-tag-un-neg))
      (ast.AstUnOp.Neg)
      (ast.AstUnOp.BitNot))))

(define (parse-ast-type-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]
  [out : (&mut out ast.AstTypeList)]) : ResultAstTypeListBuild
  (match (reader.sexpr-view s)
    [(reader.SexprView.Nil) (ResultAstTypeListBuild.Ok)]
    [(reader.SexprView.Cons head tail)
      (match (parse-ast-type dispatch pools head)
        [(ResultAstType.Ok parsed-head)
          (begin
            (ast.ast-type-list-push
              out
              (ast.ast-node-pool-context-type-push pools parsed-head))
            (parse-ast-type-list dispatch pools tail out))]
        [(ResultAstType.Err message) (ResultAstTypeListBuild.Err message)])]
    [_ (ResultAstTypeListBuild.Err "parse: malformed type list")]))

(define (parse-ast-type-list-result
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstTypeList
  (let
    [out : ast.AstTypeList (ast.ast-type-list-new)]
    (match (parse-ast-type-list dispatch pools s (&mut out))
      [(ResultAstTypeListBuild.Ok) (ResultAstTypeList.Ok out)]
      [(ResultAstTypeListBuild.Err message) (ResultAstTypeList.Err message)])))

(define (parse-ast-lifetime-name?
  [dispatch : sym_i64_env.SymI64Env]
  [name : ci.InternSyntaxId]) : bool
  (let
    [tag : i64
      (compiler-parse-dispatch-tag dispatch (ci.intern-syntax-id-value name))]
    (not
      (or
        (and
          (>= tag (compiler-parse-tag-ty-i64))
          (<= tag (compiler-parse-tag-ty-bytes)))
        (and
          (>= tag (compiler-parse-tag-ty-func))
          (<= tag (compiler-parse-tag-ty-slice)))))))

(define (parse-ast-lifetime-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]
  [message : String]
  [out : (&mut out ast.AstLifetimeList)]) : ResultAstLifetimeListBuild
  (match (reader.sexpr-view s)
    [(reader.SexprView.Nil) (ResultAstLifetimeListBuild.Ok)]
    [(reader.SexprView.Cons head tail)
      (match (reader.sexpr-view head)
        [(reader.SexprView.Sym name)
          (if (parse-ast-lifetime-name? dispatch name)
            (begin
              (ast.ast-lifetime-list-push out (ci.intern-syntax-id-value name))
              (parse-ast-lifetime-list dispatch pools tail message out))
            (ResultAstLifetimeListBuild.Err message))]
        [_ (ResultAstLifetimeListBuild.Err message)])]
    [(reader.SexprView.Cons _ _) (ResultAstLifetimeListBuild.Err message)]
    [_ (ResultAstLifetimeListBuild.Err message)]))

(define (parse-ast-lifetime-list-result
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]
  [message : String]) : ResultAstLifetimeList
  (let
    [out : ast.AstLifetimeList (ast.ast-lifetime-list-new)]
    (match (parse-ast-lifetime-list dispatch pools s message (&mut out))
      [(ResultAstLifetimeListBuild.Ok) (ResultAstLifetimeList.Ok out)]
      [(ResultAstLifetimeListBuild.Err parse-message)
        (ResultAstLifetimeList.Err parse-message)])))

(define (parse-ast-lifetime-list-nonempty
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]
  [message : String]) : ResultAstLifetimeList
  (match (reader.sexpr-view s)
    [(reader.SexprView.Nil) (ResultAstLifetimeList.Err message)]
    [_ (parse-ast-lifetime-list-result dispatch pools s message)]))

(define (parse-ast-consuming-param-type-allowed? [ty : ast.AstType]) : bool
  (match ty
    [(ast.AstType.Ref _ _) false]
    [(ast.AstType.MutRef _ _) false]
    [(ast.AstType.Consume _) false]
    [_ true]))

(define (parse-ast-func-param-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstType
  (match (reader.sexpr-view s)
    [(reader.SexprView.Cons key-node tail)
      (match (reader.sexpr-view key-node)
        [(reader.SexprView.Sym key)
          (if (=
            (ci.intern-syntax-id-value key)
            (cbi.compiler-builtin-ctfe-ref 179))
            (match (reader.sexpr-view tail)
              [(reader.SexprView.Cons ty-node end)
                (match (reader.sexpr-view end)
                  [(reader.SexprView.Nil)
                    (match (parse-ast-type dispatch pools ty-node)
                      [(ResultAstType.Ok ty)
                        (if (parse-ast-consuming-param-type-allowed? ty)
                          (ResultAstType.Ok
                            (ast.ast-ty-consume-with-pools pools ty))
                          (ResultAstType.Err
                            "parse: :consume requires a non-reference parameter type"))]
                      [(ResultAstType.Err message) (ResultAstType.Err message)])]
                  [_
                    (ResultAstType.Err
                      "parse: (:consume T) expects exactly one type")])]
              [_
                (ResultAstType.Err
                  "parse: (:consume T) expects exactly one type")])
            (parse-ast-type dispatch pools s))]
        [_ (parse-ast-type dispatch pools s)])]
    [_ (parse-ast-type dispatch pools s)]))

(define (parse-ast-func-type-parts
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstFuncTypeParts
  (match (reader.sexpr-view s)
    [(reader.SexprView.Cons arg rest)
      (match (reader.sexpr-view rest)
        [(reader.SexprView.Nil)
          (match (parse-ast-type dispatch pools arg)
            [(ResultAstType.Ok parsed-ret)
              (ResultAstFuncTypeParts.Ok (ast.ast-type-list-new) parsed-ret)]
            [(ResultAstType.Err message) (ResultAstFuncTypeParts.Err message)])]
        [_
          (match (parse-ast-func-param-type dispatch pools arg)
            [(ResultAstType.Ok parsed-arg)
              (match (parse-ast-func-type-parts dispatch pools rest)
                [(ResultAstFuncTypeParts.Ok parsed-args parsed-ret)
                  (ResultAstFuncTypeParts.Ok
                    (ast.ast-type-cons-with-pools pools parsed-arg parsed-args)
                    parsed-ret)]
                [(ResultAstFuncTypeParts.Err message)
                  (ResultAstFuncTypeParts.Err message)])]
            [(ResultAstType.Err message) (ResultAstFuncTypeParts.Err message)])])]
    [_
      (ResultAstFuncTypeParts.Err
        "parse: function type needs at least return type")]))

(define (parse-ast-internal-binary-data
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons bytes-node tail _)
      (match (reader.spanned-sexpr-view bytes-node)
        [(reader.SpannedSexprView.Str bytes _)
          (match (reader.spanned-sexpr-view tail)
            [(reader.SpannedSexprView.Nil _)
              (ResultAstExpr.Ok
                (ast.ast-node-pool-context-expr-push
                  pools
                  (ast.AstExpr.BinaryData
                    (compiler-parse-dispatch-id-str dispatch bytes))))]
            [_ (ResultAstExpr.Err "parse: malformed internal binary data")])]
        [_ (ResultAstExpr.Err "parse: malformed internal binary data")])]
    [_ (ResultAstExpr.Err "parse: malformed internal binary data")]))

(define (parse-ast-resolved-nominal-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.Sexpr]
  [is-struct : bool]) : ResultAstType
  (match (reader.sexpr-view rest)
    [(reader.SexprView.Cons name-node lifetimes-box)
      (match (reader.sexpr-view name-node)
        [(reader.SexprView.Sym name-id)
          (let
            [raw-name-id : i64 (ci.intern-syntax-id-value name-id)]
            (match (parse-ast-lifetime-list-result
              dispatch
              pools
              lifetimes-box
              "parse: malformed internal resolved type lifetime list")
              [(ResultAstLifetimeList.Ok lifetimes)
                (ResultAstType.Ok
                  (if is-struct
                    (if (ast.ast-lifetime-list-empty? (& lifetimes))
                      (ast.AstType.Struct raw-name-id)
                      (ast.ast-ty-struct-args raw-name-id lifetimes))
                    (if (ast.ast-lifetime-list-empty? (& lifetimes))
                      (ast.AstType.Enum raw-name-id)
                      (ast.ast-ty-enum-args raw-name-id lifetimes))))]
              [(ResultAstLifetimeList.Err message) (ResultAstType.Err message)]))]
        [(reader.SexprView.Str _)
          (ResultAstType.Err
            "parse: malformed internal resolved type name was string")]
        [(reader.SexprView.Int _ _)
          (ResultAstType.Err
            "parse: malformed internal resolved type name was integer")]
        [(reader.SexprView.Nil)
          (ResultAstType.Err
            "parse: malformed internal resolved type name was nil")]
        [(reader.SexprView.Cons _ _)
          (ResultAstType.Err
            "parse: malformed internal resolved type name was list")]
        [(reader.SexprView.Char _)
          (ResultAstType.Err
            "parse: malformed internal resolved type name was char")]
        [(reader.SexprView.Float _)
          (ResultAstType.Err
            "parse: malformed internal resolved type name was float")])]
    [_ (ResultAstType.Err "parse: malformed internal resolved type shape")]))

(define (parse-ast-reference-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.Sexpr]
  [mutable : bool]) : ResultAstType
  (match (reader.sexpr-view rest)
    [(reader.SexprView.Cons first tail)
      (match (reader.sexpr-view tail)
        ;; The parser is context-free. An empty lifetime marker is legal in
        ;; the AST, but the typechecker only accepts it while normalizing a
        ;; function signature into hidden signature-local lifetimes.
        [(reader.SexprView.Nil)
          (match (parse-ast-type dispatch pools first)
            [(ResultAstType.Ok inner-ty)
              (if mutable
                (ResultAstType.Ok
                  (ast.ast-ty-mut-ref-with-pools
                    pools
                    cbi.compiler-builtin-id-fix-empty
                    inner-ty))
                (ResultAstType.Ok
                  (ast.ast-ty-ref-with-pools
                    pools
                    cbi.compiler-builtin-id-fix-empty
                    inner-ty)))]
            [(ResultAstType.Err message) (ResultAstType.Err message)])]
        [(reader.SexprView.Cons inner end)
          (match (reader.sexpr-view end)
            [(reader.SexprView.Nil)
              (match (reader.sexpr-view first)
                [(reader.SexprView.Sym region)
                  (match (parse-ast-type dispatch pools inner)
                    [(ResultAstType.Ok inner-ty)
                      (if mutable
                        (ResultAstType.Ok
                          (ast.ast-ty-mut-ref-with-pools
                            pools
                            (ci.intern-syntax-id-value region)
                            inner-ty))
                        (ResultAstType.Ok
                          (ast.ast-ty-ref-with-pools
                            pools
                            (ci.intern-syntax-id-value region)
                            inner-ty)))]
                    [(ResultAstType.Err message) (ResultAstType.Err message)])]
                [_
                  (ResultAstType.Err
                    "parse: reference lifetime must be an identifier")])]
            [_
              (ResultAstType.Err
                (if mutable
                  "parse: &mut expects an optional lifetime and exactly one type"
                  "parse: & expects an optional lifetime and exactly one type"))])]
        [_
          (ResultAstType.Err
            (if mutable
              "parse: &mut expects an optional lifetime and exactly one type"
              "parse: & expects an optional lifetime and exactly one type"))])]
    [_
      (ResultAstType.Err
        (if mutable
          "parse: &mut expects an optional lifetime and exactly one type"
          "parse: & expects an optional lifetime and exactly one type"))]))

(define (parse-ast-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstType
  (match (reader.sexpr-view s)
    [(reader.SexprView.Sym name)
      (let
        [name-id : i64 (ci.intern-syntax-id-value name)]
        [tag : i64 (compiler-parse-dispatch-tag-id dispatch name-id)]
        (cond
          [(= tag (compiler-parse-tag-ty-i64))
            (ResultAstType.Ok (ast.AstType.I64))]
          [(= tag (compiler-parse-tag-ty-i32))
            (ResultAstType.Ok (ast.AstType.I32))]
          [(= tag (compiler-parse-tag-ty-i16))
            (ResultAstType.Ok (ast.AstType.I16))]
          [(= tag (compiler-parse-tag-ty-i8))
            (ResultAstType.Ok (ast.AstType.I8))]
          [(= tag (compiler-parse-tag-ty-u64))
            (ResultAstType.Ok (ast.AstType.U64))]
          [(= tag (compiler-parse-tag-ty-u32))
            (ResultAstType.Ok (ast.AstType.U32))]
          [(= tag (compiler-parse-tag-ty-u16))
            (ResultAstType.Ok (ast.AstType.U16))]
          [(= tag (compiler-parse-tag-ty-u8))
            (ResultAstType.Ok (ast.AstType.U8))]
          [(= tag (compiler-parse-tag-ty-f64))
            (ResultAstType.Ok (ast.AstType.F64))]
          [(= tag (compiler-parse-tag-ty-f32))
            (ResultAstType.Ok (ast.AstType.F32))]
          [(= tag (compiler-parse-tag-ty-bool))
            (ResultAstType.Ok (ast.AstType.Bool))]
          [(= tag (compiler-parse-tag-ty-char))
            (ResultAstType.Ok (ast.AstType.Char))]
          [(= tag (compiler-parse-tag-ty-string))
            (ResultAstType.Ok (ast.AstType.String))]
          [(= tag (compiler-parse-tag-ty-str))
            (ResultAstType.Ok (ast.AstType.Str))]
          [(= tag (compiler-parse-tag-ty-bytes))
            (ResultAstType.Ok (ast.AstType.Bytes))]
          [(= tag (compiler-parse-tag-unit))
            (ResultAstType.Ok (ast.AstType.Unit))]
          [(= tag (compiler-parse-tag-ty-never))
            (ResultAstType.Ok (ast.AstType.Never))]
          [(= tag (compiler-parse-tag-ty-expr))
            (ResultAstType.Ok (ast.AstType.Expr))]
          [else (ResultAstType.Ok (ast.AstType.Var name-id))]))]
    [(reader.SexprView.Cons head-node rest-box)
      (match (reader.sexpr-view head-node)
        [(reader.SexprView.Sym head)
          (let
            [rest : reader.Sexpr rest-box]
            [head-id : i64 (ci.intern-syntax-id-value head)]
            [tag : i64 (compiler-parse-dispatch-tag-id dispatch head-id)]
            (cond
              ;; Macro output uses these non-lexer-spellable builtin IDs to
              ;; carry already-resolved aggregate types through quasiquotes.
              [(= head-id (cbi.compiler-builtin-ctfe-ref 106))
                (parse-ast-resolved-nominal-type dispatch pools rest true)]
              [(= head-id (cbi.compiler-builtin-ctfe-ref 107))
                (parse-ast-resolved-nominal-type dispatch pools rest false)]
              [(= tag (compiler-parse-tag-ty-func))
                (match (parse-ast-func-type-parts dispatch pools rest)
                  [(ResultAstFuncTypeParts.Ok args ret)
                    (ResultAstType.Ok
                      (ast.ast-ty-func-with-pools pools args ret))]
                  [(ResultAstFuncTypeParts.Err message)
                    (ResultAstType.Err message)])]
              [(= tag (compiler-parse-tag-ty-tuple))
                (match (parse-ast-type-list-result dispatch pools rest)
                  [(ResultAstTypeList.Ok elems)
                    (ResultAstType.Ok (ast.ast-ty-tuple elems))]
                  [(ResultAstTypeList.Err message) (ResultAstType.Err message)])]
              [(= tag (compiler-parse-tag-ty-array))
                (match (reader.sexpr-view rest)
                  [(reader.SexprView.Cons elem tail)
                    (match (reader.sexpr-view tail)
                      [(reader.SexprView.Nil)
                        (ResultAstType.Err
                          "parse: unsized (Array T) was removed; use (Array T N), stdlib.vector, or a borrowed Slice")]
                      [(reader.SexprView.Cons size-node end)
                        (match (reader.sexpr-view end)
                          [(reader.SexprView.Nil)
                            (match (reader.sexpr-view size-node)
                              [(reader.SexprView.Int size _)
                                (match (parse-ast-type dispatch pools elem)
                                  [(ResultAstType.Ok elem-ty)
                                    (ResultAstType.Ok
                                      (ast.ast-ty-array-with-pools
                                        pools
                                        elem-ty
                                        size))]
                                  [(ResultAstType.Err message)
                                    (ResultAstType.Err message)])]
                              [_
                                (ResultAstType.Err
                                  "parse: array size must be integer")])]
                          [_ (ResultAstType.Err "parse: malformed array type")])]
                      [_ (ResultAstType.Err "parse: malformed array type")])]
                  [_ (ResultAstType.Err "parse: malformed array type")])]
              [(= tag (compiler-parse-tag-ty-dyn-array))
                (match (reader.sexpr-view rest)
                  [(reader.SexprView.Cons elem tail)
                    (match (reader.sexpr-view tail)
                      [(reader.SexprView.Nil)
                        (match (parse-ast-type dispatch pools elem)
                          [(ResultAstType.Ok elem-ty)
                            (ResultAstType.Ok
                              (ast.ast-ty-dyn-array-with-pools pools elem-ty))]
                          [(ResultAstType.Err message)
                            (ResultAstType.Err message)])]
                      [_
                        (ResultAstType.Err
                          "parse: __tl_dyn-array expects exactly one type")])]
                  [_
                    (ResultAstType.Err
                      "parse: __tl_dyn-array expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-slice))
                (match (reader.sexpr-view rest)
                  [(reader.SexprView.Cons elem tail)
                    (match (reader.sexpr-view tail)
                      [(reader.SexprView.Nil)
                        (match (parse-ast-type dispatch pools elem)
                          [(ResultAstType.Ok elem-ty)
                            (ResultAstType.Ok
                              (ast.ast-ty-slice-with-pools pools elem-ty))]
                          [(ResultAstType.Err message)
                            (ResultAstType.Err message)])]
                      [_
                        (ResultAstType.Err
                          "parse: Slice expects exactly one type")])]
                  [_
                    (ResultAstType.Err "parse: Slice expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-ptr))
                (match (reader.sexpr-view rest)
                  [(reader.SexprView.Cons elem tail)
                    (match (reader.sexpr-view tail)
                      [(reader.SexprView.Nil)
                        (match (parse-ast-type dispatch pools elem)
                          [(ResultAstType.Ok elem-ty)
                            (ResultAstType.Ok
                              (ast.ast-ty-ptr-with-pools pools elem-ty))]
                          [(ResultAstType.Err message)
                            (ResultAstType.Err message)])]
                      [_
                        (ResultAstType.Err
                          "parse: Ptr expects exactly one type")])]
                  [_ (ResultAstType.Err "parse: Ptr expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-mut-ptr))
                (match (reader.sexpr-view rest)
                  [(reader.SexprView.Cons elem tail)
                    (match (reader.sexpr-view tail)
                      [(reader.SexprView.Nil)
                        (match (parse-ast-type dispatch pools elem)
                          [(ResultAstType.Ok elem-ty)
                            (ResultAstType.Ok
                              (ast.ast-ty-mut-ptr-with-pools pools elem-ty))]
                          [(ResultAstType.Err message)
                            (ResultAstType.Err message)])]
                      [_
                        (ResultAstType.Err
                          "parse: MutPtr expects exactly one type")])]
                  [_
                    (ResultAstType.Err "parse: MutPtr expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-box))
                (match (reader.sexpr-view rest)
                  [(reader.SexprView.Cons elem tail)
                    (match (reader.sexpr-view tail)
                      [(reader.SexprView.Nil)
                        (match (parse-ast-type dispatch pools elem)
                          [(ResultAstType.Ok elem-ty)
                            (ResultAstType.Ok
                              (ast.ast-ty-box-with-pools pools elem-ty))]
                          [(ResultAstType.Err message)
                            (ResultAstType.Err message)])]
                      [_
                        (ResultAstType.Err
                          "parse: Box expects exactly one type")])]
                  [_ (ResultAstType.Err "parse: Box expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-ref))
                (parse-ast-reference-type dispatch pools rest false)]
              [(= tag (compiler-parse-tag-ty-mut-ref))
                (parse-ast-reference-type dispatch pools rest true)]
              [(= tag (compiler-parse-tag-ty-region))
                (match (reader.sexpr-view rest)
                  [(reader.SexprView.Cons region-node tail)
                    (match (reader.sexpr-view tail)
                      [(reader.SexprView.Cons inner end)
                        (match (reader.sexpr-view end)
                          [(reader.SexprView.Nil)
                            (match (reader.sexpr-view region-node)
                              [(reader.SexprView.Sym region)
                                (match (parse-ast-type dispatch pools inner)
                                  [(ResultAstType.Ok inner-ty)
                                    (ResultAstType.Ok
                                      (ast.ast-ty-region-with-pools
                                        pools
                                        (ci.intern-syntax-id-value region)
                                        inner-ty))]
                                  [(ResultAstType.Err message)
                                    (ResultAstType.Err message)])]
                              [_
                                (ResultAstType.Err
                                  "parse: region name must be an identifier")])]
                          [_ (ResultAstType.Err "parse: malformed region type")])]
                      [_ (ResultAstType.Err "parse: malformed region type")])]
                  [_ (ResultAstType.Err "parse: malformed region type")])]
              [else
                (match (parse-ast-lifetime-list-nonempty
                  dispatch
                  pools
                  rest
                  (compiler-parse-generic-type-policy-message
                    (compiler-parse-dispatch-syntax-id-text dispatch head)))
                  [(ResultAstLifetimeList.Ok lifetimes)
                    (ResultAstType.Ok (ast.ast-ty-var-args head-id lifetimes))]
                  [(ResultAstLifetimeList.Err message)
                    (ResultAstType.Err message)])]))]
        [_ (ResultAstType.Err "parse: expected type")])]
    [_ (ResultAstType.Err "parse: expected type")]))

(define (compiler-parse-semantic-type-list-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view items)
    [(reader.SpannedSexprView.Nil _) unit]
    [(reader.SpannedSexprView.Cons head tail _)
      (begin
        (compiler-parse-semantic-type-origins! dispatch head)
        (compiler-parse-semantic-type-list-origins! dispatch tail))]
    [_ unit]))

(define (compiler-parse-semantic-func-type-item-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [item : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view item)
    [(reader.SpannedSexprView.Cons key-node tail _)
      (match (reader.spanned-sexpr-view key-node)
        [(reader.SpannedSexprView.Sym key _)
          (if (=
            (ci.intern-syntax-id-value key)
            (cbi.compiler-builtin-ctfe-ref 179))
            (match (reader.spanned-sexpr-view tail)
              [(reader.SpannedSexprView.Cons ty-node end _)
                (match (reader.spanned-sexpr-view end)
                  [(reader.SpannedSexprView.Nil _)
                    (compiler-parse-semantic-type-origins! dispatch ty-node)]
                  [_ unit])]
              [_ unit])
            (compiler-parse-semantic-type-origins! dispatch item))]
        [_ (compiler-parse-semantic-type-origins! dispatch item)])]
    [_ (compiler-parse-semantic-type-origins! dispatch item)]))

(define (compiler-parse-semantic-func-type-list-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view items)
    [(reader.SpannedSexprView.Nil _) unit]
    [(reader.SpannedSexprView.Cons head tail _)
      (begin
        (compiler-parse-semantic-func-type-item-origins! dispatch head)
        (compiler-parse-semantic-func-type-list-origins! dispatch tail))]
    [_ unit]))

(define (compiler-parse-semantic-type-second-origin!
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view items)
    [(reader.SpannedSexprView.Cons _ tail _)
      (match (reader.spanned-sexpr-view tail)
        [(reader.SpannedSexprView.Cons second _ _)
          (compiler-parse-semantic-type-origins! dispatch second)]
        [_ unit])]
    [_ unit]))

(define (compiler-parse-semantic-type-first-origin!
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view items)
    [(reader.SpannedSexprView.Cons first _ _)
      (compiler-parse-semantic-type-origins! dispatch first)]
    [_ unit]))

(define (compiler-parse-semantic-reference-type-origin!
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view items)
    [(reader.SpannedSexprView.Cons first tail _)
      (match (reader.spanned-sexpr-view tail)
        [(reader.SpannedSexprView.Nil _)
          (compiler-parse-semantic-type-origins! dispatch first)]
        [(reader.SpannedSexprView.Cons second _ _)
          (compiler-parse-semantic-type-origins! dispatch second)]
        [_ unit])]
    [_ unit]))

(define (compiler-parse-semantic-type-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view s)
    [(reader.SpannedSexprView.Sym name span)
      (let
        [name-id : i64 (ci.intern-syntax-id-value name)]
        [tag : i64 (compiler-parse-dispatch-tag-id dispatch name-id)]
        (if (or
          (and
            (>= tag (compiler-parse-tag-ty-i64))
            (<= tag (compiler-parse-tag-ty-bytes)))
          (= tag (compiler-parse-tag-unit))
          (= tag (compiler-parse-tag-ty-never))
          (= tag (compiler-parse-tag-ty-expr)))
          unit
          (compiler-parse-semantic-origin-push-components!
            name
            span
            (CompilerParseSemanticOriginKind.ModulePath)
            (CompilerParseSemanticOriginKind.TypeName))))]
    [(reader.SpannedSexprView.Cons head-node rest _)
      (match (reader.spanned-sexpr-view head-node)
        [(reader.SpannedSexprView.Sym head head-span)
          (let
            [head-id : i64 (ci.intern-syntax-id-value head)]
            [tag : i64 (compiler-parse-dispatch-tag-id dispatch head-id)]
            (cond
              [(or
                  (= head-id (cbi.compiler-builtin-ctfe-ref 106))
                  (= head-id (cbi.compiler-builtin-ctfe-ref 107)))
                unit]
              [(= tag (compiler-parse-tag-ty-func))
                (compiler-parse-semantic-func-type-list-origins! dispatch rest)]
              [(= tag (compiler-parse-tag-ty-tuple))
                (compiler-parse-semantic-type-list-origins! dispatch rest)]
              [(or
                  (= tag (compiler-parse-tag-ty-array))
                  (= tag (compiler-parse-tag-ty-dyn-array))
                  (= tag (compiler-parse-tag-ty-slice))
                  (= tag (compiler-parse-tag-ty-ptr))
                  (= tag (compiler-parse-tag-ty-mut-ptr))
                  (= tag (compiler-parse-tag-ty-box)))
                (compiler-parse-semantic-type-first-origin! dispatch rest)]
              [(or
                  (= tag (compiler-parse-tag-ty-ref))
                  (= tag (compiler-parse-tag-ty-mut-ref)))
                (compiler-parse-semantic-reference-type-origin! dispatch rest)]
              [(= tag (compiler-parse-tag-ty-region))
                (compiler-parse-semantic-type-second-origin! dispatch rest)]
              [else
                (compiler-parse-semantic-origin-push-components!
                  head
                  head-span
                  (CompilerParseSemanticOriginKind.ModulePath)
                  (CompilerParseSemanticOriginKind.TypeName))]))]
        [_ unit])]
    [_ unit]))

(define (parse-ast-type-spanned
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstType
  (let
    [result : ResultAstType
      (parse-ast-type dispatch pools (reader.spanned-sexpr-form s))]
    (match result
      [(ResultAstType.Err _)
        (begin
          (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span s))
          result)]
      [(ResultAstType.Ok _)
        (begin
          (compiler-parse-semantic-type-origins! dispatch s)
          result)])))

(define (parse-ast-runtime-param-result
  [dispatch : sym_i64_env.SymI64Env]
  [name : ci.InternSyntaxId]
  [ty : ast.AstType]
  [end : reader.Sexpr]) : ResultAstParam
  (match (reader.sexpr-view end)
    [(reader.SexprView.Nil)
      (ResultAstParam.Ok
        (ast.ast-param-id (ci.intern-syntax-id-value name) ty false))]
    [(reader.SexprView.Cons metadata-node after-metadata)
      (match (reader.sexpr-view after-metadata)
        [(reader.SexprView.Nil)
          (match (reader.sexpr-view metadata-node)
            [(reader.SexprView.Cons key-node metadata-tail)
              (match (reader.sexpr-view key-node)
                [(reader.SexprView.Sym key)
                  (if (=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe-ref 179))
                    (match (reader.sexpr-view metadata-tail)
                      [(reader.SexprView.Nil)
                        (if (parse-ast-consuming-param-type-allowed? ty)
                          (ResultAstParam.Ok
                            (ast.ast-param-id-with-consume
                              (ci.intern-syntax-id-value name)
                              ty
                              false
                              true))
                          (ResultAstParam.Err
                            "parse: :consume requires a non-reference parameter type"))]
                      [_
                        (ResultAstParam.Err
                          "parse: (:consume) parameter metadata takes no arguments")])
                    (let
                      [key-text : String
                        (compiler-parse-dispatch-syntax-id-text dispatch key)]
                      (if (and
                        (> (string.string-length key-text) 0)
                        (= (string.string-ref key-text 0) ':'))
                        (ResultAstParam.Err
                          (str_cat.str-cat
                            "parse: unknown parameter metadata "
                            key-text))
                        (ResultAstParam.Err
                          "parse: malformed parameter metadata"))))]
                [_ (ResultAstParam.Err "parse: malformed parameter metadata")])]
            [_ (ResultAstParam.Err "parse: malformed parameter metadata")])]
        [_ (ResultAstParam.Err "parse: duplicate parameter metadata")])]
    [_ (ResultAstParam.Err "parse: malformed parameter")]))

(define (parse-ast-single-consume-param-metadata? [end : reader.Sexpr]) : bool
  (match (reader.sexpr-view end)
    [(reader.SexprView.Cons metadata-node after-metadata)
      (match (reader.sexpr-view after-metadata)
        [(reader.SexprView.Nil)
          (match (reader.sexpr-view metadata-node)
            [(reader.SexprView.Cons key-node metadata-tail)
              (match (reader.sexpr-view key-node)
                [(reader.SexprView.Sym key)
                  (and
                    (=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe-ref 179))
                    (match (reader.sexpr-view metadata-tail)
                      [(reader.SexprView.Nil) true]
                      [_ false]))]
                [_ false])]
            [_ false])]
        [_ false])]
    [_ false]))

(define (parse-ast-param
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstParam
  (match (reader.sexpr-view s)
    [(reader.SexprView.Cons first rest)
      (match (reader.sexpr-view first)
        [(reader.SexprView.Sym first-name)
          (if (=
            (ci.intern-syntax-id-value first-name)
            cbi.compiler-builtin-id-fix-comptime)
            (match (reader.sexpr-view rest)
              [(reader.SexprView.Cons name-node after-name)
                (match (reader.sexpr-view name-node)
                  [(reader.SexprView.Sym name)
                    (match (reader.sexpr-view after-name)
                      [(reader.SexprView.Cons colon rest2)
                        (match (reader.sexpr-view rest2)
                          [(reader.SexprView.Cons ty end)
                            (match (reader.sexpr-view end)
                              [(reader.SexprView.Nil)
                                (if (sexpr-colon? colon)
                                  (match (parse-ast-type dispatch pools ty)
                                    [(ResultAstType.Ok parsed-ty)
                                      (ResultAstParam.Ok
                                        (ast.ast-param-id
                                          (ci.intern-syntax-id-value name)
                                          parsed-ty
                                          true))]
                                    [(ResultAstType.Err message)
                                      (ResultAstParam.Err message)])
                                  (ResultAstParam.Err
                                    "parse: expected ':' in parameter"))]
                              [_
                                (if (parse-ast-single-consume-param-metadata?
                                  end)
                                  (ResultAstParam.Err
                                    "parse: comptime parameters cannot be consuming")
                                  (ResultAstParam.Err
                                    "parse: malformed parameter"))])]
                          [_ (ResultAstParam.Err "parse: malformed parameter")])]
                      [_ (ResultAstParam.Err "parse: malformed parameter")])]
                  [_ (ResultAstParam.Err "parse: malformed parameter")])]
              [_ (ResultAstParam.Err "parse: malformed parameter")])
            (match (reader.sexpr-view rest)
              [(reader.SexprView.Cons colon rest2)
                (match (reader.sexpr-view rest2)
                  [(reader.SexprView.Cons ty end)
                    (if (sexpr-colon? colon)
                      (match (parse-ast-type dispatch pools ty)
                        [(ResultAstType.Ok parsed-ty)
                          (parse-ast-runtime-param-result
                            dispatch
                            first-name
                            parsed-ty
                            end)]
                        [(ResultAstType.Err message)
                          (ResultAstParam.Err message)])
                      (ResultAstParam.Err "parse: expected ':' in parameter"))]
                  [_ (ResultAstParam.Err "parse: malformed parameter")])]
              [_ (ResultAstParam.Err "parse: malformed parameter")]))]
        [_ (ResultAstParam.Err "parse: malformed parameter")])]
    [_ (ResultAstParam.Err "parse: malformed parameter")]))

(define (ast-param-list-has-comptime? [params : ast.AstParamList]) : bool
  (ast-param-list-has-comptime-at? (& params) 0))

(define (ast-param-list-has-comptime-at?
  [params : (& params ast.AstParamList)]
  [index : i64]) : bool
  (if (>= index (ast.ast-param-list-len params))
    false
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(ast.AstParam.Param _ _ is-comptime _)
        (if is-comptime
          true
          (ast-param-list-has-comptime-at? params (+ index 1)))])))

(define (ast-macro-param-variadic? [param : ast.AstMacroParam]) : bool
  (match param
    [(ast.AstMacroParam.Param _ _ variadic _) variadic]))

(define (ast-macro-param-shape-delimited-variadic?
  [dispatch : sym_i64_env.SymI64Env]
  [param : ast.AstMacroParam]) : bool
  (match param
    [(ast.AstMacroParam.Param _ ty variadic _)
      (and
        variadic
        (match ty
          [(ast.AstType.Var name)
            (=
              (ci.intern-compat-state-qualified-base-id
                (compiler-parse-dispatch-intern-state dispatch)
                name)
              cbi.compiler-builtin-id-fix-ExprBindingClause)]
          [_ false]))]))

(define (parse-ast-macro-type-kind-known? [name : ci.InternSyntaxId]) : bool
  (let
    [name-id : i64 (ci.intern-syntax-id-value name)]
    (or
      (= name-id (cbi.compiler-builtin-ctfe-ref 159))
      (= name-id (cbi.compiler-builtin-ctfe-ref 160))
      (= name-id (cbi.compiler-builtin-ctfe-ref 161))
      (= name-id (cbi.compiler-builtin-ctfe-ref 162))
      (= name-id (cbi.compiler-builtin-ctfe-ref 163))
      (= name-id (cbi.compiler-builtin-ctfe-ref 164))
      (= name-id (cbi.compiler-builtin-ctfe-ref 165))
      (= name-id (cbi.compiler-builtin-ctfe-ref 166))
      (= name-id (cbi.compiler-builtin-ctfe-ref 167))
      (= name-id (cbi.compiler-builtin-ctfe-ref 168))
      (= name-id (cbi.compiler-builtin-ctfe-ref 169))
      (= name-id (cbi.compiler-builtin-ctfe-ref 170))
      (= name-id (cbi.compiler-builtin-ctfe-ref 223))
      (= name-id (cbi.compiler-builtin-ctfe-ref 173))
      (= name-id (cbi.compiler-builtin-ctfe-ref 174))
      (= name-id (cbi.compiler-builtin-ctfe-ref 125))
      (= name-id (cbi.compiler-builtin-ctfe-ref 224))
      (= name-id (cbi.compiler-builtin-ctfe-ref 225))
      (= name-id (cbi.compiler-builtin-ctfe-ref 124))
      (= name-id (cbi.compiler-builtin-ctfe-ref 226))
      (= name-id (cbi.compiler-builtin-ctfe-ref 227))
      (= name-id (cbi.compiler-builtin-ctfe-ref 171))
      (= name-id (cbi.compiler-builtin-ctfe-ref 228))
      (= name-id (cbi.compiler-builtin-ctfe-ref 229))
      (= name-id (cbi.compiler-builtin-ctfe-ref 230))
      (= name-id (cbi.compiler-builtin-ctfe-ref 231))
      (= name-id (cbi.compiler-builtin-ctfe-ref 232))
      (= name-id (cbi.compiler-builtin-ctfe-ref 233))
      (= name-id (cbi.compiler-builtin-ctfe-ref 132))
      (= name-id (cbi.compiler-builtin-ctfe-ref 281)))))

(define (parse-ast-macro-type-kind-error
  [operand-name : String]
  [detail : String]) : String
  (str_cat.str-cat
    "parse: macro type operand "
    operand-name
    " constraint :kind "
    detail))

(define (parse-ast-macro-type-kind-sexpr-contains-id?
  [s : reader.Sexpr]
  [kind : ci.InternSyntaxId]) : bool
  (match (reader.sexpr-view s)
    [(reader.SexprView.Nil) false]
    [(reader.SexprView.Cons head tail)
      (match (reader.sexpr-view head)
        [(reader.SexprView.Sym found)
          (or
            (ci.intern-syntax-id-eq? found kind)
            (parse-ast-macro-type-kind-sexpr-contains-id? tail kind))]
        [_ false])]
    [_ false]))

(define (parse-ast-macro-type-kind-list-count
  [dispatch : sym_i64_env.SymI64Env]
  [operand-name : String]
  [s : reader.Sexpr]) : ResultAstMacroTypeKindCount
  (match (reader.sexpr-view s)
    [(reader.SexprView.Nil) (ResultAstMacroTypeKindCount.Ok 0)]
    [(reader.SexprView.Cons head tail)
      (match (reader.sexpr-view head)
        [(reader.SexprView.Sym kind-name)
          (if (parse-ast-macro-type-kind-known? kind-name)
            (match (parse-ast-macro-type-kind-list-count
              dispatch
              operand-name
              tail)
              [(ResultAstMacroTypeKindCount.Ok count)
                (if (parse-ast-macro-type-kind-sexpr-contains-id?
                  tail
                  kind-name)
                  (ResultAstMacroTypeKindCount.Err
                    (parse-ast-macro-type-kind-error
                      operand-name
                      (str_cat.str-cat
                        "has duplicate kind "
                        (compiler-parse-dispatch-syntax-id-text
                          dispatch
                          kind-name))))
                  (ResultAstMacroTypeKindCount.Ok (+ count 1)))]
              [(ResultAstMacroTypeKindCount.Err message)
                (ResultAstMacroTypeKindCount.Err message)])
            (ResultAstMacroTypeKindCount.Err
              (parse-ast-macro-type-kind-error
                operand-name
                (str_cat.str-cat
                  "has unknown kind "
                  (compiler-parse-dispatch-syntax-id-text dispatch kind-name)))))]
        [_
          (ResultAstMacroTypeKindCount.Err
            (parse-ast-macro-type-kind-error
              operand-name
              "expects unquoted kind names"))])]
    [_
      (ResultAstMacroTypeKindCount.Err
        (parse-ast-macro-type-kind-error operand-name "is malformed"))]))

(define (parse-ast-macro-type-kind-list-fill!
  [out : (&mut out ast.AstMacroTypeKindList)]
  [s : reader.Sexpr]
  [index : i64]) : unit
  (match (reader.sexpr-view s)
    [(reader.SexprView.Nil) unit]
    [(reader.SexprView.Cons head tail)
      (match (reader.sexpr-view head)
        [(reader.SexprView.Sym kind-name)
          (begin
            (ast.ast-macro-type-kind-list-set!
              out
              index
              (ci.intern-syntax-id-value kind-name))
            (parse-ast-macro-type-kind-list-fill! out tail (+ index 1)))]
        [_ unit])]
    [_ unit]))

(define (parse-ast-macro-type-kind-list
  [dispatch : sym_i64_env.SymI64Env]
  [operand-name : String]
  [s : reader.Sexpr]) : ResultAstMacroTypeKindList
  (match (parse-ast-macro-type-kind-list-count dispatch operand-name s)
    [(ResultAstMacroTypeKindCount.Ok count)
      (let
        [out : ast.AstMacroTypeKindList
          (ast.ast-macro-type-kind-list-with-length count)]
        (begin
          (parse-ast-macro-type-kind-list-fill! (&mut out) s 0)
          (ResultAstMacroTypeKindList.Ok out)))]
    [(ResultAstMacroTypeKindCount.Err message)
      (ResultAstMacroTypeKindList.Err message)]))

(define (parse-ast-macro-type-kind-constraint
  [dispatch : sym_i64_env.SymI64Env]
  [operand-name : String]
  [s : reader.Sexpr]) : ResultAstMacroTypeKindList
  (match (reader.sexpr-view s)
    [(reader.SexprView.Cons head tail)
      (match (reader.sexpr-view head)
        [(reader.SexprView.Sym tag)
          (if (=
            (ci.intern-syntax-id-value tag)
            (cbi.compiler-builtin-ctfe-ref 221))
            (match (reader.sexpr-view tail)
              [(reader.SexprView.Nil)
                (ResultAstMacroTypeKindList.Err
                  (parse-ast-macro-type-kind-error
                    operand-name
                    "requires at least one kind"))]
              [(reader.SexprView.Cons _ _)
                (parse-ast-macro-type-kind-list dispatch operand-name tail)]
              [_
                (ResultAstMacroTypeKindList.Err
                  (parse-ast-macro-type-kind-error operand-name "is malformed"))])
            (ResultAstMacroTypeKindList.Err
              (str_cat.str-cat
                "parse: macro type operand "
                operand-name
                " has unknown constraint form "
                (compiler-parse-dispatch-syntax-id-text dispatch tag))))]
        [_
          (ResultAstMacroTypeKindList.Err
            (parse-ast-macro-type-kind-error operand-name "is malformed"))])]
    [_
      (ResultAstMacroTypeKindList.Err
        (parse-ast-macro-type-kind-error operand-name "is malformed"))]))

(define (parse-ast-macro-type-operand? [ty : ast.AstType]) : bool
  (match ty
    [(ast.AstType.Var name) (= name cbi.compiler-builtin-id-fix-type)]
    [_ false]))

(define (parse-ast-macro-param-after-type
  [dispatch : sym_i64_env.SymI64Env]
  [name : ci.InternSyntaxId]
  [parsed-ty : ast.AstType]
  [rest : reader.Sexpr]) : ResultAstMacroParam
  (let
    [name-id : i64 (ci.intern-syntax-id-value name)]
    [name-text : String (compiler-parse-dispatch-syntax-id-text dispatch name)]
    (match (reader.sexpr-view rest)
      [(reader.SexprView.Nil)
        (ResultAstMacroParam.Ok (ast.ast-macro-param name-id parsed-ty false))]
      [(reader.SexprView.Cons suffix suffix-rest)
        (match (reader.sexpr-view suffix)
          [(reader.SexprView.Sym suffix-name)
            (if (=
              (ci.intern-syntax-id-value suffix-name)
              (cbi.compiler-builtin-ctfe-ref 222))
              (match (reader.sexpr-view suffix-rest)
                [(reader.SexprView.Nil)
                  (ResultAstMacroParam.Ok
                    (ast.ast-macro-param name-id parsed-ty true))]
                [_ (ResultAstMacroParam.Err "parse: malformed macro operand")])
              (ResultAstMacroParam.Err "parse: malformed macro operand"))]
          [(reader.SexprView.Cons _ _)
            (if (parse-ast-macro-type-operand? parsed-ty)
              (match (reader.sexpr-view suffix-rest)
                [(reader.SexprView.Nil)
                  (match (parse-ast-macro-type-kind-constraint
                    dispatch
                    name-text
                    suffix)
                    [(ResultAstMacroTypeKindList.Ok type-kinds)
                      (ResultAstMacroParam.Ok
                        (ast.ast-macro-param-with-type-kinds
                          name-id
                          parsed-ty
                          false
                          type-kinds))]
                    [(ResultAstMacroTypeKindList.Err message)
                      (ResultAstMacroParam.Err message)])]
                [(reader.SexprView.Cons maybe-dots after-dots)
                  (match (reader.sexpr-view maybe-dots)
                    [(reader.SexprView.Sym dots-name)
                      (if (and
                        (=
                          (ci.intern-syntax-id-value dots-name)
                          (cbi.compiler-builtin-ctfe-ref 222))
                        (match (reader.sexpr-view after-dots)
                          [(reader.SexprView.Nil) true]
                          [_ false]))
                        (ResultAstMacroParam.Err
                          (parse-ast-macro-type-kind-error
                            name-text
                            "is not legal on variadic operands"))
                        (ResultAstMacroParam.Err
                          (parse-ast-macro-type-kind-error
                            name-text
                            "allows only one constraint form")))]
                    [_
                      (ResultAstMacroParam.Err
                        (parse-ast-macro-type-kind-error
                          name-text
                          "allows only one constraint form"))])]
                [_
                  (ResultAstMacroParam.Err
                    (parse-ast-macro-type-kind-error
                      name-text
                      "allows only one constraint form"))])
              (ResultAstMacroParam.Err
                (str_cat.str-cat
                  "parse: macro operand "
                  name-text
                  " constraint :kind is only legal on fixed type operands")))]
          [_ (ResultAstMacroParam.Err "parse: malformed macro operand")])]
      [_ (ResultAstMacroParam.Err "parse: malformed macro operand")])))

(define (parse-ast-macro-param
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstMacroParam
  (match (reader.sexpr-view s)
    [(reader.SexprView.Cons name-node rest)
      (match (reader.sexpr-view name-node)
        [(reader.SexprView.Sym name)
          (if (=
            (ci.intern-syntax-id-value name)
            cbi.compiler-builtin-id-fix-comptime)
            (ResultAstMacroParam.Err
              "parse: defmacro operands are already compile-time")
            (match (reader.sexpr-view rest)
              [(reader.SexprView.Cons colon rest2)
                (match (reader.sexpr-view rest2)
                  [(reader.SexprView.Cons ty rest3)
                    (if (sexpr-colon? colon)
                      (match (parse-ast-type dispatch pools ty)
                        [(ResultAstType.Ok parsed-ty)
                          (parse-ast-macro-param-after-type
                            dispatch
                            name
                            parsed-ty
                            rest3)]
                        [(ResultAstType.Err message)
                          (ResultAstMacroParam.Err message)])
                      (ResultAstMacroParam.Err
                        "parse: expected ':' in macro operand"))]
                  [_ (ResultAstMacroParam.Err "parse: malformed macro operand")])]
              [_ (ResultAstMacroParam.Err "parse: malformed macro operand")]))]
        [_ (ResultAstMacroParam.Err "parse: malformed macro operand")])]
    [_ (ResultAstMacroParam.Err "parse: malformed macro operand")]))

(define (parse-ast-macro-param-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstMacroParamList
  (let
    [out : ast.AstMacroParamList (ast.ast-macro-param-list-new)]
    (match (parse-ast-macro-param-list-into dispatch pools s (&mut out))
      [(ResultAstMacroParamListBuild.Ok) (ResultAstMacroParamList.Ok out)]
      [(ResultAstMacroParamListBuild.Err message)
        (ResultAstMacroParamList.Err message)])))

(define (parse-ast-macro-param-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]
  [out : (&mut out ast.AstMacroParamList)]) : ResultAstMacroParamListBuild
  (match (reader.sexpr-view s)
    [(reader.SexprView.Nil) ResultAstMacroParamListBuild.Ok]
    [(reader.SexprView.Cons head tail)
      (match (parse-ast-macro-param dispatch pools head)
        [(ResultAstMacroParam.Ok parsed-head)
          (if (ast-macro-param-variadic? parsed-head)
            (match (reader.sexpr-view tail)
              [(reader.SexprView.Nil)
                (begin
                  (ast.ast-macro-param-list-push out parsed-head)
                  ResultAstMacroParamListBuild.Ok)]
              [_
                (if (ast-macro-param-shape-delimited-variadic?
                  dispatch
                  parsed-head)
                  (begin
                    (ast.ast-macro-param-list-push out parsed-head)
                    (parse-ast-macro-param-list-into dispatch pools tail out))
                  (ResultAstMacroParamListBuild.Err
                    "parse: only ExprBindingClause macro operands may be variadic before a later operand"))])
            (begin
              (ast.ast-macro-param-list-push out parsed-head)
              (parse-ast-macro-param-list-into dispatch pools tail out)))]
        [(ResultAstMacroParam.Err message)
          (ResultAstMacroParamListBuild.Err message)])]
    [_ (ResultAstMacroParamListBuild.Err "parse: malformed macro operand list")]))

(define (parse-ast-param-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstParamList
  (let
    [out : ast.AstParamList (ast.ast-param-list-new)]
    (match (parse-ast-param-list-into dispatch pools s (&mut out))
      [(ResultAstParamListBuild.Ok) (ResultAstParamList.Ok out)]
      [(ResultAstParamListBuild.Err message) (ResultAstParamList.Err message)])))

(define (parse-ast-param-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]
  [out : (&mut out ast.AstParamList)]) : ResultAstParamListBuild
  (match (reader.sexpr-view s)
    [(reader.SexprView.Nil) ResultAstParamListBuild.Ok]
    [(reader.SexprView.Cons head tail)
      (match (parse-ast-param dispatch pools head)
        [(ResultAstParam.Ok parsed-head)
          (begin
            (ast.ast-param-list-push out parsed-head)
            (parse-ast-param-list-into dispatch pools tail out))]
        [(ResultAstParam.Err message) (ResultAstParamListBuild.Err message)])]
    [_ (ResultAstParamListBuild.Err "parse: malformed parameter list")]))

(define (compiler-parse-semantic-param-items-origin!
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view items)
    [(reader.SpannedSexprView.Cons head tail _)
      (if (sexpr-colon? (reader.spanned-sexpr-form head))
        (match (reader.spanned-sexpr-view tail)
          [(reader.SpannedSexprView.Cons ty-node _ _)
            (compiler-parse-semantic-type-origins! dispatch ty-node)]
          [_ unit])
        (compiler-parse-semantic-param-items-origin! dispatch tail))]
    [_ unit]))

(define (compiler-parse-semantic-param-origin!
  [dispatch : sym_i64_env.SymI64Env]
  [item : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view item)
    [(reader.SpannedSexprView.BracketList items _)
      (compiler-parse-semantic-param-items-origin! dispatch items)]
    [_ unit]))

(define (compiler-parse-semantic-param-list-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view items)
    [(reader.SpannedSexprView.Nil _) unit]
    [(reader.SpannedSexprView.Cons head tail _)
      (begin
        (compiler-parse-semantic-param-origin! dispatch head)
        (compiler-parse-semantic-param-list-origins! dispatch tail))]
    [_ unit]))

(define (parse-ast-field-cleanup
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.Sexpr]) : ResultAstFieldCleanup
  (match (reader.sexpr-view s)
    [(reader.SexprView.Cons key-node tail)
      (match (reader.sexpr-view key-node)
        [(reader.SexprView.Sym key)
          (cond
            [(=
                (ci.intern-syntax-id-value key)
                (cbi.compiler-builtin-ctfe-ref 234))
              (match (reader.sexpr-view tail)
                [(reader.SexprView.Cons cleanup-node end)
                  (match (reader.sexpr-view end)
                    [(reader.SexprView.Nil)
                      (match (reader.sexpr-view cleanup-node)
                        [(reader.SexprView.Sym cleanup-fn)
                          (ResultAstFieldCleanup.Ok
                            (ast.ast-field-cleanup-fn-id cleanup-fn))]
                        [_
                          (ResultAstFieldCleanup.Err
                            "parse: malformed field :cleanup metadata")])]
                    [_
                      (ResultAstFieldCleanup.Err
                        "parse: malformed field :cleanup metadata")])]
                [_
                  (ResultAstFieldCleanup.Err
                    "parse: malformed field :cleanup metadata")])]
            [(=
                (ci.intern-syntax-id-value key)
                (cbi.compiler-builtin-ctfe-ref 235))
              (match (reader.sexpr-view tail)
                [(reader.SexprView.Nil)
                  (ResultAstFieldCleanup.Ok (ast.AstFieldCleanup.Owned))]
                [_
                  (ResultAstFieldCleanup.Err
                    "parse: malformed field :owned metadata")])]
            [(compiler-parse-metadata-key? dispatch key)
              (ResultAstFieldCleanup.Err
                (str_cat.str-cat
                  "parse: unknown field metadata "
                  (compiler-parse-dispatch-syntax-id-text dispatch key)))]
            [else
              (ResultAstFieldCleanup.Err
                "parse: malformed field cleanup metadata")])]
        [_
          (ResultAstFieldCleanup.Err "parse: malformed field cleanup metadata")])]
    [_ (ResultAstFieldCleanup.Err "parse: malformed field cleanup metadata")]))

(define (parse-ast-variant-payload-cleanup
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.Sexpr]) : ResultAstVariantPayloadCleanup
  (match (reader.sexpr-view s)
    [(reader.SexprView.Cons key-node tail)
      (match (reader.sexpr-view key-node)
        [(reader.SexprView.Sym key)
          (cond
            [(=
                (ci.intern-syntax-id-value key)
                (cbi.compiler-builtin-ctfe-ref 234))
              (match (reader.sexpr-view tail)
                [(reader.SexprView.Cons cleanup-node end)
                  (match (reader.sexpr-view end)
                    [(reader.SexprView.Nil)
                      (match (reader.sexpr-view cleanup-node)
                        [(reader.SexprView.Sym cleanup-fn)
                          (ResultAstVariantPayloadCleanup.Ok
                            (ast.ast-variant-payload-cleanup-fn-id cleanup-fn))]
                        [_
                          (ResultAstVariantPayloadCleanup.Err
                            "parse: malformed enum payload :cleanup metadata")])]
                    [_
                      (ResultAstVariantPayloadCleanup.Err
                        "parse: malformed enum payload :cleanup metadata")])]
                [_
                  (ResultAstVariantPayloadCleanup.Err
                    "parse: malformed enum payload :cleanup metadata")])]
            [(=
                (ci.intern-syntax-id-value key)
                (cbi.compiler-builtin-ctfe-ref 235))
              (match (reader.sexpr-view tail)
                [(reader.SexprView.Nil)
                  (ResultAstVariantPayloadCleanup.Ok
                    (ast.AstVariantPayloadCleanup.Owned))]
                [_
                  (ResultAstVariantPayloadCleanup.Err
                    "parse: malformed enum payload :owned metadata")])]
            [(compiler-parse-metadata-key? dispatch key)
              (ResultAstVariantPayloadCleanup.Err
                (str_cat.str-cat
                  "parse: unknown enum payload metadata "
                  (compiler-parse-dispatch-syntax-id-text dispatch key)))]
            [else
              (ResultAstVariantPayloadCleanup.Err
                "parse: malformed enum payload cleanup metadata")])]
        [_
          (ResultAstVariantPayloadCleanup.Err
            "parse: malformed enum payload cleanup metadata")])]
    [_
      (ResultAstVariantPayloadCleanup.Err
        "parse: malformed enum payload cleanup metadata")]))

(define (parse-ast-field-def
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]
  [allow-cleanup : bool]) : ResultAstFieldDef
  (match (reader.sexpr-view s)
    [(reader.SexprView.Cons name-node tail)
      (match (reader.sexpr-view name-node)
        [(reader.SexprView.Sym name)
          (match (reader.sexpr-view tail)
            [(reader.SexprView.Cons ty rest)
              (match (reader.sexpr-view rest)
                [(reader.SexprView.Nil)
                  (match (parse-ast-type dispatch pools ty)
                    [(ResultAstType.Ok parsed-ty)
                      (ResultAstFieldDef.Ok
                        (ast.ast-field-def-id
                          name
                          parsed-ty
                          (ast.AstFieldCleanup.No)))]
                    [(ResultAstType.Err message)
                      (ResultAstFieldDef.Err message)])]
                [(reader.SexprView.Cons cleanup-meta extra)
                  (match (reader.sexpr-view extra)
                    [(reader.SexprView.Nil)
                      (if allow-cleanup
                        (match (parse-ast-type dispatch pools ty)
                          [(ResultAstType.Ok parsed-ty)
                            (match (parse-ast-field-cleanup
                              dispatch
                              cleanup-meta)
                              [(ResultAstFieldCleanup.Ok parsed-cleanup)
                                (ResultAstFieldDef.Ok
                                  (ast.ast-field-def-id
                                    name
                                    parsed-ty
                                    parsed-cleanup))]
                              [(ResultAstFieldCleanup.Err message)
                                (ResultAstFieldDef.Err message)])]
                          [(ResultAstType.Err message)
                            (ResultAstFieldDef.Err message)])
                        (ResultAstFieldDef.Err
                          "parse: field cleanup metadata requires struct :cleanup metadata"))]
                    [_
                      (ResultAstFieldDef.Err
                        "parse: duplicate field cleanup metadata")])]
                [_ (ResultAstFieldDef.Err "parse: malformed field definition")])]
            [_ (ResultAstFieldDef.Err "parse: malformed field definition")])]
        [_ (ResultAstFieldDef.Err "parse: malformed field definition")])]
    [_ (ResultAstFieldDef.Err "parse: malformed field definition")]))

(define (compiler-parse-metadata-key?
  [dispatch : sym_i64_env.SymI64Env]
  [name-id : ci.InternSyntaxId]) : bool
  ;; Unknown metadata is a genuinely prefix-bearing diagnostic boundary. All
  ;; recognized fixed keys are classified by ID before reaching this helper.
  (let
    [name : String (compiler-parse-dispatch-syntax-id-text dispatch name-id)]
    (and (> (string.string-length name) 0) (= (string.string-ref name 0) ':'))))

(define (parse-ast-aggregate-lifetimes-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [tail : reader.Sexpr]) : ResultAstLifetimeList
  (parse-ast-lifetime-list-nonempty
    dispatch
    pools
    tail
    "parse: :lifetimes metadata expects at least one lifetime identifier"))

(define (parse-ast-defstruct-repr-tail
  [dispatch : sym_i64_env.SymI64Env]
  [tail : reader.Sexpr]) : ResultAstStructRepr
  (match (reader.sexpr-view tail)
    [(reader.SexprView.Cons name-node end)
      (match (reader.sexpr-view end)
        [(reader.SexprView.Nil)
          (match (reader.sexpr-view name-node)
            [(reader.SexprView.Sym name)
              (if (=
                (ci.intern-syntax-id-value name)
                cbi.compiler-builtin-id-fix-c)
                (ResultAstStructRepr.Ok (ast.AstStructRepr.C))
                (if (=
                  (ci.intern-syntax-id-value name)
                  (cbi.compiler-builtin-ctfe-ref 239))
                  (ResultAstStructRepr.Err "parse: packed repr is reserved")
                  (ResultAstStructRepr.Err
                    (str_cat.str-cat
                      "parse: unknown struct repr "
                      (compiler-parse-dispatch-syntax-id-text dispatch name)))))]
            [_ (ResultAstStructRepr.Err "parse: malformed :repr metadata")])]
        [_ (ResultAstStructRepr.Err "parse: malformed :repr metadata")])]
    [_ (ResultAstStructRepr.Err "parse: malformed :repr metadata")]))

(define (parse-ast-defstruct-cleanup-tail [tail : reader.Sexpr]) : ResultAstStructCleanup
  (match (reader.sexpr-view tail)
    [(reader.SexprView.Cons cleanup-node end)
      (match (reader.sexpr-view end)
        [(reader.SexprView.Nil)
          (match (reader.sexpr-view cleanup-node)
            [(reader.SexprView.Sym cleanup-fn)
              (ResultAstStructCleanup.Ok
                (ast.ast-struct-cleanup-fn-id cleanup-fn))]
            [_
              (ResultAstStructCleanup.Err
                "parse: malformed defstruct :cleanup metadata")])]
        [_
          (ResultAstStructCleanup.Err
            "parse: malformed defstruct :cleanup metadata")])]
    [_
      (ResultAstStructCleanup.Err
        "parse: malformed defstruct :cleanup metadata")]))

(define (parse-ast-defenum-cleanup-tail [tail : reader.Sexpr]) : ResultAstEnumCleanup
  (match (reader.sexpr-view tail)
    [(reader.SexprView.Cons cleanup-node end)
      (match (reader.sexpr-view end)
        [(reader.SexprView.Nil)
          (match (reader.sexpr-view cleanup-node)
            [(reader.SexprView.Sym cleanup-fn)
              (ResultAstEnumCleanup.Ok (ast.ast-enum-cleanup-fn-id cleanup-fn))]
            [_
              (ResultAstEnumCleanup.Err
                "parse: malformed defenum :cleanup metadata")])]
        [_
          (ResultAstEnumCleanup.Err
            "parse: malformed defenum :cleanup metadata")])]
    [_ (ResultAstEnumCleanup.Err "parse: malformed defenum :cleanup metadata")]))

(define (compiler-parse-semantic-field-definition-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view items)
    [(reader.SpannedSexprView.Cons name-node tail-items _)
      (begin
        (match (reader.spanned-sexpr-view name-node)
          [(reader.SpannedSexprView.Sym name span)
            (compiler-parse-semantic-origin-push-components!
              name
              span
              (CompilerParseSemanticOriginKind.ModulePath)
              (CompilerParseSemanticOriginKind.StructFieldDefinition))]
          [_ unit])
        (match (reader.spanned-sexpr-view tail-items)
          [(reader.SpannedSexprView.Cons ty-node _ _)
            (compiler-parse-semantic-type-origins! dispatch ty-node)]
          [_ unit]))]
    [_ unit]))

(define (parse-ast-defstruct-field-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [head : reader.SpannedSexpr]
  [tail : reader.SpannedSexpr]
  [lifetimes : ast.AstLifetimeList]
  [repr : ast.AstStructRepr]
  [cleanup : ast.AstStructCleanup]
  [fields : ast.AstFieldDefList (:consume)]
  [seen-lifetimes : bool]
  [seen-repr : bool]
  [seen-cleanup : bool]) : ResultAstStructDefParts
  (match (parse-ast-field-def
    dispatch
    pools
    (reader.spanned-sexpr-form head)
    (ast.ast-struct-cleanup? cleanup))
    [(ResultAstFieldDef.Ok parsed-field)
      (let
        [next-fields : ast.AstFieldDefList fields]
        (begin
          (match (reader.spanned-sexpr-view head)
            [(reader.SpannedSexprView.BracketList items _)
              (compiler-parse-semantic-field-definition-origins! dispatch items)]
            [(reader.SpannedSexprView.Cons _ _ _)
              (compiler-parse-semantic-field-definition-origins! dispatch head)]
            [_ unit])
          (ast.ast-field-def-list-push (&mut next-fields) parsed-field)
          (reader.sp-node-push
            (reader.spanned-sexpr-empty (reader.spanned-sexpr-span head)))
          (parse-ast-defstruct-items
            dispatch
            pools
            tail
            lifetimes
            repr
            cleanup
            next-fields
            seen-lifetimes
            seen-repr
            seen-cleanup
            true)))]
    [(ResultAstFieldDef.Err message) (ResultAstStructDefParts.Err message)]))

(define (parse-ast-defstruct-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [items : reader.SpannedSexpr]
  [lifetimes : ast.AstLifetimeList]
  [repr : ast.AstStructRepr]
  [cleanup : ast.AstStructCleanup]
  [fields : ast.AstFieldDefList]
  [seen-lifetimes : bool]
  [seen-repr : bool]
  [seen-cleanup : bool]
  [seen-field : bool]) : ResultAstStructDefParts
  (match (reader.spanned-sexpr-view items)
    [(reader.SpannedSexprView.Nil _)
      (ResultAstStructDefParts.Ok lifetimes repr cleanup fields)]
    [(reader.SpannedSexprView.Cons head tail _)
      (match (reader.sexpr-view (reader.spanned-sexpr-form head))
        [(reader.SexprView.Cons key-node after-key)
          (match (reader.sexpr-view key-node)
            [(reader.SexprView.Sym key)
              (cond
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe-ref 236))
                  (if seen-field
                    (ResultAstStructDefParts.Err
                      "parse: defstruct metadata must appear before fields")
                    (if seen-lifetimes
                      (ResultAstStructDefParts.Err
                        "parse: duplicate defstruct :lifetimes metadata")
                      (match (parse-ast-aggregate-lifetimes-tail
                        dispatch
                        pools
                        after-key)
                        [(ResultAstLifetimeList.Ok next-lifetimes)
                          (parse-ast-defstruct-items
                            dispatch
                            pools
                            tail
                            next-lifetimes
                            repr
                            cleanup
                            fields
                            true
                            seen-repr
                            seen-cleanup
                            false)]
                        [(ResultAstLifetimeList.Err message)
                          (ResultAstStructDefParts.Err message)])))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe-ref 237))
                  (if seen-field
                    (ResultAstStructDefParts.Err
                      "parse: defstruct metadata must appear before fields")
                    (if seen-repr
                      (ResultAstStructDefParts.Err
                        "parse: duplicate defstruct :repr metadata")
                      (match (parse-ast-defstruct-repr-tail dispatch after-key)
                        [(ResultAstStructRepr.Ok next-repr)
                          (if (and
                            (ast.ast-struct-repr-c? next-repr)
                            (ast.ast-struct-cleanup? cleanup))
                            (ResultAstStructDefParts.Err
                              "parse: defstruct cannot combine :repr c with :cleanup metadata")
                            (parse-ast-defstruct-items
                              dispatch
                              pools
                              tail
                              lifetimes
                              next-repr
                              cleanup
                              fields
                              seen-lifetimes
                              true
                              seen-cleanup
                              false))]
                        [(ResultAstStructRepr.Err message)
                          (ResultAstStructDefParts.Err message)])))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe-ref 234))
                  (if seen-field
                    (ResultAstStructDefParts.Err
                      "parse: defstruct metadata must appear before fields")
                    (if seen-cleanup
                      (ResultAstStructDefParts.Err
                        "parse: duplicate defstruct :cleanup metadata")
                      (match (parse-ast-defstruct-cleanup-tail after-key)
                        [(ResultAstStructCleanup.Ok next-cleanup)
                          (if (ast.ast-struct-repr-c? repr)
                            (ResultAstStructDefParts.Err
                              "parse: defstruct cannot combine :repr c with :cleanup metadata")
                            (parse-ast-defstruct-items
                              dispatch
                              pools
                              tail
                              lifetimes
                              repr
                              next-cleanup
                              fields
                              seen-lifetimes
                              seen-repr
                              true
                              false))]
                        [(ResultAstStructCleanup.Err message)
                          (ResultAstStructDefParts.Err message)])))]
                [(compiler-parse-metadata-key? dispatch key)
                  (if seen-field
                    (ResultAstStructDefParts.Err
                      "parse: defstruct metadata must appear before fields")
                    (if (=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe-ref 238))
                      (ResultAstStructDefParts.Err
                        "parse: packed repr is reserved")
                      (ResultAstStructDefParts.Err
                        (str_cat.str-cat
                          "parse: unknown defstruct metadata "
                          (compiler-parse-dispatch-syntax-id-text dispatch key)))))]
                [else
                  (parse-ast-defstruct-field-item
                    dispatch
                    pools
                    head
                    tail
                    lifetimes
                    repr
                    cleanup
                    fields
                    seen-lifetimes
                    seen-repr
                    seen-cleanup)])]
            [_
              (parse-ast-defstruct-field-item
                dispatch
                pools
                head
                tail
                lifetimes
                repr
                cleanup
                fields
                seen-lifetimes
                seen-repr
                seen-cleanup)])]
        [_
          (parse-ast-defstruct-field-item
            dispatch
            pools
            head
            tail
            lifetimes
            repr
            cleanup
            fields
            seen-lifetimes
            seen-repr
            seen-cleanup)])]
    [_ (ResultAstStructDefParts.Err "parse: malformed field list")]))

(define (compiler-parse-metadata-sexpr?
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.Sexpr]) : bool
  (match (reader.sexpr-view s)
    [(reader.SexprView.Cons key-node _)
      (match (reader.sexpr-view key-node)
        [(reader.SexprView.Sym key) (compiler-parse-metadata-key? dispatch key)]
        [_ false])]
    [_ false]))

(define (parse-ast-variant-payload-parts
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]
  [allow-cleanup : bool]) : ResultAstVariantPayloadParts
  (match (reader.sexpr-view s)
    [(reader.SexprView.Nil)
      (ResultAstVariantPayloadParts.Ok
        (ast.ast-type-list-new)
        (ast.ast-variant-payload-cleanup-list-new))]
    [(reader.SexprView.Cons ty-node rest)
      (let
        [ty-form : reader.Sexpr ty-node]
        [rest-form : reader.Sexpr rest]
        (if (compiler-parse-metadata-sexpr? dispatch ty-form)
          (ResultAstVariantPayloadParts.Err
            "parse: enum payload cleanup metadata must follow a payload type")
          (match (parse-ast-type dispatch pools ty-form)
            [(ResultAstType.Ok parsed-ty)
              (match (reader.sexpr-view rest-form)
                [(reader.SexprView.Nil)
                  (ResultAstVariantPayloadParts.Ok
                    (ast.ast-type-cons-with-pools
                      pools
                      parsed-ty
                      (ast.ast-type-list-new))
                    (ast.ast-variant-payload-cleanup-cons
                      (ast.AstVariantPayloadCleanup.No)
                      (ast.ast-variant-payload-cleanup-list-new)))]
                [(reader.SexprView.Cons cleanup-node after-cleanup)
                  (let
                    [cleanup-form : reader.Sexpr cleanup-node]
                    (if (compiler-parse-metadata-sexpr? dispatch cleanup-form)
                      (if allow-cleanup
                        (match (parse-ast-variant-payload-cleanup
                          dispatch
                          cleanup-form)
                          [(ResultAstVariantPayloadCleanup.Ok parsed-cleanup)
                            (match (parse-ast-variant-payload-parts
                              dispatch
                              pools
                              after-cleanup
                              allow-cleanup)
                              [(ResultAstVariantPayloadParts.Ok
                                  parsed-rest
                                  cleanup-rest)
                                (ResultAstVariantPayloadParts.Ok
                                  (ast.ast-type-cons-with-pools
                                    pools
                                    parsed-ty
                                    parsed-rest)
                                  (ast.ast-variant-payload-cleanup-cons
                                    parsed-cleanup
                                    cleanup-rest))]
                              [(ResultAstVariantPayloadParts.Err message)
                                (ResultAstVariantPayloadParts.Err message)])]
                          [(ResultAstVariantPayloadCleanup.Err message)
                            (ResultAstVariantPayloadParts.Err message)])
                        (ResultAstVariantPayloadParts.Err
                          "parse: enum payload cleanup metadata requires enum :cleanup metadata"))
                      (match (parse-ast-variant-payload-parts
                        dispatch
                        pools
                        rest-form
                        allow-cleanup)
                        [(ResultAstVariantPayloadParts.Ok
                            parsed-rest
                            cleanup-rest)
                          (ResultAstVariantPayloadParts.Ok
                            (ast.ast-type-cons-with-pools
                              pools
                              parsed-ty
                              parsed-rest)
                            (ast.ast-variant-payload-cleanup-cons
                              (ast.AstVariantPayloadCleanup.No)
                              cleanup-rest))]
                        [(ResultAstVariantPayloadParts.Err message)
                          (ResultAstVariantPayloadParts.Err message)])))]
                [_
                  (ResultAstVariantPayloadParts.Err
                    "parse: malformed enum payload list")])]
            [(ResultAstType.Err message)
              (ResultAstVariantPayloadParts.Err message)])))]
    [_ (ResultAstVariantPayloadParts.Err "parse: malformed enum payload list")]))

(define (parse-ast-variant-def
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]
  [allow-cleanup : bool]) : ResultAstVariantDef
  (match (reader.sexpr-view s)
    [(reader.SexprView.Cons name-node fields)
      (match (reader.sexpr-view name-node)
        [(reader.SexprView.Sym name)
          (if (compiler-parse-metadata-key? dispatch name)
            (if (=
              (ci.intern-syntax-id-value name)
              (cbi.compiler-builtin-ctfe-ref 234))
              (ResultAstVariantDef.Err
                "parse: defenum metadata must appear before variants")
              (ResultAstVariantDef.Err
                (str_cat.str-cat
                  "parse: unknown defenum metadata "
                  (compiler-parse-dispatch-syntax-id-text dispatch name))))
            (match (parse-ast-variant-payload-parts
              dispatch
              pools
              fields
              allow-cleanup)
              [(ResultAstVariantPayloadParts.Ok parsed-fields parsed-cleanups)
                (ResultAstVariantDef.Ok
                  (ast.ast-variant-def-id
                    (ci.intern-syntax-id-value name)
                    parsed-fields
                    parsed-cleanups))]
              [(ResultAstVariantPayloadParts.Err message)
                (ResultAstVariantDef.Err message)]))]
        [_ (ResultAstVariantDef.Err "parse: malformed variant definition")])]
    [_ (ResultAstVariantDef.Err "parse: malformed variant definition")]))

(define (parse-ast-dispatch-isa
  [dispatch : sym_i64_env.SymI64Env]
  [name : ci.InternSyntaxId]) : ResultAstDispatchIsa
  (let
    [name-id : i64 (ci.intern-syntax-id-value name)]
    (cond
      [(= name-id (cbi.compiler-builtin-ctfe-ref 240))
        (ResultAstDispatchIsa.Ok (ast.AstDispatchIsa.Scalar))]
      [(= name-id (cbi.compiler-builtin-ctfe-ref 241))
        (ResultAstDispatchIsa.Ok (ast.AstDispatchIsa.Avx2))]
      [(= name-id (cbi.compiler-builtin-ctfe-ref 242))
        (ResultAstDispatchIsa.Ok (ast.AstDispatchIsa.Avx512))]
      [else
        (ResultAstDispatchIsa.Err
          (str_cat.str-cat
            "parse: unknown defdispatch ISA "
            (compiler-parse-dispatch-syntax-id-text dispatch name)))])))

(define (parse-ast-dispatch-variant
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]) : ResultAstDispatchVariant
  (match (reader.spanned-sexpr-view s)
    [(reader.SpannedSexprView.Cons isa-node rest _)
      (match (reader.spanned-sexpr-view isa-node)
        [(reader.SpannedSexprView.Sym isa-name _)
          (match (reader.spanned-sexpr-view rest)
            [(reader.SpannedSexprView.Cons fn-node end _)
              (match (reader.spanned-sexpr-view end)
                [(reader.SpannedSexprView.Nil _)
                  (match (reader.spanned-sexpr-view fn-node)
                    [(reader.SpannedSexprView.Sym fn-name fn-span)
                      (match (parse-ast-dispatch-isa dispatch isa-name)
                        [(ResultAstDispatchIsa.Ok isa)
                          (begin
                            (compiler-parse-semantic-origin-push-components!
                              fn-name
                              fn-span
                              (CompilerParseSemanticOriginKind.ModulePath)
                              (CompilerParseSemanticOriginKind.DispatchFunction))
                            (ResultAstDispatchVariant.Ok
                              (ast.AstDispatchVariant.Variant
                                isa
                                (ci.intern-syntax-id-value fn-name))))]
                        [(ResultAstDispatchIsa.Err message)
                          (ResultAstDispatchVariant.Err message)])]
                    [_
                      (ResultAstDispatchVariant.Err
                        "parse: malformed defdispatch variant")])]
                [_
                  (ResultAstDispatchVariant.Err
                    "parse: malformed defdispatch variant")])]
            [_
              (ResultAstDispatchVariant.Err
                "parse: malformed defdispatch variant")])]
        [_
          (ResultAstDispatchVariant.Err "parse: malformed defdispatch variant")])]
    [_ (ResultAstDispatchVariant.Err "parse: malformed defdispatch variant")]))

(define (parse-ast-dispatch-variant-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [variants : reader.SpannedSexpr]
  [out : (&mut out ast.AstDispatchVariantList)]) : ResultAstDispatchVariantListBuild
  (match (reader.spanned-sexpr-view variants)
    [(reader.SpannedSexprView.Nil _) (ResultAstDispatchVariantListBuild.Ok)]
    [(reader.SpannedSexprView.Cons head rest _)
      (match (parse-ast-dispatch-variant dispatch head)
        [(ResultAstDispatchVariant.Ok parsed)
          (begin
            (ast.ast-dispatch-variant-list-push out parsed)
            (parse-ast-dispatch-variant-list-into dispatch rest out))]
        [(ResultAstDispatchVariant.Err message)
          (ResultAstDispatchVariantListBuild.Err message)])]
    [_
      (ResultAstDispatchVariantListBuild.Err
        "parse: malformed defdispatch variant list")]))

(define (parse-ast-dispatch-variant-list
  [dispatch : sym_i64_env.SymI64Env]
  [variants : reader.SpannedSexpr]) : ResultAstDispatchVariantList
  (let
    [out : ast.AstDispatchVariantList (ast.ast-dispatch-variant-list-new)]
    (match (parse-ast-dispatch-variant-list-into dispatch variants (&mut out))
      [(ResultAstDispatchVariantListBuild.Ok)
        (ResultAstDispatchVariantList.Ok out)]
      [(ResultAstDispatchVariantListBuild.Err message)
        (ResultAstDispatchVariantList.Err message)])))

(define (compiler-parse-semantic-variant-payload-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [payloads : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view payloads)
    [(reader.SpannedSexprView.Nil _) unit]
    [(reader.SpannedSexprView.Cons head tail _)
      (begin
        (if (compiler-parse-metadata-sexpr?
          dispatch
          (reader.spanned-sexpr-form head))
          unit
          (compiler-parse-semantic-type-origins! dispatch head))
        (compiler-parse-semantic-variant-payload-origins! dispatch tail))]
    [_ unit]))

(define (parse-ast-defenum-variant-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [head : reader.SpannedSexpr]
  [tail : reader.SpannedSexpr]
  [lifetimes : ast.AstLifetimeList]
  [cleanup : ast.AstEnumCleanup]
  [seen-lifetimes : bool]
  [seen-cleanup : bool]) : ResultAstEnumDefParts
  (match (parse-ast-variant-def
    dispatch
    pools
    (reader.spanned-sexpr-form head)
    (ast.ast-enum-cleanup? cleanup))
    [(ResultAstVariantDef.Ok parsed-variant)
      (begin
        (match (reader.spanned-sexpr-view head)
          [(reader.SpannedSexprView.Cons name-node payloads _)
            (begin
              (match (reader.spanned-sexpr-view name-node)
                [(reader.SpannedSexprView.Sym name span)
                  (compiler-parse-semantic-origin-push-components!
                    name
                    span
                    (CompilerParseSemanticOriginKind.ModulePath)
                    (CompilerParseSemanticOriginKind.EnumVariantDefinition))]
                [_ unit])
              (compiler-parse-semantic-variant-payload-origins!
                dispatch
                payloads))]
          [_ unit])
        (reader.sp-node-push
          (reader.spanned-sexpr-empty (reader.spanned-sexpr-span head)))
        (match (parse-ast-defenum-items
          dispatch
          pools
          tail
          lifetimes
          cleanup
          seen-lifetimes
          seen-cleanup
          true)
          [(ResultAstEnumDefParts.Ok
              parsed-lifetimes
              parsed-cleanup
              parsed-rest)
            (ResultAstEnumDefParts.Ok
              parsed-lifetimes
              parsed-cleanup
              (ast.ast-variant-def-cons parsed-variant parsed-rest))]
          [(ResultAstEnumDefParts.Err message)
            (ResultAstEnumDefParts.Err message)]))]
    [(ResultAstVariantDef.Err message) (ResultAstEnumDefParts.Err message)]))

(define (parse-ast-defenum-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [items : reader.SpannedSexpr]
  [lifetimes : ast.AstLifetimeList]
  [cleanup : ast.AstEnumCleanup]
  [seen-lifetimes : bool]
  [seen-cleanup : bool]
  [seen-variant : bool]) : ResultAstEnumDefParts
  (match (reader.spanned-sexpr-view items)
    [(reader.SpannedSexprView.Nil _)
      (ResultAstEnumDefParts.Ok
        lifetimes
        cleanup
        (ast.ast-variant-def-list-new))]
    [(reader.SpannedSexprView.Cons head tail _)
      (match (reader.sexpr-view (reader.spanned-sexpr-form head))
        [(reader.SexprView.Cons key-node after-key)
          (match (reader.sexpr-view key-node)
            [(reader.SexprView.Sym key)
              (cond
                [(not (compiler-parse-metadata-key? dispatch key))
                  (parse-ast-defenum-variant-item
                    dispatch
                    pools
                    head
                    tail
                    lifetimes
                    cleanup
                    seen-lifetimes
                    seen-cleanup)]
                [seen-variant
                  (ResultAstEnumDefParts.Err
                    "parse: defenum metadata must appear before variants")]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe-ref 236))
                  (if seen-lifetimes
                    (ResultAstEnumDefParts.Err
                      "parse: duplicate defenum :lifetimes metadata")
                    (match (parse-ast-aggregate-lifetimes-tail
                      dispatch
                      pools
                      after-key)
                      [(ResultAstLifetimeList.Ok next-lifetimes)
                        (parse-ast-defenum-items
                          dispatch
                          pools
                          tail
                          next-lifetimes
                          cleanup
                          true
                          seen-cleanup
                          false)]
                      [(ResultAstLifetimeList.Err message)
                        (ResultAstEnumDefParts.Err message)]))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe-ref 234))
                  (if seen-cleanup
                    (ResultAstEnumDefParts.Err
                      "parse: duplicate defenum :cleanup metadata")
                    (match (parse-ast-defenum-cleanup-tail after-key)
                      [(ResultAstEnumCleanup.Ok next-cleanup)
                        (parse-ast-defenum-items
                          dispatch
                          pools
                          tail
                          lifetimes
                          next-cleanup
                          seen-lifetimes
                          true
                          false)]
                      [(ResultAstEnumCleanup.Err message)
                        (ResultAstEnumDefParts.Err message)]))]
                [else
                  (ResultAstEnumDefParts.Err
                    (str_cat.str-cat
                      "parse: unknown defenum metadata "
                      (compiler-parse-dispatch-syntax-id-text dispatch key)))])]
            [_
              (parse-ast-defenum-variant-item
                dispatch
                pools
                head
                tail
                lifetimes
                cleanup
                seen-lifetimes
                seen-cleanup)])]
        [_
          (parse-ast-defenum-variant-item
            dispatch
            pools
            head
            tail
            lifetimes
            cleanup
            seen-lifetimes
            seen-cleanup)])]
    [_ (ResultAstEnumDefParts.Err "parse: malformed variant list")]))

(define (parse-ast-pattern-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]
  [out : (&mut out ast.AstPatternList)]) : ResultAstPatternListBuild
  (match (reader.sexpr-view s)
    [(reader.SexprView.Nil) (ResultAstPatternListBuild.Ok)]
    [(reader.SexprView.Cons head tail)
      (match (parse-ast-pattern dispatch pools head)
        [(ResultAstPattern.Ok parsed-head)
          (begin
            (ast.ast-pattern-list-push out parsed-head)
            (parse-ast-pattern-list-into dispatch pools tail out))]
        [(ResultAstPattern.Err message) (ResultAstPatternListBuild.Err message)])]
    [_ (ResultAstPatternListBuild.Err "parse: malformed pattern list")]))

(define (parse-ast-pattern-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstPatternList
  (let
    [out : ast.AstPatternList (ast.ast-pattern-list-new)]
    (match (parse-ast-pattern-list-into dispatch pools s (&mut out))
      [(ResultAstPatternListBuild.Ok) (ResultAstPatternList.Ok out)]
      [(ResultAstPatternListBuild.Err message)
        (ResultAstPatternList.Err message)])))

(define (parse-ast-pattern
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.Sexpr]) : ResultAstPattern
  (match (reader.sexpr-view s)
    [(reader.SexprView.Int n text)
      (ResultAstPattern.Ok (ast.AstPattern.Literal (ast.AstLiteral.Int n text)))]
    [(reader.SexprView.Float text)
      (ResultAstPattern.Ok (ast.AstPattern.Literal (ast.AstLiteral.Float text)))]
    [(reader.SexprView.Str string-id)
      (ResultAstPattern.Ok
        (ast.AstPattern.Literal
          (ast.AstLiteral.String (ci.intern-id-value string-id))))]
    [(reader.SexprView.Char c)
      (ResultAstPattern.Ok (ast.AstPattern.Literal (ast.AstLiteral.Char c)))]
    [(reader.SexprView.Sym name)
      (let
        [name-id : i64 (ci.intern-syntax-id-value name)]
        [tag : i64 (compiler-parse-dispatch-tag-id dispatch name-id)]
        (cond
          [(= tag (compiler-parse-tag-pattern-wildcard))
            (ResultAstPattern.Ok ast.AstPattern.Wildcard)]
          [(= tag (compiler-parse-tag-lit-true))
            (ResultAstPattern.Ok
              (ast.AstPattern.Literal (ast.AstLiteral.Bool true)))]
          [(= tag (compiler-parse-tag-lit-false))
            (ResultAstPattern.Ok
              (ast.AstPattern.Literal (ast.AstLiteral.Bool false)))]
          [else (ResultAstPattern.Ok (ast.ast-pat-binding-id name-id))]))]
    [(reader.SexprView.Cons name-node args)
      (match (reader.sexpr-view name-node)
        [(reader.SexprView.Sym name)
          (match (parse-ast-pattern-list dispatch pools args)
            [(ResultAstPatternList.Ok parsed-args)
              (let
                [name-id : i64 (ci.intern-syntax-id-value name)]
                [tag : i64 (compiler-parse-dispatch-tag-id dispatch name-id)]
                (cond
                  [(= tag (compiler-parse-tag-expr-tuple))
                    (ResultAstPattern.Ok (ast.ast-pat-tuple parsed-args))]
                  [(= tag (compiler-parse-tag-expr-array))
                    (ResultAstPattern.Ok (ast.ast-pat-array parsed-args))]
                  [else
                    (ResultAstPattern.Ok
                      (ast.ast-pat-variant-id name-id parsed-args))]))]
            [(ResultAstPatternList.Err message) (ResultAstPattern.Err message)])]
        [_ (ResultAstPattern.Err "parse: expected pattern")])]
    [_ (ResultAstPattern.Err "parse: expected pattern")]))

(define (compiler-parse-semantic-pattern-list-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [patterns : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view patterns)
    [(reader.SpannedSexprView.Nil _) unit]
    [(reader.SpannedSexprView.Cons head tail _)
      (begin
        (compiler-parse-semantic-pattern-origins! dispatch head)
        (compiler-parse-semantic-pattern-list-origins! dispatch tail))]
    [_ unit]))

(define (compiler-parse-semantic-pattern-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [pattern : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view pattern)
    [(reader.SpannedSexprView.BracketList items _)
      (compiler-parse-semantic-pattern-origins! dispatch items)]
    [(reader.SpannedSexprView.Cons name-node args _)
      (begin
        (match (reader.spanned-sexpr-view name-node)
          [(reader.SpannedSexprView.Sym name span)
            (let
              [tag : i64
                (compiler-parse-dispatch-tag-id
                  dispatch
                  (ci.intern-syntax-id-value name))]
              (if (or
                (= tag (compiler-parse-tag-expr-tuple))
                (= tag (compiler-parse-tag-expr-array)))
                unit
                (compiler-parse-semantic-origin-push-components!
                  name
                  span
                  (CompilerParseSemanticOriginKind.ModulePath)
                  (CompilerParseSemanticOriginKind.EnumVariantPattern))))]
          [_ unit])
        (compiler-parse-semantic-pattern-list-origins! dispatch args))]
    [(reader.SpannedSexprView.Sym name span)
      (let
        [tag : i64
          (compiler-parse-dispatch-tag-id
            dispatch
            (ci.intern-syntax-id-value name))]
        (if (or
          (= tag (compiler-parse-tag-pattern-wildcard))
          (= tag (compiler-parse-tag-lit-true))
          (= tag (compiler-parse-tag-lit-false)))
          unit
          (compiler-parse-semantic-origin-push-components!
            name
            span
            (CompilerParseSemanticOriginKind.ModulePath)
            (CompilerParseSemanticOriginKind.EnumVariantPattern))))]
    [_ unit]))

(define (parse-ast-cfg-expr-maybe
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstMaybeExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons pred then-tail _)
      (match (reader.spanned-sexpr-view then-tail)
        [(reader.SpannedSexprView.Cons then-expr rest-tail _)
          (match (reader.spanned-sexpr-view rest-tail)
            [(reader.SpannedSexprView.Nil _)
              (match (compiler-cfg-eval dispatch pred)
                [(ResultCompilerCfg.Ok enabled)
                  (if enabled
                    (match (parse-ast-expr-with-pools dispatch pools then-expr)
                      [(ResultAstExpr.Ok parsed)
                        (ResultAstMaybeExpr.SomeExpr parsed)]
                      [(ResultAstExpr.Err message)
                        (ResultAstMaybeExpr.Err message)])
                    (ResultAstMaybeExpr.NoExpr))]
                [(ResultCompilerCfg.Err message)
                  (ResultAstMaybeExpr.Err message)])]
            [(reader.SpannedSexprView.Cons else-expr end _)
              (match (reader.spanned-sexpr-view end)
                [(reader.SpannedSexprView.Nil _)
                  (if (compiler-cfg-predicate-union? dispatch pred)
                    (match (parse-ast-expr-with-pools dispatch pools then-expr)
                      [(ResultAstExpr.Ok parsed-then)
                        (match (parse-ast-expr-with-pools
                          dispatch
                          pools
                          else-expr)
                          [(ResultAstExpr.Ok parsed-else)
                            (let
                              [exprs : ast.AstExprList (ast.ast-expr-list-new)]
                              (begin
                                (ast.ast-expr-list-push
                                  (&mut exprs)
                                  parsed-then)
                                (ast.ast-expr-list-push
                                  (&mut exprs)
                                  parsed-else)
                                (ResultAstMaybeExpr.SomeExpr
                                  (ast.ast-node-pool-context-expr-push
                                    pools
                                    (ast.AstExpr.Begin exprs)))))]
                          [(ResultAstExpr.Err message)
                            (ResultAstMaybeExpr.Err message)])]
                      [(ResultAstExpr.Err message)
                        (ResultAstMaybeExpr.Err message)])
                    (match (compiler-cfg-eval dispatch pred)
                      [(ResultCompilerCfg.Ok enabled)
                        (match (parse-ast-expr-with-pools
                          dispatch
                          pools
                          (if enabled
                            then-expr
                            else-expr))
                          [(ResultAstExpr.Ok parsed)
                            (ResultAstMaybeExpr.SomeExpr parsed)]
                          [(ResultAstExpr.Err message)
                            (ResultAstMaybeExpr.Err message)])]
                      [(ResultCompilerCfg.Err message)
                        (ResultAstMaybeExpr.Err message)]))]
                [_
                  (ResultAstMaybeExpr.Err
                    "parse: cfg expression expects predicate and expression")])]
            [_
              (ResultAstMaybeExpr.Err
                "parse: cfg expression expects predicate and expression")])]
        [_
          (ResultAstMaybeExpr.Err
            "parse: cfg expression expects predicate and expression")])]
    [_
      (ResultAstMaybeExpr.Err
        "parse: cfg expression expects predicate and expression")]))

(define (parse-ast-cfg-expr
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-cfg-expr-maybe dispatch pools rest)
    [(ResultAstMaybeExpr.SomeExpr expr) (ResultAstExpr.Ok expr)]
    [(ResultAstMaybeExpr.NoExpr)
      (ResultAstExpr.Ok
        (ast.ast-node-pool-context-expr-push
          pools
          (ast.AstExpr.Literal ast.AstLiteral.Unit)))]
    [(ResultAstMaybeExpr.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-expr-list-item-maybe
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [head : reader.SpannedSexpr]) : ResultAstMaybeExpr
  (match (reader.spanned-sexpr-view head)
    [(reader.SpannedSexprView.Cons op-node cfg-rest _)
      (match (reader.spanned-sexpr-view op-node)
        [(reader.SpannedSexprView.Sym op _)
          (if (=
            (ci.intern-syntax-id-value op)
            (cbi.compiler-builtin-ctfe-ref 243))
            (parse-ast-cfg-expr-maybe dispatch pools cfg-rest)
            (match (parse-ast-expr-with-pools dispatch pools head)
              [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
              [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)]))]
        [_
          (match (parse-ast-expr-with-pools dispatch pools head)
            [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
            [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)])])]
    [_
      (match (parse-ast-expr-with-pools dispatch pools head)
        [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
        [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)])]))

(define (parse-ast-expr-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [out : (&mut out ast.AstExprList)]) : ResultAstExprListBuild
  (match (reader.spanned-sexpr-view s)
    [(reader.SpannedSexprView.Nil _) (ResultAstExprListBuild.Ok)]
    [(reader.SpannedSexprView.Cons head tail _)
      (match (parse-ast-expr-list-item-maybe dispatch pools head)
        [(ResultAstMaybeExpr.SomeExpr parsed-head)
          (begin
            (ast.ast-expr-list-push out parsed-head)
            (parse-ast-expr-list-into dispatch pools tail out))]
        [(ResultAstMaybeExpr.NoExpr)
          (parse-ast-expr-list-into dispatch pools tail out)]
        [(ResultAstMaybeExpr.Err message) (ResultAstExprListBuild.Err message)])]
    [_ (ResultAstExprListBuild.Err "parse: malformed expression list")]))

(define (parse-ast-expr-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstExprList
  (let
    [out : ast.AstExprList (ast.ast-expr-list-new)]
    (match (parse-ast-expr-list-into dispatch pools s (&mut out))
      [(ResultAstExprListBuild.Ok) (ResultAstExprList.Ok out)]
      [(ResultAstExprListBuild.Err message) (ResultAstExprList.Err message)])))

(define (parse-ast-body-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [missing-message : String]) : ResultAstExpr
  (match (reader.spanned-sexpr-view s)
    [(reader.SpannedSexprView.Nil _) (ResultAstExpr.Err missing-message)]
    [_
      (match (parse-ast-expr-list dispatch pools s)
        [(ResultAstExprList.Ok exprs)
          (let
            [n : i64 exprs.len]
            (cond
              [(= n 0) (ResultAstExpr.Err missing-message)]
              [(= n 1) (ResultAstExpr.Ok (ast.ast-expr-list-get (& exprs) 0 0))]
              [else
                (ResultAstExpr.Ok
                  (ast.ast-node-pool-context-expr-push
                    pools
                    (ast.AstExpr.Begin exprs)))]))]
        [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]))

(define (parse-ast-call-bracket-clause
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [items : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools items)
    [(ResultAstExprList.Ok parsed-items)
      (ResultAstExpr.Ok
        (ast-expr-wrap-span
          pools
          (ast.ast-expr-bracket-clause-with-pools pools parsed-items)
          s))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-call-arg-maybe
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [head : reader.SpannedSexpr]) : ResultAstMaybeExpr
  (match (reader.spanned-sexpr-view head)
    [(reader.SpannedSexprView.BracketList items _)
      (match (parse-ast-call-bracket-clause dispatch pools head items)
        [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
        [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)])]
    [(reader.SpannedSexprView.Cons op-node cfg-rest _)
      (match (reader.spanned-sexpr-view op-node)
        [(reader.SpannedSexprView.Sym op _)
          (if (=
            (ci.intern-syntax-id-value op)
            (cbi.compiler-builtin-ctfe-ref 243))
            (parse-ast-cfg-expr-maybe dispatch pools cfg-rest)
            (match (parse-ast-expr-with-pools dispatch pools head)
              [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
              [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)]))]
        [_
          (match (parse-ast-expr-with-pools dispatch pools head)
            [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
            [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)])])]
    [_
      (match (parse-ast-expr-with-pools dispatch pools head)
        [(ResultAstExpr.Ok parsed) (ResultAstMaybeExpr.SomeExpr parsed)]
        [(ResultAstExpr.Err message) (ResultAstMaybeExpr.Err message)])]))

(define (parse-ast-call-arg-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [out : (&mut out ast.AstExprList)]) : ResultAstExprListBuild
  (match (reader.spanned-sexpr-view s)
    [(reader.SpannedSexprView.Nil _) (ResultAstExprListBuild.Ok)]
    [(reader.SpannedSexprView.Cons head tail _)
      (match (parse-ast-call-arg-maybe dispatch pools head)
        [(ResultAstMaybeExpr.SomeExpr parsed-head)
          (begin
            (ast.ast-expr-list-push out parsed-head)
            (parse-ast-call-arg-list-into dispatch pools tail out))]
        [(ResultAstMaybeExpr.NoExpr)
          (parse-ast-call-arg-list-into dispatch pools tail out)]
        [(ResultAstMaybeExpr.Err message) (ResultAstExprListBuild.Err message)])]
    [_ (ResultAstExprListBuild.Err "parse: malformed call argument list")]))

(define (parse-ast-call-arg-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstExprList
  (let
    [out : ast.AstExprList (ast.ast-expr-list-new)]
    (match (parse-ast-call-arg-list-into dispatch pools s (&mut out))
      [(ResultAstExprListBuild.Ok) (ResultAstExprList.Ok out)]
      [(ResultAstExprListBuild.Err message) (ResultAstExprList.Err message)])))

(define (parse-ast-binary
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [op : ast.AstBinOp]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons left right-tail _)
      (match (reader.spanned-sexpr-view right-tail)
        [(reader.SpannedSexprView.Cons right end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (match (parse-ast-expr-with-pools dispatch pools left)
                [(ResultAstExpr.Ok parsed-left)
                  (match (parse-ast-expr-with-pools dispatch pools right)
                    [(ResultAstExpr.Ok parsed-right)
                      (ResultAstExpr.Ok
                        (ast.ast-expr-binary-with-pools
                          pools
                          op
                          parsed-left
                          parsed-right))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed binary expression")])]
        [_ (ResultAstExpr.Err "parse: malformed binary expression")])]
    [_ (ResultAstExpr.Err "parse: malformed binary expression")]))

(define (parse-ast-binary-left-fold-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [op : ast.AstBinOp]
  [acc : i64]
  [tail : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view tail)
    [(reader.SpannedSexprView.Nil _) (ResultAstExpr.Ok acc)]
    [(reader.SpannedSexprView.Cons expr rest _)
      (match (parse-ast-expr-with-pools dispatch pools expr)
        [(ResultAstExpr.Ok parsed-expr)
          (parse-ast-binary-left-fold-tail
            dispatch
            pools
            op
            (ast.ast-expr-binary-with-pools pools op acc parsed-expr)
            rest)]
        [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
    [_ (ResultAstExpr.Err "parse: malformed binary expression")]))

(define (parse-ast-binary-left-fold
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [op : ast.AstBinOp]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons left right-tail _)
      (match (reader.spanned-sexpr-view right-tail)
        [(reader.SpannedSexprView.Cons right tail _)
          (match (parse-ast-expr-with-pools dispatch pools left)
            [(ResultAstExpr.Ok parsed-left)
              (match (parse-ast-expr-with-pools dispatch pools right)
                [(ResultAstExpr.Ok parsed-right)
                  (parse-ast-binary-left-fold-tail
                    dispatch
                    pools
                    op
                    (ast.ast-expr-binary-with-pools
                      pools
                      op
                      parsed-left
                      parsed-right)
                    tail)]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: malformed binary expression")])]
    [_ (ResultAstExpr.Err "parse: malformed binary expression")]))

(define (parse-ast-unary
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [op : ast.AstUnOp]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(reader.SpannedSexprView.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools expr)
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok
                (ast.ast-expr-unary-with-pools pools op parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: malformed unary expression")])]
    [_ (ResultAstExpr.Err "parse: malformed unary expression")]))

(define (parse-ast-if-missing-else-message) : String
  "parse: if is missing its else branch")

(define (parse-ast-if-arity-message) : String
  "parse: if expects condition, then branch, and else branch")

(define (parse-ast-if-example-note) : String
  "example: (if condition then-expr else-expr)")

(define (parse-ast-if-one-sided-note) : String
  "use (when condition body...) or (unless condition body...) for one-sided conditionals")

(define (parse-ast-if-message? [message : String]) : bool
  (or
    (string.eq message (parse-ast-if-missing-else-message))
    (string.eq message (parse-ast-if-arity-message))))

(define (parse-ast-if-diagnostic-notes [diag : cdiag.CompilerDiagnostic]) : cdiag.CompilerDiagnostic
  (cdiag.compiler-diagnostic-with-note
    (cdiag.compiler-diagnostic-with-note diag (parse-ast-if-one-sided-note))
    (parse-ast-if-example-note)))

(define (parse-ast-if
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons cond then-tail _)
      (match (reader.spanned-sexpr-view then-tail)
        [(reader.SpannedSexprView.Cons then-branch else-tail _)
          (match (reader.spanned-sexpr-view else-tail)
            [(reader.SpannedSexprView.Cons else-branch end _)
              (match (reader.spanned-sexpr-view end)
                [(reader.SpannedSexprView.Nil _)
                  (match (parse-ast-expr-with-pools dispatch pools cond)
                    [(ResultAstExpr.Ok parsed-cond)
                      (match (parse-ast-expr-with-pools
                        dispatch
                        pools
                        then-branch)
                        [(ResultAstExpr.Ok parsed-then)
                          (match (parse-ast-expr-with-pools
                            dispatch
                            pools
                            else-branch)
                            [(ResultAstExpr.Ok parsed-else)
                              (ResultAstExpr.Ok
                                (ast.ast-expr-if-with-pools
                                  pools
                                  parsed-cond
                                  parsed-then
                                  parsed-else))]
                            [(ResultAstExpr.Err message)
                              (ResultAstExpr.Err message)])]
                        [(ResultAstExpr.Err message)
                          (ResultAstExpr.Err message)])]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_ (ResultAstExpr.Err (parse-ast-if-arity-message))])]
            [_ (ResultAstExpr.Err (parse-ast-if-missing-else-message))])]
        [_ (ResultAstExpr.Err (parse-ast-if-arity-message))])]
    [_ (ResultAstExpr.Err (parse-ast-if-arity-message))]))

(define (parse-ast-while
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons cond body-tail _)
      (match (parse-ast-expr-with-pools dispatch pools cond)
        [(ResultAstExpr.Ok parsed-cond)
          (match (parse-ast-body-tail
            dispatch
            pools
            body-tail
            "parse: malformed while")
            [(ResultAstExpr.Ok parsed-body)
              (ResultAstExpr.Ok
                (ast.ast-expr-while-with-pools pools parsed-cond parsed-body))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
    [_ (ResultAstExpr.Err "parse: malformed while")]))

(define (parse-ast-set
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons target-node value-tail _)
      (match (reader.spanned-sexpr-view value-tail)
        [(reader.SpannedSexprView.Cons value end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (match (parse-ast-expr-with-pools dispatch pools value)
                [(ResultAstExpr.Ok parsed-value)
                  (match (reader.spanned-sexpr-view target-node)
                    [(reader.SpannedSexprView.Sym name target-span)
                      (begin
                        (compiler-parse-semantic-dotted-field-origins!
                          name
                          target-span)
                        (ResultAstExpr.Ok
                          (ast.ast-expr-spanned-with-pools
                            pools
                            (ast.ast-expr-set-id-with-pools
                              pools
                              (ci.intern-syntax-id-value name)
                              parsed-value)
                            (ast-source-span-from-source-span
                              (reader.spanned-sexpr-span target-node)))))]
                    [_
                      (match (parse-ast-expr-with-pools
                        dispatch
                        pools
                        target-node)
                        [(ResultAstExpr.Ok parsed-target)
                          (match (ast.ast-expr-unspan-with-pools
                            pools
                            (ast.ast-node-pool-context-expr-get
                              pools
                              parsed-target))
                            [(ast.AstExpr.StructGet receiver-box field)
                              (ResultAstExpr.Ok
                                (ast.ast-expr-struct-set-id-with-pools
                                  pools
                                  receiver-box
                                  field
                                  parsed-value))]
                            [(ast.AstExpr.TupleRef receiver-box index)
                              (if (< index 0)
                                (ResultAstExpr.Err
                                  "parse: tuple-ref assignment index must be non-negative")
                                (ResultAstExpr.Ok
                                  (ast.ast-expr-struct-set-id-with-pools
                                    pools
                                    receiver-box
                                    (ast.ast-tuple-set-field-id-from-index
                                      index)
                                    parsed-value)))]
                            [(ast.AstExpr.ArrayRef receiver-box index-box)
                              (ResultAstExpr.Ok
                                (ast.ast-expr-array-set-with-pools
                                  pools
                                  receiver-box
                                  index-box
                                  parsed-value))]
                            [(ast.AstExpr.BoxGet receiver-box)
                              (ResultAstExpr.Ok
                                (ast.ast-expr-box-set-with-pools
                                  pools
                                  receiver-box
                                  parsed-value))]
                            [(ast.AstExpr.BoxTake receiver-box)
                              (ResultAstExpr.Ok
                                (ast.ast-expr-box-set-with-pools
                                  pools
                                  receiver-box
                                  parsed-value))]
                            [(ast.AstExpr.Unquote _)
                              (ResultAstExpr.Ok
                                (ast.ast-expr-struct-set-id-with-pools
                                  pools
                                  parsed-target
                                  (ast.ast-expr-unquote-set-target-field-id)
                                  parsed-value))]
                            [_
                              (ResultAstExpr.Err
                                "parse: set! target must be a mutable place")])]
                        [(ResultAstExpr.Err message)
                          (ResultAstExpr.Err message)])])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed set!")])]
        [_ (ResultAstExpr.Err "parse: malformed set!")])]
    [_ (ResultAstExpr.Err "parse: malformed set!")]))

(define (parse-ast-replace-place?
  [pools : ast.AstNodePoolContext]
  [expr-id : i64]) : bool
  (match (ast.ast-expr-unspan-with-pools
    pools
    (ast.ast-node-pool-context-expr-get pools expr-id))
    [(ast.AstExpr.Var _) true]
    [(ast.AstExpr.StructGet _ _) true]
    [(ast.AstExpr.TupleRef _ index) (>= index 0)]
    [(ast.AstExpr.ArrayRef _ _) true]
    [(ast.AstExpr.BoxGet _) true]
    [(ast.AstExpr.BoxTake _) true]
    [_ false]))

(define (parse-ast-replace
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons place-node replacement-tail _)
      (match (reader.spanned-sexpr-view replacement-tail)
        [(reader.SpannedSexprView.Cons replacement-node end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (match (parse-ast-expr-with-pools dispatch pools place-node)
                [(ResultAstExpr.Ok place-id)
                  (if (parse-ast-replace-place? pools place-id)
                    (match (parse-ast-expr-with-pools
                      dispatch
                      pools
                      replacement-node)
                      [(ResultAstExpr.Ok replacement-id)
                        (ResultAstExpr.Ok
                          (ast.ast-expr-replace-with-pools
                            pools
                            place-id
                            replacement-id))]
                      [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])
                    (ResultAstExpr.Err
                      "parse: replace! target must be a mutable place"))]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_
              (ResultAstExpr.Err "parse: replace! expects exactly two operands")])]
        [_ (ResultAstExpr.Err "parse: replace! expects exactly two operands")])]
    [_ (ResultAstExpr.Err "parse: replace! expects exactly two operands")]))

(define (parse-ast-ann-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [is-cast : bool]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr colon-tail _)
      (match (reader.spanned-sexpr-view colon-tail)
        [(reader.SpannedSexprView.Cons colon ty-tail _)
          (match (reader.spanned-sexpr-view ty-tail)
            [(reader.SpannedSexprView.Cons ty end _)
              (match (reader.spanned-sexpr-view end)
                [(reader.SpannedSexprView.Nil _)
                  (if (sexpr-colon? (reader.spanned-sexpr-form colon))
                    (match (parse-ast-expr-with-pools dispatch pools expr)
                      [(ResultAstExpr.Ok parsed-expr)
                        (match (parse-ast-type-spanned dispatch pools ty)
                          [(ResultAstType.Ok parsed-ty)
                            (if is-cast
                              (ResultAstExpr.Ok
                                (ast.ast-expr-cast-with-pools
                                  pools
                                  parsed-expr
                                  parsed-ty))
                              (ResultAstExpr.Ok
                                (ast.ast-expr-ann-with-pools
                                  pools
                                  parsed-expr
                                  parsed-ty)))]
                          [(ResultAstType.Err message)
                            (ResultAstExpr.Err message)])]
                      [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])
                    (ResultAstExpr.Err "parse: expected ':' in annotation"))]
                [_ (ResultAstExpr.Err "parse: malformed annotation")])]
            [_ (ResultAstExpr.Err "parse: malformed annotation")])]
        [_ (ResultAstExpr.Err "parse: malformed annotation")])]
    [_ (ResultAstExpr.Err "parse: malformed annotation")]))

(define (parse-ast-let-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstLetBinding
  (let
    [result : ResultAstLetBinding
      (match (reader.spanned-sexpr-view s)
        [(reader.SpannedSexprView.BracketList items _)
          (parse-ast-let-binding dispatch pools items)]
        [(reader.SpannedSexprView.Cons name-node tail _)
          (match (reader.spanned-sexpr-view name-node)
            [(reader.SpannedSexprView.Sym name _)
              (match (reader.spanned-sexpr-view tail)
                [(reader.SpannedSexprView.Cons second rest _)
                  (match (reader.spanned-sexpr-view rest)
                    [(reader.SpannedSexprView.Nil _)
                      (match (parse-ast-expr-with-pools dispatch pools second)
                        [(ResultAstExpr.Ok parsed-value)
                          (ResultAstLetBinding.Ok
                            (ast.ast-let-binding-id
                              (ci.intern-syntax-id-value name)
                              ast.AstMaybeType.No
                              parsed-value))]
                        [(ResultAstExpr.Err message)
                          (ResultAstLetBinding.Err message)])]
                    [(reader.SpannedSexprView.Cons ty value-tail _)
                      (match (reader.spanned-sexpr-view value-tail)
                        [(reader.SpannedSexprView.Cons value end _)
                          (match (reader.spanned-sexpr-view end)
                            [(reader.SpannedSexprView.Nil _)
                              (if (sexpr-colon?
                                (reader.spanned-sexpr-form second))
                                (match (parse-ast-type-spanned
                                  dispatch
                                  pools
                                  ty)
                                  [(ResultAstType.Ok parsed-ty)
                                    (match (parse-ast-expr-with-pools
                                      dispatch
                                      pools
                                      value)
                                      [(ResultAstExpr.Ok parsed-value)
                                        (ResultAstLetBinding.Ok
                                          (ast.ast-let-binding-id
                                            (ci.intern-syntax-id-value name)
                                            (ast.AstMaybeType.Some parsed-ty)
                                            parsed-value))]
                                      [(ResultAstExpr.Err message)
                                        (ResultAstLetBinding.Err message)])]
                                  [(ResultAstType.Err message)
                                    (ResultAstLetBinding.Err message)])
                                (ResultAstLetBinding.Err
                                  "parse: expected ':' in let binding"))]
                            [_
                              (ResultAstLetBinding.Err
                                "parse: malformed let binding")])]
                        [_
                          (ResultAstLetBinding.Err
                            "parse: malformed let binding")])]
                    [_ (ResultAstLetBinding.Err "parse: malformed let binding")])]
                [_ (ResultAstLetBinding.Err "parse: malformed let binding")])]
            [_ (ResultAstLetBinding.Err "parse: malformed let binding")])]
        [_ (ResultAstLetBinding.Err "parse: malformed let binding")])]
    (parse-ast-error-span-note-let-binding dispatch s result)))

(define (parse-ast-let-flat-tail-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [out : (&mut out ast.AstLetBindingList)]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons head tail _)
      (match (reader.spanned-sexpr-view head)
        [(reader.SpannedSexprView.BracketList _ _)
          (match (parse-ast-let-binding dispatch pools head)
            [(ResultAstLetBinding.Ok parsed-head)
              (begin
                (ast.ast-let-binding-list-push out parsed-head)
                (parse-ast-let-flat-tail-into dispatch pools tail out))]
            [(ResultAstLetBinding.Err message) (ResultAstExpr.Err message)])]
        [_ (parse-ast-body-tail dispatch pools rest "parse: let missing body")])]
    [(reader.SpannedSexprView.Nil _)
      (ResultAstExpr.Err "parse: let missing body")]
    [_ (ResultAstExpr.Err "parse: malformed let")]))

(define (parse-ast-let-flat-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstLetParts
  (let
    [out : ast.AstLetBindingList (ast.ast-let-binding-list-new)]
    (match (parse-ast-let-flat-tail-into dispatch pools rest (&mut out))
      [(ResultAstExpr.Ok parsed-body) (ResultAstLetParts.Ok out parsed-body)]
      [(ResultAstExpr.Err message) (ResultAstLetParts.Err message)])))

(define (parse-ast-let-flat
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons head _ _)
      (match (reader.spanned-sexpr-view head)
        [(reader.SpannedSexprView.BracketList items _)
          (match (reader.spanned-sexpr-view items)
            [(reader.SpannedSexprView.Nil _)
              (match (reader.spanned-sexpr-view rest)
                [(reader.SpannedSexprView.Cons _ body-tail _)
                  (parse-ast-body-tail
                    dispatch
                    pools
                    body-tail
                    "parse: let missing body")]
                [_ (ResultAstExpr.Err "parse: malformed let")])]
            [_
              (match (parse-ast-let-flat-tail dispatch pools rest)
                [(ResultAstLetParts.Ok parsed-bindings parsed-body)
                  (ResultAstExpr.Ok
                    (ast.ast-expr-let-with-pools
                      pools
                      parsed-bindings
                      parsed-body))]
                [(ResultAstLetParts.Err message) (ResultAstExpr.Err message)])])]
        [_ (ResultAstExpr.Err "parse: let requires at least one binding")])]
    [_ (ResultAstExpr.Err "parse: malformed let")]))

(define (parse-ast-let
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons bindings _ _)
      (match (reader.spanned-sexpr-view bindings)
        [(reader.SpannedSexprView.BracketList _ _)
          (parse-ast-let-flat dispatch pools rest)]
        [(reader.SpannedSexprView.Nil _)
          (begin
            (parse-ast-error-span-note!
              dispatch
              (reader.spanned-sexpr-span bindings))
            (ResultAstExpr.Err
              "parse: (let () body...) was removed; write (let [] body...)"))]
        [(reader.SpannedSexprView.Cons _ _ _)
          (begin
            (parse-ast-error-span-note!
              dispatch
              (reader.spanned-sexpr-span bindings))
            (ResultAstExpr.Err
              "parse: parenthesized let bindings were removed; write leading [name [: type] init] bindings without parentheses"))]
        [_ (ResultAstExpr.Err "parse: let requires at least one binding")])]
    [_ (ResultAstExpr.Err "parse: malformed let")]))

(define (parse-ast-lambda
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons params tail _)
      (match (parse-ast-param-list
        dispatch
        pools
        (reader.spanned-sexpr-form params))
        [(ResultAstParamList.Ok parsed-params)
          (begin
            (compiler-parse-semantic-param-list-origins! dispatch params)
            (if (ast-param-list-has-comptime? parsed-params)
              (ResultAstExpr.Err
                "comptime parameters are only supported on top-level function definitions")
              (match (reader.spanned-sexpr-view tail)
                [(reader.SpannedSexprView.Cons first rest-tail _)
                  (if (sexpr-colon? (reader.spanned-sexpr-form first))
                    (match (reader.spanned-sexpr-view rest-tail)
                      [(reader.SpannedSexprView.Cons ret body-tail _)
                        (match (parse-ast-type-spanned dispatch pools ret)
                          [(ResultAstType.Ok parsed-ret)
                            (match (parse-ast-body-tail
                              dispatch
                              pools
                              body-tail
                              "parse: malformed lambda")
                              [(ResultAstExpr.Ok parsed-body)
                                (ResultAstExpr.Ok
                                  (ast.ast-expr-lambda-with-pools
                                    pools
                                    parsed-params
                                    (ast.AstMaybeType.Some parsed-ret)
                                    parsed-body))]
                              [(ResultAstExpr.Err message)
                                (ResultAstExpr.Err message)])]
                          [(ResultAstType.Err message)
                            (ResultAstExpr.Err message)])]
                      [_ (ResultAstExpr.Err "parse: malformed lambda")])
                    (match (parse-ast-body-tail
                      dispatch
                      pools
                      tail
                      "parse: malformed lambda")
                      [(ResultAstExpr.Ok parsed-body)
                        (ResultAstExpr.Ok
                          (ast.ast-expr-lambda-with-pools
                            pools
                            parsed-params
                            ast.AstMaybeType.No
                            parsed-body))]
                      [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))]
                [_ (ResultAstExpr.Err "parse: malformed lambda")])))]
        [(ResultAstParamList.Err message) (ResultAstExpr.Err message)])]
    [_ (ResultAstExpr.Err "parse: malformed lambda")]))

(define (parse-ast-tuple-ref
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr index-tail _)
      (match (reader.spanned-sexpr-view index-tail)
        [(reader.SpannedSexprView.Cons index-node end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (match (reader.spanned-sexpr-view index-node)
                [(reader.SpannedSexprView.Int index _ _)
                  (match (parse-ast-expr-with-pools dispatch pools expr)
                    [(ResultAstExpr.Ok parsed-expr)
                      (ResultAstExpr.Ok
                        (ast.ast-expr-tuple-ref-with-pools
                          pools
                          parsed-expr
                          index))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_ (ResultAstExpr.Err "parse: tuple-ref index must be integer")])]
            [_ (ResultAstExpr.Err "parse: malformed tuple-ref")])]
        [_ (ResultAstExpr.Err "parse: malformed tuple-ref")])]
    [_ (ResultAstExpr.Err "parse: malformed tuple-ref")]))

(define (parse-ast-dyn-array-literal
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools rest)
    [(ResultAstExprList.Ok exprs)
      (ResultAstExpr.Ok (ast.ast-expr-dyn-array-with-pools pools exprs))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-make-array
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons elem-ty len-tail _)
      (match (reader.spanned-sexpr-view len-tail)
        [(reader.SpannedSexprView.Cons len end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (match (parse-ast-type-spanned dispatch pools elem-ty)
                [(ResultAstType.Ok parsed-ty)
                  (match (parse-ast-expr-with-pools dispatch pools len)
                    [(ResultAstExpr.Ok parsed-len)
                      (ResultAstExpr.Ok
                        (ast.ast-expr-make-array-with-pools
                          pools
                          parsed-ty
                          parsed-len))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstType.Err _)
                  (parse-ast-dyn-array-literal dispatch pools rest)])]
            [_ (parse-ast-dyn-array-literal dispatch pools rest)])]
        [_ (parse-ast-dyn-array-literal dispatch pools rest)])]
    [_ (parse-ast-dyn-array-literal dispatch pools rest)]))

(define (parse-ast-fixed-make-array
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons elem-ty len-tail _)
      (match (reader.spanned-sexpr-view len-tail)
        [(reader.SpannedSexprView.Cons len end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (match (parse-ast-type-spanned dispatch pools elem-ty)
                [(ResultAstType.Ok parsed-ty)
                  (match (parse-ast-expr-with-pools dispatch pools len)
                    [(ResultAstExpr.Ok parsed-len)
                      (ResultAstExpr.Ok
                        (ast.ast-expr-fixed-make-array-with-pools
                          pools
                          parsed-ty
                          parsed-len))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstType.Err message) (ResultAstExpr.Err message)])]
            [_
              (ResultAstExpr.Err
                "parse: make-array expects exactly one type and one length")])]
        [_
          (ResultAstExpr.Err
            "parse: make-array expects exactly one type and one length")])]
    [_
      (ResultAstExpr.Err
        "parse: make-array expects exactly one type and one length")]))

(define (parse-ast-array-ref-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [is-string : bool]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr index-tail _)
      (match (reader.spanned-sexpr-view index-tail)
        [(reader.SpannedSexprView.Cons index end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (match (parse-ast-expr-with-pools dispatch pools expr)
                [(ResultAstExpr.Ok parsed-expr)
                  (match (parse-ast-expr-with-pools dispatch pools index)
                    [(ResultAstExpr.Ok parsed-index)
                      (if is-string
                        (ResultAstExpr.Ok
                          (ast.ast-expr-string-ref-with-pools
                            pools
                            parsed-expr
                            parsed-index))
                        (ResultAstExpr.Ok
                          (ast.ast-expr-array-ref-with-pools
                            pools
                            parsed-expr
                            parsed-index)))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed ref expression")])]
        [_ (ResultAstExpr.Err "parse: malformed ref expression")])]
    [_ (ResultAstExpr.Err "parse: malformed ref expression")]))

(define (parse-ast-array-set
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr index-tail _)
      (match (reader.spanned-sexpr-view index-tail)
        [(reader.SpannedSexprView.Cons index value-tail _)
          (match (reader.spanned-sexpr-view value-tail)
            [(reader.SpannedSexprView.Cons value end _)
              (match (reader.spanned-sexpr-view end)
                [(reader.SpannedSexprView.Nil _)
                  (match (parse-ast-expr-with-pools dispatch pools expr)
                    [(ResultAstExpr.Ok parsed-expr)
                      (match (parse-ast-expr-with-pools dispatch pools index)
                        [(ResultAstExpr.Ok parsed-index)
                          (match (parse-ast-expr-with-pools
                            dispatch
                            pools
                            value)
                            [(ResultAstExpr.Ok parsed-value)
                              (ResultAstExpr.Ok
                                (ast.ast-expr-array-set-with-pools
                                  pools
                                  parsed-expr
                                  parsed-index
                                  parsed-value))]
                            [(ResultAstExpr.Err message)
                              (ResultAstExpr.Err message)])]
                        [(ResultAstExpr.Err message)
                          (ResultAstExpr.Err message)])]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_ (ResultAstExpr.Err "parse: malformed array-set!")])]
            [_ (ResultAstExpr.Err "parse: malformed array-set!")])]
        [_ (ResultAstExpr.Err "parse: malformed array-set!")])]
    [_ (ResultAstExpr.Err "parse: malformed array-set!")]))

(define (parse-ast-array-push
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr value-tail _)
      (match (reader.spanned-sexpr-view value-tail)
        [(reader.SpannedSexprView.Cons value end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (match (parse-ast-expr-with-pools dispatch pools expr)
                [(ResultAstExpr.Ok parsed-expr)
                  (match (parse-ast-expr-with-pools dispatch pools value)
                    [(ResultAstExpr.Ok parsed-value)
                      (ResultAstExpr.Ok
                        (ast.ast-expr-array-push-with-pools
                          pools
                          parsed-expr
                          parsed-value))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed __tl_array-push!")])]
        [_ (ResultAstExpr.Err "parse: malformed __tl_array-push!")])]
    [_ (ResultAstExpr.Err "parse: malformed __tl_array-push!")]))

(define (parse-ast-private-array-take
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons array live-tail _)
      (match (reader.spanned-sexpr-view live-tail)
        [(reader.SpannedSexprView.Cons live index-tail _)
          (match (reader.spanned-sexpr-view index-tail)
            [(reader.SpannedSexprView.Cons index end _)
              (match (reader.spanned-sexpr-view end)
                [(reader.SpannedSexprView.Nil _)
                  (match (parse-ast-expr-with-pools dispatch pools array)
                    [(ResultAstExpr.Ok parsed-array)
                      (match (parse-ast-expr-with-pools dispatch pools live)
                        [(ResultAstExpr.Ok parsed-live)
                          (match (parse-ast-expr-with-pools
                            dispatch
                            pools
                            index)
                            [(ResultAstExpr.Ok parsed-index)
                              (ResultAstExpr.Ok
                                (ast.ast-expr-array-take-with-pools
                                  pools
                                  parsed-array
                                  parsed-live
                                  parsed-index))]
                            [(ResultAstExpr.Err message)
                              (ResultAstExpr.Err message)])]
                        [(ResultAstExpr.Err message)
                          (ResultAstExpr.Err message)])]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_ (ResultAstExpr.Err "parse: malformed __tl_array-take!")])]
            [_ (ResultAstExpr.Err "parse: malformed __tl_array-take!")])]
        [_ (ResultAstExpr.Err "parse: malformed __tl_array-take!")])]
    [_ (ResultAstExpr.Err "parse: malformed __tl_array-take!")]))

(define (parse-ast-fixed-array-take
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons array index-tail _)
      (match (reader.spanned-sexpr-view index-tail)
        [(reader.SpannedSexprView.Cons index end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (match (parse-ast-expr-with-pools dispatch pools array)
                [(ResultAstExpr.Ok parsed-array)
                  (match (parse-ast-expr-with-pools dispatch pools index)
                    [(ResultAstExpr.Ok parsed-index)
                      (ResultAstExpr.Ok
                        (ast.ast-expr-fixed-array-take-with-pools
                          pools
                          parsed-array
                          parsed-index))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_
              (ResultAstExpr.Err
                "parse: array-take! expects exactly two operands; compatibility storage must use private __tl_array-take!")])]
        [_ (ResultAstExpr.Err "parse: malformed array-take!")])]
    [_ (ResultAstExpr.Err "parse: malformed array-take!")]))

(define (parse-ast-for-owned-state
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools rest)
    [(ResultAstExprList.Ok args)
      (if (= args.len 4)
        (ResultAstExpr.Ok
          (ast.ast-expr-for-owned-state-with-pools
            pools
            (ast.ast-expr-list-get (& args) 0 0)
            (ast.ast-expr-list-get (& args) 1 0)
            (ast.ast-expr-list-get (& args) 2 0)
            (ast.ast-expr-list-get (& args) 3 0)))
        (ResultAstExpr.Err
          "parse: __tl_for-owned-state expects exactly four operands"))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-for-owned-step
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [typed : bool]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools rest)
    [(ResultAstExprList.Ok args)
      (let
        [expected-count : i64
          (if typed
            6
            5)]
        (if (= args.len expected-count)
          (ResultAstExpr.Ok
            (ast.ast-expr-for-owned-step-with-pools
              pools
              (ast.ast-expr-list-get (& args) 0 0)
              (ast.ast-expr-list-get (& args) 1 0)
              (ast.ast-expr-list-get (& args) 2 0)
              (if typed
                (ast.ast-expr-list-get (& args) 3 0)
                -1)
              (ast.ast-expr-list-get
                (& args)
                (if typed
                  4
                  3)
                0)
              (ast.ast-expr-list-get
                (& args)
                (if typed
                  5
                  4)
                0)))
          (ResultAstExpr.Err
            (if typed
              "parse: __tl_for-owned-step-typed expects exactly six operands"
              "parse: __tl_for-owned-step expects exactly five operands"))))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-borrow
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [mutable : bool]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons first tail _)
      (match (reader.spanned-sexpr-view tail)
        [(reader.SpannedSexprView.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools first)
            [(ResultAstExpr.Ok parsed-place)
              (ResultAstExpr.Ok
                (ast.ast-expr-borrow-with-pools
                  pools
                  mutable
                  ast.AstBorrowLifetime.Inferred
                  parsed-place))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [(reader.SpannedSexprView.Cons place end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (match (reader.spanned-sexpr-view first)
                [(reader.SpannedSexprView.Sym name _)
                  (match (parse-ast-expr-with-pools dispatch pools place)
                    [(ResultAstExpr.Ok parsed-place)
                      (ResultAstExpr.Ok
                        (ast.ast-expr-borrow-with-pools
                          pools
                          mutable
                          (ast.AstBorrowLifetime.Named
                            (ci.intern-syntax-id-value name))
                          parsed-place))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_
                  (ResultAstExpr.Err
                    "parse: borrow lifetime must be an identifier")])]
            [_
              (ResultAstExpr.Err
                "parse: borrow expects a place or lifetime and place")])]
        [_
          (ResultAstExpr.Err
            "parse: borrow expects a place or lifetime and place")])]
    [_
      (ResultAstExpr.Err "parse: borrow expects a place or lifetime and place")]))

(define (parse-ast-struct-get
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr field-tail _)
      (match (reader.spanned-sexpr-view field-tail)
        [(reader.SpannedSexprView.Cons field-node end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (match (reader.spanned-sexpr-view field-node)
                [(reader.SpannedSexprView.Sym field _)
                  (match (parse-ast-expr-with-pools dispatch pools expr)
                    [(ResultAstExpr.Ok parsed-expr)
                      (begin
                        (compiler-parse-semantic-origin-push-components!
                          field
                          (reader.spanned-sexpr-span field-node)
                          (CompilerParseSemanticOriginKind.ModulePath)
                          (CompilerParseSemanticOriginKind.StructFieldUse))
                        (ResultAstExpr.Ok
                          (ast.ast-expr-struct-get-id-with-pools
                            pools
                            parsed-expr
                            (ci.intern-syntax-id-value field))))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [_ (ResultAstExpr.Err "parse: malformed struct-get")])]
            [_ (ResultAstExpr.Err "parse: malformed struct-get")])]
        [_ (ResultAstExpr.Err "parse: malformed struct-get")])]
    [_ (ResultAstExpr.Err "parse: malformed struct-get")]))

;; `(comptime expr)` wraps exactly one inner expression for compile-time
;; evaluation; evaluation itself happens in CTFE, not the parser.
(define (parse-ast-comptime
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(reader.SpannedSexprView.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools expr)
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok
                (ast.ast-expr-comptime-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: comptime expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: comptime expects exactly one expression")]))

(define (parse-ast-type-literal
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons ty end _)
      (match (reader.spanned-sexpr-view end)
        [(reader.SpannedSexprView.Nil _)
          (match (parse-ast-type-spanned dispatch pools ty)
            [(ResultAstType.Ok parsed-ty)
              (ResultAstExpr.Ok
                (ast.ast-node-pool-context-expr-push
                  pools
                  (ast.AstExpr.TypeLiteral
                    (ast.ast-node-pool-context-type-push pools parsed-ty))))]
            [(ResultAstType.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: type expects exactly one type")])]
    [_ (ResultAstExpr.Err "parse: type expects exactly one type")]))

(define (parse-ast-reduce-op [dispatch : sym_i64_env.SymI64Env] [name-id : i64]) : ResultAstReduceOp
  (cond
    [(= name-id (cbi.compiler-builtin-ctfe-ref 262))
      (ResultAstReduceOp.Ok (ast.AstReduceOp.Sum))]
    [(= name-id (cbi.compiler-builtin-ctfe-ref 263))
      (ResultAstReduceOp.Ok (ast.AstReduceOp.Min))]
    [(= name-id (cbi.compiler-builtin-ctfe-ref 264))
      (ResultAstReduceOp.Ok (ast.AstReduceOp.Max))]
    [(= name-id (cbi.compiler-builtin-ctfe-ref 219))
      (ResultAstReduceOp.Ok (ast.AstReduceOp.All))]
    [(= name-id (cbi.compiler-builtin-ctfe-ref 220))
      (ResultAstReduceOp.Ok (ast.AstReduceOp.Any))]
    [else
      (ResultAstReduceOp.Err
        (str_cat.str-cat
          "parse: unsupported spmd-reduce operator `"
          (compiler-parse-dispatch-name-text dispatch name-id)
          "`; expected one of sum, min, max, all, any"))]))

(define (parse-ast-scan-op [dispatch : sym_i64_env.SymI64Env] [name-id : i64]) : ResultAstReduceOp
  (cond
    [(= name-id (cbi.compiler-builtin-ctfe-ref 262))
      (ResultAstReduceOp.Ok (ast.AstReduceOp.Sum))]
    [(= name-id (cbi.compiler-builtin-ctfe-ref 263))
      (ResultAstReduceOp.Ok (ast.AstReduceOp.Min))]
    [(= name-id (cbi.compiler-builtin-ctfe-ref 264))
      (ResultAstReduceOp.Ok (ast.AstReduceOp.Max))]
    [(= name-id (cbi.compiler-builtin-ctfe-ref 219))
      (ResultAstReduceOp.Ok (ast.AstReduceOp.All))]
    [(= name-id (cbi.compiler-builtin-ctfe-ref 220))
      (ResultAstReduceOp.Ok (ast.AstReduceOp.Any))]
    [else
      (ResultAstReduceOp.Err
        (str_cat.str-cat
          "parse: unsupported spmd-scan operator `"
          (compiler-parse-dispatch-name-text dispatch name-id)
          "`; expected one of sum, min, max, all, any"))]))

(define (parse-ast-spmd-reduce-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [op : ast.AstReduceOp]
  [binding : reader.SpannedSexpr]
  [init : reader.SpannedSexpr]
  [value : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view binding)
    [(reader.SpannedSexprView.BracketList items _)
      (parse-ast-spmd-reduce-binding dispatch pools op items init value)]
    [(reader.SpannedSexprView.Cons index-node colon-tail _)
      (match (reader.spanned-sexpr-view index-node)
        [(reader.SpannedSexprView.Sym index _)
          (match (reader.spanned-sexpr-view colon-tail)
            [(reader.SpannedSexprView.Cons colon index-ty-tail _)
              (match (reader.spanned-sexpr-view index-ty-tail)
                [(reader.SpannedSexprView.Cons index-ty start-tail _)
                  (match (reader.spanned-sexpr-view start-tail)
                    [(reader.SpannedSexprView.Cons start end-tail _)
                      (match (reader.spanned-sexpr-view end-tail)
                        [(reader.SpannedSexprView.Cons end finish _)
                          (match (reader.spanned-sexpr-view finish)
                            [(reader.SpannedSexprView.Nil _)
                              (if (sexpr-colon?
                                (reader.spanned-sexpr-form colon))
                                (match (parse-ast-type-spanned
                                  dispatch
                                  pools
                                  index-ty)
                                  [(ResultAstType.Ok parsed-index-ty)
                                    (match (parse-ast-expr-with-pools
                                      dispatch
                                      pools
                                      start)
                                      [(ResultAstExpr.Ok parsed-start)
                                        (match (parse-ast-expr-with-pools
                                          dispatch
                                          pools
                                          end)
                                          [(ResultAstExpr.Ok parsed-end)
                                            (match (parse-ast-expr-with-pools
                                              dispatch
                                              pools
                                              init)
                                              [(ResultAstExpr.Ok parsed-init)
                                                (match (parse-ast-expr-with-pools
                                                  dispatch
                                                  pools
                                                  value)
                                                  [(ResultAstExpr.Ok
                                                      parsed-value)
                                                    (ResultAstExpr.Ok
                                                      (ast.ast-expr-spmd-reduce-id-with-pools
                                                        pools
                                                        op
                                                        (ci.intern-syntax-id-value
                                                          index)
                                                        parsed-index-ty
                                                        parsed-start
                                                        parsed-end
                                                        parsed-init
                                                        parsed-value))]
                                                  [(ResultAstExpr.Err message)
                                                    (ResultAstExpr.Err message)])]
                                              [(ResultAstExpr.Err message)
                                                (ResultAstExpr.Err message)])]
                                          [(ResultAstExpr.Err message)
                                            (ResultAstExpr.Err message)])]
                                      [(ResultAstExpr.Err message)
                                        (ResultAstExpr.Err message)])]
                                  [(ResultAstType.Err message)
                                    (ResultAstExpr.Err message)])
                                (ResultAstExpr.Err
                                  "parse: expected ':' in spmd-reduce"))]
                            [_
                              (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                        [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                    [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
    [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")]))

(define (parse-ast-spmd-reduce
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons op-node binding-tail _)
      (match (reader.spanned-sexpr-view op-node)
        [(reader.SpannedSexprView.Sym op-name _)
          (match (reader.spanned-sexpr-view binding-tail)
            [(reader.SpannedSexprView.Cons binding-list init-tail _)
              (match (reader.spanned-sexpr-view binding-list)
                [(reader.SpannedSexprView.Cons binding binding-list-end _)
                  (match (reader.spanned-sexpr-view binding-list-end)
                    [(reader.SpannedSexprView.Nil _)
                      (match (reader.spanned-sexpr-view init-tail)
                        [(reader.SpannedSexprView.Cons init value-tail _)
                          (match (reader.spanned-sexpr-view value-tail)
                            [(reader.SpannedSexprView.Cons value end _)
                              (match (reader.spanned-sexpr-view end)
                                [(reader.SpannedSexprView.Nil _)
                                  (match (parse-ast-reduce-op
                                    dispatch
                                    (ci.intern-syntax-id-value op-name))
                                    [(ResultAstReduceOp.Ok op)
                                      (parse-ast-spmd-reduce-binding
                                        dispatch
                                        pools
                                        op
                                        binding
                                        init
                                        value)]
                                    [(ResultAstReduceOp.Err message)
                                      (ResultAstExpr.Err message)])]
                                [_
                                  (ResultAstExpr.Err
                                    "parse: malformed spmd-reduce")])]
                            [_
                              (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                        [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                    [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
                [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")])]
    [(reader.SpannedSexprView.Cons _ _ _)
      (ResultAstExpr.Err "parse: malformed spmd-reduce")]
    [_ (ResultAstExpr.Err "parse: malformed spmd-reduce")]))

(define (parse-ast-spmd-scan
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons op-node binding-tail _)
      (match (reader.spanned-sexpr-view op-node)
        [(reader.SpannedSexprView.Sym op-name _)
          (match (reader.spanned-sexpr-view binding-tail)
            [(reader.SpannedSexprView.Cons binding-list value-tail _)
              (match (reader.spanned-sexpr-view binding-list)
                [(reader.SpannedSexprView.Cons range-binding prefix-tail _)
                  (match (reader.spanned-sexpr-view prefix-tail)
                    [(reader.SpannedSexprView.Cons prefix-binding binding-end _)
                      (match (reader.spanned-sexpr-view binding-end)
                        [(reader.SpannedSexprView.Nil _)
                          (match (reader.spanned-sexpr-view value-tail)
                            [(reader.SpannedSexprView.Cons value body-tail _)
                              (match (reader.spanned-sexpr-view body-tail)
                                [(reader.SpannedSexprView.Cons body end _)
                                  (match (reader.spanned-sexpr-view end)
                                    [(reader.SpannedSexprView.Nil _)
                                      (match (parse-ast-scan-op
                                        dispatch
                                        (ci.intern-syntax-id-value op-name))
                                        [(ResultAstReduceOp.Ok op)
                                          (parse-ast-spmd-scan-bindings
                                            dispatch
                                            pools
                                            op
                                            range-binding
                                            prefix-binding
                                            value
                                            body)]
                                        [(ResultAstReduceOp.Err message)
                                          (ResultAstExpr.Err message)])]
                                    [_
                                      (ResultAstExpr.Err
                                        "parse: malformed spmd-scan")])]
                                [_
                                  (ResultAstExpr.Err
                                    "parse: malformed spmd-scan")])]
                            [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
                        [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
                    [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
                [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-scan")])]
    [(reader.SpannedSexprView.Cons _ _ _)
      (ResultAstExpr.Err "parse: malformed spmd-scan")]
    [_ (ResultAstExpr.Err "parse: malformed spmd-scan")]))

(define (parse-ast-spmd-scan-bindings
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [op : ast.AstReduceOp]
  [range-binding : reader.SpannedSexpr]
  [prefix-binding : reader.SpannedSexpr]
  [value : reader.SpannedSexpr]
  [body : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view range-binding)
    [(reader.SpannedSexprView.BracketList items _)
      (parse-ast-spmd-scan-bindings
        dispatch
        pools
        op
        items
        prefix-binding
        value
        body)]
    [(reader.SpannedSexprView.Cons index-node colon-tail _)
      (match (reader.spanned-sexpr-view index-node)
        [(reader.SpannedSexprView.Sym index _)
          (match (reader.spanned-sexpr-view colon-tail)
            [(reader.SpannedSexprView.Cons colon index-ty-tail _)
              (match (reader.spanned-sexpr-view index-ty-tail)
                [(reader.SpannedSexprView.Cons index-ty start-tail _)
                  (match (reader.spanned-sexpr-view start-tail)
                    [(reader.SpannedSexprView.Cons start end-tail _)
                      (match (reader.spanned-sexpr-view end-tail)
                        [(reader.SpannedSexprView.Cons end finish _)
                          (match (reader.spanned-sexpr-view finish)
                            [(reader.SpannedSexprView.Nil _)
                              (if (sexpr-colon?
                                (reader.spanned-sexpr-form colon))
                                (match (parse-ast-type-spanned
                                  dispatch
                                  pools
                                  index-ty)
                                  [(ResultAstType.Ok parsed-index-ty)
                                    (parse-ast-spmd-scan-prefix-binding
                                      dispatch
                                      pools
                                      op
                                      (ci.intern-syntax-id-value index)
                                      parsed-index-ty
                                      start
                                      end
                                      prefix-binding
                                      value
                                      body)]
                                  [(ResultAstType.Err message)
                                    (ResultAstExpr.Err message)])
                                (ResultAstExpr.Err
                                  "parse: expected ':' in spmd-scan range binding"))]
                            [_
                              (ResultAstExpr.Err
                                "parse: malformed spmd-scan range binding")])]
                        [_
                          (ResultAstExpr.Err
                            "parse: malformed spmd-scan range binding")])]
                    [_
                      (ResultAstExpr.Err
                        "parse: malformed spmd-scan range binding")])]
                [_
                  (ResultAstExpr.Err "parse: malformed spmd-scan range binding")])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-scan range binding")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-scan range binding")])]
    [_ (ResultAstExpr.Err "parse: malformed spmd-scan range binding")]))

(define (parse-ast-spmd-scan-prefix-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [op : ast.AstReduceOp]
  [index : i64]
  [index-ty : ast.AstType]
  [start : reader.SpannedSexpr]
  [end : reader.SpannedSexpr]
  [prefix-binding : reader.SpannedSexpr]
  [value : reader.SpannedSexpr]
  [body : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view prefix-binding)
    [(reader.SpannedSexprView.BracketList items _)
      (parse-ast-spmd-scan-prefix-binding
        dispatch
        pools
        op
        index
        index-ty
        start
        end
        items
        value
        body)]
    [(reader.SpannedSexprView.Cons prefix-node colon-tail _)
      (match (reader.spanned-sexpr-view prefix-node)
        [(reader.SpannedSexprView.Sym prefix _)
          (match (reader.spanned-sexpr-view colon-tail)
            [(reader.SpannedSexprView.Cons colon prefix-ty-tail _)
              (match (reader.spanned-sexpr-view prefix-ty-tail)
                [(reader.SpannedSexprView.Cons prefix-ty init-tail _)
                  (match (reader.spanned-sexpr-view init-tail)
                    [(reader.SpannedSexprView.Cons init finish _)
                      (match (reader.spanned-sexpr-view finish)
                        [(reader.SpannedSexprView.Nil _)
                          (if (sexpr-colon? (reader.spanned-sexpr-form colon))
                            (match (parse-ast-type-spanned
                              dispatch
                              pools
                              prefix-ty)
                              [(ResultAstType.Ok parsed-prefix-ty)
                                (match (parse-ast-expr-with-pools
                                  dispatch
                                  pools
                                  start)
                                  [(ResultAstExpr.Ok parsed-start)
                                    (match (parse-ast-expr-with-pools
                                      dispatch
                                      pools
                                      end)
                                      [(ResultAstExpr.Ok parsed-end)
                                        (match (parse-ast-expr-with-pools
                                          dispatch
                                          pools
                                          init)
                                          [(ResultAstExpr.Ok parsed-init)
                                            (match (parse-ast-expr-with-pools
                                              dispatch
                                              pools
                                              value)
                                              [(ResultAstExpr.Ok parsed-value)
                                                (match (parse-ast-expr-with-pools
                                                  dispatch
                                                  pools
                                                  body)
                                                  [(ResultAstExpr.Ok
                                                      parsed-body)
                                                    (ResultAstExpr.Ok
                                                      (ast.ast-expr-spmd-scan-id-with-pools
                                                        pools
                                                        op
                                                        index
                                                        index-ty
                                                        parsed-start
                                                        parsed-end
                                                        (ci.intern-syntax-id-value
                                                          prefix)
                                                        parsed-prefix-ty
                                                        parsed-init
                                                        parsed-value
                                                        parsed-body))]
                                                  [(ResultAstExpr.Err message)
                                                    (ResultAstExpr.Err message)])]
                                              [(ResultAstExpr.Err message)
                                                (ResultAstExpr.Err message)])]
                                          [(ResultAstExpr.Err message)
                                            (ResultAstExpr.Err message)])]
                                      [(ResultAstExpr.Err message)
                                        (ResultAstExpr.Err message)])]
                                  [(ResultAstExpr.Err message)
                                    (ResultAstExpr.Err message)])]
                              [(ResultAstType.Err message)
                                (ResultAstExpr.Err message)])
                            (ResultAstExpr.Err
                              "parse: expected ':' in spmd-scan prefix binding"))]
                        [_
                          (ResultAstExpr.Err
                            "parse: malformed spmd-scan prefix binding")])]
                    [_
                      (ResultAstExpr.Err
                        "parse: malformed spmd-scan prefix binding")])]
                [_
                  (ResultAstExpr.Err
                    "parse: malformed spmd-scan prefix binding")])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-scan prefix binding")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-scan prefix binding")])]
    [_ (ResultAstExpr.Err "parse: malformed spmd-scan prefix binding")]))

(define (parse-ast-spmd-broadcast
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons value-node lane-tail _)
      (match (reader.spanned-sexpr-view lane-tail)
        [(reader.SpannedSexprView.Cons lane-node end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (match (parse-ast-expr-with-pools dispatch pools value-node)
                [(ResultAstExpr.Ok value)
                  (match (parse-ast-expr-with-pools dispatch pools lane-node)
                    [(ResultAstExpr.Ok lane)
                      (ResultAstExpr.Ok
                        (ast.ast-expr-spmd-broadcast-with-pools
                          pools
                          value
                          lane))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-broadcast")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-broadcast")])]
    [_ (ResultAstExpr.Err "parse: malformed spmd-broadcast")]))

(define (parse-ast-spmd-shuffle
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons value-node lane-tail _)
      (match (reader.spanned-sexpr-view lane-tail)
        [(reader.SpannedSexprView.Cons lane-node end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (match (parse-ast-expr-with-pools dispatch pools value-node)
                [(ResultAstExpr.Ok value)
                  (match (parse-ast-expr-with-pools dispatch pools lane-node)
                    [(ResultAstExpr.Ok lane)
                      (ResultAstExpr.Ok
                        (ast.ast-expr-spmd-shuffle-with-pools pools value lane))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_ (ResultAstExpr.Err "parse: malformed spmd-shuffle")])]
        [_ (ResultAstExpr.Err "parse: malformed spmd-shuffle")])]
    [_ (ResultAstExpr.Err "parse: malformed spmd-shuffle")]))

(define (parse-ast-try
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(reader.SpannedSexprView.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools expr)
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok (ast.ast-expr-try-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: try expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: try expects exactly one expression")]))

(define (parse-ast-return
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(reader.SpannedSexprView.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools expr)
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok
                (ast.ast-expr-return-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: return expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: return expects exactly one expression")]))

(define (parse-ast-box-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [is-get : bool]
  [is-take : bool]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(reader.SpannedSexprView.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools expr)
            [(ResultAstExpr.Ok parsed-expr)
              (if is-get
                (ResultAstExpr.Ok
                  (ast.ast-expr-box-get-with-pools pools parsed-expr))
                (if is-take
                  (ResultAstExpr.Ok
                    (ast.ast-expr-box-take-with-pools pools parsed-expr))
                  (ResultAstExpr.Ok
                    (ast.ast-expr-box-with-pools pools parsed-expr))))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_
          (ResultAstExpr.Err
            (if is-get
              "parse: box-get expects exactly one expression"
              (if is-take
                "parse: box-take expects exactly one expression"
                "parse: box expects exactly one expression")))])]
    [_
      (ResultAstExpr.Err
        (if is-get
          "parse: box-get expects exactly one expression"
          (if is-take
            "parse: box-take expects exactly one expression"
            "parse: box expects exactly one expression")))]))

(define (parse-ast-deref
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(reader.SpannedSexprView.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools expr)
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok
                (ast.ast-expr-box-take-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: deref expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: deref expects exactly one expression")]))

;; `(ptr-null : T)` - a colon followed by a pointer type, no leading expression.
;; The parser accepts any type here; the typechecker rejects non-pointer `T`.
(define (parse-ast-ptr-null
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons colon ty-tail _)
      (match (reader.spanned-sexpr-view ty-tail)
        [(reader.SpannedSexprView.Cons ty end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (if (sexpr-colon? (reader.spanned-sexpr-form colon))
                (match (parse-ast-type-spanned dispatch pools ty)
                  [(ResultAstType.Ok parsed-ty)
                    (ResultAstExpr.Ok
                      (ast.ast-node-pool-context-expr-push
                        pools
                        (ast.AstExpr.PtrNull
                          (ast.ast-node-pool-context-type-push pools parsed-ty))))]
                  [(ResultAstType.Err message) (ResultAstExpr.Err message)])
                (ResultAstExpr.Err "parse: expected ':' in ptr-null"))]
            [_
              (ResultAstExpr.Err
                "parse: ptr-null expects (ptr-null : T) with a pointer type T")])]
        [_
          (ResultAstExpr.Err
            "parse: ptr-null expects (ptr-null : T) with a pointer type T")])]
    [_
      (ResultAstExpr.Err
        "parse: ptr-null expects (ptr-null : T) with a pointer type T")]))

;; `(init : T)` carries an explicit target type. Bare `(init)` is contextual
;; and must be checked/lowered in a position with an expected type.
(define (parse-ast-init
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Nil _)
      (ResultAstExpr.Ok (ast.ast-expr-init-contextual-with-pools pools))]
    [(reader.SpannedSexprView.Cons colon ty-tail _)
      (match (reader.spanned-sexpr-view ty-tail)
        [(reader.SpannedSexprView.Cons ty end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (if (sexpr-colon? (reader.spanned-sexpr-form colon))
                (match (parse-ast-type-spanned dispatch pools ty)
                  [(ResultAstType.Ok parsed-ty)
                    (ResultAstExpr.Ok
                      (ast.ast-expr-init-with-pools pools parsed-ty))]
                  [(ResultAstType.Err message) (ResultAstExpr.Err message)])
                (ResultAstExpr.Err "parse: expected ':' in init"))]
            [_ (ResultAstExpr.Err "parse: init expects (init : T)")])]
        [_ (ResultAstExpr.Err "parse: init expects (init : T)")])]
    [_ (ResultAstExpr.Err "parse: init expects (init : T)")]))

;; `(ptr-null? p)` - a single pointer operand.
(define (parse-ast-ptr-null-check
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(reader.SpannedSexprView.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools expr)
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok
                (ast.ast-expr-ptr-null-check-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_
          (ResultAstExpr.Err "parse: ptr-null? expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: ptr-null? expects exactly one expression")]))

(define (parse-ast-ptr-read
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(reader.SpannedSexprView.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools expr)
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok
                (ast.ast-expr-ptr-read-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: ptr-read expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: ptr-read expects exactly one expression")]))

(define (parse-ast-ptr-addr-of
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons place end _)
      (match (reader.spanned-sexpr-view end)
        [(reader.SpannedSexprView.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools place)
            [(ResultAstExpr.Ok parsed-place)
              (ResultAstExpr.Ok
                (ast.ast-expr-ptr-addr-of-id-with-pools pools parsed-place))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_
          (ResultAstExpr.Err
            "parse: ptr-addr-of expects exactly one addressable place")])]
    [_
      (ResultAstExpr.Err
        "parse: ptr-addr-of expects exactly one addressable place")]))

(define (parse-ast-ptr-write
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons ptr value-tail _)
      (match (reader.spanned-sexpr-view value-tail)
        [(reader.SpannedSexprView.Cons value end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (match (parse-ast-expr-with-pools dispatch pools ptr)
                [(ResultAstExpr.Ok parsed-ptr)
                  (match (parse-ast-expr-with-pools dispatch pools value)
                    [(ResultAstExpr.Ok parsed-value)
                      (ResultAstExpr.Ok
                        (ast.ast-expr-ptr-write-with-pools
                          pools
                          parsed-ptr
                          parsed-value))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_
              (ResultAstExpr.Err
                "parse: ptr-write! expects exactly two expressions")])]
        [_
          (ResultAstExpr.Err
            "parse: ptr-write! expects exactly two expressions")])]
    [_ (ResultAstExpr.Err "parse: ptr-write! expects exactly two expressions")]))

(define (parse-ast-ptr-offset
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons ptr offset-tail _)
      (match (reader.spanned-sexpr-view offset-tail)
        [(reader.SpannedSexprView.Cons offset end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (match (parse-ast-expr-with-pools dispatch pools ptr)
                [(ResultAstExpr.Ok parsed-ptr)
                  (match (parse-ast-expr-with-pools dispatch pools offset)
                    [(ResultAstExpr.Ok parsed-offset)
                      (ResultAstExpr.Ok
                        (ast.ast-expr-ptr-offset-with-pools
                          pools
                          parsed-ptr
                          parsed-offset))]
                    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
            [_
              (ResultAstExpr.Err
                "parse: ptr-offset expects exactly two expressions")])]
        [_
          (ResultAstExpr.Err
            "parse: ptr-offset expects exactly two expressions")])]
    [_ (ResultAstExpr.Err "parse: ptr-offset expects exactly two expressions")]))

(define (parse-ast-ptr-cast-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [is-int-to-ptr : bool]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr colon-tail _)
      (match (reader.spanned-sexpr-view colon-tail)
        [(reader.SpannedSexprView.Cons colon ty-tail _)
          (match (reader.spanned-sexpr-view ty-tail)
            [(reader.SpannedSexprView.Cons ty end _)
              (match (reader.spanned-sexpr-view end)
                [(reader.SpannedSexprView.Nil _)
                  (if (sexpr-colon? (reader.spanned-sexpr-form colon))
                    (match (parse-ast-expr-with-pools dispatch pools expr)
                      [(ResultAstExpr.Ok parsed-expr)
                        (match (parse-ast-type-spanned dispatch pools ty)
                          [(ResultAstType.Ok parsed-ty)
                            (if is-int-to-ptr
                              (ResultAstExpr.Ok
                                (ast.ast-expr-int-to-ptr-with-pools
                                  pools
                                  parsed-expr
                                  parsed-ty))
                              (ResultAstExpr.Ok
                                (ast.ast-expr-ptr-cast-with-pools
                                  pools
                                  parsed-expr
                                  parsed-ty)))]
                          [(ResultAstType.Err message)
                            (ResultAstExpr.Err message)])]
                      [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])
                    (ResultAstExpr.Err "parse: expected ':' in pointer cast"))]
                [_
                  (ResultAstExpr.Err
                    "parse: pointer cast expects (form expr : pointer-type)")])]
            [_
              (ResultAstExpr.Err
                "parse: pointer cast expects (form expr : pointer-type)")])]
        [_
          (ResultAstExpr.Err
            "parse: pointer cast expects (form expr : pointer-type)")])]
    [_
      (ResultAstExpr.Err
        "parse: pointer cast expects (form expr : pointer-type)")]))

(define (parse-ast-ptr-to-int
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(reader.SpannedSexprView.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools expr)
            [(ResultAstExpr.Ok parsed-expr)
              (ResultAstExpr.Ok
                (ast.ast-expr-ptr-to-int-with-pools pools parsed-expr))]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
        [_ (ResultAstExpr.Err "parse: ptr->int expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: ptr->int expects exactly one expression")]))

(define (parse-ast-one-expr
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [name : String]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(reader.SpannedSexprView.Nil _)
          (parse-ast-expr-with-pools dispatch pools expr)]
        [_
          (ResultAstExpr.Err
            (str_cat.str-cat "parse: " name " expects exactly one expression"))])]
    [_
      (ResultAstExpr.Err
        (str_cat.str-cat "parse: " name " expects exactly one expression"))]))

(define (parse-ast-two-exprs
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [name : String]) : ResultAstExprPair
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons first second-tail _)
      (match (reader.spanned-sexpr-view second-tail)
        [(reader.SpannedSexprView.Cons second end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (match (parse-ast-expr-with-pools dispatch pools first)
                [(ResultAstExpr.Ok parsed-first)
                  (match (parse-ast-expr-with-pools dispatch pools second)
                    [(ResultAstExpr.Ok parsed-second)
                      (ResultAstExprPair.Ok
                        (AstExprPair parsed-first parsed-second))]
                    [(ResultAstExpr.Err message)
                      (ResultAstExprPair.Err message)])]
                [(ResultAstExpr.Err message) (ResultAstExprPair.Err message)])]
            [_
              (ResultAstExprPair.Err
                (str_cat.str-cat
                  "parse: "
                  name
                  " expects exactly two expressions"))])]
        [_
          (ResultAstExprPair.Err
            (str_cat.str-cat "parse: " name " expects exactly two expressions"))])]
    [_
      (ResultAstExprPair.Err
        (str_cat.str-cat "parse: " name " expects exactly two expressions"))]))

(define (parse-ast-string-data
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-one-expr dispatch pools rest "string-data")
    [(ResultAstExpr.Ok expr)
      (ResultAstExpr.Ok (ast.ast-expr-string-data-with-pools pools expr))]
    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-string-from-bytes
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-two-exprs dispatch pools rest "string-from-bytes")
    [(ResultAstExprPair.Ok pair)
      (ResultAstExpr.Ok
        (ast.ast-expr-string-from-bytes-with-pools pools pair.first pair.second))]
    [(ResultAstExprPair.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-array-data
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-one-expr dispatch pools rest "__tl_array-data")
    [(ResultAstExpr.Ok expr)
      (ResultAstExpr.Ok (ast.ast-expr-array-data-with-pools pools expr))]
    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-no-arg-low-level
  [rest : reader.SpannedSexpr]
  [name : String]
  [expr : i64]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Nil _) (ResultAstExpr.Ok expr)]
    [_
      (ResultAstExpr.Err
        (str_cat.str-cat "parse: " name " expects no arguments"))]))

(define (parse-ast-cpuid-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [tag : i64]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-two-exprs dispatch pools rest "cpuid")
    [(ResultAstExprPair.Ok pair)
      (let
        [leaf : i64 pair.first]
        [subleaf : i64 pair.second]
        (cond
          [(= tag (compiler-parse-tag-expr-cpuid-eax))
            (ResultAstExpr.Ok
              (ast.ast-expr-cpuid-eax-with-pools pools leaf subleaf))]
          [(= tag (compiler-parse-tag-expr-cpuid-ebx))
            (ResultAstExpr.Ok
              (ast.ast-expr-cpuid-ebx-with-pools pools leaf subleaf))]
          [(= tag (compiler-parse-tag-expr-cpuid-ecx))
            (ResultAstExpr.Ok
              (ast.ast-expr-cpuid-ecx-with-pools pools leaf subleaf))]
          [else
            (ResultAstExpr.Ok
              (ast.ast-expr-cpuid-edx-with-pools pools leaf subleaf))]))]
    [(ResultAstExprPair.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-xgetbv
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-one-expr dispatch pools rest "xgetbv")
    [(ResultAstExpr.Ok expr)
      (ResultAstExpr.Ok (ast.ast-expr-xgetbv-with-pools pools expr))]
    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-syscall-count [args : ast.AstExprList]) : i64
  args.len)

;; `(syscall number a0 .. a5)`: the syscall number followed by up to six
;; arguments (1 to 7 operands total). Typechecking requires an enclosing
;; `(unsafe ...)` context before this lowers to a raw `syscall` instruction.
(define (parse-ast-syscall
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools rest)
    [(ResultAstExprList.Ok args)
      (let
        [count : i64 (parse-ast-syscall-count args)]
        (if (< count 1)
          (ResultAstExpr.Err "parse: syscall requires a syscall number")
          (if (> count 7)
            (ResultAstExpr.Err
              "parse: syscall takes at most 7 operands (number plus six arguments)")
            (ResultAstExpr.Ok (ast.ast-expr-syscall-with-pools pools args)))))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-with-region
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Nil _)
      (ResultAstExpr.Err
        "parse: with-arena requires a region name before its body")]
    [(reader.SpannedSexprView.Cons _ _ _)
      (match (reader.spanned-sexpr-view rest)
        [(reader.SpannedSexprView.Cons region-node body _)
          (match (reader.spanned-sexpr-view region-node)
            [(reader.SpannedSexprView.Sym region _)
              (match (reader.spanned-sexpr-view body)
                [(reader.SpannedSexprView.Nil _)
                  (ResultAstExpr.Err
                    (str_cat.str-cat
                      "parse: with-arena '"
                      (compiler-parse-dispatch-syntax-id-text dispatch region)
                      "' requires a non-empty body"))]
                [_
                  (match (parse-ast-expr-list dispatch pools body)
                    [(ResultAstExprList.Ok exprs)
                      (ResultAstExpr.Ok
                        (ast.ast-node-pool-context-expr-push
                          pools
                          (ast.AstExpr.WithRegion
                            (ci.intern-syntax-id-value region)
                            exprs)))]
                    [(ResultAstExprList.Err message)
                      (ResultAstExpr.Err message)])])]
            [_
              (ResultAstExpr.Err
                "parse: with-arena region name must be an identifier")])]
        [_ (ResultAstExpr.Err "parse: malformed with-arena")])]
    [_ (ResultAstExpr.Err "parse: malformed with-arena")]))

(define (parse-ast-with-escape
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Nil _)
      (ResultAstExpr.Err
        "parse: with-escape requires a scratch arena before its body")]
    [(reader.SpannedSexprView.Cons scratch body _)
      (match (reader.spanned-sexpr-view body)
        [(reader.SpannedSexprView.Nil _)
          (ResultAstExpr.Err "parse: with-escape requires a non-empty body")]
        [_
          (match (parse-ast-expr-with-pools dispatch pools scratch)
            [(ResultAstExpr.Ok parsed-scratch)
              (match (parse-ast-expr-list dispatch pools body)
                [(ResultAstExprList.Ok exprs)
                  (ResultAstExpr.Ok
                    (ast.ast-expr-with-escape-with-pools
                      pools
                      parsed-scratch
                      exprs))]
                [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])])]
    [_ (ResultAstExpr.Err "parse: malformed with-escape")]))

(define (parse-ast-with-scratch
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Nil _)
      (ResultAstExpr.Err "parse: with-scratch requires a non-empty body")]
    [(reader.SpannedSexprView.Cons _ _ _)
      (match (parse-ast-expr-list dispatch pools rest)
        [(ResultAstExprList.Ok exprs)
          (ResultAstExpr.Ok (ast.ast-expr-with-scratch-with-pools pools exprs))]
        [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]
    [_ (ResultAstExpr.Err "parse: malformed with-scratch")]))

(define (parse-ast-in-arena
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Nil _)
      (ResultAstExpr.Err "parse: in-arena requires an arena before its body")]
    [(reader.SpannedSexprView.Cons arena body _)
      (match (reader.spanned-sexpr-view body)
        [(reader.SpannedSexprView.Nil _)
          (ResultAstExpr.Err "parse: in-arena requires a non-empty body")]
        [_
          (match (parse-ast-expr-with-pools dispatch pools arena)
            [(ResultAstExpr.Ok parsed-arena)
              (match (parse-ast-expr-list dispatch pools body)
                [(ResultAstExprList.Ok exprs)
                  (ResultAstExpr.Ok
                    (ast.ast-expr-in-arena-with-pools pools parsed-arena exprs))]
                [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]
            [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])])]
    [_ (ResultAstExpr.Err "parse: malformed in-arena")]))

(define (parse-ast-resource-binding-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [items : reader.SpannedSexpr]) : ResultAstResourceBinding
  (match (reader.spanned-sexpr-view items)
    [(reader.SpannedSexprView.Cons _ _ _)
      (match (reader.spanned-sexpr-view items)
        [(reader.SpannedSexprView.Cons name-node rest _)
          (match (reader.spanned-sexpr-view name-node)
            [(reader.SpannedSexprView.Sym name _)
              (match (reader.spanned-sexpr-view rest)
                [(reader.SpannedSexprView.Nil _)
                  (ResultAstResourceBinding.Err
                    "parse: with binding is missing initializer")]
                [(reader.SpannedSexprView.Cons init tail _)
                  (match (reader.spanned-sexpr-view tail)
                    [(reader.SpannedSexprView.Nil _)
                      (ResultAstResourceBinding.Err
                        "parse: with binding is missing cleanup function")]
                    [(reader.SpannedSexprView.Cons cleanup extra _)
                      (match (reader.spanned-sexpr-view extra)
                        [(reader.SpannedSexprView.Nil _)
                          (match (parse-ast-expr-with-pools dispatch pools init)
                            [(ResultAstExpr.Ok parsed-init)
                              (match (parse-ast-expr-with-pools
                                dispatch
                                pools
                                cleanup)
                                [(ResultAstExpr.Ok parsed-cleanup)
                                  (ResultAstResourceBinding.Ok
                                    (ast.ast-resource-binding-id
                                      (ci.intern-syntax-id-value name)
                                      parsed-init
                                      parsed-cleanup))]
                                [(ResultAstExpr.Err message)
                                  (ResultAstResourceBinding.Err message)])]
                            [(ResultAstExpr.Err message)
                              (ResultAstResourceBinding.Err message)])]
                        [_
                          (ResultAstResourceBinding.Err
                            "parse: with binding has too many fields")])]
                    [_
                      (ResultAstResourceBinding.Err
                        "parse: malformed with binding")])]
                [_
                  (ResultAstResourceBinding.Err "parse: malformed with binding")])]
            [_
              (ResultAstResourceBinding.Err
                "parse: with binding name must be an identifier")])]
        [_ (ResultAstResourceBinding.Err "parse: malformed with binding")])]
    [_ (ResultAstResourceBinding.Err "parse: malformed with binding")]))

(define (parse-ast-resource-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [binding : reader.SpannedSexpr]) : ResultAstResourceBinding
  (match (reader.spanned-sexpr-view binding)
    [(reader.SpannedSexprView.BracketList items _)
      (parse-ast-resource-binding-items dispatch pools items)]
    [_
      (ResultAstResourceBinding.Err
        "parse: with binding must use bracket syntax")]))

(define (parse-ast-resource-binding-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [bindings : reader.SpannedSexpr]
  [out : (&mut out ast.AstResourceBindingList)]) : ResultAstResourceBindingListBuild
  (match (reader.spanned-sexpr-view bindings)
    [(reader.SpannedSexprView.Nil _) (ResultAstResourceBindingListBuild.Ok)]
    [(reader.SpannedSexprView.Cons head rest _)
      (match (parse-ast-resource-binding dispatch pools head)
        [(ResultAstResourceBinding.Ok parsed-head)
          (begin
            (ast.ast-resource-binding-list-push out parsed-head)
            (parse-ast-resource-binding-list-into dispatch pools rest out))]
        [(ResultAstResourceBinding.Err message)
          (ResultAstResourceBindingListBuild.Err message)])]
    [_
      (ResultAstResourceBindingListBuild.Err
        "parse: malformed with binding list")]))

(define (parse-ast-resource-binding-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [bindings : reader.SpannedSexpr]) : ResultAstResourceBindingList
  (let
    [out : ast.AstResourceBindingList (ast.ast-resource-binding-list-new)]
    (match (parse-ast-resource-binding-list-into
      dispatch
      pools
      bindings
      (&mut out))
      [(ResultAstResourceBindingListBuild.Ok)
        (ResultAstResourceBindingList.Ok out)]
      [(ResultAstResourceBindingListBuild.Err message)
        (ResultAstResourceBindingList.Err message)])))

(define (parse-ast-with-resource
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Nil _)
      (ResultAstExpr.Err "parse: with requires a binding list before its body")]
    [(reader.SpannedSexprView.Cons bindings body _)
      (match (reader.spanned-sexpr-view bindings)
        [(reader.SpannedSexprView.Nil _)
          (ResultAstExpr.Err "parse: with requires a non-empty binding list")]
        [(reader.SpannedSexprView.Cons _ _ _)
          (match (reader.spanned-sexpr-view body)
            [(reader.SpannedSexprView.Nil _)
              (ResultAstExpr.Err "parse: with requires a non-empty body")]
            [_
              (match (parse-ast-resource-binding-list dispatch pools bindings)
                [(ResultAstResourceBindingList.Ok parsed-bindings)
                  (match (parse-ast-expr-list dispatch pools body)
                    [(ResultAstExprList.Ok parsed-body)
                      (ResultAstExpr.Ok
                        (ast.ast-node-pool-context-expr-push
                          pools
                          (ast.AstExpr.WithResource
                            (box
                              (ast.AstWithResource.WithResource
                                parsed-bindings
                                parsed-body)))))]
                    [(ResultAstExprList.Err message)
                      (ResultAstExpr.Err message)])]
                [(ResultAstResourceBindingList.Err message)
                  (ResultAstExpr.Err message)])])]
        [_ (ResultAstExpr.Err "parse: malformed with binding list")])]
    [_ (ResultAstExpr.Err "parse: malformed with")]))

(define (parse-ast-match-arm
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstMatchArm
  (match (reader.spanned-sexpr-view s)
    [(reader.SpannedSexprView.BracketList items _)
      (parse-ast-match-arm dispatch pools items)]
    [(reader.SpannedSexprView.Cons pattern body-tail _)
      (match (reader.spanned-sexpr-view body-tail)
        [(reader.SpannedSexprView.Cons body end _)
          (match (reader.spanned-sexpr-view end)
            [(reader.SpannedSexprView.Nil _)
              (match (parse-ast-pattern
                dispatch
                pools
                (reader.spanned-sexpr-form pattern))
                [(ResultAstPattern.Ok parsed-pattern)
                  (begin
                    (compiler-parse-semantic-pattern-origins! dispatch pattern)
                    (match (parse-ast-expr-with-pools dispatch pools body)
                      [(ResultAstExpr.Ok parsed-body)
                        (ResultAstMatchArm.Ok
                          (ast.ast-match-arm
                            parsed-pattern
                            (ast.ast-expr-spanned-with-pools
                              pools
                              parsed-body
                              (ast-source-span-from-source-span
                                (reader.spanned-sexpr-span pattern)))))]
                      [(ResultAstExpr.Err message)
                        (ResultAstMatchArm.Err message)]))]
                [(ResultAstPattern.Err message) (ResultAstMatchArm.Err message)])]
            [_ (ResultAstMatchArm.Err "parse: malformed match arm")])]
        [_ (ResultAstMatchArm.Err "parse: malformed match arm")])]
    [_ (ResultAstMatchArm.Err "parse: malformed match arm")]))

(define (parse-ast-match-arm-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [out : (&mut out ast.AstMatchArmList)]) : ResultAstMatchArmListBuild
  (match (reader.spanned-sexpr-view s)
    [(reader.SpannedSexprView.Nil _) (ResultAstMatchArmListBuild.Ok)]
    [(reader.SpannedSexprView.Cons head tail _)
      (match (parse-ast-match-arm dispatch pools head)
        [(ResultAstMatchArm.Ok parsed-head)
          (begin
            (ast.ast-match-arm-list-push out parsed-head)
            (parse-ast-match-arm-list-into dispatch pools tail out))]
        [(ResultAstMatchArm.Err message)
          (ResultAstMatchArmListBuild.Err message)])]
    [_ (ResultAstMatchArmListBuild.Err "parse: malformed match arm list")]))

(define (parse-ast-match-arm-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstMatchArmList
  (let
    [out : ast.AstMatchArmList (ast.ast-match-arm-list-new)]
    (match (parse-ast-match-arm-list-into dispatch pools s (&mut out))
      [(ResultAstMatchArmListBuild.Ok) (ResultAstMatchArmList.Ok out)]
      [(ResultAstMatchArmListBuild.Err message)
        (ResultAstMatchArmList.Err message)])))

(define (parse-ast-match
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons scrutinee arms _)
      (match (parse-ast-expr-with-pools dispatch pools scrutinee)
        [(ResultAstExpr.Ok parsed-scrutinee)
          (match (parse-ast-match-arm-list dispatch pools arms)
            [(ResultAstMatchArmList.Ok parsed-arms)
              (ResultAstExpr.Ok
                (ast.ast-expr-match-with-pools
                  pools
                  parsed-scrutinee
                  parsed-arms))]
            [(ResultAstMatchArmList.Err message) (ResultAstExpr.Err message)])]
        [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])]
    [_ (ResultAstExpr.Err "parse: malformed match")]))

(define (parse-ast-foreach-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [binding : reader.SpannedSexpr]
  [body : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view binding)
    [(reader.SpannedSexprView.BracketList items _)
      (parse-ast-foreach-binding dispatch pools items body)]
    [(reader.SpannedSexprView.Cons index-node colon-tail _)
      (match (reader.spanned-sexpr-view index-node)
        [(reader.SpannedSexprView.Sym index _)
          (match (reader.spanned-sexpr-view colon-tail)
            [(reader.SpannedSexprView.Cons colon index-ty-tail _)
              (match (reader.spanned-sexpr-view index-ty-tail)
                [(reader.SpannedSexprView.Cons index-ty start-tail _)
                  (match (reader.spanned-sexpr-view start-tail)
                    [(reader.SpannedSexprView.Cons start end-tail _)
                      (match (reader.spanned-sexpr-view end-tail)
                        [(reader.SpannedSexprView.Cons end finish _)
                          (match (reader.spanned-sexpr-view finish)
                            [(reader.SpannedSexprView.Nil _)
                              (if (sexpr-colon?
                                (reader.spanned-sexpr-form colon))
                                (match (parse-ast-type-spanned
                                  dispatch
                                  pools
                                  index-ty)
                                  [(ResultAstType.Ok parsed-index-ty)
                                    (match (parse-ast-expr-with-pools
                                      dispatch
                                      pools
                                      start)
                                      [(ResultAstExpr.Ok parsed-start)
                                        (match (parse-ast-expr-with-pools
                                          dispatch
                                          pools
                                          end)
                                          [(ResultAstExpr.Ok parsed-end)
                                            (match (parse-ast-expr-with-pools
                                              dispatch
                                              pools
                                              body)
                                              [(ResultAstExpr.Ok parsed-body)
                                                (ResultAstExpr.Ok
                                                  (ast.ast-expr-foreach-id-with-pools
                                                    pools
                                                    (ci.intern-syntax-id-value
                                                      index)
                                                    parsed-index-ty
                                                    parsed-start
                                                    parsed-end
                                                    parsed-body))]
                                              [(ResultAstExpr.Err message)
                                                (ResultAstExpr.Err message)])]
                                          [(ResultAstExpr.Err message)
                                            (ResultAstExpr.Err message)])]
                                      [(ResultAstExpr.Err message)
                                        (ResultAstExpr.Err message)])]
                                  [(ResultAstType.Err message)
                                    (ResultAstExpr.Err message)])
                                (ResultAstExpr.Err
                                  "parse: expected ':' in foreach"))]
                            [_
                              (ResultAstExpr.Err
                                "parse: malformed foreach binding")])]
                        [_
                          (ResultAstExpr.Err "parse: malformed foreach binding")])]
                    [_ (ResultAstExpr.Err "parse: malformed foreach binding")])]
                [_ (ResultAstExpr.Err "parse: malformed foreach binding")])]
            [_ (ResultAstExpr.Err "parse: malformed foreach binding")])]
        [_ (ResultAstExpr.Err "parse: malformed foreach binding")])]
    [_ (ResultAstExpr.Err "parse: malformed foreach binding")]))

(define (parse-ast-foreach
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons binding-list body-tail _)
      (match (reader.spanned-sexpr-view binding-list)
        [(reader.SpannedSexprView.Cons binding binding-end _)
          (match (reader.spanned-sexpr-view binding-end)
            [(reader.SpannedSexprView.Nil _)
              (match (reader.spanned-sexpr-view body-tail)
                [(reader.SpannedSexprView.Cons body end _)
                  (match (reader.spanned-sexpr-view end)
                    [(reader.SpannedSexprView.Nil _)
                      (parse-ast-foreach-binding dispatch pools binding body)]
                    [_ (ResultAstExpr.Err "parse: malformed foreach")])]
                [_ (ResultAstExpr.Err "parse: malformed foreach")])]
            [_ (ResultAstExpr.Err "parse: malformed foreach")])]
        [_ (ResultAstExpr.Err "parse: malformed foreach")])]
    [_ (ResultAstExpr.Err "parse: malformed foreach")]))

(define (parse-ast-call
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [head : reader.SpannedSexpr]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-with-pools dispatch pools head)
    [(ResultAstExpr.Ok parsed-head)
      (match (parse-ast-call-arg-list dispatch pools rest)
        [(ResultAstExprList.Ok parsed-args)
          (ResultAstExpr.Ok
            (ast.ast-expr-call-with-pools pools parsed-head parsed-args))]
        [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]
    [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-begin
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools rest)
    [(ResultAstExprList.Ok exprs)
      (ResultAstExpr.Ok
        (ast.ast-node-pool-context-expr-push pools (ast.AstExpr.Begin exprs)))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

;; `(unsafe expr+)` parses like `begin` but requires a non-empty body. It has
;; the same behavior as `begin`; it marks an unsafe context for later raw-pointer
;; ops.
(define (parse-ast-unsafe
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Nil _)
      (ResultAstExpr.Err "parse: unsafe requires a non-empty body")]
    [_
      (match (parse-ast-expr-list dispatch pools rest)
        [(ResultAstExprList.Ok exprs)
          (ResultAstExpr.Ok
            (ast.ast-node-pool-context-expr-push
              pools
              (ast.AstExpr.Unsafe exprs)))]
        [(ResultAstExprList.Err message) (ResultAstExpr.Err message)])]))

(define (parse-ast-tuple
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools rest)
    [(ResultAstExprList.Ok exprs)
      (ResultAstExpr.Ok
        (ast.ast-node-pool-context-expr-push pools (ast.AstExpr.Tuple exprs)))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-array
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-expr-list dispatch pools rest)
    [(ResultAstExprList.Ok exprs)
      (ResultAstExpr.Ok
        (ast.ast-node-pool-context-expr-push pools (ast.AstExpr.Array exprs)))]
    [(ResultAstExprList.Err message) (ResultAstExpr.Err message)]))

(define (parse-ast-quote-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [tag : i64]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(reader.SpannedSexprView.Nil _)
          (let
            [saved-depth : i64 compiler-parse-quote-depth]
            [saved-semantic-depth : i64 compiler-parse-semantic-quote-depth]
            [result : ResultAstExpr
              (begin
                (set! compiler-parse-quote-depth (+ saved-depth 1))
                (set!
                  compiler-parse-semantic-quote-depth
                  (if (or
                    (= tag (compiler-parse-tag-expr-unquote))
                    (= tag (compiler-parse-tag-expr-unquote-splicing)))
                    (if (> saved-semantic-depth 0)
                      (- saved-semantic-depth 1)
                      0)
                    (+ saved-semantic-depth 1)))
                (match (parse-ast-expr-with-pools dispatch pools expr)
                  [(ResultAstExpr.Ok parsed)
                    (cond
                      [(= tag (compiler-parse-tag-expr-quote))
                        (ResultAstExpr.Ok
                          (ast.ast-expr-quote-with-pools pools parsed))]
                      [(= tag (compiler-parse-tag-expr-quasiquote))
                        (ResultAstExpr.Ok
                          (ast.ast-expr-quasiquote-with-pools pools parsed))]
                      [(= tag (compiler-parse-tag-expr-unquote))
                        (ResultAstExpr.Ok
                          (ast.ast-expr-unquote-with-pools pools parsed))]
                      [else
                        (ResultAstExpr.Ok
                          (ast.ast-expr-unquote-splicing-with-pools
                            pools
                            parsed))])]
                  [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))]
            (begin
              (set! compiler-parse-quote-depth saved-depth)
              (set! compiler-parse-semantic-quote-depth saved-semantic-depth)
              result))]
        [_
          (ResultAstExpr.Err "parse: quote form expects exactly one expression")])]
    [_ (ResultAstExpr.Err "parse: quote form expects exactly one expression")]))

(define (parse-ast-list-expr-tag
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [tag : i64]
  [head : reader.SpannedSexpr]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (cond
    [(= tag (compiler-parse-tag-expr-if)) (parse-ast-if dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-let)) (parse-ast-let dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-lambda))
      (parse-ast-lambda dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-while))
      (parse-ast-while dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-begin))
      (parse-ast-begin dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-unsafe))
      (parse-ast-unsafe dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-set)) (parse-ast-set dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-replace))
      (parse-ast-replace dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-ann))
      (parse-ast-ann-like dispatch pools false rest)]
    [(= tag (compiler-parse-tag-expr-cast))
      (parse-ast-ann-like dispatch pools true rest)]
    [(= tag (compiler-parse-tag-expr-tuple))
      (parse-ast-tuple dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-tuple-ref))
      (parse-ast-tuple-ref dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-array))
      (parse-ast-array dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-make-array))
      (parse-ast-make-array dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-fixed-make-array))
      (parse-ast-fixed-make-array dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-array-ref))
      (parse-ast-array-ref-like dispatch pools false rest)]
    [(= tag (compiler-parse-tag-expr-array-set))
      (parse-ast-array-set dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-array-push))
      (parse-ast-array-push dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-array-take))
      (parse-ast-private-array-take dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-fixed-array-take))
      (parse-ast-fixed-array-take dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-for-owned-state))
      (parse-ast-for-owned-state dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-for-owned-step))
      (parse-ast-for-owned-step dispatch pools false rest)]
    [(= tag (compiler-parse-tag-expr-for-owned-step-typed))
      (parse-ast-for-owned-step dispatch pools true rest)]
    [(= tag (compiler-parse-tag-expr-match))
      (parse-ast-match dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-foreach))
      (parse-ast-foreach dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-spmd-reduce))
      (parse-ast-spmd-reduce dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-spmd-scan))
      (parse-ast-spmd-scan dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-spmd-broadcast))
      (parse-ast-spmd-broadcast dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-spmd-shuffle))
      (parse-ast-spmd-shuffle dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-spmd-program-index))
      (parse-ast-no-arg-low-level
        rest
        "program-index"
        (ast.ast-expr-spmd-program-index-with-pools pools))]
    [(= tag (compiler-parse-tag-expr-spmd-program-count))
      (parse-ast-no-arg-low-level
        rest
        "program-count"
        (ast.ast-expr-spmd-program-count-with-pools pools))]
    [(= tag (compiler-parse-tag-expr-retired-struct-get))
      (if (> compiler-parse-quote-depth 0)
        (parse-ast-struct-get dispatch pools rest)
        (ResultAstExpr.Err
          "parse: struct-get was removed; use dotted field projection value.field"))]
    [(= tag (compiler-parse-tag-expr-retired-array-set))
      (if (> compiler-parse-quote-depth 0)
        (parse-ast-array-set dispatch pools rest)
        (ResultAstExpr.Err
          "parse: array-set! was removed; use (set! (array-ref array index) value)"))]
    [(= tag (compiler-parse-tag-expr-retired-box-get))
      (if (> compiler-parse-quote-depth 0)
        (parse-ast-box-like dispatch pools rest true false)
        (ResultAstExpr.Err "parse: box-get was removed; use (deref box)"))]
    [(= tag (compiler-parse-tag-expr-retired-box-take))
      (if (> compiler-parse-quote-depth 0)
        (parse-ast-box-like dispatch pools rest false true)
        (ResultAstExpr.Err "parse: box-take was removed; use (deref box)"))]
    [(= tag (compiler-parse-tag-expr-retired-struct-set))
      (ResultAstExpr.Err
        "parse: struct-set/struct-set! was removed; use (set! value.field replacement)")]
    [(= tag (compiler-parse-tag-expr-retired-array-push))
      (ResultAstExpr.Err
        "parse: bare array-push! was removed; use a generated vector mutator")]
    [(= tag (compiler-parse-tag-expr-retired-array-data))
      (ResultAstExpr.Err
        "parse: array-data was removed; raw dynamic-buffer storage is compiler-private")]
    [(= tag (compiler-parse-tag-expr-struct-get))
      (parse-ast-struct-get dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-comptime))
      (parse-ast-comptime dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-type-literal))
      (parse-ast-type-literal dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-with-region))
      (parse-ast-with-region dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-with-escape))
      (parse-ast-with-escape dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-with-scratch))
      (parse-ast-with-scratch dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-in-arena))
      (parse-ast-in-arena dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-with-resource))
      (parse-ast-with-resource dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-quote))
      (parse-ast-quote-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-quasiquote))
      (parse-ast-quote-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-unquote))
      (parse-ast-quote-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-unquote-splicing))
      (parse-ast-quote-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-try)) (parse-ast-try dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-return))
      (parse-ast-return dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-break))
      (parse-ast-no-arg-low-level
        rest
        "break"
        (ast.ast-expr-break-with-pools pools))]
    [(= tag (compiler-parse-tag-expr-continue))
      (parse-ast-no-arg-low-level
        rest
        "continue"
        (ast.ast-expr-continue-with-pools pools))]
    [(= tag (compiler-parse-tag-expr-box))
      (parse-ast-box-like dispatch pools rest false false)]
    [(= tag (compiler-parse-tag-expr-box-get))
      (parse-ast-box-like dispatch pools rest true false)]
    [(= tag (compiler-parse-tag-expr-box-take))
      (parse-ast-box-like dispatch pools rest false true)]
    [(= tag (compiler-parse-tag-expr-deref))
      (parse-ast-deref dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-string-data))
      (parse-ast-string-data dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-string-from-bytes))
      (parse-ast-string-from-bytes dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-array-data))
      (parse-ast-array-data dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-program-argc))
      (parse-ast-no-arg-low-level
        rest
        "program-argc"
        (ast.ast-node-pool-context-expr-push pools (ast.AstExpr.ProgramArgc)))]
    [(= tag (compiler-parse-tag-expr-program-argv))
      (parse-ast-no-arg-low-level
        rest
        "program-argv"
        (ast.ast-node-pool-context-expr-push pools (ast.AstExpr.ProgramArgv)))]
    [(= tag (compiler-parse-tag-expr-program-envp))
      (parse-ast-no-arg-low-level
        rest
        "program-envp"
        (ast.ast-node-pool-context-expr-push pools (ast.AstExpr.ProgramEnvp)))]
    [(= tag (compiler-parse-tag-expr-cpuid-eax))
      (parse-ast-cpuid-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-cpuid-ebx))
      (parse-ast-cpuid-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-cpuid-ecx))
      (parse-ast-cpuid-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-cpuid-edx))
      (parse-ast-cpuid-like dispatch pools tag rest)]
    [(= tag (compiler-parse-tag-expr-xgetbv))
      (parse-ast-xgetbv dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-syscall))
      (parse-ast-syscall dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-init))
      (parse-ast-init dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-ptr-null))
      (parse-ast-ptr-null dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-ptr-null-check))
      (parse-ast-ptr-null-check dispatch pools rest)]
    [else (parse-ast-call dispatch pools head rest)]))

(define (parse-ast-list-expr
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [head : reader.SpannedSexpr]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view head)
    [(reader.SpannedSexprView.Sym op _)
      (cond
        [(= (ci.intern-syntax-id-value op) (cbi.compiler-builtin-ctfe-ref 213))
          (parse-ast-internal-binary-data dispatch pools rest)]
        [(=
            (compiler-parse-dispatch-tag
              dispatch
              (ci.intern-syntax-id-value op))
            (compiler-parse-tag-expr-init))
          (match (reader.spanned-sexpr-view rest)
            [(reader.SpannedSexprView.Cons first _ _)
              (if (sexpr-colon? (reader.spanned-sexpr-form first))
                (parse-ast-init dispatch pools rest)
                (parse-ast-call dispatch pools head rest))]
            [(reader.SpannedSexprView.Nil _)
              (parse-ast-init dispatch pools rest)]
            [_ (parse-ast-call dispatch pools head rest)])]
        [else
          (let
            [tag : i64
              (compiler-parse-dispatch-tag
                dispatch
                (ci.intern-syntax-id-value op))]
            (cond
              [(= tag (compiler-parse-tag-expr-ptr-addr-of))
                (parse-ast-ptr-addr-of dispatch pools rest)]
              [(= tag (compiler-parse-tag-expr-ptr-read))
                (parse-ast-ptr-read dispatch pools rest)]
              [(= tag (compiler-parse-tag-expr-ptr-write))
                (parse-ast-ptr-write dispatch pools rest)]
              [(= tag (compiler-parse-tag-expr-ptr-offset))
                (parse-ast-ptr-offset dispatch pools rest)]
              [(= tag (compiler-parse-tag-expr-ptr-cast))
                (parse-ast-ptr-cast-like dispatch pools false rest)]
              [(= tag (compiler-parse-tag-expr-ptr-to-int))
                (parse-ast-ptr-to-int dispatch pools rest)]
              [(= tag (compiler-parse-tag-expr-int-to-ptr))
                (parse-ast-ptr-cast-like dispatch pools true rest)]
              [(ast-unop-tag? tag)
                (parse-ast-unary dispatch pools (ast-unop-from-tag tag) rest)]
              [(ast-binop-tag? tag)
                (if (ast-left-fold-binop-tag? tag)
                  (parse-ast-binary-left-fold
                    dispatch
                    pools
                    (ast-binop-from-tag tag)
                    rest)
                  (parse-ast-binary
                    dispatch
                    pools
                    (ast-binop-from-tag tag)
                    rest))]
              [(= tag (compiler-parse-tag-ty-ref))
                (parse-ast-borrow dispatch pools false rest)]
              [(= tag (compiler-parse-tag-ty-mut-ref))
                (parse-ast-borrow dispatch pools true rest)]
              [else
                (if (parse-ast-removed-declaration-name?
                  dispatch
                  (ci.intern-syntax-id-value op))
                  (ResultAstExpr.Err (parse-ast-removed-declaration-message))
                  (parse-ast-list-expr-tag dispatch pools tag head rest))]))])]
    [_ (parse-ast-call dispatch pools head rest)]))

(define (parse-ast-expr-with-pools
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [result : ResultAstExpr
      (match (reader.spanned-sexpr-view s)
        [(reader.SpannedSexprView.Int n text _)
          (ResultAstExpr.Ok
            (ast-expr-wrap-span
              pools
              (ast.ast-node-pool-context-expr-push
                pools
                (ast.AstExpr.Literal (ast.AstLiteral.Int n text)))
              s))]
        [(reader.SpannedSexprView.Float text _)
          (ResultAstExpr.Ok
            (ast-expr-wrap-span
              pools
              (ast.ast-node-pool-context-expr-push
                pools
                (ast.AstExpr.Literal (ast.AstLiteral.Float text)))
              s))]
        [(reader.SpannedSexprView.Str string-id _)
          (ResultAstExpr.Ok
            (ast-expr-wrap-span
              pools
              (ast.ast-node-pool-context-expr-push
                pools
                (ast.AstExpr.Literal
                  (ast.AstLiteral.String (ci.intern-id-value string-id))))
              s))]
        [(reader.SpannedSexprView.Char c _)
          (ResultAstExpr.Ok
            (ast-expr-wrap-span
              pools
              (ast.ast-node-pool-context-expr-push
                pools
                (ast.AstExpr.Literal (ast.AstLiteral.Char c)))
              s))]
        [(reader.SpannedSexprView.Sym name span)
          (let
            [name-id : i64 (ci.intern-syntax-id-value name)]
            [tag : i64 (compiler-parse-dispatch-tag-id dispatch name-id)]
            (cond
              [(= tag (compiler-parse-tag-lit-true))
                (ResultAstExpr.Ok
                  (ast-expr-wrap-span
                    pools
                    (ast.ast-node-pool-context-expr-push
                      pools
                      (ast.AstExpr.Literal (ast.AstLiteral.Bool true)))
                    s))]
              [(= tag (compiler-parse-tag-lit-false))
                (ResultAstExpr.Ok
                  (ast-expr-wrap-span
                    pools
                    (ast.ast-node-pool-context-expr-push
                      pools
                      (ast.AstExpr.Literal (ast.AstLiteral.Bool false)))
                    s))]
              [(= tag (compiler-parse-tag-unit))
                (ResultAstExpr.Ok
                  (ast-expr-wrap-span
                    pools
                    (ast.ast-node-pool-context-expr-push
                      pools
                      (ast.AstExpr.Literal ast.AstLiteral.Unit))
                    s))]
              [else
                (begin
                  ;; This is a source candidate, not a claimed field use. The
                  ;; helper rejects generated syntax identities and plain
                  ;; names before reading dotted-name metadata.
                  (compiler-parse-semantic-dotted-field-origins! name span)
                  (ResultAstExpr.Ok
                    (ast-expr-wrap-span
                      pools
                      (ast.ast-node-pool-context-expr-push
                        pools
                        (ast.AstExpr.Var name-id))
                      s)))]))]
        [(reader.SpannedSexprView.Cons head rest _)
          (match (reader.spanned-sexpr-view head)
            [(reader.SpannedSexprView.Sym op _)
              (if (=
                (ci.intern-syntax-id-value op)
                (cbi.compiler-builtin-ctfe-ref 243))
                (match (parse-ast-cfg-expr dispatch pools rest)
                  [(ResultAstExpr.Ok parsed)
                    (ResultAstExpr.Ok (ast-expr-wrap-span pools parsed s))]
                  [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])
                (match (parse-ast-list-expr dispatch pools head rest)
                  [(ResultAstExpr.Ok parsed)
                    (ResultAstExpr.Ok (ast-expr-wrap-span pools parsed s))]
                  [(ResultAstExpr.Err message) (ResultAstExpr.Err message)]))]
            [_
              (match (parse-ast-list-expr dispatch pools head rest)
                [(ResultAstExpr.Ok parsed)
                  (ResultAstExpr.Ok (ast-expr-wrap-span pools parsed s))]
                [(ResultAstExpr.Err message) (ResultAstExpr.Err message)])])]
        [_ (ResultAstExpr.Err "parse: malformed expression")])]
    (parse-ast-error-span-note-expr dispatch s result)))

(define (parse-ast-expr
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultAstExpr (parse-ast-expr-with-pools dispatch pools s)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      result)))

(define (parse-ast-define-value
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [name : i64]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons first tail _)
      (match (reader.spanned-sexpr-view tail)
        [(reader.SpannedSexprView.Nil _)
          (match (parse-ast-expr-with-pools dispatch pools first)
            [(ResultAstExpr.Ok parsed-value)
              (ResultAstDecl.Ok
                (ast.ast-decl-def-id name ast.AstMaybeType.No parsed-value))]
            [(ResultAstExpr.Err message) (ResultAstDecl.Err message)])]
        [(reader.SpannedSexprView.Cons ty value-tail _)
          (match (reader.spanned-sexpr-view value-tail)
            [(reader.SpannedSexprView.Cons value end _)
              (match (reader.spanned-sexpr-view end)
                [(reader.SpannedSexprView.Nil _)
                  (if (sexpr-colon? (reader.spanned-sexpr-form first))
                    (match (parse-ast-type-spanned dispatch pools ty)
                      [(ResultAstType.Ok parsed-ty)
                        (match (parse-ast-expr-with-pools dispatch pools value)
                          [(ResultAstExpr.Ok parsed-value)
                            (ResultAstDecl.Ok
                              (ast.ast-decl-def-id
                                name
                                (ast.AstMaybeType.Some parsed-ty)
                                parsed-value))]
                          [(ResultAstExpr.Err message)
                            (ResultAstDecl.Err message)])]
                      [(ResultAstType.Err message) (ResultAstDecl.Err message)])
                    (ResultAstDecl.Err "parse: expected ':' in definition"))]
                [_ (ResultAstDecl.Err "parse: malformed value definition")])]
            [_ (ResultAstDecl.Err "parse: malformed value definition")])]
        [_ (ResultAstDecl.Err "parse: malformed value definition")])]
    [_ (ResultAstDecl.Err "parse: malformed value definition")]))

(define (parse-ast-spmd-param-classes
  [items : reader.Sexpr]
  [out : ast.AstSpmdParamClassList (:consume)]) : ResultAstSpmdParamClassList
  (match (reader.sexpr-view items)
    [(reader.SexprView.Nil) (ResultAstSpmdParamClassList.Ok out)]
    [(reader.SexprView.Cons head rest)
      (match (reader.sexpr-view head)
        [(reader.SexprView.Sym name)
          (let
            [next : ast.AstSpmdParamClassList out]
            (if (=
              (ci.intern-syntax-id-value name)
              (cbi.compiler-builtin-ctfe-ref 244))
              (begin
                (ast.ast-spmd-param-class-list-push
                  (&mut next)
                  ast.AstSpmdParamClass.Uniform)
                (parse-ast-spmd-param-classes rest next))
              (if (=
                (ci.intern-syntax-id-value name)
                (cbi.compiler-builtin-ctfe-ref 245))
                (begin
                  (ast.ast-spmd-param-class-list-push
                    (&mut next)
                    ast.AstSpmdParamClass.Varying)
                  (parse-ast-spmd-param-classes rest next))
                (ResultAstSpmdParamClassList.Err
                  "parse: :spmd-callable args expects only uniform or varying"))))]
        [_
          (ResultAstSpmdParamClassList.Err
            "parse: :spmd-callable args expects only uniform or varying")])]
    [_
      (ResultAstSpmdParamClassList.Err
        "parse: malformed :spmd-callable args field")]))

(define (parse-ast-spmd-result-class [tail : reader.Sexpr]) : ResultAstSpmdResultClass
  (match (reader.sexpr-view tail)
    [(reader.SexprView.Cons head rest)
      (match (reader.sexpr-view rest)
        [(reader.SexprView.Nil)
          (match (reader.sexpr-view head)
            [(reader.SexprView.Sym name)
              (cond
                [(=
                    (ci.intern-syntax-id-value name)
                    (cbi.compiler-builtin-ctfe-ref 173))
                  (ResultAstSpmdResultClass.Ok ast.AstSpmdResultClass.Unit)]
                [(=
                    (ci.intern-syntax-id-value name)
                    (cbi.compiler-builtin-ctfe-ref 244))
                  (ResultAstSpmdResultClass.Ok ast.AstSpmdResultClass.Uniform)]
                [(=
                    (ci.intern-syntax-id-value name)
                    (cbi.compiler-builtin-ctfe-ref 245))
                  (ResultAstSpmdResultClass.Ok ast.AstSpmdResultClass.Varying)]
                [else
                  (ResultAstSpmdResultClass.Err
                    "parse: :spmd-callable result expects unit, uniform, or varying")])]
            [_
              (ResultAstSpmdResultClass.Err
                "parse: :spmd-callable result expects unit, uniform, or varying")])]
        [_
          (ResultAstSpmdResultClass.Err
            "parse: :spmd-callable result expects one value")])]
    [_
      (ResultAstSpmdResultClass.Err
        "parse: malformed :spmd-callable result field")]))

(define (parse-ast-spmd-index-param [tail : reader.Sexpr]) : ResultAstSpmdIndexParam
  (match (reader.sexpr-view tail)
    [(reader.SexprView.Cons head rest)
      (match (reader.sexpr-view rest)
        [(reader.SexprView.Nil)
          (match (reader.sexpr-view head)
            [(reader.SexprView.Sym name)
              (if (=
                (ci.intern-syntax-id-value name)
                (cbi.compiler-builtin-ctfe-ref 246))
                (ResultAstSpmdIndexParam.Ok -1)
                (ResultAstSpmdIndexParam.Err
                  "parse: :spmd-callable index-param expects none or a non-negative integer"))]
            [(reader.SexprView.Int value _)
              (if (>= value 0)
                (ResultAstSpmdIndexParam.Ok value)
                (ResultAstSpmdIndexParam.Err
                  "parse: :spmd-callable index-param expects none or a non-negative integer"))]
            [_
              (ResultAstSpmdIndexParam.Err
                "parse: :spmd-callable index-param expects none or a non-negative integer")])]
        [_
          (ResultAstSpmdIndexParam.Err
            "parse: :spmd-callable index-param expects one value")])]
    [_
      (ResultAstSpmdIndexParam.Err
        "parse: malformed :spmd-callable index-param field")]))

(define (parse-ast-spmd-specialization-fields
  [dispatch : sym_i64_env.SymI64Env]
  [fields : reader.Sexpr]
  [state : AstSpmdSpecializationParseState]) : ResultAstSpmdSpecializationParseState
  (match (reader.sexpr-view fields)
    [(reader.SexprView.Nil) (ResultAstSpmdSpecializationParseState.Ok state)]
    [(reader.SexprView.Cons field-node rest)
      (match (reader.sexpr-view field-node)
        [(reader.SexprView.Cons key-node value-tail)
          (match (reader.sexpr-view key-node)
            [(reader.SexprView.Sym key)
              (cond
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe-ref 247))
                  (if state.seen-lanes
                    (ResultAstSpmdSpecializationParseState.Err
                      "parse: duplicate :spmd-callable lanes field")
                    (match (reader.sexpr-view value-tail)
                      [(reader.SexprView.Cons value-node end)
                        (match (reader.sexpr-view end)
                          [(reader.SexprView.Nil)
                            (match (reader.sexpr-view value-node)
                              [(reader.SexprView.Int lanes _)
                                (if (> lanes 1)
                                  (parse-ast-spmd-specialization-fields
                                    dispatch
                                    rest
                                    (AstSpmdSpecializationParseState
                                      lanes
                                      state.args
                                      state.result
                                      state.index-param
                                      true
                                      state.seen-args
                                      state.seen-result
                                      state.seen-index-param))
                                  (ResultAstSpmdSpecializationParseState.Err
                                    "parse: :spmd-callable lanes must be greater than one"))]
                              [_
                                (ResultAstSpmdSpecializationParseState.Err
                                  "parse: :spmd-callable lanes expects one integer")])]
                          [_
                            (ResultAstSpmdSpecializationParseState.Err
                              "parse: :spmd-callable lanes expects one integer")])]
                      [_
                        (ResultAstSpmdSpecializationParseState.Err
                          "parse: :spmd-callable lanes expects one integer")]))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe-ref 248))
                  (if state.seen-args
                    (ResultAstSpmdSpecializationParseState.Err
                      "parse: duplicate :spmd-callable args field")
                    (match (parse-ast-spmd-param-classes
                      value-tail
                      (ast.ast-spmd-param-class-list-new))
                      [(ResultAstSpmdParamClassList.Err message)
                        (ResultAstSpmdSpecializationParseState.Err message)]
                      [(ResultAstSpmdParamClassList.Ok args)
                        (parse-ast-spmd-specialization-fields
                          dispatch
                          rest
                          (AstSpmdSpecializationParseState
                            state.lanes
                            args
                            state.result
                            state.index-param
                            state.seen-lanes
                            true
                            state.seen-result
                            state.seen-index-param))]))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe-ref 249))
                  (if state.seen-result
                    (ResultAstSpmdSpecializationParseState.Err
                      "parse: duplicate :spmd-callable result field")
                    (match (parse-ast-spmd-result-class value-tail)
                      [(ResultAstSpmdResultClass.Err message)
                        (ResultAstSpmdSpecializationParseState.Err message)]
                      [(ResultAstSpmdResultClass.Ok result)
                        (parse-ast-spmd-specialization-fields
                          dispatch
                          rest
                          (AstSpmdSpecializationParseState
                            state.lanes
                            state.args
                            result
                            state.index-param
                            state.seen-lanes
                            state.seen-args
                            true
                            state.seen-index-param))]))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe-ref 250))
                  (if state.seen-index-param
                    (ResultAstSpmdSpecializationParseState.Err
                      "parse: duplicate :spmd-callable index-param field")
                    (match (parse-ast-spmd-index-param value-tail)
                      [(ResultAstSpmdIndexParam.Err message)
                        (ResultAstSpmdSpecializationParseState.Err message)]
                      [(ResultAstSpmdIndexParam.Ok index-param)
                        (parse-ast-spmd-specialization-fields
                          dispatch
                          rest
                          (AstSpmdSpecializationParseState
                            state.lanes
                            state.args
                            state.result
                            index-param
                            state.seen-lanes
                            state.seen-args
                            state.seen-result
                            true))]))]
                [else
                  (ResultAstSpmdSpecializationParseState.Err
                    (str_cat.str-cat
                      "parse: unknown :spmd-callable specialization field "
                      (compiler-parse-dispatch-syntax-id-text dispatch key)))])]
            [_
              (ResultAstSpmdSpecializationParseState.Err
                "parse: malformed :spmd-callable specialization field")])]
        [_
          (ResultAstSpmdSpecializationParseState.Err
            "parse: malformed :spmd-callable specialization field")])]
    [_
      (ResultAstSpmdSpecializationParseState.Err
        "parse: malformed :spmd-callable specialization")]))

(define (parse-ast-spmd-specialization
  [dispatch : sym_i64_env.SymI64Env]
  [tail : reader.Sexpr]
  [param-count : i64]) : ResultAstSpmdSpecialization
  (match (parse-ast-spmd-specialization-fields
    dispatch
    tail
    (AstSpmdSpecializationParseState
      0
      (ast.ast-spmd-param-class-list-new)
      ast.AstSpmdResultClass.Unit
      -1
      false
      false
      false
      false))
    [(ResultAstSpmdSpecializationParseState.Err message)
      (ResultAstSpmdSpecialization.Err message)]
    [(ResultAstSpmdSpecializationParseState.Ok state)
      (cond
        [(not state.seen-lanes)
          (ResultAstSpmdSpecialization.Err
            "parse: :spmd-callable specialization is missing lanes")]
        [(not state.seen-args)
          (ResultAstSpmdSpecialization.Err
            "parse: :spmd-callable specialization is missing args")]
        [(not state.seen-result)
          (ResultAstSpmdSpecialization.Err
            "parse: :spmd-callable specialization is missing result")]
        [(not state.seen-index-param)
          (ResultAstSpmdSpecialization.Err
            "parse: :spmd-callable specialization is missing index-param")]
        [(not
            (= (ast.ast-spmd-param-class-list-len (& state.args)) param-count))
          (ResultAstSpmdSpecialization.Err
            "parse: :spmd-callable args must contain one class per ordinary parameter")]
        [(>= state.index-param param-count)
          (ResultAstSpmdSpecialization.Err
            "parse: :spmd-callable index-param is outside the parameter list")]
        [else
          (ResultAstSpmdSpecialization.Ok
            (ast.AstSpmdSpecialization
              state.lanes
              (box state.args)
              state.result
              state.index-param))])]))

(define (parse-ast-spmd-param-classes-eq-at?
  [left : (& left ast.AstSpmdParamClassList)]
  [right : (& right ast.AstSpmdParamClassList)]
  [index : i64]) : bool
  (if (>= index (ast.ast-spmd-param-class-list-len left))
    (=
      (ast.ast-spmd-param-class-list-len left)
      (ast.ast-spmd-param-class-list-len right))
    (and
      (< index (ast.ast-spmd-param-class-list-len right))
      (match (ast.ast-spmd-param-class-list-get
        left
        index
        ast.AstSpmdParamClass.Uniform)
        [(ast.AstSpmdParamClass.Uniform)
          (match (ast.ast-spmd-param-class-list-get
            right
            index
            ast.AstSpmdParamClass.Varying)
            [(ast.AstSpmdParamClass.Uniform)
              (parse-ast-spmd-param-classes-eq-at? left right (+ index 1))]
            [_ false])]
        [(ast.AstSpmdParamClass.Varying)
          (match (ast.ast-spmd-param-class-list-get
            right
            index
            ast.AstSpmdParamClass.Uniform)
            [(ast.AstSpmdParamClass.Varying)
              (parse-ast-spmd-param-classes-eq-at? left right (+ index 1))]
            [_ false])]))))

(define (parse-ast-spmd-specialization-eq?
  [left : ast.AstSpmdSpecialization]
  [right : ast.AstSpmdSpecialization]) : bool
  (and
    (= left.lanes right.lanes)
    (= left.result right.result)
    (= left.index-param right.index-param)
    (parse-ast-spmd-param-classes-eq-at?
      (& (__tl-box-place left.args))
      (& (__tl-box-place right.args))
      0)))

(define (parse-ast-spmd-specialization-present-at?
  [items : (& items ast.AstSpmdSpecializationList)]
  [wanted : ast.AstSpmdSpecialization]
  [index : i64]) : bool
  (if (>= index (ast.ast-spmd-specialization-list-len items))
    false
    (if (parse-ast-spmd-specialization-eq?
      (ast.ast-spmd-specialization-list-get items index wanted)
      wanted)
      true
      (parse-ast-spmd-specialization-present-at? items wanted (+ index 1)))))

(define (parse-ast-spmd-specializations
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.Sexpr]
  [param-count : i64]
  [out : ast.AstSpmdSpecializationList (:consume)]) : ResultAstSpmdCallable
  (match (reader.sexpr-view items)
    [(reader.SexprView.Nil)
      (if (= (ast.ast-spmd-specialization-list-len (& out)) 0)
        (ResultAstSpmdCallable.Err
          "parse: :spmd-callable expects at least one specialization")
        (ResultAstSpmdCallable.Ok (ast.AstSpmdCallable.Callable out)))]
    [(reader.SexprView.Cons item-node rest)
      (match (reader.sexpr-view item-node)
        [(reader.SexprView.Cons name-node fields)
          (match (reader.sexpr-view name-node)
            [(reader.SexprView.Sym name)
              (if (=
                (ci.intern-syntax-id-value name)
                (cbi.compiler-builtin-ctfe-ref 251))
                (match (parse-ast-spmd-specialization
                  dispatch
                  fields
                  param-count)
                  [(ResultAstSpmdSpecialization.Err message)
                    (ResultAstSpmdCallable.Err message)]
                  [(ResultAstSpmdSpecialization.Ok specialization)
                    (if (parse-ast-spmd-specialization-present-at?
                      (& out)
                      specialization
                      0)
                      (ResultAstSpmdCallable.Err
                        "parse: duplicate :spmd-callable specialization")
                      (let
                        [next : ast.AstSpmdSpecializationList out]
                        (begin
                          (ast.ast-spmd-specialization-list-push
                            (&mut next)
                            specialization)
                          (parse-ast-spmd-specializations
                            dispatch
                            rest
                            param-count
                            next))))])
                (ResultAstSpmdCallable.Err
                  "parse: :spmd-callable expects specialization forms"))]
            [_
              (ResultAstSpmdCallable.Err
                "parse: malformed :spmd-callable specialization")])]
        [_
          (ResultAstSpmdCallable.Err
            "parse: malformed :spmd-callable specialization")])]
    [_ (ResultAstSpmdCallable.Err "parse: malformed :spmd-callable metadata")]))

(define (parse-ast-define-fn-spmd-callable-tail
  [dispatch : sym_i64_env.SymI64Env]
  [tail : reader.Sexpr]
  [param-count : i64]) : ResultAstSpmdCallable
  (parse-ast-spmd-specializations
    dispatch
    tail
    param-count
    (ast.ast-spmd-specialization-list-new)))

(define (parse-ast-define-fn-export-tail
  [dispatch : sym_i64_env.SymI64Env]
  [tail : reader.Sexpr]) : ResultAstFnExport
  (match (reader.sexpr-view tail)
    [(reader.SexprView.Cons value-node end)
      (match (reader.sexpr-view end)
        [(reader.SexprView.Nil)
          (match (reader.sexpr-view value-node)
            [(reader.SexprView.Str value-id)
              (if (>
                (string.string-length
                  (compiler-parse-dispatch-id-str dispatch value-id))
                0)
                (ResultAstFnExport.Ok (ast.ast-fn-export-id value-id))
                (ResultAstFnExport.Err
                  "parse: define :export-symbol must not be empty"))]
            [_
              (ResultAstFnExport.Err
                "parse: malformed define :export-symbol metadata")])]
        [_
          (ResultAstFnExport.Err
            "parse: malformed define :export-symbol metadata")])]
    [_
      (ResultAstFnExport.Err "parse: malformed define :export-symbol metadata")]))

(define (parse-ast-define-fn-metadata?
  [dispatch : sym_i64_env.SymI64Env]
  [item : reader.SpannedSexpr]) : bool
  (match (reader.sexpr-view (reader.spanned-sexpr-form item))
    [(reader.SexprView.Cons key-node _)
      (match (reader.sexpr-view key-node)
        [(reader.SexprView.Sym key) (compiler-parse-metadata-key? dispatch key)]
        [_ false])]
    [_ false]))

(define (parse-ast-define-fn-finish
  [name : i64]
  [params : ast.AstParamList]
  [ret : ast.AstType]
  [body : i64]
  [export : ast.AstFnExport]
  [spmd-callable : ast.AstSpmdCallable]) : ResultAstDecl
  (if (and
    (match export
      [(ast.AstFnExport.Export _) true]
      [_ false])
    (match spmd-callable
      [(ast.AstSpmdCallable.Callable _) true]
      [_ false]))
    (ResultAstDecl.Err
      "parse: define :spmd-callable cannot be combined with :export-symbol")
    (if (ast-param-list-has-comptime? params)
      (match export
        [(ast.AstFnExport.Export _)
          (ResultAstDecl.Err
            "parse: define :export-symbol cannot be used on functions with comptime parameters")]
        [(ast.AstFnExport.No)
          (match spmd-callable
            [(ast.AstSpmdCallable.No)
              (ResultAstDecl.Ok
                (ast.ast-decl-def-fn-metadata-id
                  name
                  params
                  ret
                  body
                  (ast.ast-fn-metadata-full export spmd-callable)))]
            [(ast.AstSpmdCallable.Callable _)
              (ResultAstDecl.Err
                "parse: define :spmd-callable cannot be used on functions with comptime parameters")])])
      (ResultAstDecl.Ok
        (ast.ast-decl-def-fn-metadata-id
          name
          params
          ret
          body
          (ast.ast-fn-metadata-full export spmd-callable))))))

(define (parse-ast-define-fn-rest
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [name : i64]
  [params : ast.AstParamList]
  [export : ast.AstFnExport]
  [seen-export : bool]
  [spmd-callable : ast.AstSpmdCallable]
  [seen-spmd-callable : bool]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons first tail _)
      (if (sexpr-colon? (reader.spanned-sexpr-form first))
        (match (reader.spanned-sexpr-view tail)
          [(reader.SpannedSexprView.Cons ret body-tail _)
            (match (parse-ast-type-spanned dispatch pools ret)
              [(ResultAstType.Ok parsed-ret)
                (match (parse-ast-body-tail
                  dispatch
                  pools
                  body-tail
                  "parse: malformed function definition")
                  [(ResultAstExpr.Ok parsed-body)
                    (parse-ast-define-fn-finish
                      name
                      params
                      parsed-ret
                      parsed-body
                      export
                      spmd-callable)]
                  [(ResultAstExpr.Err message) (ResultAstDecl.Err message)])]
              [(ResultAstType.Err message) (ResultAstDecl.Err message)])]
          [_ (ResultAstDecl.Err "parse: malformed function definition")])
        (if (parse-ast-define-fn-metadata? dispatch first)
          (match (reader.sexpr-view (reader.spanned-sexpr-form first))
            [(reader.SexprView.Cons key-node after-key)
              (match (reader.sexpr-view key-node)
                [(reader.SexprView.Sym key)
                  (cond
                    [(=
                        (ci.intern-syntax-id-value key)
                        (cbi.compiler-builtin-ctfe-ref 252))
                      (if seen-export
                        (ResultAstDecl.Err
                          "parse: duplicate define :export-symbol metadata")
                        (match (parse-ast-define-fn-export-tail
                          dispatch
                          after-key)
                          [(ResultAstFnExport.Ok parsed-export)
                            (parse-ast-define-fn-rest
                              dispatch
                              pools
                              name
                              params
                              parsed-export
                              true
                              spmd-callable
                              seen-spmd-callable
                              tail)]
                          [(ResultAstFnExport.Err message)
                            (ResultAstDecl.Err message)]))]
                    [(=
                        (ci.intern-syntax-id-value key)
                        (cbi.compiler-builtin-ctfe-ref 253))
                      (if seen-spmd-callable
                        (ResultAstDecl.Err
                          "parse: duplicate define :spmd-callable metadata")
                        (match (parse-ast-define-fn-spmd-callable-tail
                          dispatch
                          after-key
                          (ast.ast-param-list-len (& params)))
                          [(ResultAstSpmdCallable.Ok parsed-callable)
                            (parse-ast-define-fn-rest
                              dispatch
                              pools
                              name
                              params
                              export
                              seen-export
                              parsed-callable
                              true
                              tail)]
                          [(ResultAstSpmdCallable.Err message)
                            (ResultAstDecl.Err message)]))]
                    [(compiler-parse-metadata-key? dispatch key)
                      (ResultAstDecl.Err
                        (str_cat.str-cat
                          "parse: unknown define metadata "
                          (compiler-parse-dispatch-syntax-id-text dispatch key)))]
                    [else
                      (ResultAstDecl.Err "parse: malformed function metadata")])]
                [_ (ResultAstDecl.Err "parse: malformed function definition")])]
            [_ (ResultAstDecl.Err "parse: malformed function definition")])
          (match (parse-ast-body-tail
            dispatch
            pools
            rest
            "parse: malformed function definition")
            [(ResultAstExpr.Ok parsed-body)
              (parse-ast-define-fn-finish
                name
                params
                (ast.AstType.Unit)
                parsed-body
                export
                spmd-callable)]
            [(ResultAstExpr.Err message) (ResultAstDecl.Err message)])))]
    [_ (ResultAstDecl.Err "parse: malformed function definition")]))

(define (parse-ast-define-fn
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [name : i64]
  [params : reader.SpannedSexpr]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (parse-ast-param-list
    dispatch
    pools
    (reader.spanned-sexpr-form params))
    [(ResultAstParamList.Ok parsed-params)
      (begin
        (compiler-parse-semantic-param-list-origins! dispatch params)
        (parse-ast-define-fn-rest
          dispatch
          pools
          name
          parsed-params
          ast.AstFnExport.No
          false
          ast.AstSpmdCallable.No
          false
          rest))]
    [(ResultAstParamList.Err message) (ResultAstDecl.Err message)]))

(define (parse-ast-define
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons head after-name _)
      (match (reader.spanned-sexpr-view head)
        [(reader.SpannedSexprView.Sym name _)
          (parse-ast-define-value
            dispatch
            pools
            (ci.intern-syntax-id-value name)
            after-name)]
        [(reader.SpannedSexprView.Cons name-node params _)
          (match (reader.spanned-sexpr-view name-node)
            [(reader.SpannedSexprView.Sym name _)
              (parse-ast-define-fn
                dispatch
                pools
                (ci.intern-syntax-id-value name)
                params
                after-name)]
            [_ (ResultAstDecl.Err "parse: malformed define")])]
        [_ (ResultAstDecl.Err "parse: malformed define")])]
    [_ (ResultAstDecl.Err "parse: malformed define")]))

(define (parse-ast-defmacro
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons header after-header _)
      (match (reader.spanned-sexpr-view header)
        [(reader.SpannedSexprView.Cons name-node params _)
          (match (reader.spanned-sexpr-view name-node)
            [(reader.SpannedSexprView.Sym name _)
              (match (reader.spanned-sexpr-view after-header)
                [(reader.SpannedSexprView.Cons colon ret-tail _)
                  (match (reader.spanned-sexpr-view ret-tail)
                    [(reader.SpannedSexprView.Cons ret body-tail _)
                      (match (reader.spanned-sexpr-view body-tail)
                        [(reader.SpannedSexprView.Cons body end _)
                          (match (reader.spanned-sexpr-view end)
                            [(reader.SpannedSexprView.Nil _)
                              (if (sexpr-colon?
                                (reader.spanned-sexpr-form colon))
                                (match (parse-ast-macro-param-list
                                  dispatch
                                  pools
                                  (reader.spanned-sexpr-form params))
                                  [(ResultAstMacroParamList.Ok parsed-params)
                                    (begin
                                      (compiler-parse-semantic-param-list-origins!
                                        dispatch
                                        params)
                                      (match (parse-ast-type-spanned
                                        dispatch
                                        pools
                                        ret)
                                        [(ResultAstType.Ok parsed-ret)
                                          (match (parse-ast-expr-with-pools
                                            dispatch
                                            pools
                                            body)
                                            [(ResultAstExpr.Ok parsed-body)
                                              (ResultAstDecl.Ok
                                                (ast.ast-decl-def-macro-id
                                                  (ci.intern-syntax-id-value
                                                    name)
                                                  parsed-params
                                                  parsed-ret
                                                  parsed-body))]
                                            [(ResultAstExpr.Err message)
                                              (ResultAstDecl.Err message)])]
                                        [(ResultAstType.Err message)
                                          (ResultAstDecl.Err message)]))]
                                  [(ResultAstMacroParamList.Err message)
                                    (ResultAstDecl.Err message)])
                                (ResultAstDecl.Err
                                  "parse: expected ':' in macro definition"))]
                            [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
                        [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
                    [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
                [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
            [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
        [_ (ResultAstDecl.Err "parse: malformed defmacro")])]
    [_ (ResultAstDecl.Err "parse: malformed defmacro")]))

(define (parse-ast-extern-varargs-typed-name?
  [dispatch : sym_i64_env.SymI64Env]
  [name-id : ci.InternSyntaxId]) : bool
  ;; Unlike the fixed open tail `...`, typed tails encode their type in the
  ;; symbol spelling (`...T`) and therefore require this content boundary.
  (let
    [name : String (compiler-parse-dispatch-syntax-id-text dispatch name-id)]
    (if (> (string.string-length name) 3)
      (string.eq (string.substring name 0 3) "...")
      false)))

(define (parse-ast-extern-varargs-tail-id
  [dispatch : sym_i64_env.SymI64Env]
  [name-id : ci.InternSyntaxId]) : i64
  (let
    [intern-state : ci.InternCompatState
      (compiler-parse-dispatch-intern-state dispatch)]
    [name : String (ci.intern-compat-state-syntax-id-text intern-state name-id)]
    [tail : String (string.substring name 3 (- (string.string-length name) 3))]
    (ci.intern-id-value
      (ci.intern-compat-state-source-slice-id
        intern-state
        tail
        0
        (string.string-length tail)))))

(define (parse-ast-extern-varargs-open? [name-id : ci.InternSyntaxId]) : bool
  (= (ci.intern-syntax-id-value name-id) (cbi.compiler-builtin-ctfe-ref 222)))

(define (parse-ast-extern-varargs-tail-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [name-id : ci.InternSyntaxId]) : ResultAstType
  (if (parse-ast-extern-varargs-typed-name? dispatch name-id)
    (parse-ast-type
      dispatch
      pools
      (reader.Sexpr.Sym
        (ci.intern-syntax-id-from-raw
          (parse-ast-extern-varargs-tail-id dispatch name-id))))
    (ResultAstType.Err "parse: expected typed extern varargs tail")))

(define (parse-ast-extern-head-fixed-param
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [item : reader.SpannedSexpr]) : ResultAstExternHeadItem
  (match (parse-ast-param dispatch pools (reader.spanned-sexpr-form item))
    [(ResultAstParam.Ok param)
      (begin
        (compiler-parse-semantic-param-origin! dispatch item)
        (match param
          [(ast.AstParam.Param _ ty comptime? consume?)
            (if comptime?
              (ResultAstExternHeadItem.Err
                "parse: extern parameters cannot be comptime")
              (if consume?
                (ResultAstExternHeadItem.Err
                  "parse: extern parameters cannot be consuming")
                (ResultAstExternHeadItem.Ok (AstExternHeadItem.Param ty))))]))]
    [(ResultAstParam.Err message) (ResultAstExternHeadItem.Err message)]))

(define (parse-ast-extern-head-bracket-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [item : reader.SpannedSexpr]
  [items : reader.SpannedSexpr]) : ResultAstExternHeadItem
  (match (reader.spanned-sexpr-view items)
    [(reader.SpannedSexprView.Cons _ after-name _)
      (match (reader.spanned-sexpr-view after-name)
        [(reader.SpannedSexprView.Cons colon after-colon _)
          (match (reader.spanned-sexpr-view after-colon)
            [(reader.SpannedSexprView.Cons ty-node end _)
              (match (reader.spanned-sexpr-view end)
                [(reader.SpannedSexprView.Nil _)
                  (if (sexpr-colon? (reader.spanned-sexpr-form colon))
                    (match (reader.spanned-sexpr-view ty-node)
                      [(reader.SpannedSexprView.Sym ty-name ty-span)
                        (if (parse-ast-extern-varargs-open? ty-name)
                          (ResultAstExternHeadItem.Err
                            "parse: extern typed varargs tail needs a type")
                          (if (parse-ast-extern-varargs-typed-name?
                            dispatch
                            ty-name)
                            (match (parse-ast-extern-varargs-tail-type
                              dispatch
                              pools
                              ty-name)
                              [(ResultAstType.Ok tail-ty)
                                (begin
                                  (compiler-parse-semantic-type-origins!
                                    dispatch
                                    (reader.SpannedSexpr.Sym
                                      (ci.intern-syntax-id-from-raw
                                        (parse-ast-extern-varargs-tail-id
                                          dispatch
                                          ty-name))
                                      (token.SourceSpan
                                        (token.span-start-line ty-span)
                                        (+ (token.span-start-col ty-span) 3)
                                        (token.span-end-line ty-span)
                                        (token.span-end-col ty-span))))
                                  (ResultAstExternHeadItem.Ok
                                    (AstExternHeadItem.VarargsTyped tail-ty)))]
                              [(ResultAstType.Err message)
                                (ResultAstExternHeadItem.Err message)])
                            (parse-ast-extern-head-fixed-param
                              dispatch
                              pools
                              item)))]
                      [_
                        (parse-ast-extern-head-fixed-param dispatch pools item)])
                    (parse-ast-extern-head-fixed-param dispatch pools item))]
                [_ (parse-ast-extern-head-fixed-param dispatch pools item)])]
            [_ (parse-ast-extern-head-fixed-param dispatch pools item)])]
        [_ (parse-ast-extern-head-fixed-param dispatch pools item)])]
    [_ (parse-ast-extern-head-fixed-param dispatch pools item)]))

(define (parse-ast-extern-head-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [item : reader.SpannedSexpr]) : ResultAstExternHeadItem
  (match (reader.spanned-sexpr-view item)
    [(reader.SpannedSexprView.Sym name _)
      (if (parse-ast-extern-varargs-open? name)
        (ResultAstExternHeadItem.Ok (AstExternHeadItem.VarargsOpen))
        (if (parse-ast-extern-varargs-typed-name? dispatch name)
          (ResultAstExternHeadItem.Err
            "parse: typed extern varargs tail must use bracket syntax")
          (ResultAstExternHeadItem.Err "parse: malformed extern function head")))]
    [(reader.SpannedSexprView.BracketList items _)
      (parse-ast-extern-head-bracket-item dispatch pools item items)]
    [_ (ResultAstExternHeadItem.Err "parse: malformed extern function head")]))

(define (parse-ast-extern-head-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [items : reader.SpannedSexpr]) : ResultAstExternHeader
  (match (reader.spanned-sexpr-view items)
    [(reader.SpannedSexprView.Nil _)
      (ResultAstExternHeader.Ok -1 (ast.ast-type-list-new) (ast.AstExternAbi.C))]
    [(reader.SpannedSexprView.Cons item tail _)
      (let
        [item : reader.SpannedSexpr item]
        [tail : reader.SpannedSexpr tail]
        (match (parse-ast-extern-head-item dispatch pools item)
          [(ResultAstExternHeadItem.Ok parsed-item)
            (match parsed-item
              [(AstExternHeadItem.Param ty)
                (match (parse-ast-extern-head-items dispatch pools tail)
                  [(ResultAstExternHeader.Ok _ parsed-tail parsed-abi)
                    (ResultAstExternHeader.Ok
                      -1
                      (ast.ast-type-cons-with-pools pools ty parsed-tail)
                      parsed-abi)]
                  [(ResultAstExternHeader.Err message)
                    (ResultAstExternHeader.Err message)])]
              [(AstExternHeadItem.VarargsOpen)
                (match (reader.spanned-sexpr-view tail)
                  [(reader.SpannedSexprView.Nil _)
                    (ResultAstExternHeader.Ok
                      -1
                      (ast.ast-type-list-new)
                      (ast.AstExternAbi.CVarargsOpen))]
                  [_
                    (ResultAstExternHeader.Err
                      "parse: extern varargs tail must be final")])]
              [(AstExternHeadItem.VarargsTyped tail-ty)
                (match (reader.spanned-sexpr-view tail)
                  [(reader.SpannedSexprView.Nil _)
                    (ResultAstExternHeader.Ok
                      -1
                      (ast.ast-type-list-new)
                      (ast.AstExternAbi.CVarargsTyped tail-ty))]
                  [_
                    (ResultAstExternHeader.Err
                      "parse: extern varargs tail must be final")])])]
          [(ResultAstExternHeadItem.Err message)
            (ResultAstExternHeader.Err message)]))]
    [_ (ResultAstExternHeader.Err "parse: malformed extern function head")]))

(define (parse-ast-extern-header
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [head : reader.SpannedSexpr]) : ResultAstExternHeader
  (match (reader.spanned-sexpr-view head)
    [(reader.SpannedSexprView.Cons name-node params _)
      (match (reader.spanned-sexpr-view name-node)
        [(reader.SpannedSexprView.Sym name _)
          (match (parse-ast-extern-head-items dispatch pools params)
            [(ResultAstExternHeader.Ok _ param-types abi)
              (ResultAstExternHeader.Ok
                (ci.intern-syntax-id-value name)
                param-types
                abi)]
            [(ResultAstExternHeader.Err message)
              (ResultAstExternHeader.Err message)])]
        [_ (ResultAstExternHeader.Err "parse: malformed extern function head")])]
    [_ (ResultAstExternHeader.Err "parse: malformed extern function head")]))

(define (parse-ast-extern-c-varargs-legacy-message) : String
  "parse: legacy :abi c-varargs metadata is retired; use function-head ... or ...T varargs")

(define (parse-ast-extern-abi-tail
  [dispatch : sym_i64_env.SymI64Env]
  [tail : reader.Sexpr]) : ResultAstExternAbi
  (match (reader.sexpr-view tail)
    [(reader.SexprView.Cons name-node rest)
      (match (reader.sexpr-view name-node)
        [(reader.SexprView.Sym name)
          (match (reader.sexpr-view rest)
            [(reader.SexprView.Nil)
              (if (=
                (ci.intern-syntax-id-value name)
                cbi.compiler-builtin-id-fix-c)
                (ResultAstExternAbi.Ok (ast.AstExternAbi.C))
                (if (=
                  (ci.intern-syntax-id-value name)
                  (cbi.compiler-builtin-ctfe-ref 254))
                  (ResultAstExternAbi.Err
                    (parse-ast-extern-c-varargs-legacy-message))
                  (ResultAstExternAbi.Err
                    (str_cat.str-cat
                      "parse: unknown extern ABI "
                      (compiler-parse-dispatch-syntax-id-text dispatch name)))))]
            [(reader.SexprView.Cons fixed-node end)
              (match (reader.sexpr-view end)
                [(reader.SexprView.Nil)
                  (match (reader.sexpr-view fixed-node)
                    [(reader.SexprView.Int _ _)
                      (if (=
                        (ci.intern-syntax-id-value name)
                        (cbi.compiler-builtin-ctfe-ref 254))
                        (ResultAstExternAbi.Err
                          (parse-ast-extern-c-varargs-legacy-message))
                        (ResultAstExternAbi.Err
                          (str_cat.str-cat
                            "parse: unknown extern ABI "
                            (compiler-parse-dispatch-syntax-id-text
                              dispatch
                              name))))]
                    [_
                      (ResultAstExternAbi.Err
                        "parse: malformed extern :abi metadata")])]
                [_
                  (ResultAstExternAbi.Err
                    "parse: malformed extern :abi metadata")])]
            [_ (ResultAstExternAbi.Err "parse: malformed extern :abi metadata")])]
        [_ (ResultAstExternAbi.Err "parse: malformed extern :abi metadata")])]
    [_ (ResultAstExternAbi.Err "parse: malformed extern :abi metadata")]))

(define (parse-ast-extern-string-tail
  [dispatch : sym_i64_env.SymI64Env]
  [key : String]
  [tail : reader.Sexpr]) : ResultAstExternSymbol
  (match (reader.sexpr-view tail)
    [(reader.SexprView.Cons value-node end)
      (match (reader.sexpr-view end)
        [(reader.SexprView.Nil)
          (match (reader.sexpr-view value-node)
            [(reader.SexprView.Str value-id)
              (let
                [value : String
                  (compiler-parse-dispatch-id-str dispatch value-id)]
                (if (> (string.string-length value) 0)
                  (ResultAstExternSymbol.Ok value value-id)
                  (ResultAstExternSymbol.Err
                    (str_cat.str-cat "parse: extern " key " must not be empty"))))]
            [_
              (ResultAstExternSymbol.Err
                (str_cat.str-cat "parse: malformed extern " key " metadata"))])]
        [_
          (ResultAstExternSymbol.Err
            (str_cat.str-cat "parse: malformed extern " key " metadata"))])]
    [_
      (ResultAstExternSymbol.Err
        (str_cat.str-cat "parse: malformed extern " key " metadata"))]))

(define (parse-ast-extern-symbol-tail
  [dispatch : sym_i64_env.SymI64Env]
  [tail : reader.Sexpr]) : ResultAstExternSymbol
  (parse-ast-extern-string-tail dispatch ":symbol" tail))

(define (parse-ast-extern-abi-combine
  [base : ast.AstExternAbi]
  [parsed : ast.AstExternAbi]) : ResultAstExternAbi
  (if (ast.ast-extern-abi-c-varargs? base)
    (match parsed
      [(ast.AstExternAbi.C) (ResultAstExternAbi.Ok base)]
      [_
        (ResultAstExternAbi.Err
          "parse: extern varargs tail cannot be combined with another ABI")])
    (ResultAstExternAbi.Ok parsed)))

(define (parse-ast-extern-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [items : reader.SpannedSexpr]
  [abi : ast.AstExternAbi]
  [symbol-id : ci.InternId]
  [link-inputs : (&mut link-inputs ast.AstExternLinkInputList)]
  [seen-abi : bool]
  [seen-symbol : bool]) : ResultAstExternParts
  (match (reader.spanned-sexpr-view items)
    [(reader.SpannedSexprView.Cons head tail _)
      (if (sexpr-colon? (reader.spanned-sexpr-form head))
        (match (reader.spanned-sexpr-view tail)
          [(reader.SpannedSexprView.Cons ty end _)
            (match (reader.spanned-sexpr-view end)
              [(reader.SpannedSexprView.Nil _)
                (match (parse-ast-type-spanned dispatch pools ty)
                  [(ResultAstType.Ok parsed-ty)
                    (ResultAstExternParts.Ok abi symbol-id seen-abi parsed-ty)]
                  [(ResultAstType.Err message)
                    (ResultAstExternParts.Err message)])]
              [_ (ResultAstExternParts.Err "parse: malformed extern")])]
          [_ (ResultAstExternParts.Err "parse: malformed extern")])
        (match (reader.sexpr-view (reader.spanned-sexpr-form head))
          [(reader.SexprView.Cons key-node after-key)
            (match (reader.sexpr-view key-node)
              [(reader.SexprView.Sym key)
                (cond
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe-ref 255))
                    (if seen-abi
                      (ResultAstExternParts.Err
                        "parse: duplicate extern :abi metadata")
                      (match (parse-ast-extern-abi-tail dispatch after-key)
                        [(ResultAstExternAbi.Ok parsed-abi)
                          (parse-ast-extern-items
                            dispatch
                            pools
                            tail
                            parsed-abi
                            symbol-id
                            link-inputs
                            true
                            seen-symbol)]
                        [(ResultAstExternAbi.Err message)
                          (ResultAstExternParts.Err message)]))]
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe-ref 256))
                    (if seen-symbol
                      (ResultAstExternParts.Err
                        "parse: duplicate extern :symbol metadata")
                      (match (parse-ast-extern-symbol-tail dispatch after-key)
                        [(ResultAstExternSymbol.Ok _ parsed-symbol-id)
                          (parse-ast-extern-items
                            dispatch
                            pools
                            tail
                            abi
                            parsed-symbol-id
                            link-inputs
                            seen-abi
                            true)]
                        [(ResultAstExternSymbol.Err message)
                          (ResultAstExternParts.Err message)]))]
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe-ref 257))
                    (match (parse-ast-extern-string-tail
                      dispatch
                      ":link-lib"
                      after-key)
                      [(ResultAstExternSymbol.Ok value _)
                        (begin
                          (ast.ast-extern-link-input-list-push
                            link-inputs
                            (ast.AstExternLinkInput.Lib value))
                          (parse-ast-extern-items
                            dispatch
                            pools
                            tail
                            abi
                            symbol-id
                            link-inputs
                            seen-abi
                            seen-symbol))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe-ref 258))
                    (match (parse-ast-extern-string-tail
                      dispatch
                      ":link-search"
                      after-key)
                      [(ResultAstExternSymbol.Ok value _)
                        (begin
                          (ast.ast-extern-link-input-list-push
                            link-inputs
                            (ast.AstExternLinkInput.Search value))
                          (parse-ast-extern-items
                            dispatch
                            pools
                            tail
                            abi
                            symbol-id
                            link-inputs
                            seen-abi
                            seen-symbol))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe-ref 259))
                    (match (parse-ast-extern-string-tail
                      dispatch
                      ":link-arg"
                      after-key)
                      [(ResultAstExternSymbol.Ok value _)
                        (begin
                          (ast.ast-extern-link-input-list-push
                            link-inputs
                            (ast.AstExternLinkInput.Arg value))
                          (parse-ast-extern-items
                            dispatch
                            pools
                            tail
                            abi
                            symbol-id
                            link-inputs
                            seen-abi
                            seen-symbol))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(compiler-parse-metadata-key? dispatch key)
                    (ResultAstExternParts.Err
                      (str_cat.str-cat
                        "parse: unknown extern metadata "
                        (compiler-parse-dispatch-syntax-id-text dispatch key)))]
                  [else
                    (ResultAstExternParts.Err "parse: expected ':' in extern")])]
              [_ (ResultAstExternParts.Err "parse: expected ':' in extern")])]
          [_ (ResultAstExternParts.Err "parse: expected ':' in extern")]))]
    [_ (ResultAstExternParts.Err "parse: malformed extern")]))

(define (parse-ast-extern-head-finish
  [pools : ast.AstNodePoolContext]
  [abi : ast.AstExternAbi]
  [symbol-id : ci.InternId]
  [seen-abi : bool]
  [param-types : ast.AstTypeList]
  [ret : ast.AstType]) : ResultAstExternParts
  (ResultAstExternParts.Ok
    abi
    symbol-id
    seen-abi
    (ast.ast-ty-func-with-pools pools param-types ret)))

(define (parse-ast-extern-head-post-ret
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [items : reader.SpannedSexpr]
  [abi : ast.AstExternAbi]
  [symbol-id : ci.InternId]
  [link-inputs : (&mut link-inputs ast.AstExternLinkInputList)]
  [seen-abi : bool]
  [seen-symbol : bool]
  [param-types : ast.AstTypeList]
  [ret : ast.AstType]) : ResultAstExternParts
  (match (reader.spanned-sexpr-view items)
    [(reader.SpannedSexprView.Nil _)
      (parse-ast-extern-head-finish
        pools
        abi
        symbol-id
        seen-abi
        param-types
        ret)]
    [(reader.SpannedSexprView.Cons head tail _)
      (match (reader.sexpr-view (reader.spanned-sexpr-form head))
        [(reader.SexprView.Cons key-node after-key)
          (match (reader.sexpr-view key-node)
            [(reader.SexprView.Sym key)
              (cond
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe-ref 255))
                  (if seen-abi
                    (ResultAstExternParts.Err
                      "parse: duplicate extern :abi metadata")
                    (match (parse-ast-extern-abi-tail dispatch after-key)
                      [(ResultAstExternAbi.Ok parsed-abi)
                        (match (parse-ast-extern-abi-combine abi parsed-abi)
                          [(ResultAstExternAbi.Ok combined-abi)
                            (parse-ast-extern-head-post-ret
                              dispatch
                              pools
                              tail
                              combined-abi
                              symbol-id
                              link-inputs
                              true
                              seen-symbol
                              param-types
                              ret)]
                          [(ResultAstExternAbi.Err message)
                            (ResultAstExternParts.Err message)])]
                      [(ResultAstExternAbi.Err message)
                        (ResultAstExternParts.Err message)]))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe-ref 256))
                  (if seen-symbol
                    (ResultAstExternParts.Err
                      "parse: duplicate extern :symbol metadata")
                    (match (parse-ast-extern-symbol-tail dispatch after-key)
                      [(ResultAstExternSymbol.Ok _ parsed-symbol-id)
                        (parse-ast-extern-head-post-ret
                          dispatch
                          pools
                          tail
                          abi
                          parsed-symbol-id
                          link-inputs
                          seen-abi
                          true
                          param-types
                          ret)]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)]))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe-ref 257))
                  (match (parse-ast-extern-string-tail
                    dispatch
                    ":link-lib"
                    after-key)
                    [(ResultAstExternSymbol.Ok value _)
                      (begin
                        (ast.ast-extern-link-input-list-push
                          link-inputs
                          (ast.AstExternLinkInput.Lib value))
                        (parse-ast-extern-head-post-ret
                          dispatch
                          pools
                          tail
                          abi
                          symbol-id
                          link-inputs
                          seen-abi
                          seen-symbol
                          param-types
                          ret))]
                    [(ResultAstExternSymbol.Err message)
                      (ResultAstExternParts.Err message)])]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe-ref 258))
                  (match (parse-ast-extern-string-tail
                    dispatch
                    ":link-search"
                    after-key)
                    [(ResultAstExternSymbol.Ok value _)
                      (begin
                        (ast.ast-extern-link-input-list-push
                          link-inputs
                          (ast.AstExternLinkInput.Search value))
                        (parse-ast-extern-head-post-ret
                          dispatch
                          pools
                          tail
                          abi
                          symbol-id
                          link-inputs
                          seen-abi
                          seen-symbol
                          param-types
                          ret))]
                    [(ResultAstExternSymbol.Err message)
                      (ResultAstExternParts.Err message)])]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe-ref 259))
                  (match (parse-ast-extern-string-tail
                    dispatch
                    ":link-arg"
                    after-key)
                    [(ResultAstExternSymbol.Ok value _)
                      (begin
                        (ast.ast-extern-link-input-list-push
                          link-inputs
                          (ast.AstExternLinkInput.Arg value))
                        (parse-ast-extern-head-post-ret
                          dispatch
                          pools
                          tail
                          abi
                          symbol-id
                          link-inputs
                          seen-abi
                          seen-symbol
                          param-types
                          ret))]
                    [(ResultAstExternSymbol.Err message)
                      (ResultAstExternParts.Err message)])]
                [(compiler-parse-metadata-key? dispatch key)
                  (ResultAstExternParts.Err
                    (str_cat.str-cat
                      "parse: unknown extern metadata "
                      (compiler-parse-dispatch-syntax-id-text dispatch key)))]
                [else (ResultAstExternParts.Err "parse: malformed extern")])]
            [_ (ResultAstExternParts.Err "parse: malformed extern")])]
        [_ (ResultAstExternParts.Err "parse: malformed extern")])]
    [_ (ResultAstExternParts.Err "parse: malformed extern")]))

(define (parse-ast-extern-head-rest
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [items : reader.SpannedSexpr]
  [abi : ast.AstExternAbi]
  [symbol-id : ci.InternId]
  [link-inputs : (&mut link-inputs ast.AstExternLinkInputList)]
  [seen-abi : bool]
  [seen-symbol : bool]
  [param-types : ast.AstTypeList]) : ResultAstExternParts
  (match (reader.spanned-sexpr-view items)
    [(reader.SpannedSexprView.Cons head tail _)
      (if (sexpr-colon? (reader.spanned-sexpr-form head))
        (match (reader.spanned-sexpr-view tail)
          [(reader.SpannedSexprView.Cons ret end _)
            (match (reader.spanned-sexpr-view end)
              [(reader.SpannedSexprView.Nil _)
                (match (parse-ast-type-spanned dispatch pools ret)
                  [(ResultAstType.Ok parsed-ret)
                    (parse-ast-extern-head-finish
                      pools
                      abi
                      symbol-id
                      seen-abi
                      param-types
                      parsed-ret)]
                  [(ResultAstType.Err message)
                    (ResultAstExternParts.Err message)])]
              [_
                (match (parse-ast-type-spanned dispatch pools ret)
                  [(ResultAstType.Ok parsed-ret)
                    (parse-ast-extern-head-post-ret
                      dispatch
                      pools
                      end
                      abi
                      symbol-id
                      link-inputs
                      seen-abi
                      seen-symbol
                      param-types
                      parsed-ret)]
                  [(ResultAstType.Err message)
                    (ResultAstExternParts.Err message)])])]
          [_ (ResultAstExternParts.Err "parse: malformed extern")])
        (match (reader.sexpr-view (reader.spanned-sexpr-form head))
          [(reader.SexprView.Cons key-node after-key)
            (match (reader.sexpr-view key-node)
              [(reader.SexprView.Sym key)
                (cond
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe-ref 255))
                    (if seen-abi
                      (ResultAstExternParts.Err
                        "parse: duplicate extern :abi metadata")
                      (match (parse-ast-extern-abi-tail dispatch after-key)
                        [(ResultAstExternAbi.Ok parsed-abi)
                          (match (parse-ast-extern-abi-combine abi parsed-abi)
                            [(ResultAstExternAbi.Ok combined-abi)
                              (parse-ast-extern-head-rest
                                dispatch
                                pools
                                tail
                                combined-abi
                                symbol-id
                                link-inputs
                                true
                                seen-symbol
                                param-types)]
                            [(ResultAstExternAbi.Err message)
                              (ResultAstExternParts.Err message)])]
                        [(ResultAstExternAbi.Err message)
                          (ResultAstExternParts.Err message)]))]
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe-ref 256))
                    (if seen-symbol
                      (ResultAstExternParts.Err
                        "parse: duplicate extern :symbol metadata")
                      (match (parse-ast-extern-symbol-tail dispatch after-key)
                        [(ResultAstExternSymbol.Ok _ parsed-symbol-id)
                          (parse-ast-extern-head-rest
                            dispatch
                            pools
                            tail
                            abi
                            parsed-symbol-id
                            link-inputs
                            seen-abi
                            true
                            param-types)]
                        [(ResultAstExternSymbol.Err message)
                          (ResultAstExternParts.Err message)]))]
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe-ref 257))
                    (match (parse-ast-extern-string-tail
                      dispatch
                      ":link-lib"
                      after-key)
                      [(ResultAstExternSymbol.Ok value _)
                        (begin
                          (ast.ast-extern-link-input-list-push
                            link-inputs
                            (ast.AstExternLinkInput.Lib value))
                          (parse-ast-extern-head-rest
                            dispatch
                            pools
                            tail
                            abi
                            symbol-id
                            link-inputs
                            seen-abi
                            seen-symbol
                            param-types))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe-ref 258))
                    (match (parse-ast-extern-string-tail
                      dispatch
                      ":link-search"
                      after-key)
                      [(ResultAstExternSymbol.Ok value _)
                        (begin
                          (ast.ast-extern-link-input-list-push
                            link-inputs
                            (ast.AstExternLinkInput.Search value))
                          (parse-ast-extern-head-rest
                            dispatch
                            pools
                            tail
                            abi
                            symbol-id
                            link-inputs
                            seen-abi
                            seen-symbol
                            param-types))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe-ref 259))
                    (match (parse-ast-extern-string-tail
                      dispatch
                      ":link-arg"
                      after-key)
                      [(ResultAstExternSymbol.Ok value _)
                        (begin
                          (ast.ast-extern-link-input-list-push
                            link-inputs
                            (ast.AstExternLinkInput.Arg value))
                          (parse-ast-extern-head-rest
                            dispatch
                            pools
                            tail
                            abi
                            symbol-id
                            link-inputs
                            seen-abi
                            seen-symbol
                            param-types))]
                      [(ResultAstExternSymbol.Err message)
                        (ResultAstExternParts.Err message)])]
                  [(compiler-parse-metadata-key? dispatch key)
                    (ResultAstExternParts.Err
                      (str_cat.str-cat
                        "parse: unknown extern metadata "
                        (compiler-parse-dispatch-syntax-id-text dispatch key)))]
                  [else
                    (ResultAstExternParts.Err "parse: expected ':' in extern")])]
              [_ (ResultAstExternParts.Err "parse: expected ':' in extern")])]
          [_ (ResultAstExternParts.Err "parse: expected ':' in extern")]))]
    [_ (ResultAstExternParts.Err "parse: malformed extern")]))

(define (parse-ast-extern-function-head
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [head : reader.SpannedSexpr]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (parse-ast-extern-header dispatch pools head)
    [(ResultAstExternHeader.Ok name param-types abi)
      (let
        [link-inputs : ast.AstExternLinkInputList
          (ast.ast-extern-link-input-list-new)]
        [source-symbol : ci.InternId
          (ci.intern-syntax-id-renderable (ci.intern-syntax-id-from-raw name))]
        (match (parse-ast-extern-head-rest
          dispatch
          pools
          rest
          abi
          source-symbol
          (&mut link-inputs)
          false
          false
          param-types)
          [(ResultAstExternParts.Ok parsed-abi parsed-symbol-id explicit-abi ty)
            (ResultAstDecl.Ok
              (ast.ast-decl-extern-id
                name
                (ast.AstExternKind.Function)
                (ast.AstExternMetadata.Metadata
                  parsed-abi
                  parsed-symbol-id
                  link-inputs
                  (ast.ast-extern-metadata-flags
                    explicit-abi
                    (ci.intern-id-eq? parsed-symbol-id source-symbol))
                  ast.AstImportedSpmdMetadata.No)
                ty))]
          [(ResultAstExternParts.Err message) (ResultAstDecl.Err message)]))]
    [(ResultAstExternHeader.Err message) (ResultAstDecl.Err message)]))

(define (parse-ast-extern
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons name-node after-name _)
      (match (reader.spanned-sexpr-view name-node)
        [(reader.SpannedSexprView.Sym name _)
          (let
            [name-id : i64 (ci.intern-syntax-id-value name)]
            [source-symbol : ci.InternId (ci.intern-syntax-id-renderable name)]
            [link-inputs : ast.AstExternLinkInputList
              (ast.ast-extern-link-input-list-new)]
            (match (parse-ast-extern-items
              dispatch
              pools
              after-name
              (ast.AstExternAbi.C)
              source-symbol
              (&mut link-inputs)
              false
              false)
              [(ResultAstExternParts.Ok
                  parsed-abi
                  parsed-symbol-id
                  explicit-abi
                  parsed-ty)
                (ResultAstDecl.Ok
                  (ast.ast-decl-extern-id
                    name-id
                    (ast.AstExternKind.Value)
                    (ast.AstExternMetadata.Metadata
                      parsed-abi
                      parsed-symbol-id
                      link-inputs
                      (ast.ast-extern-metadata-flags
                        explicit-abi
                        (ci.intern-id-eq? parsed-symbol-id source-symbol))
                      ast.AstImportedSpmdMetadata.No)
                    parsed-ty))]
              [(ResultAstExternParts.Err message) (ResultAstDecl.Err message)]))]
        [_ (parse-ast-extern-function-head dispatch pools name-node after-name)])]
    [_ (ResultAstDecl.Err "parse: malformed extern")]))

(define (parse-ast-defenum
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons name-node variants _)
      (match (reader.spanned-sexpr-view name-node)
        [(reader.SpannedSexprView.Sym name name-span)
          (let
            [name-id : i64 (ci.intern-syntax-id-value name)]
            [member-marker : i64
              (reader.sp-node-push
                (reader.SpannedSexpr.Int
                  0
                  "__tl_member_origin"
                  (reader.spanned-sexpr-span name-node)))]
            (begin
              (compiler-parse-semantic-origin-push-components!
                name
                name-span
                (CompilerParseSemanticOriginKind.ModulePath)
                (CompilerParseSemanticOriginKind.TypeDefinition))
              (match (parse-ast-defenum-items
                dispatch
                pools
                variants
                (ast.ast-lifetime-list-new)
                (ast.AstEnumCleanup.No)
                false
                false
                false)
                [(ResultAstEnumDefParts.Ok lifetimes cleanup parsed-variants)
                  (begin
                    (set!
                      (array-ref reader.sp-node-pool-slots member-marker)
                      (reader.SpannedSexpr.Int
                        (unsafe
                          (cast
                            (ptr->int
                              (ptr-cast
                                (__tl_array-data parsed-variants.slots)
                                : (Ptr u8)))
                            : i64))
                        "__tl_member_origin"
                        (reader.spanned-sexpr-span name-node)))
                    (if (ast.ast-variant-def-list-empty? (& parsed-variants))
                      (ResultAstDecl.Err
                        "parse: defenum needs at least one variant")
                      (if (ast.ast-lifetime-list-empty? (& lifetimes))
                        (ResultAstDecl.Ok
                          (ast.ast-decl-def-enum-id
                            name-id
                            cleanup
                            parsed-variants))
                        (ResultAstDecl.Ok
                          (ast.ast-decl-def-enum-lifetimes-id
                            name-id
                            lifetimes
                            cleanup
                            parsed-variants)))))]
                [(ResultAstEnumDefParts.Err message)
                  (ResultAstDecl.Err message)])))]
        [_ (ResultAstDecl.Err "parse: malformed defenum")])]
    [_ (ResultAstDecl.Err "parse: malformed defenum")]))

(define (parse-ast-defstruct
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons name-node fields _)
      (match (reader.spanned-sexpr-view name-node)
        [(reader.SpannedSexprView.Sym name name-span)
          (let
            [name-id : i64 (ci.intern-syntax-id-value name)]
            [member-marker : i64
              (reader.sp-node-push
                (reader.SpannedSexpr.Int
                  0
                  "__tl_member_origin"
                  (reader.spanned-sexpr-span name-node)))]
            (begin
              (compiler-parse-semantic-origin-push-components!
                name
                name-span
                (CompilerParseSemanticOriginKind.ModulePath)
                (CompilerParseSemanticOriginKind.TypeDefinition))
              (match (parse-ast-defstruct-items
                dispatch
                pools
                fields
                (ast.ast-lifetime-list-new)
                (ast.AstStructRepr.Default)
                (ast.AstStructCleanup.No)
                (ast.ast-field-def-list-new)
                false
                false
                false
                false)
                [(ResultAstStructDefParts.Ok
                    lifetimes
                    repr
                    cleanup
                    parsed-fields)
                  (begin
                    (set!
                      (array-ref reader.sp-node-pool-slots member-marker)
                      (reader.SpannedSexpr.Int
                        (unsafe
                          (cast
                            (ptr->int
                              (ptr-cast
                                (__tl_array-data parsed-fields.slots)
                                : (Ptr u8)))
                            : i64))
                        "__tl_member_origin"
                        (reader.spanned-sexpr-span name-node)))
                    (if (ast.ast-field-def-list-empty? (& parsed-fields))
                      (ResultAstDecl.Err
                        "parse: defstruct needs at least one field")
                      (if (ast.ast-lifetime-list-empty? (& lifetimes))
                        (ResultAstDecl.Ok
                          (ast.ast-decl-def-struct-id
                            name-id
                            repr
                            cleanup
                            parsed-fields))
                        (ResultAstDecl.Ok
                          (ast.ast-decl-def-struct-lifetimes-id
                            name-id
                            lifetimes
                            repr
                            cleanup
                            parsed-fields)))))]
                [(ResultAstStructDefParts.Err message)
                  (ResultAstDecl.Err message)])))]
        [_ (ResultAstDecl.Err "parse: malformed defstruct")])]
    [_ (ResultAstDecl.Err "parse: malformed defstruct")]))

(define (parse-ast-defdispatch
  [dispatch : sym_i64_env.SymI64Env]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons name-node variants _)
      (match (reader.spanned-sexpr-view name-node)
        [(reader.SpannedSexprView.Sym name _)
          (match (parse-ast-dispatch-variant-list dispatch variants)
            [(ResultAstDispatchVariantList.Ok parsed-variants)
              (if (ast.ast-dispatch-variant-list-empty? (& parsed-variants))
                (ResultAstDecl.Err
                  "parse: defdispatch needs at least one variant")
                (ResultAstDecl.Ok
                  (ast.ast-decl-def-dispatch-id
                    (ci.intern-syntax-id-value name)
                    parsed-variants)))]
            [(ResultAstDispatchVariantList.Err message)
              (ResultAstDecl.Err message)])]
        [_ (ResultAstDecl.Err "parse: malformed defdispatch")])]
    [_ (ResultAstDecl.Err "parse: malformed defdispatch")]))

(define (parse-ast-module-body-forms-into-vec
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [forms : reader.SpannedSexpr]
  [semantic-origins : (MutPtr ParseSemanticOriginVec)]
  [out : (&mut out ParseAstDeclVec)]) : ResultParseAstDeclVec
  (match (reader.spanned-sexpr-view forms)
    [(reader.SpannedSexprView.Nil _) (ResultParseAstDeclVec.Ok)]
    [(reader.SpannedSexprView.Cons form rest _)
      (let
        [semantic-start : i64 out.semantic-origins.len]
        (begin
          (compiler-parse-semantic-origin-capture-select!
            semantic-origins
            out.len)
          (match (parse-ast-decl-maybe-with-pools dispatch pools form)
            [(ResultAstMaybeDecl.SomeDecl decl)
              (begin
                (parse-ast-decl-vec-push-with-span
                  out
                  decl
                  (compiler-parse-decl-origin-syntax-span dispatch form))
                (parse-ast-module-body-forms-into-vec
                  dispatch
                  pools
                  rest
                  semantic-origins
                  out))]
            [(ResultAstMaybeDecl.Decls decls)
              (begin
                (set! out.semantic-origins.len semantic-start)
                (parse-ast-decl-vec-push-list! out decls)
                (parse-ast-module-body-forms-into-vec
                  dispatch
                  pools
                  rest
                  semantic-origins
                  out))]
            [(ResultAstMaybeDecl.NoDecl)
              (begin
                (set! out.semantic-origins.len semantic-start)
                (parse-ast-module-body-forms-into-vec
                  dispatch
                  pools
                  rest
                  semantic-origins
                  out))]
            [(ResultAstMaybeDecl.Err message)
              (begin
                (set! out.semantic-origins.len semantic-start)
                (ResultParseAstDeclVec.Err message))])))]
    [_ (ResultParseAstDeclVec.Err "parse: malformed module")]))

(define (parse-ast-module-body
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [name : i64]
  [body : reader.SpannedSexpr]) : ResultAstDecl
  (let
    [previous-capture : CompilerParseSemanticOriginCaptureState
      (compiler-parse-semantic-origin-capture-current)]
    [out : ParseAstDeclVec (parse-ast-decl-vec-new)]
    [result : ResultAstDecl
      (match (parse-ast-module-body-forms-into-vec
        dispatch
        pools
        body
        (unsafe
          (ptr-addr-of out.semantic-origins))
        (&mut out))
        [(ResultParseAstDeclVec.Ok)
          (ResultAstDecl.Ok
            (ast.ast-decl-module-body-id
              name
              (parse-ast-decl-vec-to-list (& out))))]
        [(ResultParseAstDeclVec.Err message) (ResultAstDecl.Err message)])]
    (begin
      (compiler-parse-semantic-origin-capture-restore! previous-capture)
      result)))

(define (parse-ast-module
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons name-node end _)
      (match (reader.spanned-sexpr-view name-node)
        [(reader.SpannedSexprView.Sym name span)
          (begin
            (compiler-parse-semantic-origin-push-components!
              name
              span
              (CompilerParseSemanticOriginKind.ModuleDefinition)
              (CompilerParseSemanticOriginKind.ModuleDefinition))
            (match (reader.spanned-sexpr-view end)
              [(reader.SpannedSexprView.Nil _)
                (ResultAstDecl.Ok
                  (ast.ast-decl-module-id (ci.intern-syntax-id-value name)))]
              [_
                (parse-ast-module-body
                  dispatch
                  pools
                  (ci.intern-syntax-id-value name)
                  end)]))]
        [_ (ResultAstDecl.Err "parse: malformed module")])]
    [_ (ResultAstDecl.Err "parse: malformed module")]))

(define (parse-ast-import-spec
  [kind : ast.AstImportKind]
  [path : String]
  [module-name : ast.AstMaybeModuleName]
  [alias : ast.AstMaybeImportAlias]
  [span : ast.AstSourceSpan]) : ResultAstDecl
  (ResultAstDecl.Ok
    (ast.AstDecl.Import
      (ast.ast-decl-meta-runtime-shared-view)
      (ast.AstImportSpec.Spec kind path module-name alias (box span)))))

(define (parse-ast-import-alias
  [kind : ast.AstImportKind]
  [path : String]
  [module-name : ast.AstMaybeModuleName]
  [tail : reader.SpannedSexpr]
  [span : ast.AstSourceSpan]) : ResultAstDecl
  (match (reader.spanned-sexpr-view tail)
    [(reader.SpannedSexprView.Cons as-node alias-tail _)
      (match (reader.spanned-sexpr-view as-node)
        [(reader.SpannedSexprView.Sym as-name _)
          (match (reader.spanned-sexpr-view alias-tail)
            [(reader.SpannedSexprView.Cons alias-node end _)
              (match (reader.spanned-sexpr-view end)
                [(reader.SpannedSexprView.Nil _)
                  (match (reader.spanned-sexpr-view alias-node)
                    [(reader.SpannedSexprView.Sym alias alias-span)
                      (if (=
                        (ci.intern-syntax-id-value as-name)
                        (cbi.compiler-builtin-ctfe-ref 260))
                        (begin
                          (compiler-parse-semantic-origin-push-components!
                            alias
                            alias-span
                            (CompilerParseSemanticOriginKind.ModulePath)
                            (CompilerParseSemanticOriginKind.ImportAlias))
                          (parse-ast-import-spec
                            kind
                            path
                            module-name
                            (ast.AstMaybeImportAlias.Some
                              (ci.intern-syntax-id-value alias))
                            span))
                        (ResultAstDecl.Err "parse: malformed import"))]
                    [_ (ResultAstDecl.Err "parse: malformed import")])]
                [_ (ResultAstDecl.Err "parse: malformed import")])]
            [_ (ResultAstDecl.Err "parse: malformed import")])]
        [_ (ResultAstDecl.Err "parse: malformed import")])]
    [_ (ResultAstDecl.Err "parse: malformed import")]))

(define (parse-ast-import-macro-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [call-form : reader.SpannedSexpr]
  [tail : reader.SpannedSexpr]
  [span : ast.AstSourceSpan]) : ResultAstDecl
  (match (parse-ast-expr-with-pools dispatch pools call-form)
    [(ResultAstExpr.Ok call-expr)
      (match (ast.ast-expr-unspan-with-pools
        pools
        (ast.ast-node-pool-context-expr-get pools call-expr))
        [(ast.AstExpr.Call _ _)
          (match (reader.spanned-sexpr-view tail)
            [(reader.SpannedSexprView.Nil _)
              (parse-ast-import-spec
                (ast.AstImportKind.Macro call-expr ast.AstMaybeModuleName.No)
                ""
                ast.AstMaybeModuleName.No
                ast.AstMaybeImportAlias.No
                span)]
            [(reader.SpannedSexprView.Cons head-node _ _)
              (match (reader.spanned-sexpr-view head-node)
                [(reader.SpannedSexprView.Sym head _)
                  (if (=
                    (ci.intern-syntax-id-value head)
                    (cbi.compiler-builtin-ctfe-ref 260))
                    (parse-ast-import-alias
                      (ast.AstImportKind.Macro
                        call-expr
                        ast.AstMaybeModuleName.No)
                      ""
                      ast.AstMaybeModuleName.No
                      tail
                      span)
                    (ResultAstDecl.Err "parse: malformed import"))]
                [_ (ResultAstDecl.Err "parse: malformed import")])]
            [_ (ResultAstDecl.Err "parse: malformed import")])]
        [_ (ResultAstDecl.Err "parse: import macro operand must be a call")])]
    [(ResultAstExpr.Err message) (ResultAstDecl.Err message)]))

(define (parse-ast-dotted-import-tl-suffix? [name : String]) : bool
  (let
    [n : i64 (string.string-length name)]
    (if (< n 3)
      false
      (string.eq (string.substring name (- n 3) 3) ".tl"))))

(define (parse-ast-dotted-import-name-valid? [name : String]) : bool
  (let
    [n : i64 (string.string-length name)]
    [i : i64 0]
    [ok : bool (and (> n 0) (not (parse-ast-dotted-import-tl-suffix? name)))]
    [last-was-dot : bool true]
    (begin
      (while ok
        (if (< i n)
          (let
            [c : char (string.string-ref name i)]
            (if (or
              (string.char-eq c '/')
              (string.char-eq c '\\')
              (string.char-eq c ':'))
              (set! ok false)
              (if (string.char-eq c '.')
                (if last-was-dot
                  (set! ok false)
                  (begin
                    (set! last-was-dot true)
                    (set! i (+ i 1))))
                (begin
                  (set! last-was-dot false)
                  (set! i (+ i 1))))))
          (set! ok false)))
      (and (= i n) (not last-was-dot)))))

(define (parse-ast-dotted-import-default-alias-start [name : String]) : i64
  (let
    [n : i64 (string.string-length name)]
    [i : i64 0]
    [start : i64 0]
    (begin
      (while (< i n)
        (begin
          (if (string.char-eq (string.string-ref name i) '.')
            (set! start (+ i 1))
            unit)
          (set! i (+ i 1))))
      start)))

(define (parse-ast-dotted-import-default-alias [name : String]) : String
  (let
    [start : i64 (parse-ast-dotted-import-default-alias-start name)]
    (string.substring name start (- (string.string-length name) start))))

(define (parse-ast-dotted-import-default-alias-id-with-state
  [intern-state : ci.InternCompatState]
  [name-id : i64]) : i64
  (ci.intern-compat-state-dotted-final-id intern-state name-id))

(define (parse-ast-dotted-import-wildcard? [name : String]) : bool
  (let
    [n : i64 (string.string-length name)]
    (and (>= n 2) (string.eq (string.substring name (- n 2) 2) ".*"))))

(define (compiler-parse-semantic-import-path-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [module-name : ci.InternSyntaxId]
  [span : token.SourceSpan]) : unit
  (let
    [intern-state : ci.InternCompatState
      (compiler-parse-dispatch-intern-state dispatch)]
    [text : String
      (ci.intern-compat-state-syntax-id-text intern-state module-name)]
    [wildcard : bool (parse-ast-dotted-import-wildcard? text)]
    (begin
      (if wildcard
        (compiler-parse-semantic-origin-push-components!
          (ci.intern-syntax-id-from-raw
            (ci.intern-compat-state-dotted-prefix-id
              intern-state
              (ci.intern-syntax-id-value module-name)))
          (token.SourceSpan
            (token.span-start-line span)
            (token.span-start-col span)
            (token.span-end-line span)
            (- (token.span-end-col span) 2))
          (CompilerParseSemanticOriginKind.ModulePath)
          (CompilerParseSemanticOriginKind.ModulePath))
        (compiler-parse-semantic-origin-push-components!
          module-name
          span
          (CompilerParseSemanticOriginKind.ModulePath)
          (CompilerParseSemanticOriginKind.ModulePath)))
      unit)))

(define (compiler-parse-semantic-default-import-alias-origin!
  [dispatch : sym_i64_env.SymI64Env]
  [module-name : ci.InternSyntaxId]
  [span : token.SourceSpan]) : unit
  (let
    [intern-state : ci.InternCompatState
      (compiler-parse-dispatch-intern-state dispatch)]
    [text : String
      (ci.intern-compat-state-syntax-id-text intern-state module-name)]
    [start-line : i64 (token.span-start-line span)]
    [start-col : i64 (token.span-start-col span)]
    [end-line : i64 (token.span-end-line span)]
    (if (parse-ast-dotted-import-wildcard? text)
      unit
      (let
        [start : i64 (parse-ast-dotted-import-default-alias-start text)]
        [n : i64 (string.string-length text)]
        (compiler-parse-semantic-origin-push!
          (CompilerParseSemanticOriginKind.ImportAlias)
          (ci.intern-id-value
            (ci.intern-compat-state-source-slice-id
              intern-state
              text
              start
              (- n start)))
          (token.SourceSpan
            start-line
            (+ start-col start)
            end-line
            (+ start-col n)))))))

(define (parse-ast-dotted-import-tail
  [dispatch : sym_i64_env.SymI64Env]
  [module-name-id : i64]
  [tail : reader.SpannedSexpr]
  [span : ast.AstSourceSpan]) : ResultAstDecl
  (let
    [intern-state : ci.InternCompatState
      (compiler-parse-dispatch-intern-state dispatch)]
    [module-name : String
      (compiler-parse-name-text-with-state intern-state module-name-id)]
    (if (not (parse-ast-dotted-import-name-valid? module-name))
      (ResultAstDecl.Err "parse: invalid dotted import module name")
      (if (parse-ast-dotted-import-wildcard? module-name)
        (match (reader.spanned-sexpr-view tail)
          [(reader.SpannedSexprView.Nil _)
            (let
              [target-id : i64
                (ci.intern-compat-state-dotted-prefix-id
                  intern-state
                  module-name-id)]
              (parse-ast-import-spec
                (ast.AstImportKind.ModuleAll)
                (ci.intern-compat-state-syntax-name-text-or
                  intern-state
                  target-id
                  "")
                (ast.AstMaybeModuleName.Some target-id)
                (ast.AstMaybeImportAlias.Some cbi.compiler-builtin-id-fix-empty)
                span))]
          [_
            (ResultAstDecl.Err
              "parse: wildcard import cannot use as; import a selected item instead")])
        (match (reader.spanned-sexpr-view tail)
          [(reader.SpannedSexprView.Nil _)
            (parse-ast-import-spec
              (ast.AstImportKind.Module)
              module-name
              (ast.AstMaybeModuleName.Some module-name-id)
              (ast.AstMaybeImportAlias.Some
                (parse-ast-dotted-import-default-alias-id-with-state
                  intern-state
                  module-name-id))
              span)]
          [(reader.SpannedSexprView.Cons head-node _ _)
            (match (reader.spanned-sexpr-view head-node)
              [(reader.SpannedSexprView.Sym head _)
                (if (=
                  (ci.intern-syntax-id-value head)
                  (cbi.compiler-builtin-ctfe-ref 260))
                  (parse-ast-import-alias
                    (ast.AstImportKind.Module)
                    module-name
                    (ast.AstMaybeModuleName.Some module-name-id)
                    tail
                    span)
                  (ResultAstDecl.Err "parse: malformed import"))]
              [_ (ResultAstDecl.Err "parse: malformed import")])]
          [_ (ResultAstDecl.Err "parse: malformed import")])))))

(define (parse-ast-import
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [span : ast.AstSourceSpan]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons path-node tail _)
      (match (reader.spanned-sexpr-view path-node)
        [(reader.SpannedSexprView.Str _ _)
          (ResultAstDecl.Err
            "parse: string-path imports are no longer supported; use a dotted module identity")]
        [(reader.SpannedSexprView.Sym module-name module-span)
          (let
            [module-start-line : i64 module-span.start-line]
            [module-start-col : i64 module-span.start-col]
            [module-end-line : i64 module-span.end-line]
            [module-end-col : i64 module-span.end-col]
            (begin
              (compiler-parse-semantic-import-path-origins!
                dispatch
                module-name
                (token.SourceSpan
                  module-start-line
                  module-start-col
                  module-end-line
                  module-end-col))
              (let
                [result : ResultAstDecl
                  (parse-ast-dotted-import-tail
                    dispatch
                    (ci.intern-syntax-id-value module-name)
                    tail
                    span)]
                (match result
                  [(ResultAstDecl.Ok _)
                    (begin
                      (match (reader.spanned-sexpr-view tail)
                        [(reader.SpannedSexprView.Nil _)
                          (compiler-parse-semantic-default-import-alias-origin!
                            dispatch
                            module-name
                            (token.SourceSpan
                              module-start-line
                              module-start-col
                              module-end-line
                              module-end-col))]
                        [_ unit])
                      result)]
                  [(ResultAstDecl.Err _) result]))))]
        [(reader.SpannedSexprView.Cons _ _ _)
          (parse-ast-import-macro-tail dispatch pools path-node tail span)]
        [_ (ResultAstDecl.Err "parse: malformed import")])]
    [_ (ResultAstDecl.Err "parse: malformed import")]))

(define (parse-ast-include-str
  [dispatch : sym_i64_env.SymI64Env]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Nil _)
      (ResultAstDecl.Err "parse: include-str expects name and string path")]
    [(reader.SpannedSexprView.Cons name-node tail _)
      (match (reader.spanned-sexpr-view name-node)
        [(reader.SpannedSexprView.Sym name _)
          (match (reader.spanned-sexpr-view tail)
            [(reader.SpannedSexprView.Cons path-node after-path _)
              (match (reader.spanned-sexpr-view path-node)
                [(reader.SpannedSexprView.Str path-id _)
                  (match (reader.spanned-sexpr-view after-path)
                    [(reader.SpannedSexprView.Nil _)
                      (ResultAstDecl.Ok
                        (ast.AstDecl.IncludeStr
                          (ci.intern-syntax-id-value name)
                          (compiler-parse-dispatch-id-str dispatch path-id)))]
                    [_
                      (ResultAstDecl.Err
                        "parse: include-str expects exactly two operands")])]
                [_
                  (ResultAstDecl.Err "parse: include-str path must be a string")])]
            [(reader.SpannedSexprView.Nil _)
              (ResultAstDecl.Err
                "parse: include-str expects name and string path")]
            [_
              (ResultAstDecl.Err
                "parse: include-str expects exactly two operands")])]
        [_ (ResultAstDecl.Err "parse: include-str name must be a symbol")])]
    [_ (ResultAstDecl.Err "parse: malformed include-str")]))

(define (parse-ast-include-str-comptime
  [dispatch : sym_i64_env.SymI64Env]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Nil _)
      (ResultAstDecl.Err
        "parse: include-str-comptime expects name and string path")]
    [(reader.SpannedSexprView.Cons name-node tail _)
      (match (reader.spanned-sexpr-view name-node)
        [(reader.SpannedSexprView.Sym name _)
          (match (reader.spanned-sexpr-view tail)
            [(reader.SpannedSexprView.Cons path-node after-path _)
              (match (reader.spanned-sexpr-view path-node)
                [(reader.SpannedSexprView.Str path-id _)
                  (match (reader.spanned-sexpr-view after-path)
                    [(reader.SpannedSexprView.Nil _)
                      (ResultAstDecl.Ok
                        (ast.AstDecl.IncludeStrComptime
                          (ci.intern-syntax-id-value name)
                          (compiler-parse-dispatch-id-str dispatch path-id)))]
                    [_
                      (ResultAstDecl.Err
                        "parse: include-str-comptime expects exactly two operands")])]
                [_
                  (ResultAstDecl.Err
                    "parse: include-str-comptime path must be a string")])]
            [(reader.SpannedSexprView.Nil _)
              (ResultAstDecl.Err
                "parse: include-str-comptime expects name and string path")]
            [_
              (ResultAstDecl.Err
                "parse: include-str-comptime expects exactly two operands")])]
        [_
          (ResultAstDecl.Err
            "parse: include-str-comptime name must be a symbol")])]
    [_ (ResultAstDecl.Err "parse: malformed include-str-comptime")]))

(define (parse-ast-include-str-lzss
  [dispatch : sym_i64_env.SymI64Env]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Nil _)
      (ResultAstDecl.Err "parse: include-str-lzss expects name and string path")]
    [(reader.SpannedSexprView.Cons name-node tail _)
      (match (reader.spanned-sexpr-view name-node)
        [(reader.SpannedSexprView.Sym name _)
          (match (reader.spanned-sexpr-view tail)
            [(reader.SpannedSexprView.Cons path-node end _)
              (match (reader.spanned-sexpr-view path-node)
                [(reader.SpannedSexprView.Str path _)
                  (match (reader.spanned-sexpr-view end)
                    [(reader.SpannedSexprView.Nil _)
                      (ResultAstDecl.Ok
                        (ast.AstDecl.IncludeStrLzss
                          (ci.intern-syntax-id-value name)
                          (compiler-parse-dispatch-id-str dispatch path)))]
                    [_
                      (ResultAstDecl.Err
                        "parse: include-str-lzss expects exactly two operands")])]
                [_
                  (ResultAstDecl.Err
                    "parse: include-str-lzss path must be a string")])]
            [(reader.SpannedSexprView.Nil _)
              (ResultAstDecl.Err
                "parse: include-str-lzss expects name and string path")]
            [_
              (ResultAstDecl.Err
                "parse: include-str-lzss expects exactly two operands")])]
        [_ (ResultAstDecl.Err "parse: include-str-lzss name must be a symbol")])]
    [_ (ResultAstDecl.Err "parse: malformed include-str-lzss")]))

(define (parse-ast-include-bin
  [dispatch : sym_i64_env.SymI64Env]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Nil _)
      (ResultAstDecl.Err "parse: include-bin expects name and string path")]
    [(reader.SpannedSexprView.Cons name-node tail _)
      (match (reader.spanned-sexpr-view name-node)
        [(reader.SpannedSexprView.Sym name _)
          (match (reader.spanned-sexpr-view tail)
            [(reader.SpannedSexprView.Cons path-node after-path _)
              (match (reader.spanned-sexpr-view path-node)
                [(reader.SpannedSexprView.Str path-id _)
                  (match (reader.spanned-sexpr-view after-path)
                    [(reader.SpannedSexprView.Nil _)
                      (ResultAstDecl.Ok
                        (ast.AstDecl.IncludeBin
                          (ci.intern-syntax-id-value name)
                          (compiler-parse-dispatch-id-str dispatch path-id)))]
                    [_
                      (ResultAstDecl.Err
                        "parse: include-bin expects exactly two operands")])]
                [_
                  (ResultAstDecl.Err "parse: include-bin path must be a string")])]
            [(reader.SpannedSexprView.Nil _)
              (ResultAstDecl.Err
                "parse: include-bin expects name and string path")]
            [_
              (ResultAstDecl.Err
                "parse: include-bin expects exactly two operands")])]
        [_ (ResultAstDecl.Err "parse: include-bin name must be a symbol")])]
    [_ (ResultAstDecl.Err "parse: malformed include-bin")]))

(define (parse-ast-test-body
  [pools : ast.AstNodePoolContext]
  [exprs : ast.AstExprList]) : i64
  (if (= exprs.len 1)
    (ast.ast-expr-list-get (& exprs) 0 0)
    (ast.ast-node-pool-context-expr-push pools (ast.AstExpr.Begin exprs))))

(define (parse-ast-test
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [form-span : ast.AstSourceSpan]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons name-node body-forms _)
      (match (reader.spanned-sexpr-view name-node)
        [(reader.SpannedSexprView.Sym name _)
          (match (reader.spanned-sexpr-view body-forms)
            [(reader.SpannedSexprView.Nil _)
              (ResultAstDecl.Err "parse: test needs at least one expression")]
            [_
              (match (parse-ast-expr-list dispatch pools body-forms)
                [(ResultAstExprList.Ok exprs)
                  (ResultAstDecl.Ok
                    (ast.ast-decl-test-id
                      (ci.intern-syntax-id-value name)
                      (parse-ast-test-body pools exprs)
                      form-span))]
                [(ResultAstExprList.Err message) (ResultAstDecl.Err message)])])]
        [_ (ResultAstDecl.Err "parse: malformed test")])]
    [_ (ResultAstDecl.Err "parse: malformed test")]))

(define (parse-ast-removed-declaration-message) : String
  "parse: comptime-decl and comptime-decls are removed; use defmacro with Module or Decls return type instead")

(define (parse-ast-removed-declaration-name?
  [dispatch : sym_i64_env.SymI64Env]
  [name : i64]) : bool
  ;; Preserve the shared diagnostic for the retired prefix family
  ;; comptime-decl/comptime-decls without interning more accepted syntax.
  ;; Structural AST identities are intentionally valid unknown call heads, but
  ;; they are not source-pool indexes and cannot match this textual family.
  (if (or (< name 0) (>= name (ci.intern-capacity)))
    false
    (let
      [text : String (compiler-parse-dispatch-name-text dispatch name)]
      [n : i64 (string.string-length text)]
      (and
        (or (= n 13) (= n 14))
        (= (string.string-ref text 0) 'c')
        (= (string.string-ref text 1) 'o')
        (= (string.string-ref text 2) 'm')
        (= (string.string-ref text 3) 'p')
        (= (string.string-ref text 4) 't')
        (= (string.string-ref text 5) 'i')
        (= (string.string-ref text 6) 'm')
        (= (string.string-ref text 7) 'e')
        (= (string.string-ref text 8) '-')
        (= (string.string-ref text 9) 'd')
        (= (string.string-ref text 10) 'e')
        (= (string.string-ref text 11) 'c')
        (= (string.string-ref text 12) 'l')
        (if (= n 14)
          (= (string.string-ref text 13) 's')
          true)))))

(define (parse-ast-unsafe-decl
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(reader.SpannedSexprView.Cons inner end _)
      (match (reader.spanned-sexpr-view end)
        [(reader.SpannedSexprView.Nil _)
          (match (parse-ast-decl dispatch pools inner)
            [(ResultAstDecl.Ok decl)
              (match decl
                [(ast.AstDecl.DefFn decl-meta _ _ _ _ _)
                  (ResultAstDecl.Ok (ast.ast-decl-unsafe decl))]
                [(ast.AstDecl.Extern decl-meta _ _ _ _)
                  (ResultAstDecl.Ok (ast.ast-decl-unsafe decl))]
                [_
                  (ResultAstDecl.Err
                    "parse: unsafe declaration accepts only function define or extern")])]
            [(ResultAstDecl.Err message) (ResultAstDecl.Err message)])]
        [_
          (ResultAstDecl.Err
            "parse: unsafe declaration expects exactly one declaration")])]
    [_
      (ResultAstDecl.Err
        "parse: unsafe declaration expects exactly one declaration")]))

(define (parse-ast-module-macro-call
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [form : reader.SpannedSexpr]) : ResultAstDecl
  (match (parse-ast-expr-with-pools dispatch pools form)
    [(ResultAstExpr.Ok call-expr)
      (match (ast.ast-expr-unspan-with-pools
        pools
        (ast.ast-node-pool-context-expr-get pools call-expr))
        [(ast.AstExpr.Call _ _)
          (parse-ast-import-spec
            (ast.AstImportKind.MacroDecls call-expr ast.AstMaybeModuleName.No)
            ""
            ast.AstMaybeModuleName.No
            ast.AstMaybeImportAlias.No
            (ast-source-span-from-source-span (reader.spanned-sexpr-span form)))]
        [_ (ResultAstDecl.Err "parse: expected declaration")])]
    [(ResultAstExpr.Err message) (ResultAstDecl.Err message)]))

(define (parse-ast-decl
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstDecl
  (let
    [result : ResultAstDecl
      (match (reader.spanned-sexpr-view s)
        [(reader.SpannedSexprView.Cons head-node rest _)
          (match (reader.spanned-sexpr-view head-node)
            [(reader.SpannedSexprView.Sym head _)
              (let
                [tag : i64
                  (compiler-parse-dispatch-tag
                    dispatch
                    (ci.intern-syntax-id-value head))]
                (cond
                  [(= tag (compiler-parse-tag-decl-define))
                    (parse-ast-define dispatch pools rest)]
                  [(= tag (compiler-parse-tag-decl-extern))
                    (parse-ast-extern dispatch pools rest)]
                  [(= tag (compiler-parse-tag-decl-defenum))
                    (parse-ast-defenum dispatch pools rest)]
                  [(= tag (compiler-parse-tag-decl-defstruct))
                    (parse-ast-defstruct dispatch pools rest)]
                  [(= tag (compiler-parse-tag-decl-defdispatch))
                    (parse-ast-defdispatch dispatch rest)]
                  [(= tag (compiler-parse-tag-decl-defmacro))
                    (parse-ast-defmacro dispatch pools rest)]
                  [(= tag (compiler-parse-tag-decl-import))
                    (parse-ast-import
                      dispatch
                      pools
                      rest
                      (ast-source-span-from-source-span
                        (reader.spanned-sexpr-span s)))]
                  [(= tag (compiler-parse-tag-decl-include-str))
                    (parse-ast-include-str dispatch rest)]
                  [(= tag (compiler-parse-tag-decl-include-str-comptime))
                    (parse-ast-include-str-comptime dispatch rest)]
                  [(= tag (compiler-parse-tag-decl-include-str-lzss))
                    (parse-ast-include-str-lzss dispatch rest)]
                  [(= tag (compiler-parse-tag-decl-removed-compressed-include))
                    (ResultAstDecl.Err
                      (compiler-parse-removed-compressed-include-message))]
                  [(= tag (compiler-parse-tag-decl-include-bin))
                    (parse-ast-include-bin dispatch rest)]
                  [(= tag (compiler-parse-tag-decl-module))
                    (parse-ast-module dispatch pools rest)]
                  [(parse-ast-removed-declaration-name?
                      dispatch
                      (ci.intern-syntax-id-value head))
                    (ResultAstDecl.Err (parse-ast-removed-declaration-message))]
                  [(= tag (compiler-parse-tag-expr-unsafe))
                    (parse-ast-unsafe-decl dispatch pools rest)]
                  [(= tag (compiler-parse-tag-decl-test))
                    (parse-ast-test
                      dispatch
                      pools
                      rest
                      (ast-source-span-from-source-span
                        (reader.spanned-sexpr-span s)))]
                  [(compiler-parse-policy-form?
                      (ci.intern-syntax-id-value head))
                    (ResultAstDecl.Err
                      (compiler-parse-abstraction-policy-message))]
                  [else (parse-ast-module-macro-call dispatch pools s)]))]
            [_ (ResultAstDecl.Err "parse: malformed declaration")])]
        [_ (ResultAstDecl.Err "parse: malformed declaration")])]
    (parse-ast-error-span-note-decl dispatch s result)))

(define (parse-ast-decl-maybe-with-pools
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstMaybeDecl
  (let
    [result : ResultAstMaybeDecl
      (match (reader.spanned-sexpr-view s)
        [(reader.SpannedSexprView.Cons head-node rest _)
          (match (reader.spanned-sexpr-view head-node)
            [(reader.SpannedSexprView.Sym head _)
              (if (=
                (ci.intern-syntax-id-value head)
                (cbi.compiler-builtin-ctfe-ref 243))
                (match (reader.spanned-sexpr-view rest)
                  [(reader.SpannedSexprView.Cons pred decl-tail _)
                    (match (reader.spanned-sexpr-view decl-tail)
                      [(reader.SpannedSexprView.Cons decl-form end _)
                        (match (reader.spanned-sexpr-view end)
                          [(reader.SpannedSexprView.Nil _)
                            (match (compiler-cfg-eval dispatch pred)
                              [(ResultCompilerCfg.Ok enabled)
                                (if enabled
                                  (parse-ast-decl-maybe-with-pools
                                    dispatch
                                    pools
                                    decl-form)
                                  (ResultAstMaybeDecl.NoDecl))]
                              [(ResultCompilerCfg.Err message)
                                (ResultAstMaybeDecl.Err message)])]
                          [_
                            (ResultAstMaybeDecl.Err
                              "parse: cfg declaration expects predicate and declaration")])]
                      [_
                        (ResultAstMaybeDecl.Err
                          "parse: cfg declaration expects predicate and declaration")])]
                  [_
                    (ResultAstMaybeDecl.Err
                      "parse: cfg declaration expects predicate and declaration")])
                (match (parse-ast-decl dispatch pools s)
                  [(ResultAstDecl.Ok decl) (ResultAstMaybeDecl.SomeDecl decl)]
                  [(ResultAstDecl.Err message) (ResultAstMaybeDecl.Err message)]))]
            [_
              (match (parse-ast-decl dispatch pools s)
                [(ResultAstDecl.Ok decl) (ResultAstMaybeDecl.SomeDecl decl)]
                [(ResultAstDecl.Err message) (ResultAstMaybeDecl.Err message)])])]
        [_ (ResultAstMaybeDecl.Err "parse: malformed declaration")])]
    (parse-ast-error-span-note-maybe-decl dispatch s result)))

(define (parse-ast-decl-maybe
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]) : ResultAstMaybeDecl
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultAstMaybeDecl
      (parse-ast-decl-maybe-with-pools dispatch pools s)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      result)))

(defstruct ParseAstDeclVec
  (slots (__tl_dyn-array ast.AstDecl))
  (spans (__tl_dyn-array ast.AstSourceSpan))
  (semantic-origins ParseSemanticOriginVec)
  (len i64))

(define (parse-ast-decl-vec-fallback) : ast.AstDecl
  (ast.AstDecl.Module
    cbi.compiler-builtin-id-fix-lt_parse_ast_decl_vec_fallback_gt))

(define (parse-ast-decl-vec-with-capacity [capacity : i64]) : ParseAstDeclVec
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (ParseAstDeclVec
      (__tl_make-array ast.AstDecl cap)
      (__tl_make-array ast.AstSourceSpan cap)
      (parse-semantic-origin-vec-with-capacity (* cap 8))
      0)))

(define (parse-ast-decl-vec-new) : ParseAstDeclVec
  (parse-ast-decl-vec-with-capacity 16))

(define (parse-ast-decl-vec-len [v : (& v ParseAstDeclVec)]) : i64
  v.len)

(define (parse-ast-decl-vec-get
  [v : (& v ParseAstDeclVec)]
  [index : i64]
  [fallback : ast.AstDecl]) : ast.AstDecl
  (if (and (>= index 0) (< index (parse-ast-decl-vec-len v)))
    (array-ref v.slots index)
    fallback))

(define (parse-ast-decl-vec-copy-range
  [dst : (&mut dst (__tl_dyn-array ast.AstDecl))]
  [src : (& src (__tl_dyn-array ast.AstDecl))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref dst index) (array-ref src index))
      (parse-ast-decl-vec-copy-range dst src (+ index 1) count))))

(define (parse-ast-decl-vec-span-copy-range
  [dst : (&mut dst (__tl_dyn-array ast.AstSourceSpan))]
  [src : (& src (__tl_dyn-array ast.AstSourceSpan))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref dst index) (array-ref src index))
      (parse-ast-decl-vec-span-copy-range dst src (+ index 1) count))))

(define (parse-ast-decl-vec-grow [v : (&mut v ParseAstDeclVec)]) : unit
  (let
    [n : i64 v.len]
    [old-cap : i64 (array-length v.slots)]
    [new-cap : i64
      (if (< old-cap 1)
        1
        (* old-cap 2))]
    [bigger : (__tl_dyn-array ast.AstDecl)
      (__tl_make-array ast.AstDecl new-cap)]
    [bigger-spans : (__tl_dyn-array ast.AstSourceSpan)
      (__tl_make-array ast.AstSourceSpan new-cap)]
    (begin
      (parse-ast-decl-vec-copy-range (&mut bigger) (& v.slots) 0 n)
      (parse-ast-decl-vec-span-copy-range (&mut bigger-spans) (& v.spans) 0 n)
      (set! v.slots bigger)
      (set! v.spans bigger-spans))))

(define (parse-ast-decl-vec-push-with-span
  [v : (&mut v ParseAstDeclVec)]
  [value : ast.AstDecl]
  [span : ast.AstSourceSpan]) : unit
  (begin
    (if (< v.len (array-length v.slots))
      unit
      (parse-ast-decl-vec-grow v))
    (let
      [index : i64 v.len]
      (begin
        (set! (array-ref v.slots index) value)
        (set! (array-ref v.spans index) span)
        (set! v.len (+ index 1))))))

(define (parse-ast-decl-vec-push
  [v : (&mut v ParseAstDeclVec)]
  [value : ast.AstDecl]) : unit
  (parse-ast-decl-vec-push-with-span v value (ast.ast-decl-span-fallback)))

(define (parse-ast-decl-vec-push-list!
  [out : (&mut out ParseAstDeclVec)]
  [decls : ast.AstDeclList]) : unit
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) unit]
    [(ast.AstDeclListStep.Cons head rest)
      (begin
        (parse-ast-decl-vec-push out head)
        (parse-ast-decl-vec-push-list! out rest))]))

(define (parse-ast-decl-vec-copy-to-list
  [items : (& items ParseAstDeclVec)]
  [index : i64]
  [out : (&mut out ast.AstDeclList)]) : unit
  (if (>= index (parse-ast-decl-vec-len items))
    unit
    (begin
      (ast.ast-decl-list-push
        out
        (parse-ast-decl-vec-get items index (parse-ast-decl-vec-fallback)))
      (parse-ast-decl-vec-copy-to-list items (+ index 1) out))))

(define (compiler-parse-decl-origin-needs-record? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Def decl-meta _ _ _) false]
    [(ast.AstDecl.DefFn decl-meta _ _ _ _ _) false]
    [(ast.AstDecl.DefMacro decl-meta _ _ _ _) false]
    [(ast.AstDecl.Test _ _ _) false]
    [(ast.AstDecl.Unsafe inner-box)
      (compiler-parse-decl-origin-needs-record? (__tl-box-place inner-box))]
    [_ true]))

(define (compiler-parse-decl-origin-register-selected!
  [items : (& items ParseAstDeclVec)]
  [out : (& out ast.AstDeclList)]) : unit
  (let
    [index : i64 0]
    (while (< index (parse-ast-decl-vec-len items))
      (begin
        (if (compiler-parse-decl-origin-needs-record?
          (parse-ast-decl-vec-get items index (parse-ast-decl-vec-fallback)))
          (let
            [span : ast.AstSourceSpan (array-ref items.spans index)]
            (compiler-parse-decl-origin-register-maybe!
              out
              index
              (CompilerParseMaybeDeclSpan.Some
                (ast.AstSourceSpan
                  span.start-line
                  span.start-col
                  span.end-line
                  span.end-col))))
          unit)
        (set! index (+ index 1))))))

(define (compiler-parse-semantic-origin-register-run!
  [decls : (& decls ast.AstDeclList)]
  [slot : i64]
  [origins : (& origins ParseSemanticOriginVec)]
  [start : i64]
  [count : i64]) : unit
  (if (<= count 0)
    unit
    (let
      [first : ParseSemanticOriginRecord (array-ref origins.items start)]
      [marker-span : token.SourceSpan
        (token.SourceSpan
          first.start-line
          first.start-col
          first.end-line
          first.end-col)]
      [run-start : i64 (reader.sp-node-pool-reserve! (+ count 2))]
      [index : i64 0]
      (begin
        (set!
          (array-ref reader.sp-node-pool-slots run-start)
          (reader.SpannedSexpr.Int
            (compiler-parse-decl-list-storage-key decls)
            "__tl_semantic_origin"
            marker-span))
        (set!
          (array-ref reader.sp-node-pool-slots (+ run-start 1))
          (reader.SpannedSexpr.Int
            (+ decls.offset slot)
            "__tl_semantic_origin_start"
            (token.SourceSpan count 0 0 0)))
        (while (< index count)
          (let
            [origin : ParseSemanticOriginRecord
              (array-ref origins.items (+ start index))]
            (begin
              (set!
                (array-ref reader.sp-node-pool-slots (+ (+ run-start 2) index))
                (reader.SpannedSexpr.Int
                  origin.written-name
                  (compiler-parse-semantic-origin-kind-marker
                    (compiler-parse-semantic-origin-kind-from-tag
                      origin.kind-tag))
                  (token.SourceSpan
                    origin.start-line
                    origin.start-col
                    origin.end-line
                    origin.end-col)))
              (set! index (+ index 1)))))))))

(define (compiler-parse-semantic-origin-register-selected!
  [items : (& items ParseAstDeclVec)]
  [out : (& out ast.AstDeclList)]) : unit
  (let
    [start : i64 0]
    [total : i64 items.semantic-origins.len]
    (while (< start total)
      (let
        [first : ParseSemanticOriginRecord
          (array-ref items.semantic-origins.items start)]
        [count : i64 1]
        (begin
          (while (and
            (< (+ start count) total)
            (=
              (array-ref items.semantic-origins.items (+ start count)).decl-slot
              first.decl-slot))
            (set! count (+ count 1)))
          (compiler-parse-semantic-origin-register-run!
            out
            first.decl-slot
            (& items.semantic-origins)
            start
            count)
          (set! start (+ start count)))))))

(define (parse-ast-decl-vec-to-list [items : (& items ParseAstDeclVec)]) : ast.AstDeclList
  (let
    [out : ast.AstDeclList
      (ast.ast-decl-list-with-capacity (parse-ast-decl-vec-len items))]
    (begin
      (parse-ast-decl-vec-copy-to-list items 0 (&mut out))
      (compiler-parse-decl-origin-register-selected! items (& out))
      (compiler-parse-semantic-origin-register-selected! items (& out))
      out)))

;; Wrappers are declarations semantically, but declaration-shape errors belong
;; to the declaration inside them. Keep the innermost source form's bounds.
(define (compiler-parse-decl-origin-syntax-span
  [dispatch : sym_i64_env.SymI64Env]
  [form : reader.SpannedSexpr]) : ast.AstSourceSpan
  (let
    [fallback : ast.AstSourceSpan
      (ast-source-span-from-source-span (reader.spanned-sexpr-span form))]
    (match (reader.spanned-sexpr-view form)
      [(reader.SpannedSexprView.Cons head-node rest _)
        (match (reader.spanned-sexpr-view head-node)
          [(reader.SpannedSexprView.Sym head _)
            (let
              [tag : i64
                (compiler-parse-dispatch-tag
                  dispatch
                  (ci.intern-syntax-id-value head))]
              (cond
                [(=
                    (ci.intern-syntax-id-value head)
                    (cbi.compiler-builtin-ctfe-ref 243))
                  (match (reader.spanned-sexpr-view rest)
                    [(reader.SpannedSexprView.Cons _ decl-tail _)
                      (match (reader.spanned-sexpr-view decl-tail)
                        [(reader.SpannedSexprView.Cons decl-form _ _)
                          (compiler-parse-decl-origin-syntax-span
                            dispatch
                            decl-form)]
                        [_ fallback])]
                    [_ fallback])]
                [(= tag (compiler-parse-tag-expr-unsafe))
                  (match (reader.spanned-sexpr-view rest)
                    [(reader.SpannedSexprView.Cons inner _ _)
                      (compiler-parse-decl-origin-syntax-span dispatch inner)]
                    [_ fallback])]
                [else fallback]))]
          [_ fallback])]
      [_ fallback])))

(define (parse-ast-program-forms-into-vec
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cur : (__tl_dyn-array i64)]
  [semantic-origins : (MutPtr ParseSemanticOriginVec)]
  [out : (&mut out ParseAstDeclVec)]) : ResultParseAstDeclVec
  (if (= (reader.peek-spanned-tag toks cur) (token.tag-end))
    (ResultParseAstDeclVec.Ok)
    (let
      ;; The spanned tree for one top-level form is dead once its AstDecl is
      ;; built (the decl carries AST-pool ids + spans by value, no sp ids), so
      ;; truncate the spanned pool back to here before reading the next form.
      ;; Bounds the spanned pool to a single form so it never has to grow.
      [mark : i64 (reader.sp-node-pool-len)]
      (match (reader.form-spanned-result toks cur)
        [(reader.ResultSpannedSexpr.Ok form)
          (let
            [records-start : i64 (reader.sp-node-pool-len)]
            [semantic-start : i64 out.semantic-origins.len]
            (begin
              (compiler-parse-semantic-origin-capture-begin!
                (ci.intern-compat-state-semantic-name-view
                  (compiler-parse-dispatch-intern-state dispatch))
                semantic-origins
                out.len)
              (match (parse-ast-decl-maybe-with-pools dispatch pools form)
                [(ResultAstMaybeDecl.SomeDecl decl)
                  (begin
                    (parse-ast-decl-vec-push-with-span
                      out
                      decl
                      (compiler-parse-decl-origin-syntax-span dispatch form))
                    (compiler-parse-semantic-origin-capture-end!)
                    (compiler-parse-member-records-compact! mark records-start)
                    (parse-ast-program-forms-into-vec
                      dispatch
                      pools
                      toks
                      cur
                      semantic-origins
                      out))]
                [(ResultAstMaybeDecl.Decls decls)
                  (begin
                    (set! out.semantic-origins.len semantic-start)
                    (compiler-parse-semantic-origin-capture-end!)
                    (compiler-parse-member-records-compact! mark records-start)
                    (parse-ast-decl-vec-push-list! out decls)
                    (parse-ast-program-forms-into-vec
                      dispatch
                      pools
                      toks
                      cur
                      semantic-origins
                      out))]
                [(ResultAstMaybeDecl.NoDecl)
                  (begin
                    (set! out.semantic-origins.len semantic-start)
                    (compiler-parse-semantic-origin-capture-end!)
                    (compiler-parse-member-records-compact! mark records-start)
                    (parse-ast-program-forms-into-vec
                      dispatch
                      pools
                      toks
                      cur
                      semantic-origins
                      out))]
                [(ResultAstMaybeDecl.Err message)
                  (begin
                    (set! out.semantic-origins.len semantic-start)
                    (compiler-parse-semantic-origin-capture-end!)
                    (reader.sp-node-pool-truncate! mark)
                    (ResultParseAstDeclVec.Err message))])))]
        [(reader.ResultSpannedSexpr.Err err)
          (begin
            (reader.sp-node-pool-truncate! mark)
            (ResultParseAstDeclVec.Err (token.source-error-message err)))]))))

(define (parse-ast-program-forms
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cur : (__tl_dyn-array i64)]) : ResultAstDeclList
  (let
    [out : ParseAstDeclVec (parse-ast-decl-vec-new)]
    [result : ResultParseAstDeclVec
      (parse-ast-program-forms-into-vec
        dispatch
        pools
        toks
        cur
        (unsafe
          (ptr-addr-of out.semantic-origins))
        (&mut out))]
    (match result
      [(ResultParseAstDeclVec.Ok)
        (ResultAstDeclList.Ok (parse-ast-decl-vec-to-list (& out)))]
      [(ResultParseAstDeclVec.Err message) (ResultAstDeclList.Err message)])))

(define (parse-ast-program-dispatch) : sym_i64_env.SymI64Env
  (compiler-parse-dispatch-env))

(define (parse-ast-program-dispatch-with-cfg [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (compiler-parse-dispatch-env-from-cfg cfgs))

(define (parse-ast-program-with-cfg-and-pools
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultAstProgram
  (let
    [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [base-dispatch : sym_i64_env.SymI64Env
      (parse-ast-program-dispatch-with-cfg cfgs)]
    [invocation : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    [dispatch : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        base-dispatch
        compiler-parse-invocation-marker-id
        (compiler-parse-array-data-addr-i64 invocation))]
    (begin
      (reader.sexpr-node-pool-reset!)
      (compiler-parse-semantic-origin-capture-end!)
      (set! (array-ref cur 0) 0)
      (set!
        (array-ref invocation compiler-parse-invocation-control-slot)
        (compiler-parse-env-marker-value
          base-dispatch
          compiler-parse-state-marker-id))
      (match (parse-ast-program-forms dispatch pools toks cur)
        [(ResultAstDeclList.Ok decls)
          (ResultAstProgram.Ok (ast.ast-program decls))]
        [(ResultAstDeclList.Err message) (ResultAstProgram.Err message)]))))

(define (parse-ast-program-with-cfg
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgram
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultAstProgram
      (parse-ast-program-with-cfg-and-pools toks cfgs pools)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      result)))

(define (parse-ast-program [toks : (__tl_dyn-array token.SpannedToken)]) : ResultAstProgram
  (parse-ast-program-with-cfg toks (compiler-cfg-empty)))

(define (parse-ast-source [src : String]) : ResultAstProgram
  (parse-ast-source-with-cfg src (compiler-cfg-empty)))

(define (parse-ast-source-with-cfg-and-pools
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultAstProgram
  (begin
    (compiler-parse-source-builtins-prepare!)
    (match (compiler-parse-spanned-result-with-cfg src cfgs)
      [(lexer.ResultSpannedTokens.Ok toks)
        (parse-ast-program-with-cfg-and-pools toks cfgs pools)]
      [(lexer.ResultSpannedTokens.Err err)
        (ResultAstProgram.Err (token.source-error-message err))])))

(define (parse-ast-source-with-cfg
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgram
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultAstProgram
      (parse-ast-source-with-cfg-and-pools src cfgs pools)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      result)))

(define (parse-ast-repl-module-macro-call-decl? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Import
        decl-meta
        (ast.AstImportSpec.Spec
          (ast.AstImportKind.MacroDecls _ _)
          path
          (ast.AstMaybeModuleName.No)
          (ast.AstMaybeImportAlias.No)
          _))
      (string.eq path "")]
    [_ false]))

(define (parse-ast-repl-expr-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [form : reader.SpannedSexpr]) : ResultAstReplItem
  (match (parse-ast-expr-with-pools dispatch pools form)
    [(ResultAstExpr.Ok expr) (ResultAstReplItem.Ok (AstReplExpr expr))]
    [(ResultAstExpr.Err message) (ResultAstReplItem.Err message)]))

(define (parse-ast-repl-source-with-pools
  [src : String]
  [pools : ast.AstNodePoolContext]) : ResultAstReplItem
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (reader.sexpr-node-pool-reset!)
    (let
      [mark : i64 (reader.sp-node-pool-len)]
      (match (lexer.spanned-result src)
        [(lexer.ResultSpannedTokens.Ok toks)
          (let
            [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
            [dispatch : sym_i64_env.SymI64Env (parse-ast-program-dispatch)]
            (begin
              (set! (array-ref cur 0) 0)
              (if (= (reader.peek-spanned-tag toks cur) (token.tag-end))
                (begin
                  (reader.sp-node-pool-truncate! mark)
                  (ResultAstReplItem.Err "parse: expected REPL input"))
                (match (reader.form-spanned-result toks cur)
                  [(reader.ResultSpannedSexpr.Ok form)
                    (let
                      [records-start : i64 (reader.sp-node-pool-len)]
                      (if (= (reader.peek-spanned-tag toks cur) (token.tag-end))
                        (match (parse-ast-decl dispatch pools form)
                          [(ResultAstDecl.Ok decl)
                            (let
                              [result : ResultAstReplItem
                                (if (parse-ast-repl-module-macro-call-decl?
                                  decl)
                                  (parse-ast-repl-expr-item dispatch pools form)
                                  (ResultAstReplItem.Ok (AstReplDecl decl)))]
                              (begin
                                (compiler-parse-member-records-compact!
                                  mark
                                  records-start)
                                result))]
                          [(ResultAstDecl.Err _)
                            (begin
                              (reader.sp-node-pool-truncate! records-start)
                              (let
                                [result : ResultAstReplItem
                                  (parse-ast-repl-expr-item dispatch pools form)]
                                (begin
                                  (reader.sp-node-pool-truncate! mark)
                                  result)))])
                        (begin
                          (reader.sp-node-pool-truncate! mark)
                          (ResultAstReplItem.Err
                            "parse: trailing tokens after REPL input"))))]
                  [(reader.ResultSpannedSexpr.Err err)
                    (begin
                      (reader.sp-node-pool-truncate! mark)
                      (ResultAstReplItem.Err (token.source-error-message err)))]))))]
        [(lexer.ResultSpannedTokens.Err err)
          (begin
            (reader.sp-node-pool-truncate! mark)
            (ResultAstReplItem.Err (token.source-error-message err)))]))))

(define (parse-ast-repl-source [src : String]) : ResultAstReplItem
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultAstReplItem (parse-ast-repl-source-with-pools src pools)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      result)))

(define (parse-ast-canonical-diagnostic [diag : cdiag.CompilerDiagnostic]) : cdiag.CompilerDiagnostic
  (let
    [canonical : cdiag.CompilerDiagnostic
      (cdiag.compiler-diagnostic-with-category
        (cdiag.compiler-diagnostic-with-code
          diag
          (cdiag.compiler-diagnostic-code-parse))
        "parse")]
    (if (parse-ast-if-message? (cdiag.compiler-diagnostic-message canonical))
      (parse-ast-if-diagnostic-notes canonical)
      canonical)))

(define (parse-ast-recovery-prefix-tag? [tag : i64]) : bool
  (or
    (= tag (token.tag-quote))
    (= tag (token.tag-backtick))
    (= tag (token.tag-comma))
    (= tag (token.tag-comma-at))))

;; A declaration-shape error has already consumed one balanced top-level form,
;; so its cursor is a safe boundary. Reader errors are different: unexpected
;; and mismatched delimiters leave the failing token under the cursor. Rescan
;; the failed form from its original token, treating either closing delimiter
;; as ending one nesting level. This deliberately recovers only when the raw
;; token depth returns to zero; an unterminated form consumes the rest of the
;; file. Top-level quote prefixes belong to the following datum and therefore
;; cannot become false one-token boundaries.
(define (parse-ast-recover-top-level-cursor!
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cur : (__tl_dyn-array i64)]
  [form-start : i64]) : unit
  (let
    [scan : i64 form-start]
    [depth : i64 0]
    [done : bool false]
    (while (not done)
      (let
        [tag : i64
          (token.tag (token.spanned-token-token (array-ref toks scan)))]
        (cond
          [(= tag (token.tag-end))
            (begin
              (set! (array-ref cur 0) scan)
              (set! done true))]
          [(or (= tag (token.tag-lparen)) (= tag (token.tag-lbracket)))
            (begin
              (set! depth (+ depth 1))
              (set! scan (+ scan 1)))]
          [(or (= tag (token.tag-rparen)) (= tag (token.tag-rbracket)))
            (begin
              (set! scan (+ scan 1))
              (if (> depth 0)
                (set! depth (- depth 1))
                unit)
              (if (= depth 0)
                (begin
                  (set! (array-ref cur 0) scan)
                  (set! done true))
                unit))]
          [(and (= depth 0) (parse-ast-recovery-prefix-tag? tag))
            (set! scan (+ scan 1))]
          [else
            (begin
              (set! scan (+ scan 1))
              (if (= depth 0)
                (begin
                  (set! (array-ref cur 0) scan)
                  (set! done true))
                unit))])))))

(define (parse-ast-program-forms-recovery-into-vec
  [path : String]
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cur : (__tl_dyn-array i64)]
  [semantic-origins : (MutPtr ParseSemanticOriginVec)]
  [out : (&mut out ParseAstDeclVec)]
  [diagnostics : (&mut diagnostics cdiag.CompilerDiagnosticList)]) : unit
  (if (= (reader.peek-spanned-tag toks cur) (token.tag-end))
    unit
    (let
      [mark : i64 (reader.sp-node-pool-len)]
      [form-start : i64 (reader.cur-pos cur)]
      (match (reader.form-spanned-result toks cur)
        [(reader.ResultSpannedSexpr.Ok spanned-form)
          (let
            [records-start : i64 (reader.sp-node-pool-len)]
            [semantic-start : i64 out.semantic-origins.len]
            (begin
              (parse-ast-error-span-clear! dispatch)
              (compiler-parse-semantic-origin-capture-begin!
                (ci.intern-compat-state-semantic-name-view
                  (compiler-parse-dispatch-intern-state dispatch))
                semantic-origins
                out.len)
              (match (parse-ast-decl-maybe-with-pools
                dispatch
                pools
                spanned-form)
                [(ResultAstMaybeDecl.SomeDecl decl)
                  (begin
                    (parse-ast-decl-vec-push-with-span
                      out
                      decl
                      (compiler-parse-decl-origin-syntax-span
                        dispatch
                        spanned-form))
                    (compiler-parse-semantic-origin-capture-end!)
                    (compiler-parse-member-records-compact! mark records-start)
                    (parse-ast-program-forms-recovery-into-vec
                      path
                      dispatch
                      pools
                      toks
                      cur
                      semantic-origins
                      out
                      diagnostics))]
                [(ResultAstMaybeDecl.Decls decls)
                  (begin
                    (set! out.semantic-origins.len semantic-start)
                    (compiler-parse-semantic-origin-capture-end!)
                    (compiler-parse-member-records-compact! mark records-start)
                    (parse-ast-decl-vec-push-list! out decls)
                    (parse-ast-program-forms-recovery-into-vec
                      path
                      dispatch
                      pools
                      toks
                      cur
                      semantic-origins
                      out
                      diagnostics))]
                [(ResultAstMaybeDecl.NoDecl)
                  (begin
                    (set! out.semantic-origins.len semantic-start)
                    (compiler-parse-semantic-origin-capture-end!)
                    (compiler-parse-member-records-compact! mark records-start)
                    (parse-ast-program-forms-recovery-into-vec
                      path
                      dispatch
                      pools
                      toks
                      cur
                      semantic-origins
                      out
                      diagnostics))]
                [(ResultAstMaybeDecl.Err message)
                  (let
                    [diag : cdiag.CompilerDiagnostic
                      (parse-ast-canonical-diagnostic
                        (cdiag.compiler-diagnostic-from-span
                          path
                          (parse-ast-error-span-current
                            dispatch
                            (reader.spanned-sexpr-span spanned-form))
                          message))]
                    (begin
                      (set! out.semantic-origins.len semantic-start)
                      (compiler-parse-semantic-origin-capture-end!)
                      (reader.sp-node-pool-truncate! mark)
                      (cdiag.compiler-diagnostic-list-push! diagnostics diag)
                      (parse-ast-program-forms-recovery-into-vec
                        path
                        dispatch
                        pools
                        toks
                        cur
                        semantic-origins
                        out
                        diagnostics)))])))]
        [(reader.ResultSpannedSexpr.Err err)
          (let
            [diag : cdiag.CompilerDiagnostic
              (parse-ast-canonical-diagnostic
                (cdiag.compiler-diagnostic-from-source-error path err))]
            (begin
              (reader.sp-node-pool-truncate! mark)
              (parse-ast-recover-top-level-cursor! toks cur form-start)
              (cdiag.compiler-diagnostic-list-push! diagnostics diag)
              (parse-ast-program-forms-recovery-into-vec
                path
                dispatch
                pools
                toks
                cur
                semantic-origins
                out
                diagnostics)))]))))

(define (parse-ast-program-recovery-diagnostic-with-cfg-and-pools
  [path : String]
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultAstProgramRecovery
  (let
    [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [base-dispatch : sym_i64_env.SymI64Env
      (parse-ast-program-dispatch-with-cfg cfgs)]
    [invocation : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    [dispatch : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        base-dispatch
        compiler-parse-invocation-marker-id
        (compiler-parse-array-data-addr-i64 invocation))]
    [out : ParseAstDeclVec (parse-ast-decl-vec-new)]
    (begin
      (reader.sexpr-node-pool-reset!)
      (set! (array-ref cur 0) 0)
      (set!
        (array-ref invocation compiler-parse-invocation-control-slot)
        (compiler-parse-env-marker-value
          base-dispatch
          compiler-parse-state-marker-id))
      (let
        [diagnostics : cdiag.CompilerDiagnosticList
          (cdiag.compiler-diagnostic-list-empty)]
        (begin
          (parse-ast-program-forms-recovery-into-vec
            path
            dispatch
            pools
            toks
            cur
            (unsafe
              (ptr-addr-of out.semantic-origins))
            (&mut out)
            (&mut diagnostics))
          (ResultAstProgramRecovery.Parsed
            (ast.ast-program (parse-ast-decl-vec-to-list (& out)))
            (box diagnostics)))))))

(define (parse-ast-source-recovery-diagnostic-with-cfg-and-pools
  [path : String]
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultAstProgramRecovery
  (begin
    (compiler-parse-source-builtins-prepare!)
    (match (compiler-parse-spanned-result-with-cfg src cfgs)
      [(lexer.ResultSpannedTokens.Ok toks)
        (parse-ast-program-recovery-diagnostic-with-cfg-and-pools
          path
          toks
          cfgs
          pools)]
      [(lexer.ResultSpannedTokens.Err err)
        (ResultAstProgramRecovery.Fatal
          (box
            (cdiag.compiler-diagnostic-list-single
              (parse-ast-canonical-diagnostic
                (cdiag.compiler-diagnostic-from-source-error path err)))))])))

(define (parse-ast-source-recovery-diagnostic-with-cfg
  [path : String]
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgramRecovery
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultAstProgramRecovery
      (parse-ast-source-recovery-diagnostic-with-cfg-and-pools
        path
        src
        cfgs
        pools)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      result)))

(define (parse-ast-source-recovery-diagnostic [path : String] [src : String]) : ResultAstProgramRecovery
  (parse-ast-source-recovery-diagnostic-with-cfg path src (compiler-cfg-empty)))

(define (parse-ast-program-forms-diagnostic-into-vec
  [path : String]
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cur : (__tl_dyn-array i64)]
  [semantic-origins : (MutPtr ParseSemanticOriginVec)]
  [out : (&mut out ParseAstDeclVec)]) : ResultParseAstDeclVecDiagnostic
  (if (= (reader.peek-spanned-tag toks cur) (token.tag-end))
    (ResultParseAstDeclVecDiagnostic.Ok)
    (let
      ;; Bound the spanned pool to a single top-level form (see
      ;; parse-ast-program-forms): the decl carries no sp ids, so truncate back
      ;; before reading the next form.
      [mark : i64 (reader.sp-node-pool-len)]
      (match (reader.form-spanned-result toks cur)
        [(reader.ResultSpannedSexpr.Ok spanned-form)
          (let
            [records-start : i64 (reader.sp-node-pool-len)]
            [semantic-start : i64 out.semantic-origins.len]
            (begin
              (parse-ast-error-span-clear! dispatch)
              (compiler-parse-semantic-origin-capture-begin!
                (ci.intern-compat-state-semantic-name-view
                  (compiler-parse-dispatch-intern-state dispatch))
                semantic-origins
                out.len)
              (match (parse-ast-decl-maybe-with-pools
                dispatch
                pools
                spanned-form)
                [(ResultAstMaybeDecl.SomeDecl decl)
                  (begin
                    (parse-ast-decl-vec-push-with-span
                      out
                      decl
                      (compiler-parse-decl-origin-syntax-span
                        dispatch
                        spanned-form))
                    (compiler-parse-semantic-origin-capture-end!)
                    (compiler-parse-member-records-compact! mark records-start)
                    (parse-ast-program-forms-diagnostic-into-vec
                      path
                      dispatch
                      pools
                      toks
                      cur
                      semantic-origins
                      out))]
                [(ResultAstMaybeDecl.Decls decls)
                  (begin
                    (set! out.semantic-origins.len semantic-start)
                    (compiler-parse-semantic-origin-capture-end!)
                    (compiler-parse-member-records-compact! mark records-start)
                    (parse-ast-decl-vec-push-list! out decls)
                    (parse-ast-program-forms-diagnostic-into-vec
                      path
                      dispatch
                      pools
                      toks
                      cur
                      semantic-origins
                      out))]
                [(ResultAstMaybeDecl.NoDecl)
                  (begin
                    (set! out.semantic-origins.len semantic-start)
                    (compiler-parse-semantic-origin-capture-end!)
                    (compiler-parse-member-records-compact! mark records-start)
                    (parse-ast-program-forms-diagnostic-into-vec
                      path
                      dispatch
                      pools
                      toks
                      cur
                      semantic-origins
                      out))]
                [(ResultAstMaybeDecl.Err message)
                  (begin
                    (set! out.semantic-origins.len semantic-start)
                    (compiler-parse-semantic-origin-capture-end!)
                    (reader.sp-node-pool-truncate! mark)
                    (ResultParseAstDeclVecDiagnostic.Err
                      (box
                        (parse-ast-canonical-diagnostic
                          (cdiag.compiler-diagnostic-from-span
                            path
                            (parse-ast-error-span-current
                              dispatch
                              (reader.spanned-sexpr-span spanned-form))
                            message)))))])))]
        [(reader.ResultSpannedSexpr.Err err)
          (begin
            (reader.sp-node-pool-truncate! mark)
            (ResultParseAstDeclVecDiagnostic.Err
              (box
                (parse-ast-canonical-diagnostic
                  (cdiag.compiler-diagnostic-from-source-error path err)))))]))))

(define (parse-ast-program-forms-diagnostic
  [path : String]
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cur : (__tl_dyn-array i64)]) : ResultAstDeclListDiagnostic
  (let
    [out : ParseAstDeclVec (parse-ast-decl-vec-new)]
    [result : ResultParseAstDeclVecDiagnostic
      (parse-ast-program-forms-diagnostic-into-vec
        path
        dispatch
        pools
        toks
        cur
        (unsafe
          (ptr-addr-of out.semantic-origins))
        (&mut out))]
    (match result
      [(ResultParseAstDeclVecDiagnostic.Ok)
        (ResultAstDeclListDiagnostic.Ok (parse-ast-decl-vec-to-list (& out)))]
      [(ResultParseAstDeclVecDiagnostic.Err diag)
        (ResultAstDeclListDiagnostic.Err diag)])))

(define (parse-ast-program-diagnostic-with-cfg-and-pools
  [path : String]
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultAstProgramDiagnostic
  (let
    [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [base-dispatch : sym_i64_env.SymI64Env
      (parse-ast-program-dispatch-with-cfg cfgs)]
    [invocation : (__tl_dyn-array i64) (__tl_make-array i64 6)]
    [dispatch : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        base-dispatch
        compiler-parse-invocation-marker-id
        (compiler-parse-array-data-addr-i64 invocation))]
    (begin
      (reader.sexpr-node-pool-reset!)
      (set! (array-ref cur 0) 0)
      (set!
        (array-ref invocation compiler-parse-invocation-control-slot)
        (compiler-parse-env-marker-value
          base-dispatch
          compiler-parse-state-marker-id))
      (match (parse-ast-program-forms-diagnostic path dispatch pools toks cur)
        [(ResultAstDeclListDiagnostic.Ok decls)
          (ResultAstProgramDiagnostic.Ok (ast.ast-program decls))]
        [(ResultAstDeclListDiagnostic.Err diag)
          (ResultAstProgramDiagnostic.Err diag)]))))

(define (parse-ast-source-diagnostic [path : String] [src : String]) : ResultAstProgramDiagnostic
  (parse-ast-source-diagnostic-with-cfg path src (compiler-cfg-empty)))

(define (parse-ast-source-diagnostic-with-cfg-and-pools
  [path : String]
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultAstProgramDiagnostic
  (begin
    (compiler-parse-source-builtins-prepare!)
    (match (compiler-parse-spanned-result-with-cfg src cfgs)
      [(lexer.ResultSpannedTokens.Ok toks)
        (parse-ast-program-diagnostic-with-cfg-and-pools path toks cfgs pools)]
      [(lexer.ResultSpannedTokens.Err err)
        (ResultAstProgramDiagnostic.Err
          (box
            (parse-ast-canonical-diagnostic
              (cdiag.compiler-diagnostic-from-source-error path err))))])))

(define (parse-ast-source-diagnostic-with-cfg
  [path : String]
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgramDiagnostic
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultAstProgramDiagnostic
      (parse-ast-source-diagnostic-with-cfg-and-pools path src cfgs pools)]
    (begin
      (ast.ast-node-pool-context-install! pools)
      result)))

(define (ast-decl-list-count [decls : ast.AstDeclList]) : i64
  (ast.ast-decl-list-len (& decls)))

;; Serial tool compatibility adapter. Production parsing above uses the
;; explicit-state twin; lint ownership is tracked separately by #4699.
(define (parse-ast-dotted-import-default-alias-id [name-id : i64]) : i64
  (ci.intern-dotted-final-id name-id))

(define (ast-decl-list-tag-sum [decls : ast.AstDeclList]) : i64
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) 0]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (+ (ast.ast-decl-tag decl) (ast-decl-list-tag-sum rest)))]))

(define (compiler-parse-expr-list-count [exprs : ast.AstExprList]) : i64
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
  (match (parse-ast-source "(module std.io)")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons (ast.AstDecl.Module name) rest)
            (let
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (= name (reader.stable-symbol-id "std.io"))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-module-body-ok?) : bool
  (match (parse-ast-source "(module local.helper (define value : i64 1))")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.ModuleBody name body-box)
              rest)
            (let
              [rest : ast.AstDeclList rest]
              [body : ast.AstDeclList (__tl-box-place body-box)]
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-module-body-malformed-ok?) : bool
  (match (parse-ast-source "(module local.helper (define bad))")
    [(ResultAstProgram.Ok _) false]
    [(ResultAstProgram.Err message)
      (string.eq message "parse: malformed value definition")]))

(define (compiler-parse-import-metadata-ok?) : bool
  (match (parse-ast-source "(import stdlib.core_macros as io)")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-dotted-import-explicit-alias-ok?) : bool
  (match (parse-ast-source "(import stdlib.core_macros as core)")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-dotted-import-default-alias-ok?) : bool
  (match (parse-ast-source "(import stdlib.core_macros)")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-dotted-import-wildcard-ok?) : bool
  (match (parse-ast-source "(import stdlib.core_macros.*)")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
                (ast.ast-decl-list-empty? (& rest))
                (string.eq module-path "stdlib.core_macros")
                (string.eq (ci.intern-str module-name) "stdlib.core_macros")
                (= alias cbi.compiler-builtin-id-fix-empty)))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-dotted-import-metadata-ok?) : bool
  (and
    (compiler-parse-dotted-import-explicit-alias-ok?)
    (compiler-parse-dotted-import-default-alias-ok?)
    (compiler-parse-dotted-import-wildcard-ok?)))

(define (compiler-parse-module-macro-call-ok?) : bool
  (match (parse-ast-source "(point-vec i64)")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-macro-import-ok?) : bool
  (match (parse-ast-source "(import (vector.vector i64) as svec)")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
    [(ResultAstProgram.Err _) false]))

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
  (match (parse-ast-source "(include-str payload \"data.txt\")")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        (ast-first-include-str-ok? decls))]
    [(ResultAstProgram.Err _) false]))

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
  (match (parse-ast-source "(include-str-comptime payload \"data.txt\")")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (ast-first-include-str-comptime-ok? (__tl-box-place decls-box))]
    [(ResultAstProgram.Err _) false]))

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
  (match (parse-ast-source "(include-str-lzss payload \"data.txt\")")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (ast-first-include-str-lzss-ok? (__tl-box-place decls-box))]
    [(ResultAstProgram.Err _) false]))

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
      (compiler-parse-removed-compressed-include-name)
      " payload \"data.txt\")")
    (compiler-parse-removed-compressed-include-message)))

(define (compiler-parse-include-bin-ok?) : bool
  (match (parse-ast-source "(include-bin payload \"data.bin\")")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        (ast-first-include-bin-ok? decls))]
    [(ResultAstProgram.Err _) false]))

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
  (match (parse-ast-source
    "(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2) (avx512 dot-avx512))")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-defdispatch-scalar-only-ok?) : bool
  (match (parse-ast-source "(defdispatch id (scalar id-scalar))")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
    [(ResultAstProgram.Err _) false]))

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
  (ast.ast-expr-tag (ast.ast-expr-unspan expr)))

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
  (match (parse-ast-source "(define (main) : i64 (+ 1 (* 2 3)))")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
      (match (parse-ast-source src)
        [(ResultAstProgram.Err message)
          (string.eq message "parse: malformed define")]
        [_ false])
      (match (lexer.spanned-result src)
        [(lexer.ResultSpannedTokens.Ok toks)
          (let
            [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
            (begin
              (set! (array-ref cur 0) 0)
              (match (reader.form-spanned-result toks cur)
                [(reader.ResultSpannedSexpr.Ok form)
                  (let
                    [span : token.SourceSpan (reader.spanned-sexpr-span form)]
                    (and
                      (= (token.span-start-line span) 1)
                      (= (token.span-start-col span) 1)))]
                [(reader.ResultSpannedSexpr.Err _) false])))]
        [(lexer.ResultSpannedTokens.Err _) false]))))

(define (compiler-parse-reader-diagnostic-ok?
  [path : String]
  [src : String]
  [want : String]
  [line : i64]
  [col : i64]) : bool
  (match (parse-ast-source-diagnostic path src)
    [(ResultAstProgramDiagnostic.Err diag)
      (and
        (string.eq (cdiag.compiler-diagnostic-path (__tl-box-place diag)) path)
        (= (cdiag.compiler-diagnostic-line (__tl-box-place diag)) line)
        (= (cdiag.compiler-diagnostic-col (__tl-box-place diag)) col)
        (string.eq
          (cdiag.compiler-diagnostic-message (__tl-box-place diag))
          want))]
    [(ResultAstProgramDiagnostic.Ok _) false]))

(define (compiler-parse-diagnostic-location-ok?
  [path : String]
  [src : String]
  [want : String]
  [line : i64]
  [col : i64]) : bool
  (match (parse-ast-source-diagnostic path src)
    [(ResultAstProgramDiagnostic.Err diag)
      (and
        (string.eq (cdiag.compiler-diagnostic-path (__tl-box-place diag)) path)
        (= (cdiag.compiler-diagnostic-line (__tl-box-place diag)) line)
        (= (cdiag.compiler-diagnostic-col (__tl-box-place diag)) col)
        (string.eq
          (cdiag.compiler-diagnostic-message (__tl-box-place diag))
          want))]
    [(ResultAstProgramDiagnostic.Ok _) false]))

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
    (compiler-parse-reader-diagnostic-ok?
      "missing-paren.tl"
      "(define (main) : i64 0"
      "reader: unterminated list: reached end of input before ')'"
      1
      1)
    (compiler-parse-reader-diagnostic-ok?
      "missing-bracket.tl"
      "["
      "reader: unterminated list: reached end of input before ']'"
      1
      1)
    (compiler-parse-reader-diagnostic-ok?
      "wrong-close-list.tl"
      "(define]"
      "reader: mismatched delimiter: expected ')' but found ']' at 1:8"
      1
      8)
    (compiler-parse-reader-diagnostic-ok?
      "wrong-close-bracket.tl"
      "[define)"
      "reader: mismatched delimiter: expected ']' but found ')' at 1:8"
      1
      8)))

(define (compiler-parse-float-literal-ok?) : bool
  (match (parse-ast-source "(define (main) : f64 1.5)")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-smoke-source) : String
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

(define (compiler-parse-smoke-score [program : ast.AstProgram]) : i64
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        (+
          (ast-decl-list-count decls)
          (+
            (ast-decl-list-tag-sum decls)
            (+
              (ast-main-body-tag decls)
              (if (ast-first-import-ok? decls)
                1
                0)))))]))

;; True only when `src` fails to parse with exactly the wanted diagnostic. The
;; counterpart to the success-path smoke: it pins the parser's rejection
;; messages so a regression that drops or relabels an error is caught.
(define (compiler-parse-error-ok? [src : String] [want : String]) : bool
  (match (parse-ast-source src)
    [(ResultAstProgram.Err message) (string.eq message want)]
    [(ResultAstProgram.Ok _) false]))

(define (compiler-parse-diagnostic-code-ok?) : bool
  (match (parse-ast-source-diagnostic
    "parse-code.tl"
    (compiler-parse-malformed-binary-source))
    [(ResultAstProgramDiagnostic.Err diag)
      (match (cdiag.compiler-diagnostic-code (__tl-box-place diag))
        [(CompilerDiagnosticSomeString code)
          (and
            (string.eq code (cdiag.compiler-diagnostic-code-parse))
            (match (cdiag.compiler-diagnostic-category (__tl-box-place diag))
              [(CompilerDiagnosticSomeString category)
                (string.eq category "parse")]
              [CompilerDiagnosticNoString false]))]
        [CompilerDiagnosticNoString false])]
    [(ResultAstProgramDiagnostic.Ok _) false]))

;; Minimal complete programs that lex cleanly but reach a specific parser
;; rejection, one per representative special form.
(define (compiler-parse-malformed-binary-source) : String
  "(define (main) : i64 (+ 1))")

(define (compiler-parse-malformed-if-source) : String
  "(define (main) : i64 (if true 1))")

(define (compiler-parse-if-missing-else-diagnostic-notes-ok?) : bool
  (match (parse-ast-source-diagnostic
    "missing-if-else.tl"
    (compiler-parse-malformed-if-source))
    [(ResultAstProgramDiagnostic.Err diag)
      (let
        [rendered : String
          (cdiag.compiler-diagnostic-render (__tl-box-place diag))]
        [message-needle : String "parse: if is missing its else branch"]
        [example-needle : String "example: (if condition then-expr else-expr)"]
        [when-needle : String "when condition body..."]
        [unless-needle : String "unless condition body..."]
        (and
          (string.contains (& rendered) (& message-needle))
          (string.contains (& rendered) (& example-needle))
          (string.contains (& rendered) (& when-needle))
          (string.contains (& rendered) (& unless-needle))))]
    [(ResultAstProgramDiagnostic.Ok _) false]))

(define (compiler-parse-malformed-while-source) : String
  "(define (main) : i64 (while true))")

(define (compiler-parse-malformed-set-source) : String
  "(define (main) : i64 (set! x))")

(define (compiler-parse-bracket-cond-source) : String
  "(define (main) : i64 (cond [(= 1 1) 1] [else 0]))")

(define (compiler-parse-qualified-bracket-cond-source) : String
  "(define (main) : i64 (core.cond [(= 1 1) 1] [else 0]))")

(define (compiler-parse-region-source) : String
  "(define (main) : (in r String)
  (with-arena r \"x\"))")

(define (compiler-parse-with-region-empty-source) : String
  "(define (main) : i64 (with-arena r))")

(define (compiler-parse-region-type-bad-source) : String
  "(define (main) : (in 1 String) 0)")

(define (compiler-parse-region-ok?) : bool
  (match (parse-ast-source (compiler-parse-region-source))
    [(ResultAstProgram.Ok _) true]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-arena-source) : String
  "(define (main) : i64
  (with-arena n 5))")

;; `with-arena` is the canonical spelling. Assert it parses to
;; the `AstExpr.WithRegion` form, not an unbound call.
(define (compiler-parse-arena-ok?) : bool
  (match (parse-ast-source (compiler-parse-arena-source))
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-raw-pointer-source) : String
  "(extern (raw-map [arg0 : (Ptr i64)]) : (MutPtr (Ptr u8)))")

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

(define (compiler-parse-extern-metadata-source) : String
  "(extern (local-call [arg0 : i64]) : i64 (:abi c) (:symbol \"foreign_exact\") (:link-lib \"m\") (:link-search \"native/lib\") (:link-arg \"-Wl,--as-needed\"))")

(define (compiler-parse-extern-varargs-metadata-source) : String
  "(extern (snprintf [arg0 : (MutPtr u8)] [arg1 : i64] [arg2 : (Ptr u8)] [arg3 : f64]) : i32 (:abi c-varargs 3) (:symbol \"snprintf\"))")

(define (compiler-parse-extern-function-head-varargs-source) : String
  "(extern (snprintf [buf : (MutPtr u8)] [len : i64] [fmt : (Ptr u8)] [arg : ...f64]) : i32 (:symbol \"snprintf\"))
(extern (printf [fmt : (Ptr u8)] ...) : i32 (:symbol \"printf\"))
(extern (local-add [a : i64] [b : i64]) : i64 (:symbol \"foreign_add_exact\"))")

(define (compiler-parse-type-list-count [types : ast.AstTypeList]) : i64
  (ast.ast-type-list-len (& types)))

(define (compiler-parse-raw-pointer-ops-source) : String
  "(define (main [p : (MutPtr i64)] [n : u64]) : u64
  (unsafe
    (ptr-write! p (ptr-read p))
    (ptr->int (ptr-cast (ptr-offset (int->ptr n : (MutPtr i64)) 1) : (Ptr i64)))))")

(define (compiler-parse-raw-pointer-ok?) : bool
  (match (parse-ast-source (compiler-parse-raw-pointer-source))
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
                          [args-list : ast.AstTypeList (__tl-box-place args)]
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
    [(ResultAstProgram.Err _) false]))

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
  (match (parse-ast-source (compiler-parse-extern-metadata-source))
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.Extern decl-meta name _ metadata ty)
              rest)
            (let
              [rest : ast.AstDeclList rest]
              (match (ast.ast-decl-list-step rest)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (= name (reader.stable-symbol-id "local-call"))
                    (string.eq
                      (ast.ast-extern-metadata-symbol (__tl-box-place metadata))
                      "foreign_exact")
                    (ast.ast-extern-abi-c?
                      (ast.ast-extern-metadata-abi (__tl-box-place metadata)))
                    (compiler-parse-extern-link-inputs-ok?
                      (ast.ast-extern-metadata-link-inputs
                        (__tl-box-place metadata)))
                    (match ty
                      [(ast.AstType.Func args ret)
                        (let
                          [args-list : ast.AstTypeList (__tl-box-place args)]
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-extern-varargs-metadata-rejected-ok?) : bool
  (compiler-parse-error-ok?
    (compiler-parse-extern-varargs-metadata-source)
    (parse-ast-extern-c-varargs-legacy-message)))

(define (compiler-parse-extern-head-typed-varargs-decl-ok? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Extern decl-meta name _ metadata ty)
      (and
        (= name (reader.stable-symbol-id "snprintf"))
        (match (ast.ast-extern-metadata-abi (__tl-box-place metadata))
          [(ast.AstExternAbi.CVarargsTyped tail-ty)
            (match tail-ty
              [(ast.AstType.F64) true]
              [_ false])]
          [_ false])
        (match ty
          [(ast.AstType.Func args ret)
            (let
              [args-list : ast.AstTypeList (__tl-box-place args)]
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
        (match (ast.ast-extern-metadata-abi (__tl-box-place metadata))
          [(ast.AstExternAbi.CVarargsOpen) true]
          [_ false])
        (match ty
          [(ast.AstType.Func args ret)
            (let
              [args-list : ast.AstTypeList (__tl-box-place args)]
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
          (ast.ast-extern-metadata-symbol (__tl-box-place metadata))
          "foreign_add_exact")
        (match ty
          [(ast.AstType.Func args ret)
            (and
              (= (compiler-parse-type-list-count (__tl-box-place args)) 2)
              (compiler-parse-i64-type? (ast.ty-node-get ret))
              (compiler-parse-two-i64-types? (__tl-box-place args)))]
          [_ false]))]
    [_ false]))

(define (compiler-parse-extern-function-head-varargs-ok?) : bool
  (match (parse-ast-source (compiler-parse-extern-function-head-varargs-source))
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (match (ast.ast-decl-list-step (__tl-box-place decls-box))
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-raw-pointer-ops-ok?) : bool
  (compiler-parse-ok? (compiler-parse-raw-pointer-ops-source)))

(define (compiler-parse-init-ok?) : bool
  (match (parse-ast-source "(define (main) : i64 (init : i64))")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (match (ast.ast-decl-list-step (__tl-box-place decls-box))
        [(ast.AstDeclListStep.Cons
            (ast.AstDecl.DefFn decl-meta _ _ _ body-box _)
            done-box)
          (let
            [done : ast.AstDeclList done-box]
            (and
              (ast.ast-decl-list-empty? (& done))
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-contextual-init-ok?) : bool
  (match (parse-ast-source
    "(define (init) : i64 7) (define (main) : i64 (init))")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (match (ast.ast-decl-list-step (__tl-box-place decls-box))
        [(ast.AstDeclListStep.Cons _ rest)
          (match (ast.ast-decl-list-step rest)
            [(ast.AstDeclListStep.Cons
                (ast.AstDecl.DefFn decl-meta _ _ _ body-box _)
                done-box)
              (let
                [done : ast.AstDeclList done-box]
                (and
                  (ast.ast-decl-list-empty? (& done))
                  (match (ast.ast-expr-unspan (ast.ast-node-get body-box))
                    [(ast.AstExpr.Init ty-id)
                      (match (ast.ast-maybe-type-from-id ty-id)
                        [(ast.AstMaybeType.No) true]
                        [_ false])]
                    [_ false])))]
            [_ false])]
        [_ false])]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-init-call-name-source) : String
  "(define (init [n : i64]) : i64 n)
(define (main) : i64 (init 7))")

(define (compiler-parse-init-call-name-ok?) : bool
  (compiler-parse-ok? (compiler-parse-init-call-name-source)))

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
      "(define (main [items : (Array i64 1)]) : i64 (array-take! items 0))")
    (compiler-parse-ok?
      "(define (main [items : (__tl_dyn-array i64)] [live : (__tl_dyn-array bool)]) : (Tuple bool i64) (__tl_array-take! items live 0))")
    ;; Keep the neighboring parser tag distinct: a previous collision caused
    ;; every dereference to dispatch to the two-operand array-take parser.
    (compiler-parse-ok? "(define (main [item : (Box i64)]) : i64 (deref item))")
    (compiler-parse-error-ok?
      "(define (main [items : (Array i64 1)] [live : (Array bool 1)]) : i64 (array-take! items live 0))"
      "parse: array-take! expects exactly two operands; compatibility storage must use private __tl_array-take!")))

(define (compiler-parse-replace-ok?) : bool
  (and
    (compiler-parse-ok?
      "(define (main) : i64 (let [value : i64 1] (replace! value 2)))")
    (compiler-parse-ok?
      "(define (main [items : (Array i64 2)] [i : i64]) : i64 (replace! (array-ref items i) 7))")
    (compiler-parse-error-ok?
      "(define (main) : i64 (replace! (+ 1 2) 3))"
      "parse: replace! target must be a mutable place")
    (compiler-parse-error-ok?
      "(define (main) : i64 (replace! value))"
      "parse: replace! expects exactly two operands")
    (compiler-parse-error-ok?
      "(define (main) : i64 (replace! value 1 2))"
      "parse: replace! expects exactly two operands")))

(define (compiler-parse-reference-source) : String
  "(define (use [s : (& n String)] [view : (& n str)] [items : (&mut value (__tl_dyn-array i64))]) : unit unit)")

(define (compiler-parse-reference-ok?) : bool
  (match (parse-ast-source (compiler-parse-reference-source))
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
                      [(ast.AstParam.Param _ first-ty false false)
                        (compiler-parse-type-ref-string?
                          first-ty
                          cbi.compiler-builtin-id-fix-n)]
                      [_ false])
                    (match (ast.ast-param-list-get
                      (& params)
                      1
                      (ast.ast-param-fallback))
                      [(ast.AstParam.Param _ second-ty false false)
                        (compiler-parse-type-ref-str?
                          second-ty
                          cbi.compiler-builtin-id-fix-n)]
                      [_ false])
                    (match (ast.ast-param-list-get
                      (& params)
                      2
                      (ast.ast-param-fallback))
                      [(ast.AstParam.Param _ third-ty false false)
                        (compiler-parse-type-mut-ref-dyn-array-i64?
                          third-ty
                          cbi.compiler-builtin-id-fix-value)]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-borrow-source) : String
  "(define (main [x : i64]) : i64
  (begin
    (& x)
    (& x x)
    (&mut x)
    x))")

(define (compiler-parse-borrow-ok?) : bool
  (match (parse-ast-source (compiler-parse-borrow-source))
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-try-source) : String
  "(define (main) : i64 (wrap (try (read))))")

(define (compiler-parse-try-ok?) : bool
  (match (parse-ast-source (compiler-parse-try-source))
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-return-source) : String
  "(define (main) : i64 (return 42))")

(define (compiler-parse-return-ok?) : bool
  (match (parse-ast-source (compiler-parse-return-source))
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
    [(ResultAstProgram.Err _) false]))

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

(define (compiler-parse-call-arg-count [args : ast.AstExprList]) : i64
  args.len)

(define (compiler-parse-call-body-ok?
  [source : String]
  [name : String]
  [want-args : i64]
  [check-guard-args : bool]) : bool
  (match (parse-ast-source source)
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
    [(ResultAstProgram.Err _) false]))

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
      (compiler-parse-bracket-cond-source)
      "cond"
      2
      false)
    (compiler-parse-call-body-ok?
      (compiler-parse-qualified-bracket-cond-source)
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

(define (compiler-parse-unsafe-decl-source) : String
  "(unsafe (define (danger [x : i64]) : i64 x))
(unsafe (extern (raw-call [arg0 : i64]) : i64))")

(define (compiler-parse-unsafe-decl-ok?) : bool
  (match (parse-ast-source (compiler-parse-unsafe-decl-source))
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons first tail)
            (let
              [tail : ast.AstDeclList tail]
              (match first
                [(ast.AstDecl.Unsafe first-inner-box)
                  (let
                    [first-inner : ast.AstDecl (__tl-box-place first-inner-box)]
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
                                (ast.ast-decl-list-empty? (& done))
                                (match second
                                  [(ast.AstDecl.Unsafe second-inner-box)
                                    (let
                                      [second-inner : ast.AstDecl
                                        (__tl-box-place second-inner-box)]
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-field-count [fields : ast.AstFieldDefList]) : i64
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

(define (compiler-parse-struct-cleanup-source) : String
  "(defstruct Resource
  (:cleanup close-resource)
  (fd i64 (:cleanup close-fd))
  (child i64 (:owned))
  (status i64))")

(define (compiler-parse-struct-cleanup-ok?) : bool
  (match (parse-ast-source (compiler-parse-struct-cleanup-source))
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-enum-cleanup-source) : String
  "(defenum Resource
  (:cleanup close-resource)
  (File i64 (:cleanup close-fd) Child (:owned) i64))")

(define (compiler-parse-enum-cleanup-ok?) : bool
  (match (parse-ast-source (compiler-parse-enum-cleanup-source))
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-cleanup-metadata-ok?) : bool
  (and (compiler-parse-struct-cleanup-ok?) (compiler-parse-enum-cleanup-ok?)))

(define (compiler-parse-repr-c-source) : String
  "(defstruct Stat
  (:repr c)
  (size i64)
  (mtime i64))")

(define (compiler-parse-repr-c-ok?) : bool
  (match (parse-ast-source (compiler-parse-repr-c-source))
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-inline-test-source) : String
  "(test parser-basic
  (+ 1 2)
  3)")

(define (compiler-parse-inline-test-ok?) : bool
  (match (parse-ast-source (compiler-parse-inline-test-source))
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons (ast.AstDecl.Test name body-box span) tail)
            (let
              [body : ast.AstExpr (ast.ast-node-get body-box)]
              [tail : ast.AstDeclList tail]
              (match (ast.ast-decl-list-step tail)
                [(ast.AstDeclListStep.Nil)
                  (and
                    (= name (reader.stable-symbol-id "parser-basic"))
                    (= (ast.ast-source-span-start-line span) 1)
                    (match (ast.ast-expr-unspan body)
                      [(ast.AstExpr.Begin exprs)
                        (= (compiler-parse-expr-list-count exprs) 2)]
                      [_ false]))]
                [_ false]))]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-malformed-module-source) : String
  "(module)")

(define (compiler-parse-malformed-import-source) : String
  "(import stdlib.core as)")

(define (compiler-parse-defgeneric-policy-source) : String
  "(defgeneric Box [T] (value T))")

(define (compiler-parse-trait-policy-source) : String
  "(trait Printable (print-self : (-> Self unit)))")

(define (compiler-parse-generic-type-policy-source) : String
  "(define value : (Option i64) 0)")

(define (compiler-parse-empty-test-source) : String
  "(test empty)")

(define (compiler-parse-malformed-try-source) : String
  "(define (main) : i64 (try))")

(define (compiler-parse-malformed-return-source) : String
  "(define (main) : i64 (return 1 2))")

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
  (match (parse-ast-source
    "(define (id [x : i64]) : i64 x)
(define (main) : i64 (let [x : i64 41] (id x)))")
    [(ResultAstProgram.Ok _) true]
    [(ResultAstProgram.Err _) false]))

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
      (compiler-parse-defgeneric-policy-source)
      (compiler-parse-abstraction-policy-message))
    (compiler-parse-error-ok?
      (compiler-parse-trait-policy-source)
      (compiler-parse-abstraction-policy-message))
    (compiler-parse-error-ok?
      (compiler-parse-generic-type-policy-source)
      (compiler-parse-generic-type-policy-message "Option"))))

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
  (let
    [ok : bool true]
    (begin
      (if (compiler-parse-error-ok?
        "(define (main [p : (Box)]) : unit unit)"
        "parse: Box expects exactly one type")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [p : (Box i64 bool)]) : unit unit)"
        "parse: Box expects exactly one type")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main) : (Box i64) (box))"
        "parse: box expects exactly one expression")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [b : (Box i64)]) : i64 (deref b b))"
        "parse: deref expects exactly one expression")
        unit
        (set! ok false))
      ok)))

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
  (let
    [ok : bool true]
    (begin
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:abi stdcall))"
        "parse: unknown extern ABI stdcall")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:symbol bad))"
        "parse: malformed extern :symbol metadata")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:link-lib bad))"
        "parse: malformed extern :link-lib metadata")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:link-arg \"\"))"
        "parse: extern :link-arg must not be empty")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:abi c) (:abi c))"
        "parse: duplicate extern :abi metadata")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:abi c-varargs))"
        (parse-ast-extern-c-varargs-legacy-message))
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:abi c-varargs -1))"
        (parse-ast-extern-c-varargs-legacy-message))
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f ... [x : i64]) : i64)"
        "parse: extern varargs tail must be final")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f [x : i64] ...) (:abi c-varargs 1) : i64)"
        (parse-ast-extern-c-varargs-legacy-message))
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(extern (f) : i64 (:link \"x\"))"
        "parse: unknown extern metadata :link")
        unit
        (set! ok false))
      ok)))

(define (compiler-parse-reference-error-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-parse-error-ok?
        "(define (main [p : (&)]) : unit unit)"
        "parse: & expects an optional lifetime and exactly one type")
        unit
        (set! ok false))
      (if (compiler-parse-ok? "(define (main [p : (& r)]) : unit unit)")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [p : (& 1 i64)]) : unit unit)"
        "parse: reference lifetime must be an identifier")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [p : (& r i64 i64)]) : unit unit)"
        "parse: & expects an optional lifetime and exactly one type")
        unit
        (set! ok false))
      (if (compiler-parse-ok? "(define (main [p : (&mut phase)]) : unit unit)")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [x : i64]) : unit (&))"
        "parse: borrow expects a place or lifetime and place")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [x : i64]) : unit (& x x x))"
        "parse: borrow expects a place or lifetime and place")
        unit
        (set! ok false))
      (if (compiler-parse-error-ok?
        "(define (main [x : i64]) : unit (& 1 x))"
        "parse: borrow lifetime must be an identifier")
        unit
        (set! ok false))
      ok)))

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
      (compiler-parse-malformed-while-source)
      "parse: malformed while")
    (compiler-parse-error-ok?
      (compiler-parse-malformed-set-source)
      "parse: malformed set!")
    (compiler-parse-error-ok?
      (compiler-parse-with-region-empty-source)
      "parse: with-arena 'r' requires a non-empty body")
    (compiler-parse-error-ok?
      (compiler-parse-region-type-bad-source)
      "parse: region name must be an identifier")
    (compiler-parse-error-ok?
      (compiler-parse-malformed-try-source)
      "parse: try expects exactly one expression")
    (compiler-parse-error-ok?
      (compiler-parse-malformed-return-source)
      "parse: return expects exactly one expression")))

(define (compiler-parse-recovery-balanced-decl-ok?) : bool
  (match (parse-ast-source-recovery-diagnostic
    "tests/recovery-balanced.tl"
    "(define)
(define (kept-a) : i64 1)
(define (kept-b) : i64 2)")
    [(ResultAstProgramRecovery.Parsed
        (ast.AstProgram.Program decls-box)
        diagnostics-box)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList
          (__tl-box-place diagnostics-box)]
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first diagnostics)]
        (and
          (= (ast.ast-decl-list-len (& (__tl-box-place decls-box))) 2)
          (= (cdiag.compiler-diagnostic-list-count diagnostics) 1)
          (string.eq
            (cdiag.compiler-diagnostic-message first)
            "parse: malformed define")
          (= (cdiag.compiler-diagnostic-line first) 1)))]
    [(ResultAstProgramRecovery.Fatal _) false]))

(define (compiler-parse-recovery-ordered-errors-ok?) : bool
  (match (parse-ast-source-recovery-diagnostic
    "tests/recovery-ordered.tl"
    "(define)
(define (kept-a) : i64 1)
(define)
(define (kept-b) : i64 2)")
    [(ResultAstProgramRecovery.Parsed
        (ast.AstProgram.Program decls-box)
        diagnostics-box)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList
          (__tl-box-place diagnostics-box)]
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
    [(ResultAstProgramRecovery.Fatal _) false]))

(define (compiler-parse-recovery-reader-progress-ok?) : bool
  (and
    (match (parse-ast-source-recovery-diagnostic
      "tests/recovery-mismatch.tl"
      "(define]
(define (kept) : i64 1)")
      [(ResultAstProgramRecovery.Parsed
          (ast.AstProgram.Program decls-box)
          diagnostics-box)
        (let
          [diagnostics : cdiag.CompilerDiagnosticList
            (__tl-box-place diagnostics-box)]
          [message : String
            (cdiag.compiler-diagnostic-message
              (cdiag.compiler-diagnostic-list-first diagnostics))]
          [needle : String "reader: mismatched delimiter"]
          (and
            (= (ast.ast-decl-list-len (& (__tl-box-place decls-box))) 1)
            (= (cdiag.compiler-diagnostic-list-count diagnostics) 1)
            (string.contains (& message) (& needle))))]
      [(ResultAstProgramRecovery.Fatal _) false])
    (match (parse-ast-source-recovery-diagnostic
      "tests/recovery-stray.tl"
      ") ] (define (kept) : i64 1)")
      [(ResultAstProgramRecovery.Parsed
          (ast.AstProgram.Program decls-box)
          diagnostics-box)
        (and
          (= (ast.ast-decl-list-len (& (__tl-box-place decls-box))) 1)
          (=
            (cdiag.compiler-diagnostic-list-count
              (__tl-box-place diagnostics-box))
            2))]
      [(ResultAstProgramRecovery.Fatal _) false])
    (match (parse-ast-source-recovery-diagnostic
      "tests/recovery-unterminated.tl"
      "(define
(define (not-a-boundary) : i64 1))")
      [(ResultAstProgramRecovery.Parsed
          (ast.AstProgram.Program decls-box)
          diagnostics-box)
        (and
          (= (ast.ast-decl-list-len (& (__tl-box-place decls-box))) 0)
          (=
            (cdiag.compiler-diagnostic-list-count
              (__tl-box-place diagnostics-box))
            1))]
      [(ResultAstProgramRecovery.Fatal _) false])))

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
    [(not (compiler-parse-cleanup-error-tests-ok?)) false]
    [(not
        (compiler-parse-error-ok?
          (compiler-parse-malformed-module-source)
          "parse: malformed module"))
      false]
    [(not
        (compiler-parse-error-ok?
          (compiler-parse-malformed-import-source)
          "parse: malformed import"))
      false]
    [(not
        (compiler-parse-error-ok?
          (compiler-parse-empty-test-source)
          "parse: test needs at least one expression"))
      false]
    [(not (compiler-parse-let-error-tests-ok?)) false]
    [(not (compiler-parse-abstraction-policy-tests-ok?)) false]
    [(not (compiler-parse-raw-pointer-error-tests-ok?)) false]
    [(not (compiler-parse-extern-metadata-error-tests-ok?)) false]
    [(not (compiler-parse-box-error-tests-ok?)) false]
    [(not (compiler-parse-reference-error-tests-ok?)) false]
    [else true]))

;; Top-level declaration parsing: accept value/function `define`,
;; `extern`, `defenum`, `defstruct`, and `import`; reject malformed forms with
;; stable diagnostics. Migrated from src/parser.rs declaration coverage.
(define (compiler-parse-ok? [src : String]) : bool
  (match (parse-ast-source src)
    [(ResultAstProgram.Ok _) true]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-ok-with-cfg?
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (match (parse-ast-source-with-cfg src cfgs)
    [(ResultAstProgram.Ok _) true]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-cfg-decl-count-ok?
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]
  [want : i64]) : bool
  (match (parse-ast-source-with-cfg src cfgs)
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        (= (ast-decl-list-count decls) want))]
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-cfg-error?
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : bool
  (match (parse-ast-source-with-cfg src cfgs)
    [(ResultAstProgram.Ok _) false]
    [(ResultAstProgram.Err _) true]))

(define (compiler-parse-cfg-tests-ok?) : bool
  (let
    [feature-cfg : sym_i64_env.SymI64Env
      (compiler-cfg-enable (compiler-cfg-empty) "feature")]
    [feature-union-cfg : sym_i64_env.SymI64Env
      (compiler-cfg-union (compiler-cfg-empty) "feature")]
    [windows-feature-cfg : sym_i64_env.SymI64Env
      (compiler-cfg-enable feature-cfg "windows")]
    (and
      (compiler-parse-cfg-decl-count-ok?
        "(cfg feature (define answer : i64 42))"
        (compiler-cfg-empty)
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
        (compiler-cfg-empty)
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
        (compiler-cfg-empty)
        1)
      (compiler-parse-cfg-decl-count-ok?
        "(define (main) : i64 (cfg feature (if) 42))"
        (compiler-cfg-empty)
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
      "(define (main [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (set! (array-ref out i) (spmd-broadcast (array-ref xs i) 0))) 0))")
    (compiler-parse-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (set! (array-ref out i) (spmd-shuffle (array-ref xs i) i))) 0))")
    (compiler-parse-ok?
      "(define (main [out : (__tl_dyn-array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (set! (array-ref out i) (+ (program-index) (program-count)))) 0))")
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
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-broadcast 1))"
      "parse: malformed spmd-broadcast")
    (compiler-parse-error-ok?
      "(define (main) : i64 (spmd-shuffle 1))"
      "parse: malformed spmd-shuffle")
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

(define (compiler-parse-resource-with-source) : String
  "(define (main) : i64
  (with ([h (open-handle) close-handle]
         [tmp (open-temp) close-temp])
    (use h)
    (with ([inner (open-inner tmp) close-inner])
      42)))")

(define (compiler-parse-resource-with-shape-ok?) : bool
  (match (parse-ast-source (compiler-parse-resource-with-source))
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
                      (match (__tl-box-place wr-box)
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
                                  (match (__tl-box-place nested-wr-box)
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
    [(ResultAstProgram.Err _) false]))

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
  (match (parse-ast-source
    "(define (mk [e : Expr]) : Expr `(if ,e true false))")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
    [(ResultAstProgram.Err _) false]))

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
  (match (parse-ast-repl-source src)
    [(ResultAstReplItem.Ok item)
      (match item
        [(AstReplDecl _) true]
        [(AstReplExpr _) false])]
    [(ResultAstReplItem.Err _) false]))

(define (compiler-parse-repl-expr-ok? [src : String]) : bool
  (match (parse-ast-repl-source src)
    [(ResultAstReplItem.Ok item)
      (match item
        [(AstReplExpr _) true]
        [(AstReplDecl _) false])]
    [(ResultAstReplItem.Err _) false]))

(define (compiler-parse-repl-error-ok? [src : String] [expected : String]) : bool
  (match (parse-ast-repl-source src)
    [(ResultAstReplItem.Ok _) false]
    [(ResultAstReplItem.Err message) (string.eq message expected)]))

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
    (compiler-parse-repl-error-ok? "(+ 1)" "parse: malformed binary expression")))

;; comptime function-parameter parsing: `[comptime n : i64]`
;; and the type-valued `[comptime T : type]` parse as top-level function
;; parameters marked comptime; a comptime parameter on a lambda is rejected
;; (comptime params are top-level-only). Mirrors the Rust parser's
;; test_parse_comptime_function_param / _type_valued_comptime_param /
;; _comptime_lambda_param_rejected.
(define (compiler-parse-first-fn-has-comptime-param? [src : String]) : bool
  (match (parse-ast-source src)
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        (match (ast.ast-decl-list-step decls)
          [(ast.AstDeclListStep.Cons
              (ast.AstDecl.DefFn decl-meta _ params _ _ _)
              _)
            (ast-param-list-has-comptime? params)]
          [_ false]))]
    [(ResultAstProgram.Err _) false]))

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
  (match (parse-ast-source
    "(defmacro (all [first : bool] [rest : bool ...]) : bool first)")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
    [(ResultAstProgram.Err _) false]))

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
  (match (parse-ast-source
    "(defmacro (catalog [T : type (:kind i64 struct type-var)]) : Module unit)")
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (match (ast.ast-decl-list-step (__tl-box-place decls-box))
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
    [(ResultAstProgram.Err _) false]))

(define (compiler-parse-macro-type-kind-expected-all-id [index : i64]) : i64
  (cond
    [(= index 0) (cbi.compiler-builtin-ctfe-ref 159)]
    [(= index 1) (cbi.compiler-builtin-ctfe-ref 160)]
    [(= index 2) (cbi.compiler-builtin-ctfe-ref 161)]
    [(= index 3) (cbi.compiler-builtin-ctfe-ref 162)]
    [(= index 4) (cbi.compiler-builtin-ctfe-ref 163)]
    [(= index 5) (cbi.compiler-builtin-ctfe-ref 164)]
    [(= index 6) (cbi.compiler-builtin-ctfe-ref 165)]
    [(= index 7) (cbi.compiler-builtin-ctfe-ref 166)]
    [(= index 8) (cbi.compiler-builtin-ctfe-ref 167)]
    [(= index 9) (cbi.compiler-builtin-ctfe-ref 168)]
    [(= index 10) (cbi.compiler-builtin-ctfe-ref 169)]
    [(= index 11) (cbi.compiler-builtin-ctfe-ref 170)]
    [(= index 12) (cbi.compiler-builtin-ctfe-ref 223)]
    [(= index 13) (cbi.compiler-builtin-ctfe-ref 173)]
    [(= index 14) (cbi.compiler-builtin-ctfe-ref 174)]
    [(= index 15) (cbi.compiler-builtin-ctfe-ref 125)]
    [(= index 16) (cbi.compiler-builtin-ctfe-ref 224)]
    [(= index 17) (cbi.compiler-builtin-ctfe-ref 225)]
    [(= index 18) (cbi.compiler-builtin-ctfe-ref 124)]
    [(= index 19) (cbi.compiler-builtin-ctfe-ref 226)]
    [(= index 20) (cbi.compiler-builtin-ctfe-ref 227)]
    [(= index 21) (cbi.compiler-builtin-ctfe-ref 171)]
    [(= index 22) (cbi.compiler-builtin-ctfe-ref 228)]
    [(= index 23) (cbi.compiler-builtin-ctfe-ref 229)]
    [(= index 24) (cbi.compiler-builtin-ctfe-ref 230)]
    [(= index 25) (cbi.compiler-builtin-ctfe-ref 231)]
    [(= index 26) (cbi.compiler-builtin-ctfe-ref 232)]
    [(= index 27) (cbi.compiler-builtin-ctfe-ref 233)]
    [(= index 28) (cbi.compiler-builtin-ctfe-ref 132)]
    [(= index 29) (cbi.compiler-builtin-ctfe-ref 281)]
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
  (match (parse-ast-source source)
    [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
      (match (ast.ast-decl-list-step (__tl-box-place decls-box))
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
    [(ResultAstProgram.Err _) false]))

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
      "(defmacro (all-kinds [T : type (:kind i64 i32 i16 i8 u64 u32 u16 u8 f64 f32 bool char string unit never array dyn-array function tuple struct enum str ptr mut-ptr ref mut-ref region type-var box slice)]) : Module unit)"
      30
      "i64"
      "slice"
      true)))

(define (compiler-parse-fixed-source-id-only-ok?
  [text : String]
  [fixed-id : i64]) : bool
  (let
    [source-id : i64 (reader.stable-symbol-id text)]
    [generated-id : i64 (ci.intern-generated-canonical-name text)]
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
      (parse-ast-macro-type-kind-known?
        (ci.intern-syntax-id-from-raw source-kind))
      (not
        (parse-ast-macro-type-kind-known?
          (ci.intern-syntax-id-from-raw generated-kind)))
      (parse-ast-macro-type-kind-known?
        (ci.intern-syntax-id-from-raw (reader.stable-symbol-id "box")))
      (not
        (parse-ast-macro-type-kind-known?
          (ci.intern-syntax-id-from-raw
            (ci.intern-generated-canonical-name "box"))))
      (= source-all (cbi.compiler-builtin-ctfe-ref 219))
      (not (= generated-all (cbi.compiler-builtin-ctfe-ref 219)))
      (= source-dots (cbi.compiler-builtin-ctfe-ref 222))
      (not (= generated-dots (cbi.compiler-builtin-ctfe-ref 222)))
      (= (reader.stable-symbol-id "slice") (cbi.compiler-builtin-ctfe-ref 281))
      (not
        (=
          (ci.intern-generated-canonical-name "slice")
          (cbi.compiler-builtin-ctfe-ref 281)))
      ;; One adversarial spelling per new fixed-name family proves that equal
      ;; rendered text does not confer parser syntax identity.
      (compiler-parse-fixed-source-id-only-ok?
        ":cleanup"
        (cbi.compiler-builtin-ctfe-ref 234))
      (compiler-parse-fixed-source-id-only-ok?
        "scalar"
        (cbi.compiler-builtin-ctfe-ref 240))
      (compiler-parse-fixed-source-id-only-ok?
        "cfg"
        (cbi.compiler-builtin-ctfe-ref 243))
      (compiler-parse-fixed-source-id-only-ok?
        "sum"
        (cbi.compiler-builtin-ctfe-ref 262))
      (compiler-parse-fixed-source-id-only-ok?
        ":spmd-callable"
        (cbi.compiler-builtin-ctfe-ref 253))
      (compiler-parse-fixed-source-id-only-ok?
        ":abi"
        (cbi.compiler-builtin-ctfe-ref 255))
      (compiler-parse-fixed-source-id-only-ok?
        "as"
        (cbi.compiler-builtin-ctfe-ref 260))
      (compiler-parse-fixed-source-id-only-ok?
        "defgeneric"
        (cbi.compiler-builtin-ctfe-ref 265)))))

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
    [_dispatch : sym_i64_env.SymI64Env (parse-ast-program-dispatch)]
    (match (lexer.spanned-result "(define (f [x : User]) : User x)")
      [(lexer.ResultSpannedTokens.Ok toks)
        (let
          [before : i64 (ci.intern-pool-len)]
          [parsed : ResultAstProgram (parse-ast-program toks)]
          (and
            (= before (ci.intern-pool-len))
            (match parsed
              [(ResultAstProgram.Ok _) true]
              [(ResultAstProgram.Err _) false])))]
      [(lexer.ResultSpannedTokens.Err _) false])))

(define (compiler-parse-spmd-callable-metadata-ok?) : bool
  (and
    (match (parse-ast-source
      "(define (helper [x : i64] [scale : i64])
  (:spmd-callable
    (specialization
      (result varying)
      (args varying uniform)
      (index-param 0)
      (lanes 8)))
  : i64
  (+ x scale))")
      [(ResultAstProgram.Ok (ast.AstProgram.Program decls-box))
        (let
          [decls : ast.AstDeclList (__tl-box-place decls-box)]
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
                      (__tl-box-place specialization.args)]
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

(define (compiler-parse-smoke) : i64
  (match (parse-ast-source (compiler-parse-smoke-source))
    [(ResultAstProgram.Ok program)
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
        (compiler-parse-import-metadata-ok?)
        (compiler-parse-dotted-import-metadata-ok?)
        (compiler-parse-module-macro-surface-ok?)
        (compiler-parse-defdispatch-tests-ok?)
        (compiler-parse-flat-let-call-body-ok?)
        (compiler-parse-implicit-body-tail-ok?)
        (compiler-parse-inline-test-ok?)
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
        (reader.symbol-id-preservation-ok?)
        (compiler-parse-source-symbol-ids-preserved-ok?)
        (compiler-parse-box-ok?)
        (compiler-parse-array-data-ok?)
        (compiler-parse-array-take-ok?)
        (compiler-parse-replace-ok?)
        (compiler-parse-reference-ok?)
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
    [(ResultAstProgram.Err message) (io.panic message)]))