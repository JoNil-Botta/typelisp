;; compiler_parse_core.tl - reader.SpannedSexpr -> real compiler AST parser.
;;
;; This module targets `compiler_ast_types.tl`, not the smaller
;; compile_smoke AST. It stays parser-only: the later selfhost passes consume
;; the parsed `AstProgram` for typechecking/lowering.
(import stdlib.str_cat_runtime as str_cat)
(import compiler_intern as ci)
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_cfg_core as cfg_core)
(import compiler_module_name as module_name)
(import compiler_diagnostic as cdiag)
(import lex as lexer)
(import read as reader)
(import sym_i64_env)
(import stdlib.string)
(import stdlib.option)
(import stdlib.arena)
(import token)
(import (option.option i64) as option_i64)

;; Parser dispatch environments and AST pool contexts are arena-backed shared
;; handles. Recursive parser calls borrow their backing storage; this explicit
;; shallow view keeps those internal handoffs visible under by-value ownership.
(defmacro (compiler-parse-place-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

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
  (ValueName)
  (BindingDefinition))

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

;; Semantic-origin records live in the retained spanned-node sidecar pool. A
;; source index asks for one run per declaration, so rescanning that entire
;; pool for every slot makes a sequence of cached checks quadratic. Incrementally
;; index appended sidecars instead, and invalidate the table when the reader
;; resets its pool. Alias entries are expanded by destination slot so lookup
;; remains constant-time and the existing bounded alias walk is preserved.
(defstruct CompilerParseSemanticOriginLookupSlot
  (generation i64)
  ;; 1 = semantic occurrence run, 2 = declaration span.
  (domain i64)
  (key i64)
  (slot i64)
  ;; 1 = direct semantic run, 2 = origin alias, 3 = direct declaration span.
  (kind i64)
  (run-start i64)
  (run-count i64)
  (source-key i64)
  (source-slot i64))

(define compiler-parse-semantic-origin-lookup-arena : i64
  (arena.tl_arena_make))
(define compiler-parse-semantic-origin-lookup-slots : (__tl_dyn-array
    CompilerParseSemanticOriginLookupSlot)
  (__tl_make-array CompilerParseSemanticOriginLookupSlot 0))
(define compiler-parse-semantic-origin-lookup-len : i64
  0)
(define compiler-parse-semantic-origin-lookup-generation : i64
  1)
(define compiler-parse-semantic-origin-lookup-indexed-len : i64
  0)
(define compiler-parse-semantic-origin-lookup-reader-reset-generation : i64
  0)

(define (compiler-parse-semantic-origin-lookup-slots-shared) : (__tl_dyn-array
    CompilerParseSemanticOriginLookupSlot)
  (unsafe
    (ptr-read (ptr-addr-of compiler-parse-semantic-origin-lookup-slots))))

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
    (if (> items.len 0)
      (unsafe
        (compiler-parse-runtime-copy-bytes!
          (ptr-cast (__tl_array-data next) : (MutPtr u8))
          (ptr-cast (__tl_array-data old) : (Ptr u8))
          (* items.len 56)))
      unit)
    (set! items.items next)))

(define (parse-semantic-origin-vec-push!
  [items : (&mut items ParseSemanticOriginVec)]
  [origin : ParseSemanticOriginRecord]) : unit
  (if (>= items.len (array-length items.items))
    (parse-semantic-origin-vec-grow! items)
    unit)
  (set! (array-ref items.items items.len) origin)
  (set! items.len (+ items.len 1)))

(defstruct CompilerParseSemanticOriginCaptureState
  (active bool)
  (binding-origins bool)
  (vec-addr i64)
  (decl-slot i64)
  (name-view ci.InternSemanticNameView))

(define compiler-parse-semantic-origin-capture-active : bool
  false)
(define compiler-parse-semantic-binding-origin-capture-active : bool
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
  (set! compiler-parse-semantic-origin-capture-active false)
  (set! compiler-parse-semantic-binding-origin-capture-active false)
  (set! compiler-parse-semantic-origin-capture-vec-addr 0)
  (set! compiler-parse-semantic-origin-capture-decl-slot 0)
  (set!
    (array-ref compiler-parse-semantic-origin-capture-name-view 0)
    (compiler-parse-semantic-origin-empty-name-view-shared))
  (set! compiler-parse-semantic-quote-depth 0))

(define (compiler-parse-token-span-from-ast-span [span : ast.AstSourceSpan]) : token.SourceSpan
  (token.SourceSpan
    (ast.ast-source-span-start-line span)
    (ast.ast-source-span-start-col span)
    (ast.ast-source-span-end-line span)
    (ast.ast-source-span-end-col span)))

;; Origin rows carry their marker as a reset-aware builtin intern id. Writers
;; and scanners use the id, so no origin row renders or compares its marker.
(defmacro (compiler-parse-marker [spelling : Expr]) : Expr
  `(ci.intern-id-from-renderable (cbi.compiler-builtin-ctfe ,spelling)))

(defmacro (compiler-parse-marker? [marker : Expr] [spelling : Expr]) : Expr
  `(ci.intern-id-eq? ,marker (compiler-parse-marker ,spelling)))

(define (compiler-parse-semantic-origin-kind-marker
  [kind : CompilerParseSemanticOriginKind]) : ci.InternId
  (match kind
    [(TypeName) (compiler-parse-marker "__tl_semantic_origin_type_name")]
    [(TypeDefinition)
      (compiler-parse-marker "__tl_semantic_origin_type_definition")]
    [(StructFieldDefinition)
      (compiler-parse-marker "__tl_semantic_origin_struct_field_definition")]
    [(EnumVariantDefinition)
      (compiler-parse-marker "__tl_semantic_origin_enum_variant_definition")]
    [(StructFieldUse)
      (compiler-parse-marker "__tl_semantic_origin_struct_field_use")]
    [(EnumVariantPattern)
      (compiler-parse-marker "__tl_semantic_origin_enum_variant_pattern")]
    [(DispatchFunction)
      (compiler-parse-marker "__tl_semantic_origin_dispatch_function")]
    [(ModuleDefinition)
      (compiler-parse-marker "__tl_semantic_origin_module_definition")]
    [(ModulePath) (compiler-parse-marker "__tl_semantic_origin_module_path")]
    [(ImportAlias) (compiler-parse-marker "__tl_semantic_origin_import_alias")]
    [(ValueQualifier)
      (compiler-parse-marker "__tl_semantic_origin_value_qualifier")]
    [(ValueName) (compiler-parse-marker "__tl_semantic_origin_value_name")]
    [(BindingDefinition)
      (compiler-parse-marker "__tl_semantic_origin_binding_definition")]))

(define (compiler-parse-semantic-origin-kind-tag
  [kind : CompilerParseSemanticOriginKind]) : i64
  (match kind
    [(TypeName) 1]
    [(TypeDefinition) 0]
    [(StructFieldDefinition) 2]
    [(EnumVariantDefinition) 3]
    [(StructFieldUse) 4]
    [(EnumVariantPattern) 5]
    [(DispatchFunction) 6]
    [(ModuleDefinition) 7]
    [(ModulePath) 8]
    [(ImportAlias) 9]
    [(ValueQualifier) 10]
    [(ValueName) 11]
    [(BindingDefinition) 12]))

(define (compiler-parse-semantic-origin-kind-tag-from-marker
  [marker : ci.InternId]) : i64
  (cond
    [(compiler-parse-marker? marker "__tl_semantic_origin_type_name") 1]
    [(compiler-parse-marker? marker "__tl_semantic_origin_type_definition") 0]
    [(compiler-parse-marker?
        marker
        "__tl_semantic_origin_struct_field_definition")
      2]
    [(compiler-parse-marker?
        marker
        "__tl_semantic_origin_enum_variant_definition")
      3]
    [(compiler-parse-marker? marker "__tl_semantic_origin_struct_field_use") 4]
    [(compiler-parse-marker? marker "__tl_semantic_origin_enum_variant_pattern")
      5]
    [(compiler-parse-marker? marker "__tl_semantic_origin_dispatch_function") 6]
    [(compiler-parse-marker? marker "__tl_semantic_origin_module_definition") 7]
    [(compiler-parse-marker? marker "__tl_semantic_origin_module_path") 8]
    [(compiler-parse-marker? marker "__tl_semantic_origin_import_alias") 9]
    [(compiler-parse-marker? marker "__tl_semantic_origin_value_qualifier") 10]
    [(compiler-parse-marker? marker "__tl_semantic_origin_value_name") 11]
    [(compiler-parse-marker? marker "__tl_semantic_origin_binding_definition")
      12]
    [else -1]))

(define (compiler-parse-semantic-origin-kind-from-tag [tag : i64]) : CompilerParseSemanticOriginKind
  (cond
    [(= tag 1) (TypeName)]
    [(= tag 0) (TypeDefinition)]
    [(= tag 2) (StructFieldDefinition)]
    [(= tag 3) (EnumVariantDefinition)]
    [(= tag 4) (StructFieldUse)]
    [(= tag 5) (EnumVariantPattern)]
    [(= tag 6) (DispatchFunction)]
    [(= tag 7) (ModuleDefinition)]
    [(= tag 8) (ModulePath)]
    [(= tag 9) (ImportAlias)]
    [(= tag 10) (ValueQualifier)]
    [(= tag 12) (BindingDefinition)]
    [else (ValueName)]))

(define (compiler-parse-semantic-origin-capture-current) : CompilerParseSemanticOriginCaptureState
  (CompilerParseSemanticOriginCaptureState
    compiler-parse-semantic-origin-capture-active
    compiler-parse-semantic-binding-origin-capture-active
    compiler-parse-semantic-origin-capture-vec-addr
    compiler-parse-semantic-origin-capture-decl-slot
    (compiler-parse-semantic-origin-capture-name-view-shared)))

(define (compiler-parse-semantic-origin-capture-select!
  [items : (MutPtr ParseSemanticOriginVec)]
  [decl-slot : i64]) : unit
  (set!
    compiler-parse-semantic-origin-capture-vec-addr
    (unsafe
      (cast (ptr->int (ptr-cast items : (Ptr u8))) : i64)))
  (set! compiler-parse-semantic-origin-capture-decl-slot decl-slot))

(define (compiler-parse-semantic-origin-capture-begin!
  [name-view : ci.InternSemanticNameView]
  [items : (MutPtr ParseSemanticOriginVec)]
  [decl-slot : i64]
  [binding-origins : bool]) : unit
  (set! compiler-parse-semantic-origin-capture-active true)
  (set! compiler-parse-semantic-binding-origin-capture-active binding-origins)
  (set!
    (array-ref compiler-parse-semantic-origin-capture-name-view 0)
    name-view)
  (compiler-parse-semantic-origin-capture-select! items decl-slot))

(define (compiler-parse-semantic-origin-capture-restore!
  [state : CompilerParseSemanticOriginCaptureState]) : unit
  (set! compiler-parse-semantic-origin-capture-active state.active)
  (set!
    compiler-parse-semantic-binding-origin-capture-active
    state.binding-origins)
  (set! compiler-parse-semantic-origin-capture-vec-addr state.vec-addr)
  (set! compiler-parse-semantic-origin-capture-decl-slot state.decl-slot)
  (set!
    (array-ref compiler-parse-semantic-origin-capture-name-view 0)
    state.name-view))

(define (compiler-parse-semantic-origin-capture-end!) : unit
  (set! compiler-parse-semantic-origin-capture-active false)
  (set! compiler-parse-semantic-binding-origin-capture-active false)
  (set! compiler-parse-semantic-origin-capture-vec-addr 0)
  (set! compiler-parse-semantic-origin-capture-decl-slot 0)
  (set!
    (array-ref compiler-parse-semantic-origin-capture-name-view 0)
    (compiler-parse-semantic-origin-empty-name-view-shared)))

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
        (ptr-write! items-ptr items)))))

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
                    (compiler-parse-semantic-origin-push-active!
                      final-kind
                      current
                      (token.SourceSpan
                        (token.span-start-line span)
                        start-col
                        (token.span-end-line span)
                        (+ start-col n)))
                    (set! done true)))))))))))

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
              (compiler-parse-semantic-origin-push-components!
                name
                span
                (ValueQualifier)
                (ValueName))
              (compiler-parse-semantic-origin-push-components!
                (ci.intern-syntax-id-from-raw fields-id)
                (token.SourceSpan
                  (token.span-start-line span)
                  start-col
                  (token.span-start-line span)
                  (+ start-col (string.string-length fields-text)))
                (StructFieldUse)
                (StructFieldUse)))))))
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
    (match (reader.sp-node-get cursor)
      [(Int _ marker _)
        (if (compiler-parse-marker? marker "__tl_semantic_origin")
          (match (reader.sp-node-get (+ cursor 1))
            [(Int _ run-marker run-span)
              (let
                [count : i64 (token.span-start-line run-span)]
                [next : i64 (+ (+ cursor 2) count)]
                (if (and
                  (compiler-parse-marker?
                    run-marker
                    "__tl_semantic_origin_start")
                  (>= count 0)
                  (<= next limit))
                  next
                  (+ cursor 1)))]
            [_ (+ cursor 1)])
          (+ cursor 1))]
      [_ (+ cursor 1)])
    (+ cursor 1)))

(define (compiler-parse-semantic-origin-lookup-cache-reset!) : unit
  (set!
    compiler-parse-semantic-origin-lookup-generation
    (+ compiler-parse-semantic-origin-lookup-generation 1))
  (set! compiler-parse-semantic-origin-lookup-len 0)
  (set! compiler-parse-semantic-origin-lookup-indexed-len 0))

(define (compiler-parse-semantic-origin-lookup-prepare!) : unit
  (let
    [reader-generation : i64 (reader.sp-node-pool-reset-generation-value)]
    [pool-len : i64 (reader.sp-node-pool-len)]
    (when
      (or
        (!=
          reader-generation
          compiler-parse-semantic-origin-lookup-reader-reset-generation)
        (< pool-len compiler-parse-semantic-origin-lookup-indexed-len))
      (compiler-parse-semantic-origin-lookup-cache-reset!)
      (set!
        compiler-parse-semantic-origin-lookup-reader-reset-generation
        reader-generation))
    (if (< compiler-parse-semantic-origin-lookup-indexed-len pool-len)
      (compiler-parse-semantic-origin-lookup-build!)
      unit)))

(define (compiler-parse-semantic-origin-lookup-hash
  [domain : i64]
  [key : i64]
  [slot : i64]
  [capacity : i64]) : i64
  (let
    [mixed : i64
      (bit-xor
        (bit-xor (* key 2654435761) (* domain 3266489917))
        (bit-xor (* (+ slot 1) 2246822519) (shr key 29)))]
    (bit-and (bit-xor mixed (shr mixed 31)) (- capacity 1))))

(define (compiler-parse-semantic-origin-lookup-insert-no-grow!
  [domain : i64]
  [key : i64]
  [slot : i64]
  [kind : i64]
  [run-start : i64]
  [run-count : i64]
  [source-key : i64]
  [source-slot : i64]) : unit
  (let
    [capacity : i64 (array-length compiler-parse-semantic-origin-lookup-slots)]
    [cursor : i64
      (compiler-parse-semantic-origin-lookup-hash domain key slot capacity)]
    [done : bool false]
    (while (not done)
      (let
        [entry : CompilerParseSemanticOriginLookupSlot
          (array-ref compiler-parse-semantic-origin-lookup-slots cursor)]
        (if (!=
          entry.generation
          compiler-parse-semantic-origin-lookup-generation)
          (begin
            (set!
              (array-ref compiler-parse-semantic-origin-lookup-slots cursor)
              (CompilerParseSemanticOriginLookupSlot
                compiler-parse-semantic-origin-lookup-generation
                domain
                key
                slot
                kind
                run-start
                run-count
                source-key
                source-slot))
            (set!
              compiler-parse-semantic-origin-lookup-len
              (+ compiler-parse-semantic-origin-lookup-len 1))
            (set! done true))
          (if (and
            (= entry.domain domain)
            (= entry.key key)
            (= entry.slot slot))
            (begin
              ;; Sidecar storage is append-only between resets. Replacing an
              ;; existing slot therefore keeps latest-wins behavior when an
              ;; address is reused or an alias is superseded.
              (set!
                (array-ref compiler-parse-semantic-origin-lookup-slots cursor)
                (CompilerParseSemanticOriginLookupSlot
                  compiler-parse-semantic-origin-lookup-generation
                  domain
                  key
                  slot
                  kind
                  run-start
                  run-count
                  source-key
                  source-slot))
              (set! done true))
            (set! cursor (bit-and (+ cursor 1) (- capacity 1)))))))))

(define (compiler-parse-semantic-origin-lookup-grow!) : unit
  (let
    [old : (__tl_dyn-array CompilerParseSemanticOriginLookupSlot)
      (compiler-parse-semantic-origin-lookup-slots-shared)]
    [old-capacity : i64 (array-length old)]
    [next-capacity : i64
      (if (< old-capacity 1)
        1024
        (* old-capacity 2))]
    [next : (__tl_dyn-array CompilerParseSemanticOriginLookupSlot)
      (in-arena
        (arena.Arena compiler-parse-semantic-origin-lookup-arena)
        (__tl_make-array CompilerParseSemanticOriginLookupSlot next-capacity))]
    [old-index : i64 0]
    (set! compiler-parse-semantic-origin-lookup-slots next)
    (set! compiler-parse-semantic-origin-lookup-len 0)
    (while (< old-index old-capacity)
      (let
        [entry : CompilerParseSemanticOriginLookupSlot
          (array-ref old old-index)]
        (if (=
          entry.generation
          compiler-parse-semantic-origin-lookup-generation)
          (compiler-parse-semantic-origin-lookup-insert-no-grow!
            entry.domain
            entry.key
            entry.slot
            entry.kind
            entry.run-start
            entry.run-count
            entry.source-key
            entry.source-slot)
          unit)
        (set! old-index (+ old-index 1))))))

(define (compiler-parse-semantic-origin-lookup-insert!
  [domain : i64]
  [key : i64]
  [slot : i64]
  [kind : i64]
  [run-start : i64]
  [run-count : i64]
  [source-key : i64]
  [source-slot : i64]) : unit
  (if (or
    (< (array-length compiler-parse-semantic-origin-lookup-slots) 1)
    (>=
      (* (+ compiler-parse-semantic-origin-lookup-len 1) 10)
      (* (array-length compiler-parse-semantic-origin-lookup-slots) 7)))
    (compiler-parse-semantic-origin-lookup-grow!)
    unit)
  (compiler-parse-semantic-origin-lookup-insert-no-grow!
    domain
    key
    slot
    kind
    run-start
    run-count
    source-key
    source-slot))

(define (compiler-parse-semantic-origin-lookup-build!) : unit
  (let
    [cursor : i64 compiler-parse-semantic-origin-lookup-indexed-len]
    [limit : i64 (reader.sp-node-pool-len)]
    (while (< cursor limit)
      (match (reader.sp-node-get cursor)
        [(Int record-key marker marker-span)
          (cond
            [(and
                (compiler-parse-marker? marker "__tl_semantic_origin")
                (< (+ cursor 1) limit))
              (match (reader.sp-node-get (+ cursor 1))
                [(Int run-slot run-marker run-span)
                  (let
                    [count : i64 (token.span-start-line run-span)]
                    (if (and
                      (compiler-parse-marker?
                        run-marker
                        "__tl_semantic_origin_start")
                      (>= count 0)
                      (<= (+ (+ cursor 2) count) limit))
                      (compiler-parse-semantic-origin-lookup-insert!
                        1
                        record-key
                        run-slot
                        1
                        (+ cursor 2)
                        count
                        0
                        0)
                      unit))]
                [_ unit])]
            [(and
                (compiler-parse-marker? marker "__tl_decl_origin")
                (< (+ cursor 2) limit))
              (match (reader.sp-node-get (+ cursor 1))
                [(Int run-slot run-marker _)
                  (if (compiler-parse-marker?
                    run-marker
                    "__tl_decl_origin_start")
                    (match (reader.sp-node-get (+ cursor 2))
                      [(List _ 0 span)
                        (compiler-parse-semantic-origin-lookup-insert!
                          2
                          record-key
                          run-slot
                          3
                          (token.span-start-line span)
                          (token.span-start-col span)
                          (token.span-end-line span)
                          (token.span-end-col span))]
                      [_ unit])
                    unit)]
                [_ unit])]
            [(or
                (compiler-parse-marker? marker "__tl_decl_origin_alias")
                (compiler-parse-marker? marker "__tl_decl_origin_alias_repeat"))
              (let
                [target-start : i64 (token.span-start-line marker-span)]
                [count : i64 (token.span-start-col marker-span)]
                [source-key : i64 (token.span-end-line marker-span)]
                [source-start : i64 (token.span-end-col marker-span)]
                [repeat : bool
                  (compiler-parse-marker?
                    marker
                    "__tl_decl_origin_alias_repeat")]
                [offset : i64 0]
                (while (< offset count)
                  (if repeat
                    unit
                    (compiler-parse-semantic-origin-lookup-insert!
                      1
                      record-key
                      (+ target-start offset)
                      2
                      0
                      0
                      source-key
                      (+ source-start offset)))
                  (compiler-parse-semantic-origin-lookup-insert!
                    2
                    record-key
                    (+ target-start offset)
                    2
                    0
                    0
                    source-key
                    (if repeat
                      source-start
                      (+ source-start offset)))
                  (set! offset (+ offset 1))))]
            [else unit])]
        [_ unit])
      (set! cursor (compiler-parse-semantic-origin-next-record cursor limit)))
    (set! compiler-parse-semantic-origin-lookup-indexed-len limit)))

(define (compiler-parse-semantic-origin-lookup
  [domain : i64]
  [key : i64]
  [slot : i64]) : CompilerParseSemanticOriginLookupSlot
  (let
    [capacity : i64 (array-length compiler-parse-semantic-origin-lookup-slots)]
    [cursor : i64
      (if (> capacity 0)
        (compiler-parse-semantic-origin-lookup-hash domain key slot capacity)
        0)]
    [probes : i64 0]
    [fallback : CompilerParseSemanticOriginLookupSlot
      (CompilerParseSemanticOriginLookupSlot 0 0 0 0 0 0 0 0 0)]
    (if (< capacity 1)
      fallback
      (begin
        (while (< probes capacity)
          (let
            [entry : CompilerParseSemanticOriginLookupSlot
              (array-ref compiler-parse-semantic-origin-lookup-slots cursor)]
            (if (!=
              entry.generation
              compiler-parse-semantic-origin-lookup-generation)
              (return fallback)
              (if (and
                (= entry.domain domain)
                (= entry.key key)
                (= entry.slot slot))
                (return entry)
                (begin
                  (set! cursor (bit-and (+ cursor 1) (- capacity 1)))
                  (set! probes (+ probes 1)))))))
        fallback))))

;; Declaration origins are cold records in the transient spanned-node pool.
;; A run is marker(key), marker(start slot), then one Nil(span) per slot.
(define (compiler-parse-decl-origin-span-key-slot-depth
  [key : i64]
  [target : i64]
  [depth : i64]) : CompilerParseMaybeDeclSpan
  (if (>= depth 64)
    None
    (begin
      (compiler-parse-semantic-origin-lookup-prepare!)
      (let
        [entry : CompilerParseSemanticOriginLookupSlot
          (compiler-parse-semantic-origin-lookup 2 key target)]
        (cond
          [(= entry.kind 3)
            (Some
              (ast-source-span-from-source-span
                (token.SourceSpan
                  entry.run-start
                  entry.run-count
                  entry.source-key
                  entry.source-slot)))]
          [(= entry.kind 2)
            (compiler-parse-decl-origin-span-key-slot-depth
              entry.source-key
              entry.source-slot
              (+ depth 1))]
          [else None])))))

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
    [(Some span)
      (let
        [marker-span : token.SourceSpan
          (compiler-parse-token-span-from-ast-span span)]
        (reader.sp-node-push
          (Int key (compiler-parse-marker "__tl_decl_origin") marker-span))
        (reader.sp-node-push
          (Int
            slot
            (compiler-parse-marker "__tl_decl_origin_start")
            marker-span))
        (reader.sp-node-push (reader.spanned-sexpr-empty marker-span))
        unit)]
    [(None) unit]))

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
        (Int
          (compiler-parse-decl-list-storage-key decls)
          (if repeat
            (compiler-parse-marker "__tl_decl_origin_alias_repeat")
            (compiler-parse-marker "__tl_decl_origin_alias"))
          (token.SourceSpan
            (+ decls.offset decl-slot)
            count
            source-key
            source-slot)))
      unit)))

(define (compiler-parse-decl-origin-copy-direct-records!
  [source : (& source ast.AstDeclList)]
  [dest : (& dest ast.AstDeclList)]
  [dest-slot : i64]
  [scan-start : i64]
  [scan-end : i64]) : unit
  (let
    [source-key : i64 (compiler-parse-decl-list-storage-key source)]
    [source-start : i64 source.offset]
    [source-end : i64 (+ source-start (ast.ast-decl-list-len source))]
    [dest-key : i64 (compiler-parse-decl-list-storage-key dest)]
    [dest-start : i64 (+ dest.offset dest-slot)]
    [cursor : i64 scan-start]
    [limit : i64 scan-end]
    (while (< cursor limit)
      (match (reader.sp-node-get cursor)
        [(Int record-key marker _)
          (if (= record-key source-key)
            (cond
              [(and
                  (compiler-parse-marker? marker "__tl_decl_origin")
                  (< (+ cursor 2) limit))
                (match (reader.sp-node-get (+ cursor 1))
                  [(Int record-slot run-marker marker-span)
                    (if (and
                      (compiler-parse-marker?
                        run-marker
                        "__tl_decl_origin_start")
                      (>= record-slot source-start)
                      (< record-slot source-end))
                      (begin
                        (reader.sp-node-push
                          (Int
                            dest-key
                            (compiler-parse-marker "__tl_decl_origin")
                            marker-span))
                        (reader.sp-node-push
                          (Int
                            (+ dest-start (- record-slot source-start))
                            (compiler-parse-marker "__tl_decl_origin_start")
                            marker-span))
                        (reader.sp-node-push (reader.sp-node-get (+ cursor 2)))
                        unit)
                      unit)]
                  [_ unit])]
              [(and
                  (compiler-parse-marker? marker "__tl_semantic_origin")
                  (< (+ cursor 1) limit))
                (match (reader.sp-node-get (+ cursor 1))
                  [(Int record-slot run-marker run-span)
                    (let
                      [count : i64 (token.span-start-line run-span)]
                      (if (and
                        (compiler-parse-marker?
                          run-marker
                          "__tl_semantic_origin_start")
                        (>= record-slot source-start)
                        (< record-slot source-end)
                        (>= count 0)
                        (<= (+ (+ cursor 2) count) limit))
                        (let
                          [record-index : i64 0]
                          (reader.sp-node-push
                            (Int
                              dest-key
                              (compiler-parse-marker "__tl_semantic_origin")
                              run-span))
                          (reader.sp-node-push
                            (Int
                              (+ dest-start (- record-slot source-start))
                              (compiler-parse-marker
                                "__tl_semantic_origin_start")
                              run-span))
                          (while (< record-index count)
                            (begin
                              (reader.sp-node-push
                                (reader.sp-node-get
                                  (+ (+ cursor 2) record-index)))
                              unit)
                            (set! record-index (+ record-index 1))))
                        unit))]
                  [_ unit])]
              [else unit])
            unit)]
        [_ unit])
      (set! cursor (compiler-parse-semantic-origin-next-record cursor limit)))))

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
    (while (< index len)
      (let
        [item : CompilerParseDeclOriginAlias (array-ref old-items index)]
        (set!
          (array-ref next-items index)
          (CompilerParseDeclOriginAlias
            item.target-start
            item.count
            item.source-key
            item.source-slot))
        (set! index (+ index 1))))
    (set! aliases.items next-items)))

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
    (unless
      (compiler-parse-decl-origin-alias-vec-extend-last?
        aliases
        target-start
        count
        source-key
        source-slot
        repeat)
      (if (>= aliases.len (array-length aliases.items))
        (compiler-parse-decl-origin-alias-vec-grow! aliases)
        unit)
      (let
        [index : i64 aliases.len]
        (set!
          (array-ref aliases.items index)
          (CompilerParseDeclOriginAlias
            target-start
            count
            source-key
            (if repeat
              (- (- 0 source-slot) 1)
              source-slot)))
        (set! aliases.len (+ index 1))))
    unit))

(define (compiler-parse-decl-origin-alias-vec-register!
  [decls : (& decls ast.AstDeclList)]
  [aliases : (& aliases CompilerParseDeclOriginAliasVec)]) : unit
  (let
    [index : i64 0]
    (while (< index aliases.len)
      (let
        [alias : CompilerParseDeclOriginAlias (array-ref aliases.items index)]
        (compiler-parse-decl-origin-register-alias-record!
          decls
          alias.target-start
          alias.count
          alias.source-key
          (if (< alias.source-slot 0)
            (- (- 0 alias.source-slot) 1)
            alias.source-slot)
          (< alias.source-slot 0))
        (set! index (+ index 1))))))

;; Semantic occurrence runs are direct records keyed by declaration storage and
;; slot. A normal declaration-origin alias preserves the run; a repeat alias is
;; intentionally ignored because it represents a one-to-many generated rewrite
;; whose new declarations have no independent editable source occurrences.
(define (compiler-parse-semantic-origin-run-key-slot-depth
  [key : i64]
  [target : i64]
  [depth : i64]) : CompilerParseMaybeSemanticOriginRun
  (if (>= depth 64)
    None
    (begin
      (compiler-parse-semantic-origin-lookup-prepare!)
      (let
        [entry : CompilerParseSemanticOriginLookupSlot
          (compiler-parse-semantic-origin-lookup 1 key target)]
        (cond
          [(= entry.kind 1)
            (Some
              (CompilerParseSemanticOriginRun entry.run-start entry.run-count))]
          [(= entry.kind 2)
            (compiler-parse-semantic-origin-run-key-slot-depth
              entry.source-key
              entry.source-slot
              (+ depth 1))]
          [else None])))))

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
    (TypeName)
    cbi.compiler-builtin-id-fix-empty
    (ast.ast-decl-span-fallback)
    -1))

(define (compiler-parse-semantic-origin-run-get
  [run : (& run CompilerParseSemanticOriginRun)]
  [index : i64]
  [fallback : CompilerParseSemanticOrigin]) : CompilerParseSemanticOrigin
  (if (and (>= index 0) (< index run.count))
    (match (reader.sp-node-get (+ run.start index))
      [(Int written-name marker span)
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
    (while (< cursor limit)
      (match (reader.sp-node-get cursor)
        [(Int record-key marker marker-span)
          (if (and
            (= record-key key)
            (compiler-parse-marker? marker "__tl_member_origin"))
            (let
              [record-index : i64 (+ cursor 1)]
              [record-offset : i64 0]
              [done : bool false]
              ;; The marker span is the aggregate name and remains a
              ;; useful fallback if a later transform appends a member.
              (set! result (ast-source-span-from-source-span marker-span))
              (while (and (not done) (< record-index limit))
                (match (reader.sp-node-get record-index)
                  [(List _ 0 span)
                    (if (= record-offset member-index)
                      (begin
                        (set! result (ast-source-span-from-source-span span))
                        (set! done true))
                      (begin
                        (set! record-index (+ record-index 1))
                        (set! record-offset (+ record-offset 1))))]
                  [_ (set! done true)])))
            unit)]
        [_ unit])
      (set! cursor (compiler-parse-semantic-origin-next-record cursor limit)))
    result))

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
    (while (< read-index end)
      (reader.sp-node-pool-fill! write-index (reader.sp-node-get read-index))
      (set! write-index (+ write-index 1))
      (set! read-index (+ read-index 1)))
    (reader.sp-node-pool-truncate! write-index)))

(defenum ResultAstType
  (Ok ast.AstType)
  (Err String))

(defenum ResultAstReduceOp
  (Ok ast.AstReduceOp)
  (Err String))

(defstruct ParseAstSpmdTypedRangeBinding
  (name i64)
  (ty ast.AstType)
  (start reader.SpannedSexpr)
  (end reader.SpannedSexpr))

(defenum ResultParseAstSpmdTypedRangeBinding
  (Ok ParseAstSpmdTypedRangeBinding)
  (Err String))

(defstruct ParseAstSpmdStateBinding
  (name i64)
  (ty ast.AstType)
  (init reader.SpannedSexpr))

(defenum ResultParseAstSpmdStateBinding
  (Ok ParseAstSpmdStateBinding)
  (Err String))

(defstruct ParseAstSpmdTypedBinding
  (name i64)
  (ty ast.AstType))

(defenum ResultParseAstSpmdTypedBinding
  (Ok ParseAstSpmdTypedBinding)
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

(defenum ResultAstFieldDefList
  (Ok ast.AstFieldDefList)
  (Err String))

(defenum ResultAstFieldCleanup
  (Ok ast.AstFieldCleanup)
  (Err String))

(defenum ResultAstStructRepr
  (Ok ast.AstStructRepr)
  (Err String))

(defenum ResultAstDeclaredAlign
  (Ok i64)
  (Err String))

;; A parsed field and its declared `(:align N)` value (0 when absent).
(defenum ResultAstFieldParts
  (Ok ast.AstFieldDef i64)
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
    i64
    ast.AstFieldDefList)
  (Err String))

(defenum ResultAstEnumDefParts
  (Ok ast.AstLifetimeList ast.AstEnumCleanup i64 ast.AstVariantDefList)
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

(defenum ResultAstTestMetadataForms
  (Ok ast.AstTestMetadata reader.SpannedSexpr)
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

;; A REPL parse error is an E0100 diagnostic located in the input, with an
;; empty path the REPL names.
(defenum ResultAstReplItem
  (Ok AstReplItem)
  (Err (Box cdiag.CompilerDiagnostic)))

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
  (intern-owner (__tl_dyn-array ci.InternCompatState)))

;; Kept inline in each parser entry frame so spanned-node arena rewinds cannot
;; invalidate the diagnostic span and dispatch-control fast path.
(defstruct CompilerParseInvocationFrame
  (has-error i64)
  (start-line i64)
  (start-col i64)
  (end-line i64)
  (end-col i64)
  (control i64))

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
(define compiler-parse-state-control-binding-origins : i64
  9)
(define compiler-parse-state-marker-id : i64
  -2)
(define compiler-parse-invocation-marker-id : i64
  -3)
(define compiler-parse-invocation-control-marker-id : i64
  -4)
(define compiler-parse-invocation-control-slot : i64
  5)

(defmacro (compiler-parse-array-data-addr [items : Expr]) : Expr
  `(cast
    (unsafe
      (ptr->int (ptr-cast (__tl_array-data ,items) : (Ptr u8))))
    : i64))

(define (compiler-parse-state-new-from-owner
  [owner : (__tl_dyn-array ci.InternCompatState)]) : CompilerParseState
  (let
    [control : (__tl_dyn-array i64) (__tl_make-array i64 10)]
    [keys : (__tl_dyn-array i64) (__tl_make-array i64 512)]
    [tags : (__tl_dyn-array i64) (__tl_make-array i64 512)]
    [cache : (__tl_dyn-array sym_i64_env.SymI64Env)
      (__tl_make-array sym_i64_env.SymI64Env 1)]
    (set! (array-ref cache 0) (sym_i64_env.sym-i64-empty))
    (set!
      (array-ref control compiler-parse-state-control-keys-addr)
      (compiler-parse-array-data-addr keys))
    (set!
      (array-ref control compiler-parse-state-control-tags-addr)
      (compiler-parse-array-data-addr tags))
    (set!
      (array-ref control compiler-parse-state-control-cache-addr)
      (compiler-parse-array-data-addr cache))
    (set!
      (array-ref control compiler-parse-state-control-owner-addr)
      (if (= (array-length owner) 0)
        0
        (compiler-parse-array-data-addr owner)))
    (set! (array-ref control compiler-parse-state-control-cache-generation) -1)
    (set! (array-ref control compiler-parse-state-control-cache-table-id) -1)
    (set! (array-ref control compiler-parse-state-control-marker-id) -1)
    (set! (array-ref control compiler-parse-state-control-ready) 0)
    (set! (array-ref control compiler-parse-state-control-binding-origins) 0)
    (CompilerParseState control keys tags cache owner)))

(define (compiler-parse-state-new) : CompilerParseState
  (compiler-parse-state-new-from-owner (__tl_make-array ci.InternCompatState 0)))

;; Binding tokens are requested by the checked semantic-facts consumer. The
;; ordinary parser stores no extra token occurrences for this option.
(define (compiler-parse-state-set-binding-origins!
  [state : (& state CompilerParseState)]
  [enabled : bool]) : unit
  (set!
    (array-ref state.control compiler-parse-state-control-binding-origins)
    (if enabled
      1
      0)))

(define (compiler-parse-binding-origins-enabled
  [dispatch : sym_i64_env.SymI64Env]) : bool
  (let
    [invocation : i64 (compiler-parse-dispatch-invocation-control dispatch)]
    [control : i64
      (if (!= invocation 0)
        invocation
        (compiler-parse-dispatch-indexed-control dispatch))]
    (and
      (!= control 0)
      (!=
        (compiler-parse-raw-i64-ref
          control
          compiler-parse-state-control-binding-origins)
        0))))

;; The parse control option is sampled when a capture scope begins and is
;; saved/restored with that scope. Disabled binding hooks never inspect tokens
;; or construct dispatch views.
(defmacro (compiler-parse-semantic-token-origin!
  [_dispatch : Expr]
  [node : Expr]
  [kind : Expr]) : Expr
  `(when
    compiler-parse-semantic-binding-origin-capture-active
    (compiler-parse-semantic-token-origin-active! ,node ,kind)))

(define (compiler-parse-semantic-token-origin-active!
  [node : reader.SpannedSexpr]
  [kind : CompilerParseSemanticOriginKind]) : unit
  (match (reader.spanned-sexpr-view node)
    [(Sym name span)
      (compiler-parse-semantic-origin-push!
        kind
        (ci.intern-syntax-id-value name)
        span)]
    [_ unit]))

(define (compiler-parse-state-new-with-intern-state
  [intern-state : ci.InternCompatState]) : CompilerParseState
  (let
    [owner : (__tl_dyn-array ci.InternCompatState)
      (__tl_make-array ci.InternCompatState 1)]
    (set! (array-ref owner 0) intern-state)
    (compiler-parse-state-new-from-owner owner)))

(define (compiler-parse-state-control-addr [state : CompilerParseState]) : i64
  (compiler-parse-array-data-addr state.control))

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
    (let
      [owner : ci.InternCompatState (compiler-parse-state-owner control)]
      (ci.intern-compat-state-generation owner))))

(define (compiler-parse-state-owner-table-id [control : i64]) : i64
  (if (=
    (compiler-parse-raw-i64-ref control compiler-parse-state-control-owner-addr)
    0)
    (ci.intern-active-table-id)
    (let
      [owner : ci.InternCompatState (compiler-parse-state-owner control)]
      (ci.intern-compat-state-table-id owner))))

(define (compiler-parse-state-owner-persistent-arena [control : i64]) : i64
  (if (=
    (compiler-parse-raw-i64-ref control compiler-parse-state-control-owner-addr)
    0)
    (ci.intern-persistent-arena-handle)
    (let
      [owner : ci.InternCompatState (compiler-parse-state-owner control)]
      (ci.intern-compat-state-persistent-arena owner))))

(define (compiler-parse-env-marker-value
  [dispatch : sym_i64_env.SymI64Env]
  [marker-id : i64]) : i64
  (let
    [cursor : sym_i64_env.SymI64Env dispatch]
    (while true
      (match (sym_i64_env.sym-i64-view cursor)
        [(SymI64ViewNil) (return 0)]
        [(SymI64ViewBind name-id value rest)
          (if (= name-id marker-id)
            (return value)
            (set! cursor rest))]))
    0))

(define (compiler-parse-dispatch-invocation-control
  [dispatch : sym_i64_env.SymI64Env]) : i64
  (match (sym_i64_env.sym-i64-view dispatch)
    [(SymI64ViewBind name-id value _)
      (if (= name-id compiler-parse-invocation-marker-id)
        (compiler-parse-raw-i64-ref
          value
          compiler-parse-invocation-control-slot)
        0)]
    [(SymI64ViewNil) 0]))

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
  (let
    [intern-state : ci.InternCompatState
      (compiler-parse-dispatch-intern-state dispatch)]
    (ci.intern-compat-state-syntax-id-text intern-state id)))

(define (compiler-parse-dispatch-id-str
  [dispatch : sym_i64_env.SymI64Env]
  [id : ci.InternId]) : String
  (let
    [intern-state : ci.InternCompatState
      (compiler-parse-dispatch-intern-state dispatch)]
    (ci.intern-compat-state-id-str intern-state id)))

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
          [intern-state : ci.InternCompatState
            (compiler-parse-state-owner control)]
          [result : lexer.ResultSpannedTokens
            (lexer.spanned-result-with-intern-state src (&mut intern-state))]
          ;; Keep that same temporary installed view monotone across files;
          ;; inactive owners do not match and are never published.
          (compiler-parse-state-owner-sync-active! control)
          result)))))

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

(define (sexpr-colon? [s : reader.SpannedSexpr]) : bool
  (match (reader.sexpr-view s)
    [(Sym name-id)
      (= (ci.intern-syntax-id-value name-id) cbi.compiler-builtin-id-fix-colon)]
    [_ false]))

;; ID-to-text is intentionally a boundary, not a classifier. Production
;; callers are limited to lazy unknown-name diagnostics, prefix/content syntax
;; (`:unknown`, typed `...T`, retired name families), and dotted import paths.
(define (compiler-parse-name-text-with-state
  [intern-state : (& intern-state ci.InternCompatState)]
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
  (let
    [bound-1 (compiler-parse-dispatch-intern-state dispatch)]
    (compiler-parse-name-text-with-state bound-1 name-id)))

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
    [(Sym name _)
      (compiler-cfg-union? dispatch (ci.intern-syntax-id-value name))]
    [_ false]))

(define (compiler-cfg-eval-list-all
  [dispatch : sym_i64_env.SymI64Env]
  [predicates : reader.SpannedSexpr]) : ResultCompilerCfg
  (match (reader.spanned-sexpr-view predicates)
    [(Nil _) (Ok true)]
    [(Cons head tail _)
      (let
        [enabled (try (compiler-cfg-eval dispatch head))]
        (if enabled
          (compiler-cfg-eval-list-all dispatch tail)
          (Ok false)))]
    [_ (Err "parse: cfg all expects predicates")]))

(define (compiler-cfg-eval-list-any
  [dispatch : sym_i64_env.SymI64Env]
  [predicates : reader.SpannedSexpr]) : ResultCompilerCfg
  (match (reader.spanned-sexpr-view predicates)
    [(Nil _) (Ok false)]
    [(Cons head tail _)
      (let
        [enabled (try (compiler-cfg-eval dispatch head))]
        (if enabled
          (Ok true)
          (compiler-cfg-eval-list-any dispatch tail)))]
    [_ (Err "parse: cfg any expects predicates")]))

(define (compiler-cfg-eval-not
  [dispatch : sym_i64_env.SymI64Env]
  [predicates : reader.SpannedSexpr]) : ResultCompilerCfg
  (match (reader.spanned-sexpr-view predicates)
    [(Cons pred tail _)
      (match (reader.spanned-sexpr-view tail)
        [(Nil _)
          (let
            [enabled (try (compiler-cfg-eval dispatch pred))]
            (Ok (not enabled)))]
        [_ (Err "parse: cfg not expects exactly one predicate")])]
    [_ (Err "parse: cfg not expects exactly one predicate")]))

(define (compiler-cfg-eval
  [dispatch : sym_i64_env.SymI64Env]
  [predicate : reader.SpannedSexpr]) : ResultCompilerCfg
  (match (reader.spanned-sexpr-view predicate)
    [(Sym name _)
      (Ok (compiler-cfg-enabled? dispatch (ci.intern-syntax-id-value name)))]
    [(Cons head predicates _)
      (match (reader.spanned-sexpr-view head)
        [(Sym op _)
          (cond
            [(=
                (ci.intern-syntax-id-value op)
                (cbi.compiler-builtin-ctfe "all"))
              (compiler-cfg-eval-list-all dispatch predicates)]
            [(=
                (ci.intern-syntax-id-value op)
                (cbi.compiler-builtin-ctfe "any"))
              (compiler-cfg-eval-list-any dispatch predicates)]
            [(=
                (ci.intern-syntax-id-value op)
                (cbi.compiler-builtin-ctfe "not"))
              (compiler-cfg-eval-not dispatch predicates)]
            [else (Err "parse: cfg predicate expects a name, all, any, or not")])]
        [_ (Err "parse: malformed cfg predicate")])]
    [_ (Err "parse: malformed cfg predicate")]))

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
      (cbi.compiler-builtin-ctfe "defgeneric")
      (cbi.compiler-builtin-ctfe "generic")
      (cbi.compiler-builtin-ctfe "deftrait")
      (cbi.compiler-builtin-ctfe "trait"))
    (cbi.compiler-builtin-id-any3?
      name
      (cbi.compiler-builtin-ctfe "interface")
      (cbi.compiler-builtin-ctfe "impl")
      (cbi.compiler-builtin-ctfe "where"))))

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
    (unless
      (or
        (= invocation 0)
        (not (= (compiler-parse-raw-i64-ref invocation 0) 0)))
      (compiler-parse-raw-i64-set! invocation 0 1)
      (compiler-parse-raw-i64-set! invocation 1 (token.span-start-line span))
      (compiler-parse-raw-i64-set! invocation 2 (token.span-start-col span))
      (compiler-parse-raw-i64-set! invocation 3 (token.span-end-line span))
      (compiler-parse-raw-i64-set! invocation 4 (token.span-end-col span)))))

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
  (match (& result)
    [(Err _)
      (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span s))
      result]
    [_ result]))

(define (parse-ast-error-span-note-let-binding
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]
  [result : ResultAstLetBinding]) : ResultAstLetBinding
  (match (& result)
    [(Err _)
      (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span s))
      result]
    [_ result]))

(define (parse-ast-error-span-note-decl
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]
  [result : ResultAstDecl]) : ResultAstDecl
  (match (& result)
    [(Err _)
      (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span s))
      result]
    [_ result]))

(define (parse-ast-error-span-note-maybe-decl
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]
  [result : ResultAstMaybeDecl]) : ResultAstMaybeDecl
  (match (& result)
    [(Err _)
      (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span s))
      result]
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

(define (compiler-parse-tag-ty-c-func) : i64
  141)

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

(define (compiler-parse-tag-expr-retired-array-take) : i64
  305)

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

(define (compiler-parse-tag-expr-spmd-compact) : i64
  318)

(define (compiler-parse-tag-expr-spmd-broadcast) : i64
  290)

(define (compiler-parse-tag-expr-spmd-shuffle) : i64
  297)

(define (compiler-parse-tag-expr-spmd-program-index) : i64
  295)

(define (compiler-parse-tag-expr-spmd-program-count) : i64
  296)

(define (compiler-parse-tag-expr-foreach-active) : i64
  319)

(define (compiler-parse-tag-expr-lane-value) : i64
  320)

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
      (compiler-parse-raw-i64-set! keys i 0)
      (set! i (+ i 1)))))

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
              (bit-and (+ slot 1) (- compiler-parse-dispatch-index-capacity 1)))
            (set! steps (+ steps 1))))))
    false))

(define (compiler-parse-dispatch-index-populate!
  [control : i64]
  [dispatch : sym_i64_env.SymI64Env]) : unit
  (let
    [generation : i64 (compiler-parse-state-owner-generation control)]
    [table-id : i64 (compiler-parse-state-owner-table-id control)]
    [cursor : sym_i64_env.SymI64Env dispatch]
    [done : bool false]
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
        [(SymI64ViewNil) (set! done true)]
        [(SymI64ViewBind name-id tag rest)
          (if (and (>= name-id 0) (= tag (compiler-parse-tag-decl-defdispatch)))
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
              0))]))
    (if (<
      (compiler-parse-raw-i64-ref
        control
        compiler-parse-state-control-marker-id)
      0)
      (compiler-parse-raw-i64-set! control compiler-parse-state-control-ready 0)
      unit)
    (compiler-parse-raw-i64-set!
      control
      compiler-parse-state-control-cache-generation
      generation)
    (compiler-parse-raw-i64-set!
      control
      compiler-parse-state-control-cache-table-id
      table-id)))

;; Return the owning control address only when the first non-capability binding
;; is this state's defdispatch marker. Partial/custom environments retain the
;; linked-list fallback.
(define (compiler-parse-dispatch-indexed-control
  [dispatch : sym_i64_env.SymI64Env]) : i64
  (let
    [cursor : sym_i64_env.SymI64Env dispatch]
    [control : i64 0]
    [marker-id : i64 -1]
    [marker-tag : i64 -1]
    ;; Invocation frames are created only after the complete base dispatch
    ;; has validated this control. Intern reset cannot occur during a parse,
    ;; so the frame is the constant-time production path; the scan below is
    ;; retained for derived and custom test environments.
    (match (sym_i64_env.sym-i64-view dispatch)
      [(SymI64ViewBind name-id value _)
        (cond
          [(= name-id compiler-parse-invocation-control-marker-id)
            (return value)]
          [(= name-id compiler-parse-invocation-marker-id)
            (return
              (compiler-parse-raw-i64-ref
                value
                compiler-parse-invocation-control-slot))]
          [else unit])]
      [(SymI64ViewNil) unit])
    (while (or (= control 0) (< marker-id 0))
      (match (sym_i64_env.sym-i64-view cursor)
        [(SymI64ViewNil) (return 0)]
        [(SymI64ViewBind name-id tag rest)
          (if (= name-id compiler-parse-state-marker-id)
            (set! control tag)
            unit)
          (when
            (and (>= name-id 0) (< marker-id 0))
            (set! marker-id name-id)
            (set! marker-tag tag))
          (set! cursor rest)]))
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
      0)))

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
    (while (< steps compiler-parse-dispatch-index-capacity)
      (let
        [present : i64 (compiler-parse-raw-i64-ref keys slot)]
        (cond
          [(= present 0) (return (compiler-parse-tag-unknown))]
          [(= present encoded) (return (compiler-parse-raw-i64-ref tags slot))]
          [else
            (set!
              slot
              (bit-and (+ slot 1) (- compiler-parse-dispatch-index-capacity 1)))
            (set! steps (+ steps 1))])))
    (compiler-parse-tag-unknown)))

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
        (let
          [owner : ci.InternCompatState (compiler-parse-state-owner control)]
          (ci.intern-compat-state-intern (&mut owner) name)))]
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
      (compiler-parse-dispatch-bind out "String" (compiler-parse-tag-ty-string)))
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
      (compiler-parse-dispatch-bind out "CFunc" (compiler-parse-tag-ty-c-func)))
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
      (compiler-parse-dispatch-bind out "&mut" (compiler-parse-tag-ty-mut-ref)))
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
    out))

(define (compiler-parse-dispatch-exprs [e : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [out : sym_i64_env.SymI64Env e]
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
      (compiler-parse-dispatch-bind out "while" (compiler-parse-tag-expr-while)))
    (set!
      out
      (compiler-parse-dispatch-bind out "begin" (compiler-parse-tag-expr-begin)))
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
      (compiler-parse-dispatch-bind out "tuple" (compiler-parse-tag-expr-tuple)))
    (set!
      out
      (compiler-parse-dispatch-bind
        out
        "tuple-ref"
        (compiler-parse-tag-expr-tuple-ref)))
    (set!
      out
      (compiler-parse-dispatch-bind out "array" (compiler-parse-tag-expr-array)))
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
        (compiler-parse-tag-expr-retired-array-take)))
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
      (compiler-parse-dispatch-bind out "match" (compiler-parse-tag-expr-match)))
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
        "spmd-compact"
        (compiler-parse-tag-expr-spmd-compact)))
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
        "foreach-active"
        (compiler-parse-tag-expr-foreach-active)))
    (set!
      out
      (compiler-parse-dispatch-bind
        out
        "lane-value"
        (compiler-parse-tag-expr-lane-value)))
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
      (compiler-parse-dispatch-bind out "break" (compiler-parse-tag-expr-break)))
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
      (compiler-parse-dispatch-bind out "deref" (compiler-parse-tag-expr-deref)))
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
      (compiler-parse-dispatch-bind out "quote" (compiler-parse-tag-expr-quote)))
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
    out))

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
  (unsafe
    (ptr-read
      (int->ptr
        (compiler-parse-raw-i64-ref
          control
          compiler-parse-state-control-cache-addr)
        : (Ptr sym_i64_env.SymI64Env)))))

(define (compiler-parse-dispatch-cache-set!
  [control : i64]
  [dispatch : sym_i64_env.SymI64Env]) : unit
  (unsafe
    (ptr-write!
      (int->ptr
        (compiler-parse-raw-i64-ref
          control
          compiler-parse-state-control-cache-addr)
        : (MutPtr sym_i64_env.SymI64Env))
      dispatch)))

(define (compiler-parse-state-owner-floor-refresh! [control : i64]) : unit
  (if (=
    (compiler-parse-raw-i64-ref control compiler-parse-state-control-owner-addr)
    0)
    (ci.intern-persistent-arena-floor-refresh!)
    (let
      [owner : ci.InternCompatState (compiler-parse-state-owner control)]
      (ci.intern-compat-state-persistent-arena-floor-refresh! (&mut owner)))))

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
      (let
        [arg (compiler-parse-state-owner control)]
        (ci.intern-compat-state-install! arg)))))

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
      (let
        [owner : ci.InternCompatState (compiler-parse-state-owner control)]
        (ci.intern-compat-state-capture-from-globals! (&mut owner))))))

(define (compiler-parse-dispatch-env-for-control [control : i64]) : sym_i64_env.SymI64Env
  ;; Builtin seeding may have advanced an already-installed owner's scalar
  ;; compatibility view. Capture it before direct state-owned interning.
  (compiler-parse-state-owner-capture-active! control)
  (if (and
    (not
      (=
        (compiler-parse-raw-i64-ref control compiler-parse-state-control-ready)
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
          (compiler-parse-dispatch-index-populate! control dispatch)
          (compiler-parse-dispatch-cache-set! control dispatch)
          (compiler-parse-state-owner-floor-refresh! control)
          ;; Direct owner interning advances the state's scalar pool count.
          ;; When that owner is already installed, publish those scalars once
          ;; after the immutable dispatch is complete so subsequent source
          ;; lexing continues after its syntax IDs. Inactive owners remain
          ;; untouched, preserving A/B state isolation.
          (compiler-parse-state-owner-sync-active! control)
          dispatch)))))

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
    [base : sym_i64_env.SymI64Env
      (compiler-parse-dispatch-env-for-control control)]
    [merged : sym_i64_env.SymI64Env (compiler-cfg-merge base owned-cfgs)]
    (compiler-parse-dispatch-index-mark merged)))

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
        [(Some tag) tag]
        [(None) (compiler-parse-tag-unknown)]))))

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
    [(= tag (compiler-parse-tag-bin-add)) (Add)]
    [(= tag (compiler-parse-tag-bin-sub)) (Sub)]
    [(= tag (compiler-parse-tag-bin-mul)) (Mul)]
    [(= tag (compiler-parse-tag-bin-div)) (Div)]
    [(= tag (compiler-parse-tag-bin-mod)) (Mod)]
    [(= tag (compiler-parse-tag-bin-eq)) (Eq)]
    [(= tag (compiler-parse-tag-bin-ne)) (Ne)]
    [(= tag (compiler-parse-tag-bin-lt)) (Lt)]
    [(= tag (compiler-parse-tag-bin-le)) (Le)]
    [(= tag (compiler-parse-tag-bin-gt)) (Gt)]
    [(= tag (compiler-parse-tag-bin-ge)) (Ge)]
    [(= tag (compiler-parse-tag-bin-bit-and)) (BitAnd)]
    [(= tag (compiler-parse-tag-bin-bit-or)) (BitOr)]
    [(= tag (compiler-parse-tag-bin-bit-xor)) (BitXor)]
    [(= tag (compiler-parse-tag-bin-shl)) (Shl)]
    [else (Shr)]))

(define (ast-unop-tag? [tag : i64]) : bool
  (if (= tag (compiler-parse-tag-un-not))
    true
    (if (= tag (compiler-parse-tag-un-neg))
      true
      (= tag (compiler-parse-tag-un-bit-not)))))

(define (ast-unop-from-tag [tag : i64]) : ast.AstUnOp
  (if (= tag (compiler-parse-tag-un-not))
    (Not)
    (if (= tag (compiler-parse-tag-un-neg))
      (Neg)
      (BitNot))))

(define (parse-ast-type-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [out : (&mut out ast.AstTypeList)]) : ResultAstTypeListBuild
  (match (reader.sexpr-view s)
    [(Nil) (Ok)]
    [(Cons head tail)
      (let
        [parsed-head (try (parse-ast-type dispatch pools head))]
        (ast.ast-type-list-push
          out
          (ast.ast-node-pool-context-type-push pools parsed-head))
        (parse-ast-type-list dispatch pools tail out))]
    [_ (Err "parse: malformed type list")]))

(define (parse-ast-type-list-result
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstTypeList
  (let
    [out : ast.AstTypeList (ast.ast-type-list-new)]
    [_ (try (parse-ast-type-list dispatch pools s (&mut out)))]
    (Ok out)))

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
          (<= tag (compiler-parse-tag-ty-c-func)))))))

(define (parse-ast-lifetime-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [message : String]
  [out : (&mut out ast.AstLifetimeList)]) : ResultAstLifetimeListBuild
  (match (reader.sexpr-view s)
    [(Nil) (Ok)]
    [(Cons head tail)
      (match (reader.sexpr-view head)
        [(Sym name)
          (if (parse-ast-lifetime-name? dispatch name)
            (begin
              (ast.ast-lifetime-list-push out (ci.intern-syntax-id-value name))
              (parse-ast-lifetime-list dispatch pools tail message out))
            (Err message))]
        [_ (Err message)])]
    [(Cons _ _) (Err message)]
    [_ (Err message)]))

(define (parse-ast-lifetime-list-result
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [message : String]) : ResultAstLifetimeList
  (let
    [out : ast.AstLifetimeList (ast.ast-lifetime-list-new)]
    [_ (try (parse-ast-lifetime-list dispatch pools s message (&mut out)))]
    (Ok out)))

(define (parse-ast-lifetime-list-nonempty
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [message : String]) : ResultAstLifetimeList
  (match (reader.sexpr-view (compiler-parse-place-shared-view s))
    [(Nil) (Err message)]
    [_ (parse-ast-lifetime-list-result dispatch pools s message)]))

(defenum ResultAstCFunctionMode
  (Ok ast.AstCFunctionMode)
  (Err String))

(define (parse-ast-c-function-mode [node : reader.SpannedSexpr]) : ResultAstCFunctionMode
  (match (reader.sexpr-view node)
    [(Sym name)
      (let
        [text : String (ci.intern-str (ci.intern-syntax-id-value name))]
        (cond
          [(string.eq text (ast.ast-c-function-mode-name Nullable))
            (Ok Nullable)]
          [(string.eq text (ast.ast-c-function-mode-name NonNull)) (Ok NonNull)]
          [(string.eq text (ast.ast-c-function-mode-name UnsafeNullable))
            (Ok UnsafeNullable)]
          [(string.eq text (ast.ast-c-function-mode-name UnsafeNonNull))
            (Ok UnsafeNonNull)]
          [else
            (Err
              "parse: CFunc mode must be nullable, non-null, unsafe-nullable, or unsafe-non-null")]))]
    [_ (Err "parse: CFunc mode must be a symbol")]))

(define (parse-ast-c-function-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstType
  (match (reader.sexpr-view rest)
    [(Cons mode-node signature-tail)
      (let
        [mode (try (parse-ast-c-function-mode mode-node))]
        (match (reader.sexpr-view signature-tail)
          [(Cons signature-node tail)
            (match (reader.sexpr-view tail)
              [(Nil)
                (let
                  [signature
                    (try (parse-ast-type dispatch pools signature-node))]
                  (match (compiler-parse-place-shared-view signature)
                    [(Func _ _)
                      (Ok
                        (CFunc
                          (ast.ast-node-pool-context-type-push pools signature)
                          mode))]
                    [_
                      (Err
                        "parse: CFunc requires an explicit (-> ... result) signature")]))]
              [_
                (Err
                  "parse: CFunc requires exactly a mode and a function signature")])]
          [_
            (Err
              "parse: CFunc requires exactly a mode and a function signature")]))]
    [_ (Err "parse: CFunc requires exactly a mode and a function signature")]))

;; `(:invalidate r T)`: a callable parameter type whose call destroys the owner
;; of lifetime `r` (#6670). The checker admits it only as a parameter type.
(define (parse-ast-invalidate-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstType
  (match (reader.sexpr-view rest)
    [(Cons lifetime-node tail)
      (match (reader.sexpr-view lifetime-node)
        [(Sym lifetime)
          (match (reader.sexpr-view tail)
            [(Cons ty end)
              (match (reader.sexpr-view (compiler-parse-place-shared-view end))
                [(Nil)
                  (let
                    [inner (try (parse-ast-type dispatch pools ty))]
                    (Ok
                      (ast.ast-ty-invalidate-with-pools
                        pools
                        (ci.intern-syntax-id-value lifetime)
                        inner)))]
                [_ (Err (parse-ast-invalidate-type-message))])]
            [_ (Err (parse-ast-invalidate-type-message))])]
        [_ (Err (parse-ast-invalidate-type-message))])]
    [_ (Err (parse-ast-invalidate-type-message))]))

(define (parse-ast-invalidate-type-message) : String
  "parse: malformed :invalidate type; expected (:invalidate lifetime type)")

(define (parse-ast-func-type-parts
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstFuncTypeParts
  (match (reader.sexpr-view s)
    [(Cons arg rest)
      (match (reader.sexpr-view (compiler-parse-place-shared-view rest))
        [(Nil)
          (let
            [parsed-ret (try (parse-ast-type dispatch pools arg))]
            (Ok (ast.ast-type-list-new) parsed-ret))]
        [_
          (let
            [parsed-arg (try (parse-ast-type dispatch pools arg))]
            (match (parse-ast-func-type-parts dispatch pools rest)
              [(Ok parsed-args parsed-ret)
                (Ok
                  (ast.ast-type-cons-with-pools pools parsed-arg parsed-args)
                  parsed-ret)]
              [(Err message) (Err message)]))])]
    [_ (Err "parse: function type needs at least return type")]))

(define (parse-ast-internal-binary-data
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons bytes-node tail _)
      (match (reader.spanned-sexpr-view bytes-node)
        [(Str bytes _)
          (match (reader.spanned-sexpr-view tail)
            [(Nil _)
              (Ok
                (ast.ast-node-pool-context-expr-push
                  pools
                  (BinaryData (compiler-parse-dispatch-id-str dispatch bytes))))]
            [_ (Err "parse: malformed internal binary data")])]
        [_ (Err "parse: malformed internal binary data")])]
    [_ (Err "parse: malformed internal binary data")]))

(define (parse-ast-resolved-nominal-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [is-struct : bool]) : ResultAstType
  (match (reader.sexpr-view rest)
    [(Cons name-node lifetimes-box)
      (match (reader.sexpr-view name-node)
        [(Sym name-id)
          (let
            [raw-name-id : i64 (ci.intern-syntax-id-value name-id)]
            [lifetimes
              (try
                (parse-ast-lifetime-list-result
                  dispatch
                  pools
                  lifetimes-box
                  "parse: malformed internal resolved type lifetime list"))]
            (Ok
              (if is-struct
                (if (ast.ast-lifetime-list-empty? (& lifetimes))
                  (Struct raw-name-id)
                  (ast.ast-ty-struct-args raw-name-id lifetimes))
                (if (ast.ast-lifetime-list-empty? (& lifetimes))
                  (Enum raw-name-id)
                  (ast.ast-ty-enum-args raw-name-id lifetimes)))))]
        [(Str _)
          (Err "parse: malformed internal resolved type name was string")]
        [(Int _ _)
          (Err "parse: malformed internal resolved type name was integer")]
        [(Nil) (Err "parse: malformed internal resolved type name was nil")]
        [(Cons _ _)
          (Err "parse: malformed internal resolved type name was list")]
        [(Char _) (Err "parse: malformed internal resolved type name was char")]
        [(Float _)
          (Err "parse: malformed internal resolved type name was float")])]
    [_ (Err "parse: malformed internal resolved type shape")]))

(define (parse-ast-reference-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [mutable : bool]) : ResultAstType
  (match (reader.sexpr-view rest)
    [(Cons first tail)
      (match (reader.sexpr-view tail)
        ;; The parser is context-free. An empty lifetime marker is legal in
        ;; the AST, but the typechecker only accepts it while normalizing a
        ;; function signature into hidden signature-local lifetimes.
        [(Nil)
          (let
            [inner-ty (try (parse-ast-type dispatch pools first))]
            (if mutable
              (Ok
                (ast.ast-ty-mut-ref-with-pools
                  pools
                  cbi.compiler-builtin-id-fix-empty
                  inner-ty))
              (Ok
                (ast.ast-ty-ref-with-pools
                  pools
                  cbi.compiler-builtin-id-fix-empty
                  inner-ty))))]
        [(Cons inner end)
          (match (reader.sexpr-view end)
            [(Nil)
              (match (reader.sexpr-view first)
                [(Sym region)
                  (let
                    [inner-ty (try (parse-ast-type dispatch pools inner))]
                    (if mutable
                      (Ok
                        (ast.ast-ty-mut-ref-with-pools
                          pools
                          (ci.intern-syntax-id-value region)
                          inner-ty))
                      (Ok
                        (ast.ast-ty-ref-with-pools
                          pools
                          (ci.intern-syntax-id-value region)
                          inner-ty))))]
                [_ (Err "parse: reference lifetime must be an identifier")])]
            [_
              (Err
                (if mutable
                  "parse: &mut expects an optional lifetime and exactly one type"
                  "parse: & expects an optional lifetime and exactly one type"))])]
        [_
          (Err
            (if mutable
              "parse: &mut expects an optional lifetime and exactly one type"
              "parse: & expects an optional lifetime and exactly one type"))])]
    [_
      (Err
        (if mutable
          "parse: &mut expects an optional lifetime and exactly one type"
          "parse: & expects an optional lifetime and exactly one type"))]))

(define (parse-ast-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstType
  (match (reader.sexpr-view s)
    [(Sym name)
      (let
        [name-id : i64 (ci.intern-syntax-id-value name)]
        [tag : i64 (compiler-parse-dispatch-tag-id dispatch name-id)]
        (cond
          [(= tag (compiler-parse-tag-ty-i64)) (Ok (I64))]
          [(= tag (compiler-parse-tag-ty-i32)) (Ok (I32))]
          [(= tag (compiler-parse-tag-ty-i16)) (Ok (I16))]
          [(= tag (compiler-parse-tag-ty-i8)) (Ok (I8))]
          [(= tag (compiler-parse-tag-ty-u64)) (Ok (U64))]
          [(= tag (compiler-parse-tag-ty-u32)) (Ok (U32))]
          [(= tag (compiler-parse-tag-ty-u16)) (Ok (U16))]
          [(= tag (compiler-parse-tag-ty-u8)) (Ok (U8))]
          [(= tag (compiler-parse-tag-ty-f64)) (Ok (F64))]
          [(= tag (compiler-parse-tag-ty-f32)) (Ok (F32))]
          [(= tag (compiler-parse-tag-ty-bool)) (Ok (Bool))]
          [(= tag (compiler-parse-tag-ty-char)) (Ok (Char))]
          [(= tag (compiler-parse-tag-ty-string)) (Ok (String))]
          [(= tag (compiler-parse-tag-ty-str)) (Ok (Str))]
          [(= tag (compiler-parse-tag-ty-bytes)) (Ok (Bytes))]
          [(= tag (compiler-parse-tag-unit)) (Ok (Unit))]
          [(= tag (compiler-parse-tag-ty-never)) (Ok (Never))]
          [(= tag (compiler-parse-tag-ty-expr)) (Ok (Expr))]
          [else (Ok (Var name-id))]))]
    [(Cons head-node rest-box)
      (match (reader.sexpr-view head-node)
        [(Sym head)
          (let
            [rest : reader.SpannedSexpr rest-box]
            [head-id : i64 (ci.intern-syntax-id-value head)]
            [tag : i64 (compiler-parse-dispatch-tag-id dispatch head-id)]
            (cond
              ;; Macro output uses these non-lexer-spellable builtin IDs to
              ;; carry already-resolved aggregate types through quasiquotes.
              [(=
                  head-id
                  (cbi.compiler-builtin-ctfe
                    "__typelisp internal resolved struct type"))
                (parse-ast-resolved-nominal-type dispatch pools rest true)]
              [(=
                  head-id
                  (cbi.compiler-builtin-ctfe
                    "__typelisp internal resolved enum type"))
                (parse-ast-resolved-nominal-type dispatch pools rest false)]
              [(= head-id (cbi.compiler-builtin-ctfe ":consume"))
                (Err
                  "parse: :consume has been removed; by-value parameters move non-Copy values")]
              [(= head-id (cbi.compiler-builtin-ctfe ":invalidate"))
                (parse-ast-invalidate-type dispatch pools rest)]
              [(= tag (compiler-parse-tag-ty-c-func))
                (parse-ast-c-function-type dispatch pools rest)]
              [(= tag (compiler-parse-tag-ty-func))
                (match (parse-ast-func-type-parts dispatch pools rest)
                  [(Ok args ret)
                    (Ok (ast.ast-ty-func-with-pools pools args ret))]
                  [(Err message) (Err message)])]
              [(= tag (compiler-parse-tag-ty-tuple))
                (let
                  [elems (try (parse-ast-type-list-result dispatch pools rest))]
                  (Ok (ast.ast-ty-tuple elems)))]
              [(= tag (compiler-parse-tag-ty-array))
                (match (reader.sexpr-view rest)
                  [(Cons elem tail)
                    (match (reader.sexpr-view tail)
                      [(Nil)
                        (Err
                          "parse: unsized (Array T) was removed; use (Array T N), stdlib.vector, or a borrowed Slice")]
                      [(Cons size-node end)
                        (match (reader.sexpr-view end)
                          [(Nil)
                            (match (reader.sexpr-view size-node)
                              [(Int size _)
                                (let
                                  [elem-ty
                                    (try (parse-ast-type dispatch pools elem))]
                                  (Ok
                                    (ast.ast-ty-array-with-pools
                                      pools
                                      elem-ty
                                      size)))]
                              [_ (Err "parse: array size must be integer")])]
                          [_ (Err "parse: malformed array type")])]
                      [_ (Err "parse: malformed array type")])]
                  [_ (Err "parse: malformed array type")])]
              [(= tag (compiler-parse-tag-ty-dyn-array))
                (match (reader.sexpr-view rest)
                  [(Cons elem tail)
                    (match (reader.sexpr-view tail)
                      [(Nil)
                        (let
                          [elem-ty (try (parse-ast-type dispatch pools elem))]
                          (Ok (ast.ast-ty-dyn-array-with-pools pools elem-ty)))]
                      [_ (Err "parse: __tl_dyn-array expects exactly one type")])]
                  [_ (Err "parse: __tl_dyn-array expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-slice))
                (match (reader.sexpr-view rest)
                  [(Cons elem tail)
                    (match (reader.sexpr-view tail)
                      [(Nil)
                        (let
                          [elem-ty (try (parse-ast-type dispatch pools elem))]
                          (Ok (ast.ast-ty-slice-with-pools pools elem-ty)))]
                      [_ (Err "parse: Slice expects exactly one type")])]
                  [_ (Err "parse: Slice expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-ptr))
                (match (reader.sexpr-view rest)
                  [(Cons elem tail)
                    (match (reader.sexpr-view tail)
                      [(Nil)
                        (let
                          [elem-ty (try (parse-ast-type dispatch pools elem))]
                          (Ok (ast.ast-ty-ptr-with-pools pools elem-ty)))]
                      [_ (Err "parse: Ptr expects exactly one type")])]
                  [_ (Err "parse: Ptr expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-mut-ptr))
                (match (reader.sexpr-view rest)
                  [(Cons elem tail)
                    (match (reader.sexpr-view tail)
                      [(Nil)
                        (let
                          [elem-ty (try (parse-ast-type dispatch pools elem))]
                          (Ok (ast.ast-ty-mut-ptr-with-pools pools elem-ty)))]
                      [_ (Err "parse: MutPtr expects exactly one type")])]
                  [_ (Err "parse: MutPtr expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-box))
                (match (reader.sexpr-view rest)
                  [(Cons elem tail)
                    (match (reader.sexpr-view tail)
                      [(Nil)
                        (let
                          [elem-ty (try (parse-ast-type dispatch pools elem))]
                          (Ok (ast.ast-ty-box-with-pools pools elem-ty)))]
                      [_ (Err "parse: Box expects exactly one type")])]
                  [_ (Err "parse: Box expects exactly one type")])]
              [(= tag (compiler-parse-tag-ty-ref))
                (parse-ast-reference-type dispatch pools rest false)]
              [(= tag (compiler-parse-tag-ty-mut-ref))
                (parse-ast-reference-type dispatch pools rest true)]
              [(= tag (compiler-parse-tag-ty-region))
                (match (reader.sexpr-view rest)
                  [(Cons region-node tail)
                    (match (reader.sexpr-view tail)
                      [(Cons inner end)
                        (match (reader.sexpr-view end)
                          [(Nil)
                            (match (reader.sexpr-view region-node)
                              [(Sym region)
                                (let
                                  [inner-ty
                                    (try (parse-ast-type dispatch pools inner))]
                                  (Ok
                                    (ast.ast-ty-region-with-pools
                                      pools
                                      (ci.intern-syntax-id-value region)
                                      inner-ty)))]
                              [_
                                (Err "parse: region name must be an identifier")])]
                          [_ (Err "parse: malformed region type")])]
                      [_ (Err "parse: malformed region type")])]
                  [_ (Err "parse: malformed region type")])]
              [else
                (let
                  [lifetimes
                    (try
                      (parse-ast-lifetime-list-nonempty
                        dispatch
                        pools
                        rest
                        (compiler-parse-generic-type-policy-message
                          (compiler-parse-dispatch-syntax-id-text dispatch head))))]
                  (Ok (ast.ast-ty-var-args head-id lifetimes)))]))]
        [_ (Err "parse: expected type")])]
    [_ (Err "parse: expected type")]))

(define (compiler-parse-semantic-type-list-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view items)
    [(Nil _) unit]
    [(Cons head tail _)
      (compiler-parse-semantic-type-origins! dispatch head)
      (compiler-parse-semantic-type-list-origins! dispatch tail)]
    [_ unit]))

(define (compiler-parse-semantic-func-type-item-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [item : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view item))
    [(Cons key-node tail _)
      (match (reader.spanned-sexpr-view key-node)
        [(Sym key _)
          (if (=
            (ci.intern-syntax-id-value key)
            (cbi.compiler-builtin-ctfe ":consume"))
            (match (reader.spanned-sexpr-view tail)
              [(Cons ty-node end _)
                (match (reader.spanned-sexpr-view end)
                  [(Nil _)
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
    [(Nil _) unit]
    [(Cons head tail _)
      (compiler-parse-semantic-func-type-item-origins! dispatch head)
      (compiler-parse-semantic-func-type-list-origins! dispatch tail)]
    [_ unit]))

(define (compiler-parse-semantic-type-second-origin!
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view items)
    [(Cons _ tail _)
      (match (reader.spanned-sexpr-view tail)
        [(Cons second _ _)
          (compiler-parse-semantic-type-origins! dispatch second)]
        [_ unit])]
    [_ unit]))

(define (compiler-parse-semantic-type-first-origin!
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view items)
    [(Cons first _ _) (compiler-parse-semantic-type-origins! dispatch first)]
    [_ unit]))

(define (compiler-parse-semantic-reference-type-origin!
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view items)
    [(Cons first tail _)
      (match (reader.spanned-sexpr-view tail)
        [(Nil _) (compiler-parse-semantic-type-origins! dispatch first)]
        [(Cons second _ _)
          (compiler-parse-semantic-type-origins! dispatch second)]
        [_ unit])]
    [_ unit]))

(define (compiler-parse-semantic-type-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view s)
    [(Sym name span)
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
            (ModulePath)
            (TypeName))))]
    [(Cons head-node rest _)
      (match (reader.spanned-sexpr-view head-node)
        [(Sym head head-span)
          (let
            [head-id : i64 (ci.intern-syntax-id-value head)]
            [tag : i64 (compiler-parse-dispatch-tag-id dispatch head-id)]
            (cond
              [(or
                  (=
                    head-id
                    (cbi.compiler-builtin-ctfe
                      "__typelisp internal resolved struct type"))
                  (=
                    head-id
                    (cbi.compiler-builtin-ctfe
                      "__typelisp internal resolved enum type")))
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
              [(= tag (compiler-parse-tag-ty-c-func))
                (compiler-parse-semantic-type-second-origin! dispatch rest)]
              [(= tag (compiler-parse-tag-ty-region))
                (compiler-parse-semantic-type-second-origin! dispatch rest)]
              [(= head-id (cbi.compiler-builtin-ctfe ":invalidate"))
                (compiler-parse-semantic-type-second-origin! dispatch rest)]
              [else
                (compiler-parse-semantic-origin-push-components!
                  head
                  head-span
                  (ModulePath)
                  (TypeName))]))]
        [_ unit])]
    [_ unit]))

(define (parse-ast-type-spanned
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstType
  (let
    [result : ResultAstType
      (parse-ast-type dispatch pools (compiler-parse-place-shared-view s))]
    (match (& result)
      [(Err _)
        (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span s))
        result]
      [(Ok _)
        (compiler-parse-semantic-type-origins! dispatch s)
        result])))

(define (parse-ast-runtime-param-result
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [name : ci.InternSyntaxId]
  [ty : ast.AstType]
  [end : reader.SpannedSexpr]) : ResultAstParam
  (match (reader.sexpr-view (compiler-parse-place-shared-view end))
    [(Nil) (Ok (ast.ast-param-id (ci.intern-syntax-id-value name) ty false))]
    [(Cons metadata metadata-rest)
      (match (parse-ast-param-invalidate-metadata metadata)
        [(Lifetime lifetime)
          (match (reader.sexpr-view
            (compiler-parse-place-shared-view metadata-rest))
            [(Nil)
              (Ok
                (ast.ast-param-id
                  (ci.intern-syntax-id-value name)
                  (ast.ast-ty-invalidate-with-pools pools lifetime ty)
                  false))]
            [(Cons next _)
              (match (parse-ast-param-invalidate-metadata next)
                [(Other)
                  (Err (parse-ast-param-metadata-error dispatch metadata-rest))]
                [_ (Err "parse: duplicate :invalidate parameter metadata")])]
            [_ (Err "parse: malformed parameter")])]
        [(Malformed)
          (Err
            "parse: malformed :invalidate metadata; expected (:invalidate lifetime)")]
        [(Other) (Err (parse-ast-param-metadata-error dispatch end))])]
    [_ (Err (parse-ast-param-metadata-error dispatch end))]))

;; Parameter metadata `(:invalidate r)` (#6670), told apart from any other.
(defenum ParseAstInvalidateMetadata
  (Lifetime i64)
  (Malformed)
  (Other))

(define (parse-ast-param-invalidate-metadata [metadata : reader.SpannedSexpr]) : ParseAstInvalidateMetadata
  (match (reader.sexpr-view metadata)
    [(Cons key-node tail)
      (match (reader.sexpr-view key-node)
        [(Sym key)
          (if (=
            (ci.intern-syntax-id-value key)
            (cbi.compiler-builtin-ctfe ":invalidate"))
            (match (reader.sexpr-view tail)
              [(Cons lifetime-node end)
                (match (reader.sexpr-view lifetime-node)
                  [(Sym lifetime)
                    (match (reader.sexpr-view end)
                      [(Nil) (Lifetime (ci.intern-syntax-id-value lifetime))]
                      [_ Malformed])]
                  [_ Malformed])]
              [_ Malformed])
            Other)]
        [_ Other])]
    [_ Other]))

(define (parse-ast-param-metadata-error
  [dispatch : sym_i64_env.SymI64Env]
  [end : reader.SpannedSexpr]) : String
  (match (reader.sexpr-view end)
    [(Cons metadata-node _)
      (match (reader.sexpr-view metadata-node)
        [(Cons key-node _)
          (match (reader.sexpr-view key-node)
            [(Sym key)
              (cond
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe ":consume"))
                  "parse: :consume has been removed; by-value parameters move non-Copy values"]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe ":invalidate"))
                  "parse: :invalidate requires a runtime parameter"]
                [else
                  (let
                    [key-text : String
                      (compiler-parse-dispatch-syntax-id-text dispatch key)]
                    (if (and
                      (> (string.string-length key-text) 0)
                      (= (string.string-ref key-text 0) ':'))
                      (str_cat.str-cat
                        "parse: unknown parameter metadata "
                        key-text)
                      "parse: malformed parameter metadata"))])]
            [_ "parse: malformed parameter metadata"])]
        [_ "parse: malformed parameter metadata"])]
    [_ "parse: malformed parameter"]))

(define (parse-ast-param
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstParam
  (match (reader.sexpr-view s)
    [(Cons first rest)
      (match (reader.sexpr-view first)
        [(Sym first-name)
          (if (=
            (ci.intern-syntax-id-value first-name)
            cbi.compiler-builtin-id-fix-comptime)
            (match (reader.sexpr-view rest)
              [(Cons name-node after-name)
                (match (reader.sexpr-view name-node)
                  [(Sym name)
                    (match (reader.sexpr-view after-name)
                      [(Cons colon rest2)
                        (match (reader.sexpr-view rest2)
                          [(Cons ty end)
                            (match (reader.sexpr-view
                              (compiler-parse-place-shared-view end))
                              [(Nil)
                                (if (sexpr-colon? colon)
                                  (let
                                    [parsed-ty
                                      (try (parse-ast-type dispatch pools ty))]
                                    (Ok
                                      (ast.ast-comptime-param-id
                                        (ci.intern-syntax-id-value name)
                                        parsed-ty)))
                                  (Err "parse: expected ':' in parameter"))]
                              [_
                                (Err
                                  (parse-ast-param-metadata-error dispatch end))])]
                          [_ (Err "parse: malformed parameter")])]
                      [_ (Err "parse: malformed parameter")])]
                  [_ (Err "parse: malformed parameter")])]
              [_ (Err "parse: malformed parameter")])
            (match (reader.sexpr-view rest)
              [(Cons colon rest2)
                (match (reader.sexpr-view rest2)
                  [(Cons ty end)
                    (if (sexpr-colon? colon)
                      (let
                        [parsed-ty (try (parse-ast-type dispatch pools ty))]
                        (parse-ast-runtime-param-result
                          dispatch
                          pools
                          first-name
                          parsed-ty
                          end))
                      (Err "parse: expected ':' in parameter"))]
                  [_ (Err "parse: malformed parameter")])]
              [_ (Err "parse: malformed parameter")]))]
        [_ (Err "parse: malformed parameter")])]
    [_ (Err "parse: malformed parameter")]))

(define (ast-param-list-has-comptime? [params : (& params ast.AstParamList)]) : bool
  (ast-param-list-has-comptime-at? (& params) 0))

(define (ast-param-list-has-comptime-at?
  [params : (& params ast.AstParamList)]
  [index : i64]) : bool
  (if (>= index (ast.ast-param-list-len params))
    false
    (match (ast.ast-param-list-get params index (ast.ast-param-fallback))
      [(Param _ _ is-comptime)
        (if is-comptime
          true
          (ast-param-list-has-comptime-at? params (+ index 1)))])))

(define (ast-macro-param-variadic? [param : ast.AstMacroParam]) : bool
  (match param
    [(Param _ _ variadic _) variadic]))

(define (ast-macro-param-shape-delimited-variadic?
  [dispatch : sym_i64_env.SymI64Env]
  [param : ast.AstMacroParam]) : bool
  (let
    [intern-state : ci.InternCompatState
      (compiler-parse-dispatch-intern-state dispatch)]
    (match param
      [(Param _ ty variadic _)
        (and
          variadic
          (match ty
            [(Var name)
              (=
                (ci.intern-compat-state-qualified-base-id intern-state name)
                cbi.compiler-builtin-id-fix-ExprBindingClause)]
            [_ false]))])))

(define (parse-ast-macro-type-kind-known? [name : ci.InternSyntaxId]) : bool
  (let
    [name-id : i64 (ci.intern-syntax-id-value name)]
    (or
      (= name-id (cbi.compiler-builtin-ctfe "i64"))
      (= name-id (cbi.compiler-builtin-ctfe "i32"))
      (= name-id (cbi.compiler-builtin-ctfe "i16"))
      (= name-id (cbi.compiler-builtin-ctfe "i8"))
      (= name-id (cbi.compiler-builtin-ctfe "u64"))
      (= name-id (cbi.compiler-builtin-ctfe "u32"))
      (= name-id (cbi.compiler-builtin-ctfe "u16"))
      (= name-id (cbi.compiler-builtin-ctfe "u8"))
      (= name-id (cbi.compiler-builtin-ctfe "f64"))
      (= name-id (cbi.compiler-builtin-ctfe "f32"))
      (= name-id (cbi.compiler-builtin-ctfe "bool"))
      (= name-id (cbi.compiler-builtin-ctfe "char"))
      (= name-id (cbi.compiler-builtin-ctfe "string"))
      (= name-id (cbi.compiler-builtin-ctfe "unit"))
      (= name-id (cbi.compiler-builtin-ctfe "never"))
      (= name-id (cbi.compiler-builtin-ctfe "array"))
      (= name-id (cbi.compiler-builtin-ctfe "dyn-array"))
      (= name-id (cbi.compiler-builtin-ctfe "function"))
      (= name-id (cbi.compiler-builtin-ctfe "tuple"))
      (= name-id (cbi.compiler-builtin-ctfe "struct"))
      (= name-id (cbi.compiler-builtin-ctfe "enum"))
      (= name-id (cbi.compiler-builtin-ctfe "str"))
      (= name-id (cbi.compiler-builtin-ctfe "ptr"))
      (= name-id (cbi.compiler-builtin-ctfe "mut-ptr"))
      (= name-id (cbi.compiler-builtin-ctfe "ref"))
      (= name-id (cbi.compiler-builtin-ctfe "mut-ref"))
      (= name-id (cbi.compiler-builtin-ctfe "region"))
      (= name-id (cbi.compiler-builtin-ctfe "type-var"))
      (= name-id (cbi.compiler-builtin-ctfe "box"))
      (= name-id (cbi.compiler-builtin-ctfe "slice"))
      (= name-id (cbi.compiler-builtin-ctfe "c-function"))
      (= name-id (cbi.compiler-builtin-ctfe "invalidate")))))

(define (parse-ast-macro-type-kind-error
  [operand-name : String]
  [detail : String]) : String
  (str_cat.str-cat
    "parse: macro type operand "
    operand-name
    " constraint :kind "
    detail))

(define (parse-ast-macro-type-kind-sexpr-contains-id?
  [s : reader.SpannedSexpr]
  [kind : ci.InternSyntaxId]) : bool
  (match (reader.sexpr-view s)
    [(Nil) false]
    [(Cons head tail)
      (match (reader.sexpr-view head)
        [(Sym found)
          (or
            (ci.intern-syntax-id-eq? found kind)
            (parse-ast-macro-type-kind-sexpr-contains-id? tail kind))]
        [_ false])]
    [_ false]))

(define (parse-ast-macro-type-kind-list-count
  [dispatch : sym_i64_env.SymI64Env]
  [operand-name : String]
  [s : reader.SpannedSexpr]) : ResultAstMacroTypeKindCount
  (match (reader.sexpr-view s)
    [(Nil) (Ok 0)]
    [(Cons head tail)
      (match (reader.sexpr-view head)
        [(Sym kind-name)
          (if (parse-ast-macro-type-kind-known? kind-name)
            (let
              [count
                (try
                  (parse-ast-macro-type-kind-list-count
                    dispatch
                    (compiler-parse-place-shared-view operand-name)
                    (compiler-parse-place-shared-view tail)))]
              (if (parse-ast-macro-type-kind-sexpr-contains-id? tail kind-name)
                (Err
                  (parse-ast-macro-type-kind-error
                    operand-name
                    (str_cat.str-cat
                      "has duplicate kind "
                      (compiler-parse-dispatch-syntax-id-text
                        dispatch
                        kind-name))))
                (Ok (+ count 1))))
            (Err
              (parse-ast-macro-type-kind-error
                operand-name
                (str_cat.str-cat
                  "has unknown kind "
                  (compiler-parse-dispatch-syntax-id-text dispatch kind-name)))))]
        [_
          (Err
            (parse-ast-macro-type-kind-error
              operand-name
              "expects unquoted kind names"))])]
    [_ (Err (parse-ast-macro-type-kind-error operand-name "is malformed"))]))

(define (parse-ast-macro-type-kind-list-fill!
  [out : (&mut out ast.AstMacroTypeKindList)]
  [s : reader.SpannedSexpr]
  [index : i64]) : unit
  (match (reader.sexpr-view s)
    [(Nil) unit]
    [(Cons head tail)
      (match (reader.sexpr-view head)
        [(Sym kind-name)
          (ast.ast-macro-type-kind-list-set!
            out
            index
            (ci.intern-syntax-id-value kind-name))
          (parse-ast-macro-type-kind-list-fill! out tail (+ index 1))]
        [_ unit])]
    [_ unit]))

(define (parse-ast-macro-type-kind-list
  [dispatch : sym_i64_env.SymI64Env]
  [operand-name : String]
  [s : reader.SpannedSexpr]) : ResultAstMacroTypeKindList
  (let
    [count
      (try
        (parse-ast-macro-type-kind-list-count
          dispatch
          operand-name
          (compiler-parse-place-shared-view s)))]
    [out : ast.AstMacroTypeKindList
      (ast.ast-macro-type-kind-list-with-length count)]
    (parse-ast-macro-type-kind-list-fill! (&mut out) s 0)
    (Ok out)))

(define (parse-ast-macro-type-kind-constraint
  [dispatch : sym_i64_env.SymI64Env]
  [operand-name : String]
  [s : reader.SpannedSexpr]) : ResultAstMacroTypeKindList
  (match (reader.sexpr-view s)
    [(Cons head tail)
      (match (reader.sexpr-view head)
        [(Sym tag)
          (if (=
            (ci.intern-syntax-id-value tag)
            (cbi.compiler-builtin-ctfe ":kind"))
            (match (reader.sexpr-view (compiler-parse-place-shared-view tail))
              [(Nil)
                (Err
                  (parse-ast-macro-type-kind-error
                    operand-name
                    "requires at least one kind"))]
              [(Cons _ _)
                (parse-ast-macro-type-kind-list dispatch operand-name tail)]
              [_
                (Err
                  (parse-ast-macro-type-kind-error operand-name "is malformed"))])
            (Err
              (str_cat.str-cat
                "parse: macro type operand "
                operand-name
                " has unknown constraint form "
                (compiler-parse-dispatch-syntax-id-text dispatch tag))))]
        [_ (Err (parse-ast-macro-type-kind-error operand-name "is malformed"))])]
    [_ (Err (parse-ast-macro-type-kind-error operand-name "is malformed"))]))

(define (parse-ast-macro-type-operand? [ty : ast.AstType]) : bool
  (match ty
    [(Var name) (= name cbi.compiler-builtin-id-fix-type)]
    [_ false]))

(define (parse-ast-macro-param-after-type
  [dispatch : sym_i64_env.SymI64Env]
  [name : ci.InternSyntaxId]
  [parsed-ty : ast.AstType]
  [rest : reader.SpannedSexpr]) : ResultAstMacroParam
  (let
    [name-id : i64 (ci.intern-syntax-id-value name)]
    [name-text : String (compiler-parse-dispatch-syntax-id-text dispatch name)]
    (match (reader.sexpr-view rest)
      [(Nil) (Ok (ast.ast-macro-param name-id parsed-ty false))]
      [(Cons suffix suffix-rest)
        (match (reader.sexpr-view (compiler-parse-place-shared-view suffix))
          [(Sym suffix-name)
            (if (=
              (ci.intern-syntax-id-value suffix-name)
              (cbi.compiler-builtin-ctfe "..."))
              (match (reader.sexpr-view suffix-rest)
                [(Nil) (Ok (ast.ast-macro-param name-id parsed-ty true))]
                [_ (Err "parse: malformed macro operand")])
              (Err "parse: malformed macro operand"))]
          [(Cons _ _)
            (if (parse-ast-macro-type-operand?
              (compiler-parse-place-shared-view parsed-ty))
              (match (reader.sexpr-view suffix-rest)
                [(Nil)
                  (let
                    [type-kinds
                      (try
                        (parse-ast-macro-type-kind-constraint
                          dispatch
                          name-text
                          suffix))]
                    (Ok
                      (ast.ast-macro-param-with-type-kinds
                        name-id
                        parsed-ty
                        false
                        type-kinds)))]
                [(Cons maybe-dots after-dots)
                  (match (reader.sexpr-view maybe-dots)
                    [(Sym dots-name)
                      (if (and
                        (=
                          (ci.intern-syntax-id-value dots-name)
                          (cbi.compiler-builtin-ctfe "..."))
                        (match (reader.sexpr-view after-dots)
                          [(Nil) true]
                          [_ false]))
                        (Err
                          (parse-ast-macro-type-kind-error
                            name-text
                            "is not legal on variadic operands"))
                        (Err
                          (parse-ast-macro-type-kind-error
                            name-text
                            "allows only one constraint form")))]
                    [_
                      (Err
                        (parse-ast-macro-type-kind-error
                          name-text
                          "allows only one constraint form"))])]
                [_
                  (Err
                    (parse-ast-macro-type-kind-error
                      name-text
                      "allows only one constraint form"))])
              (Err
                (str_cat.str-cat
                  "parse: macro operand "
                  name-text
                  " constraint :kind is only legal on fixed type operands")))]
          [_ (Err "parse: malformed macro operand")])]
      [_ (Err "parse: malformed macro operand")])))

(define (parse-ast-macro-param
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstMacroParam
  (match (reader.sexpr-view s)
    [(Cons name-node rest)
      (match (reader.sexpr-view name-node)
        [(Sym name)
          (if (=
            (ci.intern-syntax-id-value name)
            cbi.compiler-builtin-id-fix-comptime)
            (Err "parse: defmacro operands are already compile-time")
            (match (reader.sexpr-view rest)
              [(Cons colon rest2)
                (match (reader.sexpr-view rest2)
                  [(Cons ty rest3)
                    (if (sexpr-colon? colon)
                      (let
                        [parsed-ty (try (parse-ast-type dispatch pools ty))]
                        (parse-ast-macro-param-after-type
                          dispatch
                          name
                          parsed-ty
                          rest3))
                      (Err "parse: expected ':' in macro operand"))]
                  [_ (Err "parse: malformed macro operand")])]
              [_ (Err "parse: malformed macro operand")]))]
        [_ (Err "parse: malformed macro operand")])]
    [_ (Err "parse: malformed macro operand")]))

(define (parse-ast-macro-param-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstMacroParamList
  (let
    [out : ast.AstMacroParamList (ast.ast-macro-param-list-new)]
    [_ (try (parse-ast-macro-param-list-into dispatch pools s (&mut out)))]
    (Ok out)))

(define (parse-ast-macro-param-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [out : (&mut out ast.AstMacroParamList)]) : ResultAstMacroParamListBuild
  (match (reader.sexpr-view s)
    [(Nil) Ok]
    [(Cons head tail)
      (let
        [parsed-head (try (parse-ast-macro-param dispatch pools head))]
        (if (ast-macro-param-variadic?
          (compiler-parse-place-shared-view parsed-head))
          (match (reader.sexpr-view (compiler-parse-place-shared-view tail))
            [(Nil)
              (ast.ast-macro-param-list-push out parsed-head)
              Ok]
            [_
              (if (ast-macro-param-shape-delimited-variadic?
                dispatch
                (compiler-parse-place-shared-view parsed-head))
                (begin
                  (ast.ast-macro-param-list-push out parsed-head)
                  (parse-ast-macro-param-list-into dispatch pools tail out))
                (Err
                  "parse: only ExprBindingClause macro operands may be variadic before a later operand"))])
          (begin
            (ast.ast-macro-param-list-push out parsed-head)
            (parse-ast-macro-param-list-into dispatch pools tail out))))]
    [_ (Err "parse: malformed macro operand list")]))

(define (parse-ast-param-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstParamList
  (let
    [out : ast.AstParamList (ast.ast-param-list-new)]
    [_ (try (parse-ast-param-list-into dispatch pools s (&mut out)))]
    (Ok out)))

(define (parse-ast-param-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [out : (&mut out ast.AstParamList)]) : ResultAstParamListBuild
  (match (reader.sexpr-view s)
    [(Nil) Ok]
    [(Cons head tail)
      (let
        [parsed-head (try (parse-ast-param dispatch pools head))]
        (ast.ast-param-list-push out parsed-head)
        (parse-ast-param-list-into dispatch pools tail out))]
    [_ (Err "parse: malformed parameter list")]))

(define (compiler-parse-semantic-param-items-origin!
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view items)
    [(Cons head tail _)
      (if (sexpr-colon? head)
        (match (reader.spanned-sexpr-view tail)
          [(Cons ty-node _ _)
            (compiler-parse-semantic-type-origins! dispatch ty-node)]
          [_ unit])
        (compiler-parse-semantic-param-items-origin! dispatch tail))]
    [_ unit]))

(define (compiler-parse-semantic-param-origin!
  [dispatch : sym_i64_env.SymI64Env]
  [item : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view item)
    [(BracketList items _)
      (when
        compiler-parse-semantic-binding-origin-capture-active
        (match (reader.spanned-sexpr-view
          (compiler-parse-place-shared-view items))
          [(Cons name rest _)
            (if (match (reader.sexpr-view
              (compiler-parse-place-shared-view name))
              [(Sym id)
                (=
                  (ci.intern-syntax-id-value id)
                  cbi.compiler-builtin-id-fix-comptime)]
              [_ false])
              (match (reader.spanned-sexpr-view rest)
                [(Cons binding _ _)
                  (compiler-parse-semantic-token-origin!
                    dispatch
                    (compiler-parse-place-shared-view binding)
                    CompilerParseSemanticOriginKind.BindingDefinition)]
                [_ unit])
              (compiler-parse-semantic-token-origin!
                dispatch
                (compiler-parse-place-shared-view name)
                CompilerParseSemanticOriginKind.BindingDefinition))]
          [_ unit]))
      (compiler-parse-semantic-param-items-origin! dispatch items)]
    [_ unit]))

(define (compiler-parse-semantic-param-list-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view items)
    [(Nil _) unit]
    [(Cons head tail _)
      (compiler-parse-semantic-param-origin! dispatch head)
      (compiler-parse-semantic-param-list-origins! dispatch tail)]
    [_ unit]))

(define (parse-ast-field-cleanup
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]) : ResultAstFieldCleanup
  (match (reader.sexpr-view s)
    [(Cons key-node tail)
      (match (reader.sexpr-view key-node)
        [(Sym key)
          (cond
            [(=
                (ci.intern-syntax-id-value key)
                (cbi.compiler-builtin-ctfe ":cleanup"))
              (match (reader.sexpr-view tail)
                [(Cons cleanup-node end)
                  (match (reader.sexpr-view end)
                    [(Nil)
                      (match (reader.sexpr-view cleanup-node)
                        [(Sym cleanup-fn)
                          (Ok (ast.ast-field-cleanup-fn-id cleanup-fn))]
                        [_ (Err "parse: malformed field :cleanup metadata")])]
                    [_ (Err "parse: malformed field :cleanup metadata")])]
                [_ (Err "parse: malformed field :cleanup metadata")])]
            [(=
                (ci.intern-syntax-id-value key)
                (cbi.compiler-builtin-ctfe ":owned"))
              (match (reader.sexpr-view tail)
                [(Nil) (Ok (Owned))]
                [_ (Err "parse: malformed field :owned metadata")])]
            [(compiler-parse-metadata-key? dispatch key)
              (Err
                (str_cat.str-cat
                  "parse: unknown field metadata "
                  (compiler-parse-dispatch-syntax-id-text dispatch key)))]
            [else (Err "parse: malformed field cleanup metadata")])]
        [_ (Err "parse: malformed field cleanup metadata")])]
    [_ (Err "parse: malformed field cleanup metadata")]))

(define (parse-ast-variant-payload-cleanup
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]) : ResultAstVariantPayloadCleanup
  (match (reader.sexpr-view s)
    [(Cons key-node tail)
      (match (reader.sexpr-view key-node)
        [(Sym key)
          (cond
            [(=
                (ci.intern-syntax-id-value key)
                (cbi.compiler-builtin-ctfe ":cleanup"))
              (match (reader.sexpr-view tail)
                [(Cons cleanup-node end)
                  (match (reader.sexpr-view end)
                    [(Nil)
                      (match (reader.sexpr-view cleanup-node)
                        [(Sym cleanup-fn)
                          (Ok
                            (ast.ast-variant-payload-cleanup-fn-id cleanup-fn))]
                        [_
                          (Err
                            "parse: malformed enum payload :cleanup metadata")])]
                    [_ (Err "parse: malformed enum payload :cleanup metadata")])]
                [_ (Err "parse: malformed enum payload :cleanup metadata")])]
            [(=
                (ci.intern-syntax-id-value key)
                (cbi.compiler-builtin-ctfe ":owned"))
              (match (reader.sexpr-view tail)
                [(Nil) (Ok (Owned))]
                [_ (Err "parse: malformed enum payload :owned metadata")])]
            [(compiler-parse-metadata-key? dispatch key)
              (Err
                (str_cat.str-cat
                  "parse: unknown enum payload metadata "
                  (compiler-parse-dispatch-syntax-id-text dispatch key)))]
            [else (Err "parse: malformed enum payload cleanup metadata")])]
        [_ (Err "parse: malformed enum payload cleanup metadata")])]
    [_ (Err "parse: malformed enum payload cleanup metadata")]))

(define (parse-ast-field-def
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [allow-cleanup : bool]
  [allow-align : bool]) : ResultAstFieldParts
  (match (reader.sexpr-view s)
    [(Cons name-node tail)
      (match (reader.sexpr-view name-node)
        [(Sym name)
          (match (reader.sexpr-view tail)
            [(Cons ty rest)
              (let
                [parsed-ty (try (parse-ast-type dispatch pools ty))]
                (parse-ast-field-metadata
                  dispatch
                  name
                  parsed-ty
                  rest
                  allow-cleanup
                  allow-align
                  (No)
                  false
                  0))]
            [_ (Err "parse: malformed field definition")])]
        [_ (Err "parse: malformed field definition")])]
    [_ (Err "parse: malformed field definition")]))

;; A field's metadata forms after its type: at most one cleanup form (only in
;; a `:cleanup` struct) and at most one `(:align N)` (only in a `(:repr c)`
;; struct). The two slots are independent, in either order.
(define (parse-ast-field-metadata
  [dispatch : sym_i64_env.SymI64Env]
  [name : ci.InternSyntaxId]
  [ty : ast.AstType]
  [items : reader.SpannedSexpr]
  [allow-cleanup : bool]
  [allow-align : bool]
  [cleanup : ast.AstFieldCleanup]
  [seen-cleanup : bool]
  [align : i64]) : ResultAstFieldParts
  (match (reader.sexpr-view items)
    [(Nil) (Ok (ast.ast-field-def-id name ty cleanup) align)]
    [(Cons meta rest)
      (if (parse-ast-align-metadata? (compiler-parse-place-shared-view meta))
        (cond
          [(not allow-align)
            (parse-ast-field-align-error
              dispatch
              meta
              "parse: field :align metadata requires struct (:repr c) metadata")]
          [(> align 0)
            (parse-ast-field-align-error
              dispatch
              meta
              "parse: duplicate field :align metadata")]
          [else
            (match (parse-ast-declared-align-form
              (compiler-parse-place-shared-view meta)
              "parse: malformed field :align metadata")
              [(Ok parsed-align)
                (parse-ast-field-metadata
                  dispatch
                  name
                  ty
                  rest
                  allow-cleanup
                  allow-align
                  cleanup
                  seen-cleanup
                  parsed-align)]
              [(Err message)
                (parse-ast-field-align-error dispatch meta message)])])
        (cond
          [(not allow-cleanup)
            (Err
              "parse: field cleanup metadata requires struct :cleanup metadata")]
          [seen-cleanup (Err "parse: duplicate field cleanup metadata")]
          [else
            (let
              [parsed-cleanup (try (parse-ast-field-cleanup dispatch meta))]
              (parse-ast-field-metadata
                dispatch
                name
                ty
                rest
                allow-cleanup
                allow-align
                parsed-cleanup
                true
                align))]))]
    [_ (Err "parse: malformed field definition")]))

;; A field-level `(:align N)` error is located at the offending form.
(define (parse-ast-field-align-error
  [dispatch : sym_i64_env.SymI64Env]
  [form : reader.SpannedSexpr]
  [message : String]) : ResultAstFieldParts
  (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span form))
  (Err message))

;; Whether `meta` is an `(:align ...)` form.
(define (parse-ast-align-metadata? [meta : reader.SpannedSexpr]) : bool
  (match (reader.sexpr-view meta)
    [(Cons key-node _)
      (match (reader.sexpr-view key-node)
        [(Sym key)
          (=
            (ci.intern-syntax-id-value key)
            (cbi.compiler-builtin-ctfe ":align"))]
        [_ false])]
    [_ false]))

;; `(:align N)` takes one integer literal, a power of two from 1 through the
;; shared cap. Whether it weakens the natural alignment is a layout question
;; that typecheck answers once every field type is known.
(define (parse-ast-declared-align-form
  [form : reader.SpannedSexpr]
  [malformed : String]) : ResultAstDeclaredAlign
  (match (reader.sexpr-view form)
    [(Cons _ tail)
      (match (reader.sexpr-view tail)
        [(Cons value-node end)
          (match (reader.sexpr-view end)
            [(Nil)
              (match (reader.sexpr-view value-node)
                [(Int value _)
                  (if (ast.ast-declared-align-valid? value)
                    (Ok value)
                    (Err
                      "parse: :align value must be a power of two from 1 through 4096"))]
                [_ (Err malformed)])]
            [_ (Err malformed)])]
        [_ (Err malformed)])]
    [_ (Err malformed)]))

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
  [tail : reader.SpannedSexpr]) : ResultAstLifetimeList
  (parse-ast-lifetime-list-nonempty
    dispatch
    pools
    tail
    "parse: :lifetimes metadata expects at least one lifetime identifier"))

(define (parse-ast-defstruct-repr-tail
  [dispatch : sym_i64_env.SymI64Env]
  [tail : reader.SpannedSexpr]) : ResultAstStructRepr
  (match (reader.sexpr-view tail)
    [(Cons name-node end)
      (match (reader.sexpr-view end)
        [(Nil)
          (match (reader.sexpr-view name-node)
            [(Sym name)
              (if (=
                (ci.intern-syntax-id-value name)
                cbi.compiler-builtin-id-fix-c)
                (Ok (ast.ast-struct-repr-c))
                (if (=
                  (ci.intern-syntax-id-value name)
                  (cbi.compiler-builtin-ctfe "packed"))
                  (Err "parse: packed repr is reserved")
                  (Err
                    (str_cat.str-cat
                      "parse: unknown struct repr "
                      (compiler-parse-dispatch-syntax-id-text dispatch name)))))]
            [_ (Err "parse: malformed :repr metadata")])]
        [_ (Err "parse: malformed :repr metadata")])]
    [_ (Err "parse: malformed :repr metadata")]))

(define (parse-ast-defstruct-cleanup-tail [tail : reader.SpannedSexpr]) : ResultAstStructCleanup
  (match (reader.sexpr-view tail)
    [(Cons cleanup-node end)
      (match (reader.sexpr-view end)
        [(Nil)
          (match (reader.sexpr-view cleanup-node)
            [(Sym cleanup-fn) (Ok (ast.ast-struct-cleanup-fn-id cleanup-fn))]
            [_ (Err "parse: malformed defstruct :cleanup metadata")])]
        [_ (Err "parse: malformed defstruct :cleanup metadata")])]
    [_ (Err "parse: malformed defstruct :cleanup metadata")]))

(define (parse-ast-defenum-cleanup-tail [tail : reader.SpannedSexpr]) : ResultAstEnumCleanup
  (match (reader.sexpr-view tail)
    [(Cons cleanup-node end)
      (match (reader.sexpr-view end)
        [(Nil)
          (match (reader.sexpr-view cleanup-node)
            [(Sym cleanup-fn) (Ok (ast.ast-enum-cleanup-fn-id cleanup-fn))]
            [_ (Err "parse: malformed defenum :cleanup metadata")])]
        [_ (Err "parse: malformed defenum :cleanup metadata")])]
    [_ (Err "parse: malformed defenum :cleanup metadata")]))

(define (compiler-parse-semantic-field-definition-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view items)
    [(Cons name-node tail-items _)
      (match (reader.spanned-sexpr-view name-node)
        [(Sym name span)
          (compiler-parse-semantic-origin-push-components!
            name
            span
            (ModulePath)
            (StructFieldDefinition))]
        [_ unit])
      (match (reader.spanned-sexpr-view tail-items)
        [(Cons ty-node _ _)
          (compiler-parse-semantic-type-origins! dispatch ty-node)]
        [_ unit])]
    [_ unit]))

;; A struct-level `(:align N)` error is located at the offending form.
(define (parse-ast-defstruct-align-error
  [dispatch : sym_i64_env.SymI64Env]
  [form : reader.SpannedSexpr]
  [message : String]) : ResultAstStructDefParts
  (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span form))
  (Err message))

(define (parse-ast-defstruct-field-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [head : reader.SpannedSexpr]
  [tail : reader.SpannedSexpr]
  [lifetimes : ast.AstLifetimeList]
  [repr : ast.AstStructRepr]
  [cleanup : ast.AstStructCleanup]
  [markers : i64]
  [align : i64]
  [fields : ast.AstFieldDefList]
  [seen-lifetimes : bool]
  [seen-repr : bool]
  [seen-cleanup : bool]) : ResultAstStructDefParts
  (let
    [field-repr (try (parse-ast-defstruct-resolve-repr repr align))]
    (match (parse-ast-field-def
      dispatch
      pools
      (compiler-parse-place-shared-view head)
      (ast.ast-struct-cleanup? cleanup)
      (ast.ast-struct-repr-c? (& field-repr)))
      [(Ok parsed-field field-align)
        (let
          [field-index : i64 fields.len]
          [next-fields : ast.AstFieldDefList fields]
          (match (reader.spanned-sexpr-view
            (compiler-parse-place-shared-view head))
            [(BracketList items _)
              (compiler-parse-semantic-field-definition-origins! dispatch items)]
            [(Cons _ _ _)
              (compiler-parse-semantic-field-definition-origins!
                dispatch
                (compiler-parse-place-shared-view head))]
            [_ unit])
          (ast.ast-field-def-list-push (&mut next-fields) parsed-field)
          (reader.sp-node-push
            (reader.spanned-sexpr-empty (reader.spanned-sexpr-span head)))
          (parse-ast-defstruct-items
            dispatch
            pools
            tail
            lifetimes
            (ast.ast-struct-repr-with-field-align
              field-repr
              field-index
              field-align)
            cleanup
            markers
            0
            next-fields
            seen-lifetimes
            seen-repr
            seen-cleanup
            true))]
      [(Err message) (Err message)])))

;; Struct metadata is order-independent, so a struct-level `(:align N)` joins
;; `(:repr c)` only once every metadata form before the fields has been read.
;; A pending alignment of 0 leaves the repr unchanged.
(define (parse-ast-defstruct-align-needs-repr-c) : String
  "parse: defstruct :align metadata requires (:repr c) metadata")

;; Note the span of the first `(:align ...)` item before the fields.
(define (parse-ast-defstruct-note-align-form!
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view items)
    [(Cons head tail _)
      (if (parse-ast-align-metadata? (compiler-parse-place-shared-view head))
        (parse-ast-error-span-note! dispatch (reader.spanned-sexpr-span head))
        (parse-ast-defstruct-note-align-form! dispatch tail))]
    [_ unit]))

(define (parse-ast-defstruct-resolve-repr
  [repr : ast.AstStructRepr]
  [align : i64]) : ResultAstStructRepr
  (cond
    [(= align 0) (Ok repr)]
    [(ast.ast-struct-repr-c? (& repr))
      (Ok
        (match repr
          [(C _ fields) (C align fields)]
          [(Default) Default]))]
    [else (Err (parse-ast-defstruct-align-needs-repr-c))]))

(define (parse-ast-defstruct-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [items : reader.SpannedSexpr]
  [lifetimes : ast.AstLifetimeList]
  [repr : ast.AstStructRepr]
  [cleanup : ast.AstStructCleanup]
  [markers : i64]
  [align : i64]
  [fields : ast.AstFieldDefList]
  [seen-lifetimes : bool]
  [seen-repr : bool]
  [seen-cleanup : bool]
  [seen-field : bool]) : ResultAstStructDefParts
  (match (reader.spanned-sexpr-view items)
    [(Nil _)
      (let
        [final-repr (try (parse-ast-defstruct-resolve-repr repr align))]
        (Ok lifetimes final-repr cleanup markers fields))]
    [(Cons head tail _)
      (match (reader.sexpr-view (compiler-parse-place-shared-view head))
        [(Cons key-node after-key)
          (match (reader.sexpr-view key-node)
            [(Sym key)
              (cond
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe ":lifetimes"))
                  (if seen-field
                    (Err "parse: defstruct metadata must appear before fields")
                    (if seen-lifetimes
                      (Err "parse: duplicate defstruct :lifetimes metadata")
                      (let
                        [next-lifetimes
                          (try
                            (parse-ast-aggregate-lifetimes-tail
                              dispatch
                              pools
                              after-key))]
                        (parse-ast-defstruct-items
                          dispatch
                          pools
                          tail
                          next-lifetimes
                          repr
                          cleanup
                          markers
                          align
                          fields
                          true
                          seen-repr
                          seen-cleanup
                          false))))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe ":repr"))
                  (if seen-field
                    (Err "parse: defstruct metadata must appear before fields")
                    (if seen-repr
                      (Err "parse: duplicate defstruct :repr metadata")
                      (let
                        [next-repr
                          (try
                            (parse-ast-defstruct-repr-tail dispatch after-key))]
                        (if (and
                          (ast.ast-struct-repr-c? (& next-repr))
                          (ast.ast-struct-cleanup? cleanup))
                          (Err
                            "parse: defstruct cannot combine :repr c with :cleanup metadata")
                          (parse-ast-defstruct-items
                            dispatch
                            pools
                            tail
                            lifetimes
                            next-repr
                            cleanup
                            markers
                            align
                            fields
                            seen-lifetimes
                            true
                            seen-cleanup
                            false)))))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe ":cleanup"))
                  (if seen-field
                    (Err "parse: defstruct metadata must appear before fields")
                    (if seen-cleanup
                      (Err "parse: duplicate defstruct :cleanup metadata")
                      (let
                        [next-cleanup
                          (try (parse-ast-defstruct-cleanup-tail after-key))]
                        (if (ast.ast-struct-repr-c? (& repr))
                          (Err
                            "parse: defstruct cannot combine :repr c with :cleanup metadata")
                          (parse-ast-defstruct-items
                            dispatch
                            pools
                            tail
                            lifetimes
                            repr
                            next-cleanup
                            markers
                            align
                            fields
                            seen-lifetimes
                            seen-repr
                            true
                            false)))))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe ":align"))
                  (cond
                    [seen-field
                      (parse-ast-defstruct-align-error
                        dispatch
                        head
                        "parse: defstruct metadata must appear before fields")]
                    [(> align 0)
                      (parse-ast-defstruct-align-error
                        dispatch
                        head
                        "parse: duplicate defstruct :align metadata")]
                    [else
                      (match (parse-ast-declared-align-form
                        (compiler-parse-place-shared-view head)
                        "parse: malformed defstruct :align metadata")
                        [(Ok next-align)
                          (parse-ast-defstruct-items
                            dispatch
                            pools
                            tail
                            lifetimes
                            repr
                            cleanup
                            markers
                            next-align
                            fields
                            seen-lifetimes
                            seen-repr
                            seen-cleanup
                            false)]
                        [(Err message)
                          (parse-ast-defstruct-align-error
                            dispatch
                            head
                            message)])])]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe ":must-use"))
                  (if seen-field
                    (Err "parse: defstruct metadata must appear before fields")
                    (if (not (= (bit-and markers 1) 0))
                      (Err "parse: duplicate defstruct :must-use metadata")
                      (match (reader.sexpr-view after-key)
                        [(Nil)
                          (parse-ast-defstruct-items
                            dispatch
                            pools
                            tail
                            lifetimes
                            repr
                            cleanup
                            (+ markers 1)
                            align
                            fields
                            seen-lifetimes
                            seen-repr
                            seen-cleanup
                            false)]
                        [_ (Err "parse: :must-use metadata takes no arguments")])))]
                [(compiler-parse-metadata-key? dispatch key)
                  (if seen-field
                    (Err "parse: defstruct metadata must appear before fields")
                    (if (=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe ":packed"))
                      (Err "parse: packed repr is reserved")
                      (Err
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
                    markers
                    align
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
                markers
                align
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
            markers
            align
            fields
            seen-lifetimes
            seen-repr
            seen-cleanup)])]
    [_ (Err "parse: malformed field list")]))

(define (compiler-parse-metadata-sexpr?
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]) : bool
  (match (reader.sexpr-view s)
    [(Cons key-node _)
      (match (reader.sexpr-view key-node)
        [(Sym key) (compiler-parse-metadata-key? dispatch key)]
        [_ false])]
    [_ false]))

(define (parse-ast-variant-payload-parts
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [allow-cleanup : bool]) : ResultAstVariantPayloadParts
  (match (reader.sexpr-view s)
    [(Nil)
      (Ok (ast.ast-type-list-new) (ast.ast-variant-payload-cleanup-list-new))]
    [(Cons ty-node rest)
      (let
        [ty-form : reader.SpannedSexpr ty-node]
        [rest-form : reader.SpannedSexpr rest]
        (if (compiler-parse-metadata-sexpr?
          dispatch
          (compiler-parse-place-shared-view ty-form))
          (Err
            "parse: enum payload cleanup metadata must follow a payload type")
          (let
            [parsed-ty (try (parse-ast-type dispatch pools ty-form))]
            (match (reader.sexpr-view
              (compiler-parse-place-shared-view rest-form))
              [(Nil)
                (Ok
                  (ast.ast-type-cons-with-pools
                    pools
                    parsed-ty
                    (ast.ast-type-list-new))
                  (ast.ast-variant-payload-cleanup-cons
                    (No)
                    (ast.ast-variant-payload-cleanup-list-new)))]
              [(Cons cleanup-node after-cleanup)
                (let
                  [cleanup-form : reader.SpannedSexpr cleanup-node]
                  (if (compiler-parse-metadata-sexpr?
                    dispatch
                    (compiler-parse-place-shared-view cleanup-form))
                    (if allow-cleanup
                      (let
                        [parsed-cleanup
                          (try
                            (parse-ast-variant-payload-cleanup
                              dispatch
                              cleanup-form))]
                        (match (parse-ast-variant-payload-parts
                          dispatch
                          pools
                          after-cleanup
                          allow-cleanup)
                          [(Ok parsed-rest cleanup-rest)
                            (Ok
                              (ast.ast-type-cons-with-pools
                                pools
                                parsed-ty
                                parsed-rest)
                              (ast.ast-variant-payload-cleanup-cons
                                parsed-cleanup
                                cleanup-rest))]
                          [(Err message) (Err message)]))
                      (Err
                        "parse: enum payload cleanup metadata requires enum :cleanup metadata"))
                    (match (parse-ast-variant-payload-parts
                      dispatch
                      pools
                      rest-form
                      allow-cleanup)
                      [(Ok parsed-rest cleanup-rest)
                        (Ok
                          (ast.ast-type-cons-with-pools
                            pools
                            parsed-ty
                            parsed-rest)
                          (ast.ast-variant-payload-cleanup-cons
                            (No)
                            cleanup-rest))]
                      [(Err message) (Err message)])))]
              [_ (Err "parse: malformed enum payload list")]))))]
    [_ (Err "parse: malformed enum payload list")]))

(define (parse-ast-variant-def
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [allow-cleanup : bool]) : ResultAstVariantDef
  (match (reader.sexpr-view s)
    [(Cons name-node fields)
      (match (reader.sexpr-view name-node)
        [(Sym name)
          (if (compiler-parse-metadata-key? dispatch name)
            (if (=
              (ci.intern-syntax-id-value name)
              (cbi.compiler-builtin-ctfe ":cleanup"))
              (Err "parse: defenum metadata must appear before variants")
              (Err
                (str_cat.str-cat
                  "parse: unknown defenum metadata "
                  (compiler-parse-dispatch-syntax-id-text dispatch name))))
            (match (parse-ast-variant-payload-parts
              dispatch
              pools
              fields
              allow-cleanup)
              [(Ok parsed-fields parsed-cleanups)
                (Ok
                  (ast.ast-variant-def-id
                    (ci.intern-syntax-id-value name)
                    parsed-fields
                    parsed-cleanups))]
              [(Err message) (Err message)]))]
        [_ (Err "parse: malformed variant definition")])]
    [_ (Err "parse: malformed variant definition")]))

(define (parse-ast-dispatch-isa
  [dispatch : sym_i64_env.SymI64Env]
  [name : ci.InternSyntaxId]) : ResultAstDispatchIsa
  (let
    [name-id : i64 (ci.intern-syntax-id-value name)]
    (cond
      [(= name-id (cbi.compiler-builtin-ctfe "scalar")) (Ok (Scalar))]
      [(= name-id (cbi.compiler-builtin-ctfe "avx2")) (Ok (Avx2))]
      [(= name-id (cbi.compiler-builtin-ctfe "avx512")) (Ok (Avx512))]
      [else
        (Err
          (str_cat.str-cat
            "parse: unknown defdispatch ISA "
            (compiler-parse-dispatch-syntax-id-text dispatch name)))])))

(define (parse-ast-dispatch-variant
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]) : ResultAstDispatchVariant
  (match (reader.spanned-sexpr-view s)
    [(Cons isa-node rest _)
      (match (reader.spanned-sexpr-view isa-node)
        [(Sym isa-name _)
          (match (reader.spanned-sexpr-view rest)
            [(Cons fn-node end _)
              (match (reader.spanned-sexpr-view end)
                [(Nil _)
                  (match (reader.spanned-sexpr-view fn-node)
                    [(Sym fn-name fn-span)
                      (let
                        [isa (try (parse-ast-dispatch-isa dispatch isa-name))]
                        (compiler-parse-semantic-origin-push-components!
                          fn-name
                          fn-span
                          (ModulePath)
                          (DispatchFunction))
                        (Ok (Variant isa (ci.intern-syntax-id-value fn-name))))]
                    [_ (Err "parse: malformed defdispatch variant")])]
                [_ (Err "parse: malformed defdispatch variant")])]
            [_ (Err "parse: malformed defdispatch variant")])]
        [_ (Err "parse: malformed defdispatch variant")])]
    [_ (Err "parse: malformed defdispatch variant")]))

(define (parse-ast-dispatch-variant-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [variants : reader.SpannedSexpr]
  [out : (&mut out ast.AstDispatchVariantList)]) : ResultAstDispatchVariantListBuild
  (match (reader.spanned-sexpr-view variants)
    [(Nil _) (Ok)]
    [(Cons head rest _)
      (let
        [parsed (try (parse-ast-dispatch-variant dispatch head))]
        (ast.ast-dispatch-variant-list-push out parsed)
        (parse-ast-dispatch-variant-list-into dispatch rest out))]
    [_ (Err "parse: malformed defdispatch variant list")]))

(define (parse-ast-dispatch-variant-list
  [dispatch : sym_i64_env.SymI64Env]
  [variants : reader.SpannedSexpr]) : ResultAstDispatchVariantList
  (let
    [out : ast.AstDispatchVariantList (ast.ast-dispatch-variant-list-new)]
    [_
      (try (parse-ast-dispatch-variant-list-into dispatch variants (&mut out)))]
    (Ok out)))

(define (compiler-parse-semantic-variant-payload-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [payloads : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view payloads)
    [(Nil _) unit]
    [(Cons head tail _)
      (if (compiler-parse-metadata-sexpr?
        dispatch
        (compiler-parse-place-shared-view head))
        unit
        (compiler-parse-semantic-type-origins! dispatch head))
      (compiler-parse-semantic-variant-payload-origins! dispatch tail)]
    [_ unit]))

(define (parse-ast-defenum-variant-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [head : reader.SpannedSexpr]
  [tail : reader.SpannedSexpr]
  [lifetimes : ast.AstLifetimeList]
  [cleanup : ast.AstEnumCleanup]
  [markers : i64]
  [seen-lifetimes : bool]
  [seen-cleanup : bool]) : ResultAstEnumDefParts
  (let
    [parsed-variant
      (try
        (parse-ast-variant-def
          dispatch
          pools
          (compiler-parse-place-shared-view head)
          (ast.ast-enum-cleanup? cleanup)))]
    (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view head))
      [(Cons name-node payloads _)
        (match (reader.spanned-sexpr-view name-node)
          [(Sym name span)
            (compiler-parse-semantic-origin-push-components!
              name
              span
              (ModulePath)
              (EnumVariantDefinition))]
          [_ unit])
        (compiler-parse-semantic-variant-payload-origins! dispatch payloads)]
      [_ unit])
    (reader.sp-node-push
      (reader.spanned-sexpr-empty (reader.spanned-sexpr-span head)))
    (match (parse-ast-defenum-items
      dispatch
      pools
      tail
      lifetimes
      cleanup
      markers
      seen-lifetimes
      seen-cleanup
      true)
      [(Ok parsed-lifetimes parsed-cleanup parsed-markers parsed-rest)
        (Ok
          parsed-lifetimes
          parsed-cleanup
          parsed-markers
          (ast.ast-variant-def-cons parsed-variant parsed-rest))]
      [(Err message) (Err message)])))

(define (parse-ast-defenum-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [items : reader.SpannedSexpr]
  [lifetimes : ast.AstLifetimeList]
  [cleanup : ast.AstEnumCleanup]
  [markers : i64]
  [seen-lifetimes : bool]
  [seen-cleanup : bool]
  [seen-variant : bool]) : ResultAstEnumDefParts
  (match (reader.spanned-sexpr-view items)
    [(Nil _) (Ok lifetimes cleanup markers (ast.ast-variant-def-list-new))]
    [(Cons head tail _)
      (match (reader.sexpr-view (compiler-parse-place-shared-view head))
        [(Cons key-node after-key)
          (match (reader.sexpr-view key-node)
            [(Sym key)
              (cond
                [(not (compiler-parse-metadata-key? dispatch key))
                  (parse-ast-defenum-variant-item
                    dispatch
                    pools
                    head
                    tail
                    lifetimes
                    cleanup
                    markers
                    seen-lifetimes
                    seen-cleanup)]
                [seen-variant
                  (Err "parse: defenum metadata must appear before variants")]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe ":lifetimes"))
                  (if seen-lifetimes
                    (Err "parse: duplicate defenum :lifetimes metadata")
                    (let
                      [next-lifetimes
                        (try
                          (parse-ast-aggregate-lifetimes-tail
                            dispatch
                            pools
                            after-key))]
                      (parse-ast-defenum-items
                        dispatch
                        pools
                        tail
                        next-lifetimes
                        cleanup
                        markers
                        true
                        seen-cleanup
                        false)))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe ":cleanup"))
                  (if seen-cleanup
                    (Err "parse: duplicate defenum :cleanup metadata")
                    (let
                      [next-cleanup
                        (try (parse-ast-defenum-cleanup-tail after-key))]
                      (parse-ast-defenum-items
                        dispatch
                        pools
                        tail
                        lifetimes
                        next-cleanup
                        markers
                        seen-lifetimes
                        true
                        false)))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe ":must-use"))
                  (if (not (= (bit-and markers 1) 0))
                    (Err "parse: duplicate defenum :must-use metadata")
                    (match (reader.sexpr-view after-key)
                      [(Nil)
                        (parse-ast-defenum-items
                          dispatch
                          pools
                          tail
                          lifetimes
                          cleanup
                          (+ markers 1)
                          seen-lifetimes
                          seen-cleanup
                          false)]
                      [_ (Err "parse: :must-use metadata takes no arguments")]))]
                [else
                  (Err
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
                markers
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
            markers
            seen-lifetimes
            seen-cleanup)])]
    [_ (Err "parse: malformed variant list")]))

(define (parse-ast-pattern-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [out : (&mut out ast.AstPatternList)]) : ResultAstPatternListBuild
  (match (reader.sexpr-view s)
    [(Nil) (Ok)]
    [(Cons head tail)
      (let
        [parsed-head (try (parse-ast-pattern dispatch pools head))]
        (ast.ast-pattern-list-push out parsed-head)
        (parse-ast-pattern-list-into dispatch pools tail out))]
    [_ (Err "parse: malformed pattern list")]))

(define (parse-ast-pattern-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstPatternList
  (let
    [out : ast.AstPatternList (ast.ast-pattern-list-new)]
    [_ (try (parse-ast-pattern-list-into dispatch pools s (&mut out)))]
    (Ok out)))

;; Whether `pattern` is the `&` marker that separates a slice pattern's element
;; patterns from its rest binding.
(define (parse-ast-slice-rest-marker? [pattern : ast.AstPattern]) : bool
  (match pattern
    [(Binding name) (= name (cbi.compiler-builtin-ctfe "&"))]
    [_ false]))

;; `&rest` reads as one symbol; inside a slice pattern it is a missing space
;; rather than a binder name.
(define (parse-ast-slice-glued-rest?
  [intern-state : (& intern-state ci.InternCompatState)]
  [pattern : ast.AstPattern]) : bool
  (match pattern
    [(Binding name)
      (let
        [text : String
          (ci.intern-compat-state-syntax-name-text-or intern-state name "")]
        (and (> (string.string-length text) 1) (= (string.char-at text 0) '&')))]
    [_ false]))

(define (parse-ast-slice-rest-target? [pattern : ast.AstPattern]) : bool
  (match pattern
    [(Binding name) (not (= name (cbi.compiler-builtin-ctfe "&")))]
    [(Wildcard) true]
    [_ false]))

;; `(slice p1 ... pk)` keeps its items; `(slice p1 ... pk & rest)` drops the
;; `&` marker and keeps `rest` as the last item (AstPattern.Slice's flag).
(define (parse-ast-slice-pattern
  [dispatch : sym_i64_env.SymI64Env]
  [items : ast.AstPatternList]) : ResultAstPattern
  (let
    [intern-state : ci.InternCompatState
      (compiler-parse-dispatch-intern-state dispatch)]
    [count : i64 (ast.ast-pattern-list-len (& items))]
    [marker : i64 -1]
    [index : i64 0]
    (while (< index count)
      (when
        (parse-ast-slice-rest-marker?
          (ast.ast-pattern-list-get (& items) index (ast.ast-pattern-fallback)))
        (if (< marker 0)
          (set! marker index)
          (return
            (Err "parse: slice pattern takes at most one `&` rest binding"))))
      (when
        (parse-ast-slice-glued-rest?
          (& intern-state)
          (ast.ast-pattern-list-get (& items) index (ast.ast-pattern-fallback)))
        (return
          (Err
            "parse: slice pattern rest needs a space after `&`, as in `(slice x & rest)`")))
      (set! index (+ index 1)))
    (if (< marker 0)
      (Ok (ast.ast-pat-slice items false))
      (if (and
        (= marker (- count 2))
        (parse-ast-slice-rest-target?
          (ast.ast-pattern-list-get
            (& items)
            (- count 1)
            (ast.ast-pattern-fallback))))
        (let
          [out : ast.AstPatternList
            (ast.ast-pattern-list-with-capacity (- count 1))]
          [copy : i64 0]
          (while (< copy count)
            (unless
              (= copy marker)
              (ast.ast-pattern-list-push
                (&mut out)
                (ast.ast-pattern-list-get
                  (& items)
                  copy
                  (ast.ast-pattern-fallback))))
            (set! copy (+ copy 1)))
          (Ok (ast.ast-pat-slice out true)))
        (Err
          "parse: slice pattern `&` must be followed by exactly one rest binding or `_`")))))

(define (parse-ast-pattern
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstPattern
  (match (reader.sexpr-view (compiler-parse-place-shared-view s))
    [(Int n text) (Ok (Literal (Int n (reader.sp-text-copy text))))]
    [(Float text) (Ok (Literal (Float (reader.sp-text-copy text))))]
    [(Str string-id) (Ok (Literal (String (ci.intern-id-value string-id))))]
    [(Char c) (Ok (Literal (Char c)))]
    [(Sym name)
      (let
        [name-id : i64 (ci.intern-syntax-id-value name)]
        [tag : i64 (compiler-parse-dispatch-tag-id dispatch name-id)]
        (cond
          [(= tag (compiler-parse-tag-pattern-wildcard)) (Ok Wildcard)]
          [(= tag (compiler-parse-tag-lit-true)) (Ok (Literal (Bool true)))]
          [(= tag (compiler-parse-tag-lit-false)) (Ok (Literal (Bool false)))]
          [else
            (compiler-parse-semantic-token-origin!
              dispatch
              (compiler-parse-place-shared-view s)
              CompilerParseSemanticOriginKind.BindingDefinition)
            (Ok (ast.ast-pat-binding-id name-id))]))]
    [(Cons name-node args)
      (match (reader.sexpr-view name-node)
        [(Sym name)
          (let
            [parsed-args (try (parse-ast-pattern-list dispatch pools args))]
            [name-id : i64 (ci.intern-syntax-id-value name)]
            [tag : i64 (compiler-parse-dispatch-tag-id dispatch name-id)]
            (cond
              [(= tag (compiler-parse-tag-expr-tuple))
                (Ok (ast.ast-pat-tuple parsed-args))]
              [(= tag (compiler-parse-tag-expr-array))
                (Ok (ast.ast-pat-array parsed-args))]
              [(= name-id (cbi.compiler-builtin-ctfe "slice"))
                (parse-ast-slice-pattern dispatch parsed-args)]
              [else (Ok (ast.ast-pat-variant-id name-id parsed-args))]))]
        [_ (Err "parse: expected pattern")])]
    [_ (Err "parse: expected pattern")]))

(define (compiler-parse-semantic-pattern-list-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [patterns : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view patterns)
    [(Nil _) unit]
    [(Cons head tail _)
      (compiler-parse-semantic-pattern-origins! dispatch head)
      (compiler-parse-semantic-pattern-list-origins! dispatch tail)]
    [_ unit]))

(define (compiler-parse-semantic-pattern-origins!
  [dispatch : sym_i64_env.SymI64Env]
  [pattern : reader.SpannedSexpr]) : unit
  (match (reader.spanned-sexpr-view pattern)
    [(BracketList items _)
      (compiler-parse-semantic-pattern-origins! dispatch items)]
    [(Cons name-node args _)
      (match (reader.spanned-sexpr-view name-node)
        [(Sym name span)
          (let
            [tag : i64
              (compiler-parse-dispatch-tag-id
                dispatch
                (ci.intern-syntax-id-value name))]
            (if (or
              (= tag (compiler-parse-tag-expr-tuple))
              (= tag (compiler-parse-tag-expr-array))
              (=
                (ci.intern-syntax-id-value name)
                (cbi.compiler-builtin-ctfe "slice")))
              unit
              (compiler-parse-semantic-origin-push-components!
                name
                span
                (ModulePath)
                (EnumVariantPattern))))]
        [_ unit])
      (compiler-parse-semantic-pattern-list-origins! dispatch args)]
    [(Sym name span)
      (let
        [tag : i64
          (compiler-parse-dispatch-tag-id
            dispatch
            (ci.intern-syntax-id-value name))]
        (if (or
          (= tag (compiler-parse-tag-pattern-wildcard))
          (= tag (compiler-parse-tag-lit-true))
          (= tag (compiler-parse-tag-lit-false))
          (= (ci.intern-syntax-id-value name) (cbi.compiler-builtin-ctfe "&")))
          unit
          (compiler-parse-semantic-origin-push-components!
            name
            span
            (ModulePath)
            (EnumVariantPattern))))]
    [_ unit]))

(define (parse-ast-cfg-expr-maybe
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstMaybeExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons pred then-tail _)
      (match (reader.spanned-sexpr-view then-tail)
        [(Cons then-expr rest-tail _)
          (match (reader.spanned-sexpr-view rest-tail)
            [(Nil _)
              (match (compiler-cfg-eval dispatch pred)
                [(Ok enabled)
                  (if enabled
                    (match (parse-ast-expr-with-pools dispatch pools then-expr)
                      [(Ok parsed) (SomeExpr parsed)]
                      [(Err message) (Err message)])
                    (NoExpr))]
                [(Err message) (Err message)])]
            [(Cons else-expr end _)
              (match (reader.spanned-sexpr-view end)
                [(Nil _)
                  (if (compiler-cfg-predicate-union?
                    dispatch
                    (compiler-parse-place-shared-view pred))
                    (match (parse-ast-expr-with-pools dispatch pools then-expr)
                      [(Ok parsed-then)
                        (match (parse-ast-expr-with-pools
                          dispatch
                          pools
                          else-expr)
                          [(Ok parsed-else)
                            (let
                              [exprs : ast.AstExprList (ast.ast-expr-list-new)]
                              (ast.ast-expr-list-push (&mut exprs) parsed-then)
                              (ast.ast-expr-list-push (&mut exprs) parsed-else)
                              (SomeExpr
                                (ast.ast-node-pool-context-expr-push
                                  pools
                                  (Begin exprs))))]
                          [(Err message) (Err message)])]
                      [(Err message) (Err message)])
                    (match (compiler-cfg-eval dispatch pred)
                      [(Ok enabled)
                        (match (parse-ast-expr-with-pools
                          dispatch
                          pools
                          (if enabled
                            then-expr
                            else-expr))
                          [(Ok parsed) (SomeExpr parsed)]
                          [(Err message) (Err message)])]
                      [(Err message) (Err message)]))]
                [_
                  (Err "parse: cfg expression expects predicate and expression")])]
            [_ (Err "parse: cfg expression expects predicate and expression")])]
        [_ (Err "parse: cfg expression expects predicate and expression")])]
    [_ (Err "parse: cfg expression expects predicate and expression")]))

(define (parse-ast-cfg-expr
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (parse-ast-cfg-expr-maybe dispatch pools rest)
    [(SomeExpr expr) (Ok expr)]
    [(NoExpr) (Ok (ast.ast-node-pool-context-expr-push pools (Literal Unit)))]
    [(Err message) (Err message)]))

(define (parse-ast-expr-list-item-maybe
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [head : reader.SpannedSexpr]) : ResultAstMaybeExpr
  (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view head))
    [(Cons op-node cfg-rest _)
      (match (reader.spanned-sexpr-view op-node)
        [(Sym op _)
          (if (=
            (ci.intern-syntax-id-value op)
            (cbi.compiler-builtin-ctfe "cfg"))
            (parse-ast-cfg-expr-maybe dispatch pools cfg-rest)
            (match (parse-ast-expr-with-pools dispatch pools head)
              [(Ok parsed) (SomeExpr parsed)]
              [(Err message) (Err message)]))]
        [_
          (match (parse-ast-expr-with-pools dispatch pools head)
            [(Ok parsed) (SomeExpr parsed)]
            [(Err message) (Err message)])])]
    [_
      (match (parse-ast-expr-with-pools dispatch pools head)
        [(Ok parsed) (SomeExpr parsed)]
        [(Err message) (Err message)])]))

(define (parse-ast-expr-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [out : (&mut out ast.AstExprList)]) : ResultAstExprListBuild
  (match (reader.spanned-sexpr-view s)
    [(Nil _) (Ok)]
    [(Cons head tail _)
      (match (parse-ast-expr-list-item-maybe dispatch pools head)
        [(SomeExpr parsed-head)
          (ast.ast-expr-list-push out parsed-head)
          (parse-ast-expr-list-into dispatch pools tail out)]
        [(NoExpr) (parse-ast-expr-list-into dispatch pools tail out)]
        [(Err message) (Err message)])]
    [_ (Err "parse: malformed expression list")]))

(define (parse-ast-expr-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstExprList
  (let
    [out : ast.AstExprList (ast.ast-expr-list-new)]
    [_ (try (parse-ast-expr-list-into dispatch pools s (&mut out)))]
    (Ok out)))

(define (parse-ast-body-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [missing-message : String]) : ResultAstExpr
  (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view s))
    [(Nil _) (Err missing-message)]
    [_
      (let
        [exprs (try (parse-ast-expr-list dispatch pools s))]
        [n : i64 exprs.len]
        (cond
          [(= n 0) (Err missing-message)]
          [(= n 1) (Ok (ast.ast-expr-list-get (& exprs) 0 0))]
          [else (Ok (ast.ast-node-pool-context-expr-push pools (Begin exprs)))]))]))

(define (parse-ast-call-bracket-clause
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [items : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [parsed-items (try (parse-ast-expr-list dispatch pools items))]
    (Ok
      (ast-expr-wrap-span
        pools
        (ast.ast-expr-bracket-clause-with-pools pools parsed-items)
        s))))

(define (parse-ast-call-arg-maybe
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [head : reader.SpannedSexpr]) : ResultAstMaybeExpr
  (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view head))
    [(BracketList items _)
      (match (parse-ast-call-bracket-clause dispatch pools head items)
        [(Ok parsed) (SomeExpr parsed)]
        [(Err message) (Err message)])]
    [(Cons op-node cfg-rest _)
      (match (reader.spanned-sexpr-view op-node)
        [(Sym op _)
          (if (=
            (ci.intern-syntax-id-value op)
            (cbi.compiler-builtin-ctfe "cfg"))
            (parse-ast-cfg-expr-maybe dispatch pools cfg-rest)
            (match (parse-ast-expr-with-pools dispatch pools head)
              [(Ok parsed) (SomeExpr parsed)]
              [(Err message) (Err message)]))]
        [_
          (match (parse-ast-expr-with-pools dispatch pools head)
            [(Ok parsed) (SomeExpr parsed)]
            [(Err message) (Err message)])])]
    [_
      (match (parse-ast-expr-with-pools dispatch pools head)
        [(Ok parsed) (SomeExpr parsed)]
        [(Err message) (Err message)])]))

(define (parse-ast-call-arg-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [out : (&mut out ast.AstExprList)]) : ResultAstExprListBuild
  (match (reader.spanned-sexpr-view s)
    [(Nil _) (Ok)]
    [(Cons head tail _)
      (match (parse-ast-call-arg-maybe dispatch pools head)
        [(SomeExpr parsed-head)
          (ast.ast-expr-list-push out parsed-head)
          (parse-ast-call-arg-list-into dispatch pools tail out)]
        [(NoExpr) (parse-ast-call-arg-list-into dispatch pools tail out)]
        [(Err message) (Err message)])]
    [_ (Err "parse: malformed call argument list")]))

(define (parse-ast-call-arg-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstExprList
  (let
    [out : ast.AstExprList (ast.ast-expr-list-new)]
    [_ (try (parse-ast-call-arg-list-into dispatch pools s (&mut out)))]
    (Ok out)))

(define (parse-ast-binary
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [op : ast.AstBinOp]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons left right-tail _)
      (match (reader.spanned-sexpr-view right-tail)
        [(Cons right end _)
          (match (reader.spanned-sexpr-view end)
            [(Nil _)
              (let
                [parsed-left
                  (try (parse-ast-expr-with-pools dispatch pools left))]
                [parsed-right
                  (try (parse-ast-expr-with-pools dispatch pools right))]
                (Ok
                  (ast.ast-expr-binary-with-pools
                    pools
                    op
                    parsed-left
                    parsed-right)))]
            [_ (Err "parse: malformed binary expression")])]
        [_ (Err "parse: malformed binary expression")])]
    [_ (Err "parse: malformed binary expression")]))

(define (parse-ast-binary-left-fold-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [op : ast.AstBinOp]
  [acc : i64]
  [tail : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view tail)
    [(Nil _) (Ok acc)]
    [(Cons expr rest _)
      (let
        [parsed-expr (try (parse-ast-expr-with-pools dispatch pools expr))]
        (parse-ast-binary-left-fold-tail
          dispatch
          pools
          op
          (ast.ast-expr-binary-with-pools pools op acc parsed-expr)
          rest))]
    [_ (Err "parse: malformed binary expression")]))

(define (parse-ast-binary-left-fold
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [op : ast.AstBinOp]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons left right-tail _)
      (match (reader.spanned-sexpr-view right-tail)
        [(Cons right tail _)
          (let
            [parsed-left (try (parse-ast-expr-with-pools dispatch pools left))]
            [parsed-right
              (try (parse-ast-expr-with-pools dispatch pools right))]
            (parse-ast-binary-left-fold-tail
              dispatch
              pools
              op
              (ast.ast-expr-binary-with-pools pools op parsed-left parsed-right)
              tail))]
        [_ (Err "parse: malformed binary expression")])]
    [_ (Err "parse: malformed binary expression")]))

(define (parse-ast-unary
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [op : ast.AstUnOp]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(Nil _)
          (let
            [parsed-expr (try (parse-ast-expr-with-pools dispatch pools expr))]
            (Ok (ast.ast-expr-unary-with-pools pools op parsed-expr)))]
        [_ (Err "parse: malformed unary expression")])]
    [_ (Err "parse: malformed unary expression")]))

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
    [(Cons cond then-tail _)
      (match (reader.spanned-sexpr-view then-tail)
        [(Cons then-branch else-tail _)
          (match (reader.spanned-sexpr-view else-tail)
            [(Cons else-branch end _)
              (match (reader.spanned-sexpr-view end)
                [(Nil _)
                  (let
                    [parsed-cond
                      (try (parse-ast-expr-with-pools dispatch pools cond))]
                    [parsed-then
                      (try
                        (parse-ast-expr-with-pools dispatch pools then-branch))]
                    [parsed-else
                      (try
                        (parse-ast-expr-with-pools dispatch pools else-branch))]
                    (Ok
                      (ast.ast-expr-if-with-pools
                        pools
                        parsed-cond
                        parsed-then
                        parsed-else)))]
                [_ (Err (parse-ast-if-arity-message))])]
            [_ (Err (parse-ast-if-missing-else-message))])]
        [_ (Err (parse-ast-if-arity-message))])]
    [_ (Err (parse-ast-if-arity-message))]))

(define (parse-ast-while
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons cond body-tail _)
      (let
        [parsed-cond (try (parse-ast-expr-with-pools dispatch pools cond))]
        [parsed-body (try (parse-ast-expr-list dispatch pools body-tail))]
        (if (= parsed-body.len 0)
          (Err "parse: malformed while")
          (Ok
            (ast.ast-node-pool-context-expr-push
              pools
              (While parsed-cond parsed-body)))))]
    [_ (Err "parse: malformed while")]))

(define (parse-ast-set
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons target-node value-tail _)
      (match (reader.spanned-sexpr-view value-tail)
        [(Cons value end _)
          (match (reader.spanned-sexpr-view end)
            [(Nil _)
              (let
                [parsed-value
                  (try (parse-ast-expr-with-pools dispatch pools value))]
                (match (reader.spanned-sexpr-view
                  (compiler-parse-place-shared-view target-node))
                  [(Sym name target-span)
                    (compiler-parse-semantic-dotted-field-origins!
                      name
                      target-span)
                    (Ok
                      (ast.ast-expr-spanned-with-pools
                        pools
                        (ast.ast-expr-set-id-with-pools
                          pools
                          (ci.intern-syntax-id-value name)
                          parsed-value)
                        (ast-source-span-from-source-span
                          (reader.spanned-sexpr-span target-node))))]
                  [_
                    (let
                      [parsed-target
                        (try
                          (parse-ast-expr-with-pools dispatch pools target-node))]
                      (match (ast.ast-expr-unspan-with-pools
                        pools
                        (ast.ast-node-pool-context-expr-get pools parsed-target))
                        [(StructGet receiver-box field)
                          (Ok
                            (ast.ast-expr-struct-set-id-with-pools
                              pools
                              receiver-box
                              field
                              parsed-value))]
                        [(TupleRef receiver-box index)
                          (if (< index 0)
                            (Err
                              "parse: tuple-ref assignment index must be non-negative")
                            (Ok
                              (ast.ast-expr-struct-set-id-with-pools
                                pools
                                receiver-box
                                (ast.ast-tuple-set-field-id-from-index index)
                                parsed-value)))]
                        [(ArrayRef receiver-box index-box)
                          (Ok
                            (ast.ast-expr-array-set-with-pools
                              pools
                              receiver-box
                              index-box
                              parsed-value))]
                        [(BoxGet receiver-box)
                          (Ok
                            (ast.ast-expr-box-set-with-pools
                              pools
                              receiver-box
                              parsed-value))]
                        [(BoxTake receiver-box)
                          (Ok
                            (ast.ast-expr-box-set-with-pools
                              pools
                              receiver-box
                              parsed-value))]
                        [(Unquote _)
                          (Ok
                            (ast.ast-expr-struct-set-id-with-pools
                              pools
                              parsed-target
                              (ast.ast-expr-unquote-set-target-field-id)
                              parsed-value))]
                        [_ (Err "parse: set! target must be a mutable place")]))]))]
            [_ (Err "parse: malformed set!")])]
        [_ (Err "parse: malformed set!")])]
    [_ (Err "parse: malformed set!")]))

(define (parse-ast-replace-place?
  [pools : ast.AstNodePoolContext]
  [expr-id : i64]) : bool
  (match (ast.ast-expr-unspan-with-pools
    pools
    (ast.ast-node-pool-context-expr-get pools expr-id))
    [(Var _) true]
    [(StructGet _ _) true]
    [(TupleRef _ index) (>= index 0)]
    [(ArrayRef _ _) true]
    [(BoxGet _) true]
    [(BoxTake _) true]
    [_ false]))

(define (parse-ast-replace
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons place-node replacement-tail _)
      (match (reader.spanned-sexpr-view replacement-tail)
        [(Cons replacement-node end _)
          (match (reader.spanned-sexpr-view end)
            [(Nil _)
              (let
                [place-id
                  (try (parse-ast-expr-with-pools dispatch pools place-node))]
                (if (parse-ast-replace-place? pools place-id)
                  (let
                    [replacement-id
                      (try
                        (parse-ast-expr-with-pools
                          dispatch
                          pools
                          replacement-node))]
                    (Ok
                      (ast.ast-expr-replace-with-pools
                        pools
                        place-id
                        replacement-id)))
                  (Err "parse: replace! target must be a mutable place")))]
            [_ (Err "parse: replace! expects exactly two operands")])]
        [_ (Err "parse: replace! expects exactly two operands")])]
    [_ (Err "parse: replace! expects exactly two operands")]))

(define (parse-ast-ann-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [is-cast : bool]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons expr colon-tail _)
      (match (reader.spanned-sexpr-view colon-tail)
        [(Cons colon ty-tail _)
          (match (reader.spanned-sexpr-view ty-tail)
            [(Cons ty end _)
              (match (reader.spanned-sexpr-view end)
                [(Nil _)
                  (if (sexpr-colon? colon)
                    (let
                      [parsed-expr
                        (try (parse-ast-expr-with-pools dispatch pools expr))]
                      [parsed-ty
                        (try (parse-ast-type-spanned dispatch pools ty))]
                      (if is-cast
                        (Ok
                          (ast.ast-expr-cast-with-pools
                            pools
                            parsed-expr
                            parsed-ty))
                        (Ok
                          (ast.ast-expr-ann-with-pools
                            pools
                            parsed-expr
                            parsed-ty))))
                    (Err "parse: expected ':' in annotation"))]
                [_ (Err "parse: malformed annotation")])]
            [_ (Err "parse: malformed annotation")])]
        [_ (Err "parse: malformed annotation")])]
    [_ (Err "parse: malformed annotation")]))

(define (parse-ast-let-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstLetBinding
  (let
    [_binding-origin : unit
      (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view s))
        [(Cons name _ _)
          (compiler-parse-semantic-token-origin!
            dispatch
            (compiler-parse-place-shared-view name)
            CompilerParseSemanticOriginKind.BindingDefinition)]
        [_ unit])]
    [result : ResultAstLetBinding
      (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view s))
        [(BracketList items _) (parse-ast-let-binding dispatch pools items)]
        [(Cons name-node tail _)
          (match (reader.spanned-sexpr-view name-node)
            [(Sym name _)
              (match (reader.spanned-sexpr-view tail)
                [(Cons second rest _)
                  (match (reader.spanned-sexpr-view rest)
                    [(Nil _)
                      (match (parse-ast-expr-with-pools dispatch pools second)
                        [(Ok parsed-value)
                          (Ok
                            (ast.ast-let-binding-id
                              (ci.intern-syntax-id-value name)
                              No
                              parsed-value))]
                        [(Err message) (Err message)])]
                    [(Cons ty value-tail _)
                      (match (reader.spanned-sexpr-view value-tail)
                        [(Cons value end _)
                          (match (reader.spanned-sexpr-view end)
                            [(Nil _)
                              (if (sexpr-colon? second)
                                (match (parse-ast-type-spanned
                                  dispatch
                                  pools
                                  ty)
                                  [(Ok parsed-ty)
                                    (match (parse-ast-expr-with-pools
                                      dispatch
                                      pools
                                      value)
                                      [(Ok parsed-value)
                                        (Ok
                                          (ast.ast-let-binding-id
                                            (ci.intern-syntax-id-value name)
                                            (Some parsed-ty)
                                            parsed-value))]
                                      [(Err message) (Err message)])]
                                  [(Err message) (Err message)])
                                (Err "parse: expected ':' in let binding"))]
                            [_ (Err "parse: malformed let binding")])]
                        [_ (Err "parse: malformed let binding")])]
                    [_ (Err "parse: malformed let binding")])]
                [_ (Err "parse: malformed let binding")])]
            [_ (Err "parse: malformed let binding")])]
        [_ (Err "parse: malformed let binding")])]
    (parse-ast-error-span-note-let-binding dispatch s result)))

(define (parse-ast-let-flat-tail-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [out : (&mut out ast.AstLetBindingList)]) : ResultAstExpr
  (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view rest))
    [(Cons head tail _)
      (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view head))
        [(BracketList _ _)
          (let
            [parsed-head (try (parse-ast-let-binding dispatch pools head))]
            (ast.ast-let-binding-list-push out parsed-head)
            (parse-ast-let-flat-tail-into dispatch pools tail out))]
        [_ (parse-ast-body-tail dispatch pools rest "parse: let missing body")])]
    [(Nil _) (Err "parse: let missing body")]
    [_ (Err "parse: malformed let")]))

(define (parse-ast-let-flat-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstLetParts
  (let
    [out : ast.AstLetBindingList (ast.ast-let-binding-list-new)]
    [parsed-body
      (try (parse-ast-let-flat-tail-into dispatch pools rest (&mut out)))]
    (Ok out parsed-body)))

(define (parse-ast-let-flat
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view rest))
    [(Cons head _ _)
      (match (reader.spanned-sexpr-view head)
        [(BracketList items _)
          (match (reader.spanned-sexpr-view items)
            [(Nil _)
              (match (reader.spanned-sexpr-view rest)
                [(Cons _ body-tail _)
                  (parse-ast-body-tail
                    dispatch
                    pools
                    body-tail
                    "parse: let missing body")]
                [_ (Err "parse: malformed let")])]
            [_
              (match (parse-ast-let-flat-tail dispatch pools rest)
                [(Ok parsed-bindings parsed-body)
                  (Ok
                    (ast.ast-expr-let-with-pools
                      pools
                      parsed-bindings
                      parsed-body))]
                [(Err message) (Err message)])])]
        [_ (Err "parse: let requires at least one binding")])]
    [_ (Err "parse: malformed let")]))

(define (parse-ast-let
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view rest))
    [(Cons bindings _ _)
      (match (reader.spanned-sexpr-view
        (compiler-parse-place-shared-view bindings))
        [(BracketList _ _) (parse-ast-let-flat dispatch pools rest)]
        [(Nil _)
          (parse-ast-error-span-note!
            dispatch
            (reader.spanned-sexpr-span bindings))
          (Err "parse: (let () body...) was removed; write (let [] body...)")]
        [(Cons _ _ _)
          (parse-ast-error-span-note!
            dispatch
            (reader.spanned-sexpr-span bindings))
          (Err
            "parse: parenthesized let bindings were removed; write leading [name [: type] init] bindings without parentheses")]
        [_ (Err "parse: let requires at least one binding")])]
    [_ (Err "parse: malformed let")]))

(define (parse-ast-lambda
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons params tail _)
      (let
        [parsed-params
          (try
            (parse-ast-param-list
              dispatch
              pools
              (compiler-parse-place-shared-view params)))]
        (compiler-parse-semantic-param-list-origins! dispatch params)
        (if (ast-param-list-has-comptime? parsed-params)
          (Err
            "comptime parameters are only supported on top-level function definitions")
          (match (reader.spanned-sexpr-view
            (compiler-parse-place-shared-view tail))
            [(Cons first rest-tail _)
              (if (sexpr-colon? first)
                (match (reader.spanned-sexpr-view rest-tail)
                  [(Cons ret body-tail _)
                    (let
                      [parsed-ret
                        (try (parse-ast-type-spanned dispatch pools ret))]
                      [parsed-body
                        (try
                          (parse-ast-body-tail
                            dispatch
                            pools
                            body-tail
                            "parse: malformed lambda"))]
                      (Ok
                        (ast.ast-expr-lambda-with-pools
                          pools
                          parsed-params
                          (Some parsed-ret)
                          parsed-body)))]
                  [_ (Err "parse: malformed lambda")])
                (let
                  [parsed-body
                    (try
                      (parse-ast-body-tail
                        dispatch
                        pools
                        tail
                        "parse: malformed lambda"))]
                  (Ok
                    (ast.ast-expr-lambda-with-pools
                      pools
                      parsed-params
                      No
                      parsed-body))))]
            [_ (Err "parse: malformed lambda")])))]
    [_ (Err "parse: malformed lambda")]))

(define (parse-ast-tuple-ref
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons expr index-tail _)
      (match (reader.spanned-sexpr-view index-tail)
        [(Cons index-node end _)
          (match (reader.spanned-sexpr-view end)
            [(Nil _)
              (match (reader.spanned-sexpr-view index-node)
                [(Int index _ _)
                  (let
                    [parsed-expr
                      (try (parse-ast-expr-with-pools dispatch pools expr))]
                    (Ok
                      (ast.ast-expr-tuple-ref-with-pools
                        pools
                        parsed-expr
                        index)))]
                [_ (Err "parse: tuple-ref index must be integer")])]
            [_ (Err "parse: malformed tuple-ref")])]
        [_ (Err "parse: malformed tuple-ref")])]
    [_ (Err "parse: malformed tuple-ref")]))

(define (parse-ast-dyn-array-literal
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [exprs (try (parse-ast-expr-list dispatch pools rest))]
    (Ok (ast.ast-expr-dyn-array-with-pools pools exprs))))

(define (parse-ast-make-array
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view rest))
    [(Cons elem-ty len-tail _)
      (match (reader.spanned-sexpr-view len-tail)
        [(Cons len end _)
          (match (reader.spanned-sexpr-view end)
            [(Nil _)
              (match (parse-ast-type-spanned dispatch pools elem-ty)
                [(Ok parsed-ty)
                  (let
                    [parsed-len
                      (try (parse-ast-expr-with-pools dispatch pools len))]
                    (Ok
                      (ast.ast-expr-make-array-with-pools
                        pools
                        parsed-ty
                        parsed-len)))]
                [(Err _) (parse-ast-dyn-array-literal dispatch pools rest)])]
            [_ (parse-ast-dyn-array-literal dispatch pools rest)])]
        [_ (parse-ast-dyn-array-literal dispatch pools rest)])]
    [_ (parse-ast-dyn-array-literal dispatch pools rest)]))

(define (parse-ast-fixed-make-array
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons elem-ty len-tail _)
      (match (reader.spanned-sexpr-view len-tail)
        [(Cons len end _)
          (match (reader.spanned-sexpr-view end)
            [(Nil _)
              (let
                [parsed-ty
                  (try (parse-ast-type-spanned dispatch pools elem-ty))]
                [parsed-len
                  (try (parse-ast-expr-with-pools dispatch pools len))]
                (Ok
                  (ast.ast-expr-fixed-make-array-with-pools
                    pools
                    parsed-ty
                    parsed-len)))]
            [_
              (Err "parse: make-array expects exactly one type and one length")])]
        [_ (Err "parse: make-array expects exactly one type and one length")])]
    [_ (Err "parse: make-array expects exactly one type and one length")]))

(define (parse-ast-array-ref-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [is-string : bool]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons expr index-tail _)
      (match (reader.spanned-sexpr-view index-tail)
        [(Cons index end _)
          (match (reader.spanned-sexpr-view end)
            [(Nil _)
              (let
                [parsed-expr
                  (try (parse-ast-expr-with-pools dispatch pools expr))]
                [parsed-index
                  (try (parse-ast-expr-with-pools dispatch pools index))]
                (if is-string
                  (Ok
                    (ast.ast-expr-string-ref-with-pools
                      pools
                      parsed-expr
                      parsed-index))
                  (Ok
                    (ast.ast-expr-array-ref-with-pools
                      pools
                      parsed-expr
                      parsed-index))))]
            [_ (Err "parse: malformed ref expression")])]
        [_ (Err "parse: malformed ref expression")])]
    [_ (Err "parse: malformed ref expression")]))

(define (parse-ast-array-set
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons expr index-tail _)
      (match (reader.spanned-sexpr-view index-tail)
        [(Cons index value-tail _)
          (match (reader.spanned-sexpr-view value-tail)
            [(Cons value end _)
              (match (reader.spanned-sexpr-view end)
                [(Nil _)
                  (let
                    [parsed-expr
                      (try (parse-ast-expr-with-pools dispatch pools expr))]
                    [parsed-index
                      (try (parse-ast-expr-with-pools dispatch pools index))]
                    [parsed-value
                      (try (parse-ast-expr-with-pools dispatch pools value))]
                    (Ok
                      (ast.ast-expr-array-set-with-pools
                        pools
                        parsed-expr
                        parsed-index
                        parsed-value)))]
                [_ (Err "parse: malformed array-set!")])]
            [_ (Err "parse: malformed array-set!")])]
        [_ (Err "parse: malformed array-set!")])]
    [_ (Err "parse: malformed array-set!")]))

(define (parse-ast-array-push
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons expr value-tail _)
      (match (reader.spanned-sexpr-view value-tail)
        [(Cons value end _)
          (match (reader.spanned-sexpr-view end)
            [(Nil _)
              (let
                [parsed-expr
                  (try (parse-ast-expr-with-pools dispatch pools expr))]
                [parsed-value
                  (try (parse-ast-expr-with-pools dispatch pools value))]
                (Ok
                  (ast.ast-expr-array-push-with-pools
                    pools
                    parsed-expr
                    parsed-value)))]
            [_ (Err "parse: malformed __tl_array-push!")])]
        [_ (Err "parse: malformed __tl_array-push!")])]
    [_ (Err "parse: malformed __tl_array-push!")]))

(define (parse-ast-private-array-take
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons array live-tail _)
      (match (reader.spanned-sexpr-view live-tail)
        [(Cons live index-tail _)
          (match (reader.spanned-sexpr-view index-tail)
            [(Cons index end _)
              (match (reader.spanned-sexpr-view end)
                [(Nil _)
                  (let
                    [parsed-array
                      (try (parse-ast-expr-with-pools dispatch pools array))]
                    [parsed-live
                      (try (parse-ast-expr-with-pools dispatch pools live))]
                    [parsed-index
                      (try (parse-ast-expr-with-pools dispatch pools index))]
                    (Ok
                      (ast.ast-expr-array-take-with-pools
                        pools
                        parsed-array
                        parsed-live
                        parsed-index)))]
                [_ (Err "parse: malformed __tl_array-take!")])]
            [_ (Err "parse: malformed __tl_array-take!")])]
        [_ (Err "parse: malformed __tl_array-take!")])]
    [_ (Err "parse: malformed __tl_array-take!")]))

(define (parse-ast-for-owned-state
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [args (try (parse-ast-expr-list dispatch pools rest))]
    (if (= args.len 4)
      (Ok
        (ast.ast-expr-for-owned-state-with-pools
          pools
          (ast.ast-expr-list-get (& args) 0 0)
          (ast.ast-expr-list-get (& args) 1 0)
          (ast.ast-expr-list-get (& args) 2 0)
          (ast.ast-expr-list-get (& args) 3 0)))
      (Err "parse: __tl_for-owned-state expects exactly four operands"))))

(define (parse-ast-for-owned-step
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [typed : bool]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [args (try (parse-ast-expr-list dispatch pools rest))]
    [expected-count : i64
      (if typed
        6
        5)]
    (if (= args.len expected-count)
      (Ok
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
      (Err
        (if typed
          "parse: __tl_for-owned-step-typed expects exactly six operands"
          "parse: __tl_for-owned-step expects exactly five operands")))))

(define (parse-ast-borrow
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [mutable : bool]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons first tail _)
      (match (reader.spanned-sexpr-view tail)
        [(Nil _)
          (let
            [parsed-place
              (try (parse-ast-expr-with-pools dispatch pools first))]
            (Ok
              (ast.ast-expr-borrow-with-pools
                pools
                mutable
                Inferred
                parsed-place)))]
        [(Cons place end _)
          (match (reader.spanned-sexpr-view end)
            [(Nil _)
              (match (reader.spanned-sexpr-view first)
                [(Sym name _)
                  (let
                    [parsed-place
                      (try (parse-ast-expr-with-pools dispatch pools place))]
                    (Ok
                      (ast.ast-expr-borrow-with-pools
                        pools
                        mutable
                        (Named (ci.intern-syntax-id-value name))
                        parsed-place)))]
                [_ (Err "parse: borrow lifetime must be an identifier")])]
            [_ (Err "parse: borrow expects a place or lifetime and place")])]
        [_ (Err "parse: borrow expects a place or lifetime and place")])]
    [_ (Err "parse: borrow expects a place or lifetime and place")]))

(define (parse-ast-struct-get
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons expr field-tail _)
      (match (reader.spanned-sexpr-view field-tail)
        [(Cons field-node end _)
          (match (reader.spanned-sexpr-view end)
            [(Nil _)
              (match (reader.spanned-sexpr-view
                (compiler-parse-place-shared-view field-node))
                [(Sym field _)
                  (let
                    [parsed-expr
                      (try (parse-ast-expr-with-pools dispatch pools expr))]
                    (compiler-parse-semantic-origin-push-components!
                      field
                      (reader.spanned-sexpr-span field-node)
                      (ModulePath)
                      (StructFieldUse))
                    (Ok
                      (ast.ast-expr-struct-get-id-with-pools
                        pools
                        parsed-expr
                        (ci.intern-syntax-id-value field))))]
                [_ (Err "parse: malformed struct-get")])]
            [_ (Err "parse: malformed struct-get")])]
        [_ (Err "parse: malformed struct-get")])]
    [_ (Err "parse: malformed struct-get")]))

;; `(comptime expr)` wraps exactly one inner expression for compile-time
;; evaluation; evaluation itself happens in CTFE, not the parser.
(define (parse-ast-comptime
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(Nil _)
          (let
            [parsed-expr (try (parse-ast-expr-with-pools dispatch pools expr))]
            (Ok (ast.ast-expr-comptime-with-pools pools parsed-expr)))]
        [_ (Err "parse: comptime expects exactly one expression")])]
    [_ (Err "parse: comptime expects exactly one expression")]))

(define (parse-ast-type-literal
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons ty end _)
      (match (reader.spanned-sexpr-view end)
        [(Nil _)
          (let
            [parsed-ty (try (parse-ast-type-spanned dispatch pools ty))]
            (Ok
              (ast.ast-node-pool-context-expr-push
                pools
                (TypeLiteral
                  (ast.ast-node-pool-context-type-push pools parsed-ty)))))]
        [_ (Err "parse: type expects exactly one type")])]
    [_ (Err "parse: type expects exactly one type")]))

(define (parse-ast-spmd-reduce-op
  [dispatch : sym_i64_env.SymI64Env]
  [form-name : String]
  [name-id : i64]) : ResultAstReduceOp
  (cond
    [(= name-id (cbi.compiler-builtin-ctfe "sum")) (Ok (Sum))]
    [(= name-id (cbi.compiler-builtin-ctfe "min")) (Ok (Min))]
    [(= name-id (cbi.compiler-builtin-ctfe "max")) (Ok (Max))]
    [(= name-id (cbi.compiler-builtin-ctfe "all")) (Ok (All))]
    [(= name-id (cbi.compiler-builtin-ctfe "any")) (Ok (Any))]
    [else
      (Err
        (str_cat.str-cat
          "parse: unsupported "
          form-name
          " operator `"
          (compiler-parse-dispatch-name-text dispatch name-id)
          "`; expected one of sum, min, max, all, any"))]))

;; Parse only the shared binding grammar and type here. Expression parsing
;; stays in each form-specific caller so start/end/init/value/body retain their
;; established left-to-right error order and original spanned syntax nodes.
(define (parse-ast-spmd-typed-range-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [binding : reader.SpannedSexpr]
  [expected-colon-message : String]
  [malformed-message : String]) : ResultParseAstSpmdTypedRangeBinding
  (match (reader.spanned-sexpr-view binding)
    [(BracketList items _)
      (parse-ast-spmd-typed-range-binding
        dispatch
        pools
        items
        expected-colon-message
        malformed-message)]
    [(Cons name-node colon-tail _)
      (let
        [_origin : unit
          (compiler-parse-semantic-token-origin!
            dispatch
            (compiler-parse-place-shared-view name-node)
            CompilerParseSemanticOriginKind.BindingDefinition)]
        (match (reader.spanned-sexpr-view name-node)
          [(Sym name _)
            (match (reader.spanned-sexpr-view colon-tail)
              [(Cons colon ty-tail _)
                (match (reader.spanned-sexpr-view ty-tail)
                  [(Cons ty start-tail _)
                    (match (reader.spanned-sexpr-view start-tail)
                      [(Cons start end-tail _)
                        (match (reader.spanned-sexpr-view end-tail)
                          [(Cons end finish _)
                            (match (reader.spanned-sexpr-view finish)
                              [(Nil _)
                                (if (sexpr-colon? colon)
                                  (let
                                    [parsed-ty
                                      (try
                                        (parse-ast-type-spanned
                                          dispatch
                                          pools
                                          ty))]
                                    (Ok
                                      (ParseAstSpmdTypedRangeBinding
                                        (ci.intern-syntax-id-value name)
                                        parsed-ty
                                        start
                                        end)))
                                  (Err expected-colon-message))]
                              [_ (Err malformed-message)])]
                          [_ (Err malformed-message)])]
                      [_ (Err malformed-message)])]
                  [_ (Err malformed-message)])]
              [_ (Err malformed-message)])]
          [_ (Err malformed-message)]))]
    [_ (Err malformed-message)]))

(define (parse-ast-spmd-state-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [binding : reader.SpannedSexpr]
  [expected-colon-message : String]
  [malformed-message : String]) : ResultParseAstSpmdStateBinding
  (match (reader.spanned-sexpr-view binding)
    [(BracketList items _)
      (parse-ast-spmd-state-binding
        dispatch
        pools
        items
        expected-colon-message
        malformed-message)]
    [(Cons name-node colon-tail _)
      (let
        [_origin : unit
          (compiler-parse-semantic-token-origin!
            dispatch
            (compiler-parse-place-shared-view name-node)
            CompilerParseSemanticOriginKind.BindingDefinition)]
        (match (reader.spanned-sexpr-view name-node)
          [(Sym name _)
            (match (reader.spanned-sexpr-view colon-tail)
              [(Cons colon ty-tail _)
                (match (reader.spanned-sexpr-view ty-tail)
                  [(Cons ty init-tail _)
                    (match (reader.spanned-sexpr-view init-tail)
                      [(Cons init finish _)
                        (match (reader.spanned-sexpr-view finish)
                          [(Nil _)
                            (if (sexpr-colon? colon)
                              (let
                                [parsed-ty
                                  (try
                                    (parse-ast-type-spanned dispatch pools ty))]
                                (Ok
                                  (ParseAstSpmdStateBinding
                                    (ci.intern-syntax-id-value name)
                                    parsed-ty
                                    init)))
                              (Err expected-colon-message))]
                          [_ (Err malformed-message)])]
                      [_ (Err malformed-message)])]
                  [_ (Err malformed-message)])]
              [_ (Err malformed-message)])]
          [_ (Err malformed-message)]))]
    [_ (Err malformed-message)]))

;; `[name : T]`, the binding shape with no range or initializer.
(define (parse-ast-spmd-typed-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [binding : reader.SpannedSexpr]
  [expected-colon-message : String]
  [malformed-message : String]) : ResultParseAstSpmdTypedBinding
  (match (reader.spanned-sexpr-view binding)
    [(BracketList items _)
      (parse-ast-spmd-typed-binding
        dispatch
        pools
        items
        expected-colon-message
        malformed-message)]
    [(Cons name-node colon-tail _)
      (let
        [_origin : unit
          (compiler-parse-semantic-token-origin!
            dispatch
            (compiler-parse-place-shared-view name-node)
            CompilerParseSemanticOriginKind.BindingDefinition)]
        (match (reader.spanned-sexpr-view name-node)
          [(Sym name _)
            (match (reader.spanned-sexpr-view colon-tail)
              [(Cons colon ty-tail _)
                (match (reader.spanned-sexpr-view ty-tail)
                  [(Cons ty finish _)
                    (match (reader.spanned-sexpr-view finish)
                      [(Nil _)
                        (if (sexpr-colon? colon)
                          (let
                            [parsed-ty
                              (try (parse-ast-type-spanned dispatch pools ty))]
                            (Ok
                              (ParseAstSpmdTypedBinding
                                (ci.intern-syntax-id-value name)
                                parsed-ty)))
                          (Err expected-colon-message))]
                      [_ (Err malformed-message)])]
                  [_ (Err malformed-message)])]
              [_ (Err malformed-message)])]
          [_ (Err malformed-message)]))]
    [_ (Err malformed-message)]))

(define (parse-ast-spmd-reduce-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [op : ast.AstReduceOp]
  [binding : reader.SpannedSexpr]
  [init : reader.SpannedSexpr]
  [value : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [parsed-binding
      (try
        (parse-ast-spmd-typed-range-binding
          dispatch
          pools
          binding
          "parse: expected ':' in spmd-reduce"
          "parse: malformed spmd-reduce"))]
    [parsed-start
      (try (parse-ast-expr-with-pools dispatch pools parsed-binding.start))]
    [parsed-end
      (try (parse-ast-expr-with-pools dispatch pools parsed-binding.end))]
    [parsed-init (try (parse-ast-expr-with-pools dispatch pools init))]
    [parsed-value (try (parse-ast-expr-with-pools dispatch pools value))]
    (Ok
      (ast.ast-expr-spmd-reduce-id-with-pools
        pools
        op
        parsed-binding.name
        parsed-binding.ty
        parsed-start
        parsed-end
        parsed-init
        parsed-value))))

(define (parse-ast-spmd-reduce
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons op-node binding-tail _)
      (match (reader.spanned-sexpr-view op-node)
        [(Sym op-name _)
          (match (reader.spanned-sexpr-view binding-tail)
            [(Cons binding-list init-tail _)
              (match (reader.spanned-sexpr-view binding-list)
                [(Cons binding binding-list-end _)
                  (match (reader.spanned-sexpr-view binding-list-end)
                    [(Nil _)
                      (match (reader.spanned-sexpr-view init-tail)
                        [(Cons init value-tail _)
                          (match (reader.spanned-sexpr-view value-tail)
                            [(Cons value end _)
                              (match (reader.spanned-sexpr-view end)
                                [(Nil _)
                                  (let
                                    [op
                                      (try
                                        (parse-ast-spmd-reduce-op
                                          dispatch
                                          "spmd-reduce"
                                          (ci.intern-syntax-id-value op-name)))]
                                    (parse-ast-spmd-reduce-binding
                                      dispatch
                                      pools
                                      op
                                      binding
                                      init
                                      value))]
                                [_ (Err "parse: malformed spmd-reduce")])]
                            [_ (Err "parse: malformed spmd-reduce")])]
                        [_ (Err "parse: malformed spmd-reduce")])]
                    [_ (Err "parse: malformed spmd-reduce")])]
                [_ (Err "parse: malformed spmd-reduce")])]
            [_ (Err "parse: malformed spmd-reduce")])]
        [_ (Err "parse: malformed spmd-reduce")])]
    [(Cons _ _ _) (Err "parse: malformed spmd-reduce")]
    [_ (Err "parse: malformed spmd-reduce")]))

(define (parse-ast-spmd-scan
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons op-node binding-tail _)
      (match (reader.spanned-sexpr-view op-node)
        [(Sym op-name _)
          (match (reader.spanned-sexpr-view binding-tail)
            [(Cons binding-list value-tail _)
              (match (reader.spanned-sexpr-view binding-list)
                [(Cons range-binding prefix-tail _)
                  (match (reader.spanned-sexpr-view prefix-tail)
                    [(Cons prefix-binding binding-end _)
                      (match (reader.spanned-sexpr-view binding-end)
                        [(Nil _)
                          (match (reader.spanned-sexpr-view value-tail)
                            [(Cons value body-tail _)
                              (match (reader.spanned-sexpr-view body-tail)
                                [(Cons body end _)
                                  (match (reader.spanned-sexpr-view end)
                                    [(Nil _)
                                      (let
                                        [op
                                          (try
                                            (parse-ast-spmd-reduce-op
                                              dispatch
                                              "spmd-scan"
                                              (ci.intern-syntax-id-value
                                                op-name)))]
                                        (parse-ast-spmd-scan-bindings
                                          dispatch
                                          pools
                                          op
                                          range-binding
                                          prefix-binding
                                          value
                                          body))]
                                    [_ (Err "parse: malformed spmd-scan")])]
                                [_ (Err "parse: malformed spmd-scan")])]
                            [_ (Err "parse: malformed spmd-scan")])]
                        [_ (Err "parse: malformed spmd-scan")])]
                    [_ (Err "parse: malformed spmd-scan")])]
                [_ (Err "parse: malformed spmd-scan")])]
            [_ (Err "parse: malformed spmd-scan")])]
        [_ (Err "parse: malformed spmd-scan")])]
    [(Cons _ _ _) (Err "parse: malformed spmd-scan")]
    [_ (Err "parse: malformed spmd-scan")]))

(define (parse-ast-spmd-scan-bindings
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [op : ast.AstReduceOp]
  [range-binding : reader.SpannedSexpr]
  [prefix-binding : reader.SpannedSexpr]
  [value : reader.SpannedSexpr]
  [body : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [range
      (try
        (parse-ast-spmd-typed-range-binding
          dispatch
          pools
          range-binding
          "parse: expected ':' in spmd-scan range binding"
          "parse: malformed spmd-scan range binding"))]
    [prefix
      (try
        (parse-ast-spmd-state-binding
          dispatch
          pools
          prefix-binding
          "parse: expected ':' in spmd-scan prefix binding"
          "parse: malformed spmd-scan prefix binding"))]
    [parsed-start (try (parse-ast-expr-with-pools dispatch pools range.start))]
    [parsed-end (try (parse-ast-expr-with-pools dispatch pools range.end))]
    [parsed-init (try (parse-ast-expr-with-pools dispatch pools prefix.init))]
    [parsed-value (try (parse-ast-expr-with-pools dispatch pools value))]
    [parsed-body (try (parse-ast-expr-with-pools dispatch pools body))]
    (Ok
      (ast.ast-expr-spmd-scan-id-with-pools
        pools
        op
        range.name
        range.ty
        parsed-start
        parsed-end
        prefix.name
        prefix.ty
        parsed-init
        parsed-value
        parsed-body))))

(define (parse-ast-spmd-compact
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons binding-list keep-tail _)
      (match (reader.spanned-sexpr-view binding-list)
        [(Cons range-binding slot-tail _)
          (match (reader.spanned-sexpr-view slot-tail)
            [(Cons slot-binding bindings-end _)
              (match (reader.spanned-sexpr-view bindings-end)
                [(Nil _)
                  (match (reader.spanned-sexpr-view keep-tail)
                    [(Cons keep body-tail _)
                      (match (reader.spanned-sexpr-view body-tail)
                        [(Cons body end _)
                          (match (reader.spanned-sexpr-view end)
                            [(Nil _)
                              (parse-ast-spmd-compact-bindings
                                dispatch
                                pools
                                range-binding
                                slot-binding
                                keep
                                body)]
                            [_ (Err "parse: malformed spmd-compact")])]
                        [_ (Err "parse: malformed spmd-compact")])]
                    [_ (Err "parse: malformed spmd-compact")])]
                [_ (Err "parse: malformed spmd-compact")])]
            [_ (Err "parse: malformed spmd-compact")])]
        [_ (Err "parse: malformed spmd-compact")])]
    [(Cons _ _ _) (Err "parse: malformed spmd-compact")]
    [_ (Err "parse: malformed spmd-compact")]))

(define (parse-ast-spmd-compact-bindings
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [range-binding : reader.SpannedSexpr]
  [slot-binding : reader.SpannedSexpr]
  [keep : reader.SpannedSexpr]
  [body : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [range
      (try
        (parse-ast-spmd-typed-range-binding
          dispatch
          pools
          range-binding
          "parse: expected ':' in spmd-compact range binding"
          "parse: malformed spmd-compact range binding"))]
    [slot
      (try
        (parse-ast-spmd-state-binding
          dispatch
          pools
          slot-binding
          "parse: expected ':' in spmd-compact slot binding"
          "parse: malformed spmd-compact slot binding"))]
    [parsed-start (try (parse-ast-expr-with-pools dispatch pools range.start))]
    [parsed-end (try (parse-ast-expr-with-pools dispatch pools range.end))]
    [parsed-init (try (parse-ast-expr-with-pools dispatch pools slot.init))]
    [parsed-keep (try (parse-ast-expr-with-pools dispatch pools keep))]
    [parsed-body (try (parse-ast-expr-with-pools dispatch pools body))]
    (Ok
      (ast.ast-expr-spmd-compact-id-with-pools
        pools
        range.name
        range.ty
        parsed-start
        parsed-end
        slot.name
        slot.ty
        parsed-init
        parsed-keep
        parsed-body))))

(define (parse-ast-spmd-broadcast
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons value-node lane-tail _)
      (match (reader.spanned-sexpr-view lane-tail)
        [(Cons lane-node end _)
          (match (reader.spanned-sexpr-view end)
            [(Nil _)
              (let
                [value
                  (try (parse-ast-expr-with-pools dispatch pools value-node))]
                [lane
                  (try (parse-ast-expr-with-pools dispatch pools lane-node))]
                (Ok (ast.ast-expr-spmd-broadcast-with-pools pools value lane)))]
            [_ (Err "parse: malformed spmd-broadcast")])]
        [_ (Err "parse: malformed spmd-broadcast")])]
    [_ (Err "parse: malformed spmd-broadcast")]))

(define (parse-ast-spmd-shuffle
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons value-node lane-tail _)
      (match (reader.spanned-sexpr-view lane-tail)
        [(Cons lane-node end _)
          (match (reader.spanned-sexpr-view end)
            [(Nil _)
              (let
                [value
                  (try (parse-ast-expr-with-pools dispatch pools value-node))]
                [lane
                  (try (parse-ast-expr-with-pools dispatch pools lane-node))]
                (Ok (ast.ast-expr-spmd-shuffle-with-pools pools value lane)))]
            [_ (Err "parse: malformed spmd-shuffle")])]
        [_ (Err "parse: malformed spmd-shuffle")])]
    [_ (Err "parse: malformed spmd-shuffle")]))

;; `(foreach-active [lane : i64] body...)`. Like a `let` body, several body
;; forms become one `begin`, so the node keeps a single body expression.
(define (parse-ast-foreach-active
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons binding body-tail _)
      (let
        [parsed-binding
          (try
            (parse-ast-spmd-typed-binding
              dispatch
              pools
              binding
              "parse: expected ':' in foreach-active binding"
              "parse: malformed foreach-active binding; expected [lane : i64]"))]
        (match parsed-binding.ty
          [(I64)
            (let
              [body
                (try
                  (parse-ast-body-tail
                    dispatch
                    pools
                    body-tail
                    "parse: foreach-active requires a body"))]
              (Ok
                (ast.ast-expr-foreach-active-with-pools
                  pools
                  parsed-binding.name
                  body)))]
          [_ (Err "parse: foreach-active lane binding must have type i64")]))]
    [_
      (Err
        "parse: malformed foreach-active; expected (foreach-active [lane : i64] body...)")]))

(define (parse-ast-lane-value
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons value-node end _)
      (match (reader.spanned-sexpr-view end)
        [(Nil _)
          (let
            [value (try (parse-ast-expr-with-pools dispatch pools value-node))]
            (Ok (ast.ast-expr-lane-value-with-pools pools value)))]
        [_ (Err "parse: lane-value takes exactly one expression")])]
    [_ (Err "parse: lane-value takes exactly one expression")]))

(define (parse-ast-try
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(Nil _)
          (let
            [parsed-expr (try (parse-ast-expr-with-pools dispatch pools expr))]
            (Ok (ast.ast-expr-try-with-pools pools parsed-expr)))]
        [_ (Err "parse: try expects exactly one expression")])]
    [_ (Err "parse: try expects exactly one expression")]))

(define (parse-ast-return
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(Nil _)
          (let
            [parsed-expr (try (parse-ast-expr-with-pools dispatch pools expr))]
            (Ok (ast.ast-expr-return-with-pools pools parsed-expr)))]
        [_ (Err "parse: return expects exactly one expression")])]
    [_ (Err "parse: return expects exactly one expression")]))

(define (parse-ast-box-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [is-get : bool]
  [is-take : bool]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(Nil _)
          (let
            [parsed-expr (try (parse-ast-expr-with-pools dispatch pools expr))]
            (if is-get
              (Ok (ast.ast-expr-box-get-with-pools pools parsed-expr))
              (if is-take
                (Ok (ast.ast-expr-box-take-with-pools pools parsed-expr))
                (Ok (ast.ast-expr-box-with-pools pools parsed-expr)))))]
        [_
          (Err
            (if is-get
              "parse: box-get expects exactly one expression"
              (if is-take
                "parse: box-take expects exactly one expression"
                "parse: box expects exactly one expression")))])]
    [_
      (Err
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
    [(Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(Nil _)
          (let
            [parsed-expr (try (parse-ast-expr-with-pools dispatch pools expr))]
            (Ok (ast.ast-expr-box-take-with-pools pools parsed-expr)))]
        [_ (Err "parse: deref expects exactly one expression")])]
    [_ (Err "parse: deref expects exactly one expression")]))

;; `(ptr-null : T)` - a colon followed by a pointer type, no leading expression.
;; The parser accepts any type here; the typechecker rejects non-pointer `T`.
(define (parse-ast-ptr-null
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons colon ty-tail _)
      (match (reader.spanned-sexpr-view ty-tail)
        [(Cons ty end _)
          (match (reader.spanned-sexpr-view end)
            [(Nil _)
              (if (sexpr-colon? colon)
                (let
                  [parsed-ty (try (parse-ast-type-spanned dispatch pools ty))]
                  (Ok
                    (ast.ast-node-pool-context-expr-push
                      pools
                      (PtrNull
                        (ast.ast-node-pool-context-type-push pools parsed-ty)))))
                (Err "parse: expected ':' in ptr-null"))]
            [_
              (Err
                "parse: ptr-null expects (ptr-null : T) with a pointer type T")])]
        [_ (Err "parse: ptr-null expects (ptr-null : T) with a pointer type T")])]
    [_ (Err "parse: ptr-null expects (ptr-null : T) with a pointer type T")]))

;; `(init : T)` carries an explicit target type. Bare `(init)` is contextual
;; and must be checked/lowered in a position with an expected type.
(define (parse-ast-init
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Nil _) (Ok (ast.ast-expr-init-contextual-with-pools pools))]
    [(Cons colon ty-tail _)
      (match (reader.spanned-sexpr-view ty-tail)
        [(Cons ty end _)
          (match (reader.spanned-sexpr-view end)
            [(Nil _)
              (if (sexpr-colon? colon)
                (let
                  [parsed-ty (try (parse-ast-type-spanned dispatch pools ty))]
                  (Ok (ast.ast-expr-init-with-pools pools parsed-ty)))
                (Err "parse: expected ':' in init"))]
            [_ (Err "parse: init expects (init : T)")])]
        [_ (Err "parse: init expects (init : T)")])]
    [_ (Err "parse: init expects (init : T)")]))

;; `(ptr-null? p)` - a single pointer operand.
(define (parse-ast-ptr-null-check
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(Nil _)
          (let
            [parsed-expr (try (parse-ast-expr-with-pools dispatch pools expr))]
            (Ok (ast.ast-expr-ptr-null-check-with-pools pools parsed-expr)))]
        [_ (Err "parse: ptr-null? expects exactly one expression")])]
    [_ (Err "parse: ptr-null? expects exactly one expression")]))

(define (parse-ast-ptr-read
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(Nil _)
          (let
            [parsed-expr (try (parse-ast-expr-with-pools dispatch pools expr))]
            (Ok (ast.ast-expr-ptr-read-with-pools pools parsed-expr)))]
        [_ (Err "parse: ptr-read expects exactly one expression")])]
    [_ (Err "parse: ptr-read expects exactly one expression")]))

(define (parse-ast-ptr-addr-of
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons place end _)
      (match (reader.spanned-sexpr-view end)
        [(Nil _)
          (let
            [parsed-place
              (try (parse-ast-expr-with-pools dispatch pools place))]
            (Ok (ast.ast-expr-ptr-addr-of-id-with-pools pools parsed-place)))]
        [_ (Err "parse: ptr-addr-of expects exactly one addressable place")])]
    [_ (Err "parse: ptr-addr-of expects exactly one addressable place")]))

(define (parse-ast-ptr-write
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons ptr value-tail _)
      (match (reader.spanned-sexpr-view value-tail)
        [(Cons value end _)
          (match (reader.spanned-sexpr-view end)
            [(Nil _)
              (let
                [parsed-ptr
                  (try (parse-ast-expr-with-pools dispatch pools ptr))]
                [parsed-value
                  (try (parse-ast-expr-with-pools dispatch pools value))]
                (Ok
                  (ast.ast-expr-ptr-write-with-pools
                    pools
                    parsed-ptr
                    parsed-value)))]
            [_ (Err "parse: ptr-write! expects exactly two expressions")])]
        [_ (Err "parse: ptr-write! expects exactly two expressions")])]
    [_ (Err "parse: ptr-write! expects exactly two expressions")]))

(define (parse-ast-ptr-offset
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons ptr offset-tail _)
      (match (reader.spanned-sexpr-view offset-tail)
        [(Cons offset end _)
          (match (reader.spanned-sexpr-view end)
            [(Nil _)
              (let
                [parsed-ptr
                  (try (parse-ast-expr-with-pools dispatch pools ptr))]
                [parsed-offset
                  (try (parse-ast-expr-with-pools dispatch pools offset))]
                (Ok
                  (ast.ast-expr-ptr-offset-with-pools
                    pools
                    parsed-ptr
                    parsed-offset)))]
            [_ (Err "parse: ptr-offset expects exactly two expressions")])]
        [_ (Err "parse: ptr-offset expects exactly two expressions")])]
    [_ (Err "parse: ptr-offset expects exactly two expressions")]))

(define (parse-ast-ptr-cast-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [is-int-to-ptr : bool]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons expr colon-tail _)
      (match (reader.spanned-sexpr-view colon-tail)
        [(Cons colon ty-tail _)
          (match (reader.spanned-sexpr-view ty-tail)
            [(Cons ty end _)
              (match (reader.spanned-sexpr-view end)
                [(Nil _)
                  (if (sexpr-colon? colon)
                    (let
                      [parsed-expr
                        (try (parse-ast-expr-with-pools dispatch pools expr))]
                      [parsed-ty
                        (try (parse-ast-type-spanned dispatch pools ty))]
                      (if is-int-to-ptr
                        (Ok
                          (ast.ast-expr-int-to-ptr-with-pools
                            pools
                            parsed-expr
                            parsed-ty))
                        (Ok
                          (ast.ast-expr-ptr-cast-with-pools
                            pools
                            parsed-expr
                            parsed-ty))))
                    (Err "parse: expected ':' in pointer cast"))]
                [_
                  (Err "parse: pointer cast expects (form expr : pointer-type)")])]
            [_ (Err "parse: pointer cast expects (form expr : pointer-type)")])]
        [_ (Err "parse: pointer cast expects (form expr : pointer-type)")])]
    [_ (Err "parse: pointer cast expects (form expr : pointer-type)")]))

(define (parse-ast-ptr-to-int
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(Nil _)
          (let
            [parsed-expr (try (parse-ast-expr-with-pools dispatch pools expr))]
            (Ok (ast.ast-expr-ptr-to-int-with-pools pools parsed-expr)))]
        [_ (Err "parse: ptr->int expects exactly one expression")])]
    [_ (Err "parse: ptr->int expects exactly one expression")]))

(define (parse-ast-one-expr
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [name : String]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(Nil _) (parse-ast-expr-with-pools dispatch pools expr)]
        [_
          (Err
            (str_cat.str-cat "parse: " name " expects exactly one expression"))])]
    [_ (Err (str_cat.str-cat "parse: " name " expects exactly one expression"))]))

(define (parse-ast-two-exprs
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [name : String]) : ResultAstExprPair
  (match (reader.spanned-sexpr-view rest)
    [(Cons first second-tail _)
      (match (reader.spanned-sexpr-view second-tail)
        [(Cons second end _)
          (match (reader.spanned-sexpr-view end)
            [(Nil _)
              (let
                [parsed-first
                  (try (parse-ast-expr-with-pools dispatch pools first))]
                [parsed-second
                  (try (parse-ast-expr-with-pools dispatch pools second))]
                (Ok (AstExprPair parsed-first parsed-second)))]
            [_
              (Err
                (str_cat.str-cat
                  "parse: "
                  name
                  " expects exactly two expressions"))])]
        [_
          (Err
            (str_cat.str-cat "parse: " name " expects exactly two expressions"))])]
    [_
      (Err (str_cat.str-cat "parse: " name " expects exactly two expressions"))]))

(define (parse-ast-string-data
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [expr (try (parse-ast-one-expr dispatch pools rest "string-data"))]
    (Ok (ast.ast-expr-string-data-with-pools pools expr))))

(define (parse-ast-string-from-bytes
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [pair (try (parse-ast-two-exprs dispatch pools rest "string-from-bytes"))]
    (Ok
      (ast.ast-expr-string-from-bytes-with-pools pools pair.first pair.second))))

(define (parse-ast-array-data
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [expr (try (parse-ast-one-expr dispatch pools rest "__tl_array-data"))]
    (Ok (ast.ast-expr-array-data-with-pools pools expr))))

(define (parse-ast-no-arg-low-level
  [rest : reader.SpannedSexpr]
  [name : String]
  [expr : i64]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Nil _) (Ok expr)]
    [_ (Err (str_cat.str-cat "parse: " name " expects no arguments"))]))

(define (parse-ast-cpuid-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [tag : i64]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [pair (try (parse-ast-two-exprs dispatch pools rest "cpuid"))]
    [leaf : i64 pair.first]
    [subleaf : i64 pair.second]
    (cond
      [(= tag (compiler-parse-tag-expr-cpuid-eax))
        (Ok (ast.ast-expr-cpuid-eax-with-pools pools leaf subleaf))]
      [(= tag (compiler-parse-tag-expr-cpuid-ebx))
        (Ok (ast.ast-expr-cpuid-ebx-with-pools pools leaf subleaf))]
      [(= tag (compiler-parse-tag-expr-cpuid-ecx))
        (Ok (ast.ast-expr-cpuid-ecx-with-pools pools leaf subleaf))]
      [else (Ok (ast.ast-expr-cpuid-edx-with-pools pools leaf subleaf))])))

(define (parse-ast-xgetbv
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [expr (try (parse-ast-one-expr dispatch pools rest "xgetbv"))]
    (Ok (ast.ast-expr-xgetbv-with-pools pools expr))))

(define (parse-ast-syscall-count [args : (& args ast.AstExprList)]) : i64
  args.len)

;; `(syscall number a0 .. a5)`: the syscall number followed by up to six
;; arguments (1 to 7 operands total). Typechecking requires an enclosing
;; `(unsafe ...)` context before this lowers to a raw `syscall` instruction.
(define (parse-ast-syscall
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [args (try (parse-ast-expr-list dispatch pools rest))]
    [count : i64 (parse-ast-syscall-count args)]
    (if (< count 1)
      (Err "parse: syscall requires a syscall number")
      (if (> count 7)
        (Err
          "parse: syscall takes at most 7 operands (number plus six arguments)")
        (Ok (ast.ast-expr-syscall-with-pools pools args))))))

(define (parse-ast-with-region
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view rest))
    [(Nil _) (Err "parse: with-arena requires a region name before its body")]
    [(Cons _ _ _)
      (match (reader.spanned-sexpr-view rest)
        [(Cons region-node body _)
          (let
            [_origin : unit
              (compiler-parse-semantic-token-origin!
                dispatch
                (compiler-parse-place-shared-view region-node)
                CompilerParseSemanticOriginKind.BindingDefinition)]
            (match (reader.spanned-sexpr-view region-node)
              [(Sym region _)
                (match (reader.spanned-sexpr-view
                  (compiler-parse-place-shared-view body))
                  [(Nil _)
                    (Err
                      (str_cat.str-cat
                        "parse: with-arena '"
                        (compiler-parse-dispatch-syntax-id-text dispatch region)
                        "' requires a non-empty body"))]
                  [_
                    (let
                      [exprs (try (parse-ast-expr-list dispatch pools body))]
                      (Ok
                        (ast.ast-node-pool-context-expr-push
                          pools
                          (WithRegion (ci.intern-syntax-id-value region) exprs))))])]
              [_ (Err "parse: with-arena region name must be an identifier")]))]
        [_ (Err "parse: malformed with-arena")])]
    [_ (Err "parse: malformed with-arena")]))

(define (parse-ast-with-escape
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Nil _)
      (Err "parse: with-escape requires a scratch arena before its body")]
    [(Cons scratch body _)
      (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view body))
        [(Nil _) (Err "parse: with-escape requires a non-empty body")]
        [_
          (let
            [parsed-scratch
              (try (parse-ast-expr-with-pools dispatch pools scratch))]
            [exprs (try (parse-ast-expr-list dispatch pools body))]
            (Ok
              (ast.ast-expr-with-escape-with-pools pools parsed-scratch exprs)))])]
    [_ (Err "parse: malformed with-escape")]))

(define (parse-ast-with-scratch
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view rest))
    [(Nil _) (Err "parse: with-scratch requires a non-empty body")]
    [(Cons _ _ _)
      (let
        [exprs (try (parse-ast-expr-list dispatch pools rest))]
        (Ok (ast.ast-expr-with-scratch-with-pools pools exprs)))]
    [_ (Err "parse: malformed with-scratch")]))

(define (parse-ast-in-arena
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Nil _) (Err "parse: in-arena requires an arena before its body")]
    [(Cons arena body _)
      (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view body))
        [(Nil _) (Err "parse: in-arena requires a non-empty body")]
        [_
          (let
            [parsed-arena
              (try (parse-ast-expr-with-pools dispatch pools arena))]
            [exprs (try (parse-ast-expr-list dispatch pools body))]
            (Ok (ast.ast-expr-in-arena-with-pools pools parsed-arena exprs)))])]
    [_ (Err "parse: malformed in-arena")]))

(define (parse-ast-resource-binding-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [items : reader.SpannedSexpr]) : ResultAstResourceBinding
  (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view items))
    [(Cons _ _ _)
      (match (reader.spanned-sexpr-view items)
        [(Cons name-node rest _)
          (let
            [_origin : unit
              (compiler-parse-semantic-token-origin!
                dispatch
                (compiler-parse-place-shared-view name-node)
                CompilerParseSemanticOriginKind.BindingDefinition)]
            (match (reader.spanned-sexpr-view name-node)
              [(Sym name _)
                (match (reader.spanned-sexpr-view rest)
                  [(Nil _) (Err "parse: with binding is missing initializer")]
                  [(Cons init tail _)
                    (match (reader.spanned-sexpr-view tail)
                      [(Nil _)
                        (Err "parse: with binding is missing cleanup function")]
                      [(Cons cleanup extra _)
                        (match (reader.spanned-sexpr-view extra)
                          [(Nil _)
                            (let
                              [parsed-init
                                (try
                                  (parse-ast-expr-with-pools
                                    dispatch
                                    pools
                                    init))]
                              [parsed-cleanup
                                (try
                                  (parse-ast-expr-with-pools
                                    dispatch
                                    pools
                                    cleanup))]
                              (Ok
                                (ast.ast-resource-binding-id
                                  (ci.intern-syntax-id-value name)
                                  parsed-init
                                  parsed-cleanup)))]
                          [_ (Err "parse: with binding has too many fields")])]
                      [_ (Err "parse: malformed with binding")])]
                  [_ (Err "parse: malformed with binding")])]
              [_ (Err "parse: with binding name must be an identifier")]))]
        [_ (Err "parse: malformed with binding")])]
    [_ (Err "parse: malformed with binding")]))

(define (parse-ast-resource-binding
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [binding : reader.SpannedSexpr]) : ResultAstResourceBinding
  (match (reader.spanned-sexpr-view binding)
    [(BracketList items _)
      (parse-ast-resource-binding-items dispatch pools items)]
    [_ (Err "parse: with binding must use bracket syntax")]))

(define (parse-ast-resource-binding-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [bindings : reader.SpannedSexpr]
  [out : (&mut out ast.AstResourceBindingList)]) : ResultAstResourceBindingListBuild
  (match (reader.spanned-sexpr-view bindings)
    [(Nil _) (Ok)]
    [(Cons head rest _)
      (let
        [parsed-head (try (parse-ast-resource-binding dispatch pools head))]
        (ast.ast-resource-binding-list-push out parsed-head)
        (parse-ast-resource-binding-list-into dispatch pools rest out))]
    [_ (Err "parse: malformed with binding list")]))

(define (parse-ast-resource-binding-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [bindings : reader.SpannedSexpr]) : ResultAstResourceBindingList
  (let
    [out : ast.AstResourceBindingList (ast.ast-resource-binding-list-new)]
    [_
      (try
        (parse-ast-resource-binding-list-into
          dispatch
          pools
          bindings
          (&mut out)))]
    (Ok out)))

(define (parse-ast-with-resource
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Nil _) (Err "parse: with requires a binding list before its body")]
    [(Cons bindings body _)
      (match (reader.spanned-sexpr-view
        (compiler-parse-place-shared-view bindings))
        [(Nil _) (Err "parse: with requires a non-empty binding list")]
        [(Cons _ _ _)
          (match (reader.spanned-sexpr-view
            (compiler-parse-place-shared-view body))
            [(Nil _) (Err "parse: with requires a non-empty body")]
            [_
              (let
                [parsed-bindings
                  (try
                    (parse-ast-resource-binding-list dispatch pools bindings))]
                [parsed-body (try (parse-ast-expr-list dispatch pools body))]
                (Ok
                  (ast.ast-node-pool-context-expr-push
                    pools
                    (WithResource
                      (box
                        (ast.AstWithResource.WithResource
                          parsed-bindings
                          parsed-body))))))])]
        [_ (Err "parse: malformed with binding list")])]
    [_ (Err "parse: malformed with")]))

(define (parse-sexpr-list-last [s : reader.SpannedSexpr]) : reader.SpannedSexpr
  (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view s))
    [(Cons head tail _)
      (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view tail))
        [(Cons _ _ _) (parse-sexpr-list-last tail)]
        [_ head])]
    [_ s]))

;; A match arm body is one or more forms. One form keeps the ordinary
;; expression path, so a lone `(cfg ...)` still defaults to `unit`; several
;; forms are an implicit `begin` through the shared body-tail parser. The
;; sequence gets a span from its first to its last form so the arm body keeps
;; a source span of its own beside the pattern span wrapped around it.
(define (parse-ast-match-arm-body
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [body-tail : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view
    (compiler-parse-place-shared-view body-tail))
    [(Cons body end _)
      (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view end))
        [(Nil _) (parse-ast-expr-with-pools dispatch pools body)]
        [_
          (let
            [parsed-body
              (try
                (parse-ast-body-tail
                  dispatch
                  pools
                  body-tail
                  "parse: malformed match arm"))]
            (Ok
              (ast.ast-expr-spanned-with-pools
                pools
                parsed-body
                (ast-source-span-from-source-span
                  (token.merge-spans
                    (reader.spanned-sexpr-span body)
                    (reader.spanned-sexpr-span (parse-sexpr-list-last end)))))))])]
    [_ (Err "parse: malformed match arm")]))

(define (parse-ast-match-arm
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstMatchArm
  (match (reader.spanned-sexpr-view s)
    [(BracketList items _) (parse-ast-match-arm dispatch pools items)]
    [(Cons pattern body-tail _)
      (match (reader.spanned-sexpr-view
        (compiler-parse-place-shared-view body-tail))
        [(Cons _ _ _)
          (let
            [parsed-pattern
              (try
                (parse-ast-pattern
                  dispatch
                  pools
                  (compiler-parse-place-shared-view pattern)))]
            (compiler-parse-semantic-pattern-origins!
              dispatch
              (compiler-parse-place-shared-view pattern))
            (let
              [parsed-body
                (try (parse-ast-match-arm-body dispatch pools body-tail))]
              (Ok
                (ast.ast-match-arm
                  parsed-pattern
                  (ast.ast-expr-spanned-with-pools
                    pools
                    parsed-body
                    (ast-source-span-from-source-span
                      (reader.spanned-sexpr-span pattern)))))))]
        [_ (Err "parse: malformed match arm")])]
    [_ (Err "parse: malformed match arm")]))

(define (parse-ast-match-arm-list-into
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]
  [out : (&mut out ast.AstMatchArmList)]) : ResultAstMatchArmListBuild
  (match (reader.spanned-sexpr-view s)
    [(Nil _) (Ok)]
    [(Cons head tail _)
      (let
        [parsed-head (try (parse-ast-match-arm dispatch pools head))]
        (ast.ast-match-arm-list-push out parsed-head)
        (parse-ast-match-arm-list-into dispatch pools tail out))]
    [_ (Err "parse: malformed match arm list")]))

(define (parse-ast-match-arm-list
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstMatchArmList
  (let
    [out : ast.AstMatchArmList (ast.ast-match-arm-list-new)]
    [_ (try (parse-ast-match-arm-list-into dispatch pools s (&mut out)))]
    (Ok out)))

(define (parse-ast-match
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons scrutinee arms _)
      (let
        [parsed-scrutinee
          (try (parse-ast-expr-with-pools dispatch pools scrutinee))]
        [parsed-arms (try (parse-ast-match-arm-list dispatch pools arms))]
        (Ok (ast.ast-expr-match-with-pools pools parsed-scrutinee parsed-arms)))]
    [_ (Err "parse: malformed match")]))

;; One parsed `[name : type start end]` foreach domain binding.
(defenum ResultForeachDim
  (Ok i64 ast.AstType i64 i64)
  (Err String))

(define (parse-ast-foreach-dim
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [binding : reader.SpannedSexpr]) : ResultForeachDim
  (match (reader.spanned-sexpr-view binding)
    [(BracketList items _) (parse-ast-foreach-dim dispatch pools items)]
    [(Cons index-node colon-tail _)
      (let
        [_origin : unit
          (compiler-parse-semantic-token-origin!
            dispatch
            (compiler-parse-place-shared-view index-node)
            CompilerParseSemanticOriginKind.BindingDefinition)]
        (match (reader.spanned-sexpr-view index-node)
          [(Sym index _)
            (match (reader.spanned-sexpr-view colon-tail)
              [(Cons colon index-ty-tail _)
                (match (reader.spanned-sexpr-view index-ty-tail)
                  [(Cons index-ty start-tail _)
                    (match (reader.spanned-sexpr-view start-tail)
                      [(Cons start end-tail _)
                        (match (reader.spanned-sexpr-view end-tail)
                          [(Cons end finish _)
                            (match (reader.spanned-sexpr-view finish)
                              [(Nil _)
                                (if (sexpr-colon? colon)
                                  (let
                                    [parsed-index-ty
                                      (try
                                        (parse-ast-type-spanned
                                          dispatch
                                          pools
                                          index-ty))]
                                    [parsed-start
                                      (try
                                        (parse-ast-expr-with-pools
                                          dispatch
                                          pools
                                          start))]
                                    [parsed-end
                                      (try
                                        (parse-ast-expr-with-pools
                                          dispatch
                                          pools
                                          end))]
                                    (Ok
                                      (ci.intern-syntax-id-value index)
                                      parsed-index-ty
                                      parsed-start
                                      parsed-end))
                                  (Err "parse: expected ':' in foreach"))]
                              [_ (Err "parse: malformed foreach binding")])]
                          [_ (Err "parse: malformed foreach binding")])]
                      [_ (Err "parse: malformed foreach binding")])]
                  [_ (Err "parse: malformed foreach binding")])]
              [_ (Err "parse: malformed foreach binding")])]
          [_ (Err "parse: malformed foreach binding")]))]
    [_ (Err "parse: malformed foreach binding")]))

;; Parse the single body form of a foreach after its domain bindings.
(define (parse-ast-foreach-body
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [body-tail : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view body-tail)
    [(Cons body end _)
      (match (reader.spanned-sexpr-view end)
        [(Nil _) (parse-ast-expr-with-pools dispatch pools body)]
        [_ (Err "parse: malformed foreach")])]
    [_ (Err "parse: malformed foreach")]))

;; `(foreach ([i : T start end]) body)` is a rank-1 domain and
;; `(foreach ([y : T y0 y1] [x : T x0 x1]) body)` a rank-2 one. Bindings,
;; then the body, are parsed in source order.
(define (parse-ast-foreach
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons binding-list body-tail _)
      (match (reader.spanned-sexpr-view binding-list)
        [(Nil _) (Err "parse: foreach requires one or two domain bindings")]
        [(Cons binding binding-end _)
          (match (reader.spanned-sexpr-view binding-end)
            [(Nil _)
              (match (parse-ast-foreach-dim dispatch pools binding)
                [(Ok name index-ty start end)
                  (let
                    [body
                      (try (parse-ast-foreach-body dispatch pools body-tail))]
                    (Ok
                      (ast.ast-expr-foreach-id-with-pools
                        pools
                        name
                        index-ty
                        start
                        end
                        body)))]
                [(Err message) (Err message)])]
            [(Cons inner-binding rank-end _)
              (match (reader.spanned-sexpr-view rank-end)
                [(Nil _)
                  (match (parse-ast-foreach-dim dispatch pools binding)
                    [(Ok outer outer-ty outer-start outer-end)
                      (match (parse-ast-foreach-dim
                        dispatch
                        pools
                        inner-binding)
                        [(Ok inner inner-ty inner-start inner-end)
                          (if (= outer inner)
                            (Err
                              "parse: foreach domain bindings must use distinct names")
                            (let
                              [body
                                (try
                                  (parse-ast-foreach-body
                                    dispatch
                                    pools
                                    body-tail))]
                              (Ok
                                (ast.ast-expr-foreach2-id-with-pools
                                  pools
                                  outer
                                  outer-ty
                                  outer-start
                                  outer-end
                                  inner
                                  inner-ty
                                  inner-start
                                  inner-end
                                  body))))]
                        [(Err message) (Err message)])]
                    [(Err message) (Err message)])]
                [_
                  (Err
                    "parse: foreach supports at most two domain bindings (rank 2)")])]
            [_ (Err "parse: malformed foreach")])]
        [_ (Err "parse: malformed foreach")])]
    [_ (Err "parse: malformed foreach")]))

(define (parse-ast-call
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [head : reader.SpannedSexpr]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [parsed-head (try (parse-ast-expr-with-pools dispatch pools head))]
    [parsed-args (try (parse-ast-call-arg-list dispatch pools rest))]
    (Ok (ast.ast-expr-call-with-pools pools parsed-head parsed-args))))

(define (parse-ast-begin
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [exprs (try (parse-ast-expr-list dispatch pools rest))]
    (Ok (ast.ast-node-pool-context-expr-push pools (Begin exprs)))))

;; `(unsafe expr+)` parses like `begin` but requires a non-empty body. It has
;; the same behavior as `begin`; it marks an unsafe context for later raw-pointer
;; ops.
(define (parse-ast-unsafe
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view rest))
    [(Nil _) (Err "parse: unsafe requires a non-empty body")]
    [_
      (let
        [exprs (try (parse-ast-expr-list dispatch pools rest))]
        (Ok (ast.ast-node-pool-context-expr-push pools (Unsafe exprs))))]))

(define (parse-ast-tuple
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [exprs (try (parse-ast-expr-list dispatch pools rest))]
    (Ok (ast.ast-node-pool-context-expr-push pools (Tuple exprs)))))

(define (parse-ast-array
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [exprs (try (parse-ast-expr-list dispatch pools rest))]
    (Ok (ast.ast-node-pool-context-expr-push pools (Array exprs)))))

(define (parse-ast-quote-like
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [tag : i64]
  [rest : reader.SpannedSexpr]) : ResultAstExpr
  (match (reader.spanned-sexpr-view rest)
    [(Cons expr end _)
      (match (reader.spanned-sexpr-view end)
        [(Nil _)
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
                  [(Ok parsed)
                    (cond
                      [(= tag (compiler-parse-tag-expr-quote))
                        (Ok (ast.ast-expr-quote-with-pools pools parsed))]
                      [(= tag (compiler-parse-tag-expr-quasiquote))
                        (Ok (ast.ast-expr-quasiquote-with-pools pools parsed))]
                      [(= tag (compiler-parse-tag-expr-unquote))
                        (Ok (ast.ast-expr-unquote-with-pools pools parsed))]
                      [else
                        (Ok
                          (ast.ast-expr-unquote-splicing-with-pools
                            pools
                            parsed))])]
                  [(Err message) (Err message)]))]
            (set! compiler-parse-quote-depth saved-depth)
            (set! compiler-parse-semantic-quote-depth saved-semantic-depth)
            result)]
        [_ (Err "parse: quote form expects exactly one expression")])]
    [_ (Err "parse: quote form expects exactly one expression")]))

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
    [(= tag (compiler-parse-tag-expr-spmd-compact))
      (parse-ast-spmd-compact dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-spmd-broadcast))
      (parse-ast-spmd-broadcast dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-spmd-shuffle))
      (parse-ast-spmd-shuffle dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-foreach-active))
      (parse-ast-foreach-active dispatch pools rest)]
    [(= tag (compiler-parse-tag-expr-lane-value))
      (parse-ast-lane-value dispatch pools rest)]
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
        (Err
          "parse: struct-get was removed; use dotted field projection value.field"))]
    [(= tag (compiler-parse-tag-expr-retired-array-set))
      (if (> compiler-parse-quote-depth 0)
        (parse-ast-array-set dispatch pools rest)
        (Err
          "parse: array-set! was removed; use (set! (array-ref array index) value)"))]
    [(= tag (compiler-parse-tag-expr-retired-box-get))
      (if (> compiler-parse-quote-depth 0)
        (parse-ast-box-like dispatch pools rest true false)
        (Err "parse: box-get was removed; use (deref box)"))]
    [(= tag (compiler-parse-tag-expr-retired-box-take))
      (if (> compiler-parse-quote-depth 0)
        (parse-ast-box-like dispatch pools rest false true)
        (Err "parse: box-take was removed; use (deref box)"))]
    [(= tag (compiler-parse-tag-expr-retired-struct-set))
      (Err
        "parse: struct-set/struct-set! was removed; use (set! value.field replacement)")]
    [(= tag (compiler-parse-tag-expr-retired-array-push))
      (Err
        "parse: bare array-push! was removed; use a generated vector mutator")]
    [(= tag (compiler-parse-tag-expr-retired-array-data))
      (Err
        "parse: array-data was removed; raw dynamic-buffer storage is compiler-private")]
    [(= tag (compiler-parse-tag-expr-retired-array-take))
      (Err
        "parse: array-take! was removed; use (replace! (array-ref array index) replacement)")]
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
        (ast.ast-node-pool-context-expr-push pools (ProgramArgc)))]
    [(= tag (compiler-parse-tag-expr-program-argv))
      (parse-ast-no-arg-low-level
        rest
        "program-argv"
        (ast.ast-node-pool-context-expr-push pools (ProgramArgv)))]
    [(= tag (compiler-parse-tag-expr-program-envp))
      (parse-ast-no-arg-low-level
        rest
        "program-envp"
        (ast.ast-node-pool-context-expr-push pools (ProgramEnvp)))]
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
  (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view head))
    [(Sym op _)
      (cond
        [(=
            (ci.intern-syntax-id-value op)
            (cbi.compiler-builtin-ctfe "__typelisp internal binary data"))
          (parse-ast-internal-binary-data dispatch pools rest)]
        [(=
            (compiler-parse-dispatch-tag
              dispatch
              (ci.intern-syntax-id-value op))
            (compiler-parse-tag-expr-init))
          (match (reader.spanned-sexpr-view
            (compiler-parse-place-shared-view rest))
            [(Cons first _ _)
              (if (sexpr-colon? first)
                (parse-ast-init dispatch pools rest)
                (parse-ast-call dispatch pools head rest))]
            [(Nil _) (parse-ast-init dispatch pools rest)]
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
                  (Err (parse-ast-removed-declaration-message))
                  (parse-ast-list-expr-tag dispatch pools tag head rest))]))])]
    [_ (parse-ast-call dispatch pools head rest)]))

(define (parse-ast-expr-with-pools
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [result : ResultAstExpr
      (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view s))
        [(Int n text _)
          (Ok
            (ast-expr-wrap-span
              pools
              (ast.ast-node-pool-context-expr-push
                pools
                (Literal (Int n (reader.sp-text-copy text))))
              (compiler-parse-place-shared-view s)))]
        [(Float text _)
          (Ok
            (ast-expr-wrap-span
              pools
              (ast.ast-node-pool-context-expr-push
                pools
                (Literal (Float (reader.sp-text-copy text))))
              (compiler-parse-place-shared-view s)))]
        [(Str string-id _)
          (Ok
            (ast-expr-wrap-span
              pools
              (ast.ast-node-pool-context-expr-push
                pools
                (Literal (String (ci.intern-id-value string-id))))
              (compiler-parse-place-shared-view s)))]
        [(Char c _)
          (Ok
            (ast-expr-wrap-span
              pools
              (ast.ast-node-pool-context-expr-push pools (Literal (Char c)))
              (compiler-parse-place-shared-view s)))]
        [(Sym name span)
          (let
            [name-id : i64 (ci.intern-syntax-id-value name)]
            [tag : i64 (compiler-parse-dispatch-tag-id dispatch name-id)]
            (cond
              [(= tag (compiler-parse-tag-lit-true))
                (Ok
                  (ast-expr-wrap-span
                    pools
                    (ast.ast-node-pool-context-expr-push
                      pools
                      (Literal (Bool true)))
                    (compiler-parse-place-shared-view s)))]
              [(= tag (compiler-parse-tag-lit-false))
                (Ok
                  (ast-expr-wrap-span
                    pools
                    (ast.ast-node-pool-context-expr-push
                      pools
                      (Literal (Bool false)))
                    (compiler-parse-place-shared-view s)))]
              [(= tag (compiler-parse-tag-unit))
                (Ok
                  (ast-expr-wrap-span
                    pools
                    (ast.ast-node-pool-context-expr-push pools (Literal Unit))
                    (compiler-parse-place-shared-view s)))]
              [else
                ;; This is a source candidate, not a claimed field use. The
                ;; helper rejects generated syntax identities and plain
                ;; names before reading dotted-name metadata.
                (compiler-parse-semantic-dotted-field-origins! name span)
                (Ok
                  (ast-expr-wrap-span
                    pools
                    (ast.ast-node-pool-context-expr-push pools (Var name-id))
                    (compiler-parse-place-shared-view s)))]))]
        [(Cons head rest _)
          (match (reader.spanned-sexpr-view
            (compiler-parse-place-shared-view head))
            [(Sym op _)
              (if (=
                (ci.intern-syntax-id-value op)
                (cbi.compiler-builtin-ctfe "cfg"))
                (match (parse-ast-cfg-expr dispatch pools rest)
                  [(Ok parsed)
                    (Ok
                      (ast-expr-wrap-span
                        pools
                        parsed
                        (compiler-parse-place-shared-view s)))]
                  [(Err message) (Err message)])
                (match (parse-ast-list-expr dispatch pools head rest)
                  [(Ok parsed)
                    (Ok
                      (ast-expr-wrap-span
                        pools
                        parsed
                        (compiler-parse-place-shared-view s)))]
                  [(Err message) (Err message)]))]
            [_
              (match (parse-ast-list-expr dispatch pools head rest)
                [(Ok parsed)
                  (Ok
                    (ast-expr-wrap-span
                      pools
                      parsed
                      (compiler-parse-place-shared-view s)))]
                [(Err message) (Err message)])])]
        [_ (Err "parse: malformed expression")])]
    (parse-ast-error-span-note-expr dispatch s result)))

(define (parse-ast-expr
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]) : ResultAstExpr
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultAstExpr (parse-ast-expr-with-pools dispatch pools s)]
    (ast.ast-node-pool-context-install! pools)
    result))

(define (parse-ast-define-value
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [name : i64]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(Cons first tail _)
      (match (reader.spanned-sexpr-view tail)
        [(Nil _)
          (let
            [parsed-value
              (try (parse-ast-expr-with-pools dispatch pools first))]
            (Ok (ast.ast-decl-def-id name No parsed-value)))]
        [(Cons ty value-tail _)
          (match (reader.spanned-sexpr-view value-tail)
            [(Cons value end _)
              (match (reader.spanned-sexpr-view end)
                [(Nil _)
                  (if (sexpr-colon? first)
                    (let
                      [parsed-ty
                        (try (parse-ast-type-spanned dispatch pools ty))]
                      [parsed-value
                        (try (parse-ast-expr-with-pools dispatch pools value))]
                      (Ok
                        (ast.ast-decl-def-id name (Some parsed-ty) parsed-value)))
                    (Err "parse: expected ':' in definition"))]
                [_ (Err "parse: malformed value definition")])]
            [_ (Err "parse: malformed value definition")])]
        [_ (Err "parse: malformed value definition")])]
    [_ (Err "parse: malformed value definition")]))

(define (parse-ast-spmd-param-classes
  [items : reader.SpannedSexpr]
  [out : ast.AstSpmdParamClassList]) : ResultAstSpmdParamClassList
  (match (reader.sexpr-view items)
    [(Nil) (Ok out)]
    [(Cons head rest)
      (match (reader.sexpr-view head)
        [(Sym name)
          (let
            [next : ast.AstSpmdParamClassList out]
            (if (=
              (ci.intern-syntax-id-value name)
              (cbi.compiler-builtin-ctfe "uniform"))
              (begin
                (ast.ast-spmd-param-class-list-push (&mut next) Uniform)
                (parse-ast-spmd-param-classes rest next))
              (if (=
                (ci.intern-syntax-id-value name)
                (cbi.compiler-builtin-ctfe "varying"))
                (begin
                  (ast.ast-spmd-param-class-list-push (&mut next) Varying)
                  (parse-ast-spmd-param-classes rest next))
                (Err
                  "parse: :spmd-callable args expects only uniform or varying"))))]
        [_ (Err "parse: :spmd-callable args expects only uniform or varying")])]
    [_ (Err "parse: malformed :spmd-callable args field")]))

(define (parse-ast-spmd-result-class [tail : reader.SpannedSexpr]) : ResultAstSpmdResultClass
  (match (reader.sexpr-view tail)
    [(Cons head rest)
      (match (reader.sexpr-view rest)
        [(Nil)
          (match (reader.sexpr-view head)
            [(Sym name)
              (cond
                [(=
                    (ci.intern-syntax-id-value name)
                    (cbi.compiler-builtin-ctfe "unit"))
                  (Ok Unit)]
                [(=
                    (ci.intern-syntax-id-value name)
                    (cbi.compiler-builtin-ctfe "uniform"))
                  (Ok Uniform)]
                [(=
                    (ci.intern-syntax-id-value name)
                    (cbi.compiler-builtin-ctfe "varying"))
                  (Ok Varying)]
                [else
                  (Err
                    "parse: :spmd-callable result expects unit, uniform, or varying")])]
            [_
              (Err
                "parse: :spmd-callable result expects unit, uniform, or varying")])]
        [_ (Err "parse: :spmd-callable result expects one value")])]
    [_ (Err "parse: malformed :spmd-callable result field")]))

(define (parse-ast-spmd-index-param [tail : reader.SpannedSexpr]) : ResultAstSpmdIndexParam
  (match (reader.sexpr-view tail)
    [(Cons head rest)
      (match (reader.sexpr-view rest)
        [(Nil)
          (match (reader.sexpr-view head)
            [(Sym name)
              (if (=
                (ci.intern-syntax-id-value name)
                (cbi.compiler-builtin-ctfe "none"))
                (Ok -1)
                (Err
                  "parse: :spmd-callable index-param expects none or a non-negative integer"))]
            [(Int value _)
              (if (>= value 0)
                (Ok value)
                (Err
                  "parse: :spmd-callable index-param expects none or a non-negative integer"))]
            [_
              (Err
                "parse: :spmd-callable index-param expects none or a non-negative integer")])]
        [_ (Err "parse: :spmd-callable index-param expects one value")])]
    [_ (Err "parse: malformed :spmd-callable index-param field")]))

(define (parse-ast-spmd-specialization-fields
  [dispatch : sym_i64_env.SymI64Env]
  [fields : reader.SpannedSexpr]
  [state : AstSpmdSpecializationParseState]) : ResultAstSpmdSpecializationParseState
  (match (reader.sexpr-view fields)
    [(Nil) (Ok state)]
    [(Cons field-node rest)
      (match (reader.sexpr-view field-node)
        [(Cons key-node value-tail)
          (match (reader.sexpr-view key-node)
            [(Sym key)
              (cond
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe "lanes"))
                  (if state.seen-lanes
                    (Err "parse: duplicate :spmd-callable lanes field")
                    (match (reader.sexpr-view value-tail)
                      [(Cons value-node end)
                        (match (reader.sexpr-view end)
                          [(Nil)
                            (match (reader.sexpr-view value-node)
                              [(Int lanes _)
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
                                  (Err
                                    "parse: :spmd-callable lanes must be greater than one"))]
                              [_
                                (Err
                                  "parse: :spmd-callable lanes expects one integer")])]
                          [_
                            (Err
                              "parse: :spmd-callable lanes expects one integer")])]
                      [_
                        (Err "parse: :spmd-callable lanes expects one integer")]))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe "args"))
                  (if state.seen-args
                    (Err "parse: duplicate :spmd-callable args field")
                    (let
                      [args
                        (try
                          (parse-ast-spmd-param-classes
                            value-tail
                            (ast.ast-spmd-param-class-list-new)))]
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
                          state.seen-index-param))))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe "result"))
                  (if state.seen-result
                    (Err "parse: duplicate :spmd-callable result field")
                    (let
                      [result (try (parse-ast-spmd-result-class value-tail))]
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
                          state.seen-index-param))))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe "index-param"))
                  (if state.seen-index-param
                    (Err "parse: duplicate :spmd-callable index-param field")
                    (let
                      [index-param
                        (try (parse-ast-spmd-index-param value-tail))]
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
                          true))))]
                [else
                  (Err
                    (str_cat.str-cat
                      "parse: unknown :spmd-callable specialization field "
                      (compiler-parse-dispatch-syntax-id-text dispatch key)))])]
            [_ (Err "parse: malformed :spmd-callable specialization field")])]
        [_ (Err "parse: malformed :spmd-callable specialization field")])]
    [_ (Err "parse: malformed :spmd-callable specialization")]))

(define (parse-ast-spmd-specialization
  [dispatch : sym_i64_env.SymI64Env]
  [tail : reader.SpannedSexpr]
  [param-count : i64]) : ResultAstSpmdSpecialization
  (let
    [state
      (try
        (parse-ast-spmd-specialization-fields
          dispatch
          tail
          (AstSpmdSpecializationParseState
            0
            (ast.ast-spmd-param-class-list-new)
            Unit
            -1
            false
            false
            false
            false)))]
    (cond
      [(not state.seen-lanes)
        (Err "parse: :spmd-callable specialization is missing lanes")]
      [(not state.seen-args)
        (Err "parse: :spmd-callable specialization is missing args")]
      [(not state.seen-result)
        (Err "parse: :spmd-callable specialization is missing result")]
      [(not state.seen-index-param)
        (Err "parse: :spmd-callable specialization is missing index-param")]
      [(not (= (ast.ast-spmd-param-class-list-len (& state.args)) param-count))
        (Err
          "parse: :spmd-callable args must contain one class per ordinary parameter")]
      [(>= state.index-param param-count)
        (Err "parse: :spmd-callable index-param is outside the parameter list")]
      [else
        (Ok
          (ast.AstSpmdSpecialization
            state.lanes
            (box state.args)
            state.result
            state.index-param))])))

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
      (match (ast.ast-spmd-param-class-list-get left index Uniform)
        [(Uniform)
          (match (ast.ast-spmd-param-class-list-get right index Varying)
            [(Uniform)
              (parse-ast-spmd-param-classes-eq-at? left right (+ index 1))]
            [_ false])]
        [(Varying)
          (match (ast.ast-spmd-param-class-list-get right index Uniform)
            [(Varying)
              (parse-ast-spmd-param-classes-eq-at? left right (+ index 1))]
            [_ false])]))))

(define (parse-ast-spmd-specialization-eq?
  [left : ast.AstSpmdSpecialization]
  [right : (& right ast.AstSpmdSpecialization)]) : bool
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
      (ast.ast-spmd-specialization-list-get
        items
        index
        (compiler-parse-place-shared-view wanted))
      wanted)
      true
      (parse-ast-spmd-specialization-present-at? items wanted (+ index 1)))))

(define (parse-ast-spmd-specializations
  [dispatch : sym_i64_env.SymI64Env]
  [items : reader.SpannedSexpr]
  [param-count : i64]
  [out : ast.AstSpmdSpecializationList]) : ResultAstSpmdCallable
  (match (reader.sexpr-view items)
    [(Nil)
      (if (= (ast.ast-spmd-specialization-list-len (& out)) 0)
        (Err "parse: :spmd-callable expects at least one specialization")
        (Ok (Callable out)))]
    [(Cons item-node rest)
      (match (reader.sexpr-view item-node)
        [(Cons name-node fields)
          (match (reader.sexpr-view name-node)
            [(Sym name)
              (if (=
                (ci.intern-syntax-id-value name)
                (cbi.compiler-builtin-ctfe "specialization"))
                (let
                  [specialization
                    (try
                      (parse-ast-spmd-specialization
                        dispatch
                        fields
                        param-count))]
                  (if (parse-ast-spmd-specialization-present-at?
                    (& out)
                    (compiler-parse-place-shared-view specialization)
                    0)
                    (Err "parse: duplicate :spmd-callable specialization")
                    (let
                      [next : ast.AstSpmdSpecializationList out]
                      (ast.ast-spmd-specialization-list-push
                        (&mut next)
                        specialization)
                      (parse-ast-spmd-specializations
                        dispatch
                        rest
                        param-count
                        next))))
                (Err "parse: :spmd-callable expects specialization forms"))]
            [_ (Err "parse: malformed :spmd-callable specialization")])]
        [_ (Err "parse: malformed :spmd-callable specialization")])]
    [_ (Err "parse: malformed :spmd-callable metadata")]))

(define (parse-ast-define-fn-spmd-callable-tail
  [dispatch : sym_i64_env.SymI64Env]
  [tail : reader.SpannedSexpr]
  [param-count : i64]) : ResultAstSpmdCallable
  (parse-ast-spmd-specializations
    dispatch
    tail
    param-count
    (ast.ast-spmd-specialization-list-new)))

(define (parse-ast-define-fn-export-tail
  [dispatch : sym_i64_env.SymI64Env]
  [tail : reader.SpannedSexpr]) : ResultAstFnExport
  (match (reader.sexpr-view tail)
    [(Cons value-node end)
      (match (reader.sexpr-view end)
        [(Nil)
          (match (reader.sexpr-view value-node)
            [(Str value-id)
              (if (>
                (string.string-length
                  (compiler-parse-dispatch-id-str dispatch value-id))
                0)
                (Ok (ast.ast-fn-export-id value-id))
                (Err "parse: define :export-symbol must not be empty"))]
            [_ (Err "parse: malformed define :export-symbol metadata")])]
        [_ (Err "parse: malformed define :export-symbol metadata")])]
    [_ (Err "parse: malformed define :export-symbol metadata")]))

(define (parse-ast-metadata-form?
  [dispatch : sym_i64_env.SymI64Env]
  [item : reader.SpannedSexpr]) : bool
  (match (reader.sexpr-view item)
    [(Cons key-node _)
      (match (reader.sexpr-view key-node)
        [(Sym key) (compiler-parse-metadata-key? dispatch key)]
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
      [(Export _) true]
      [_ false])
    (match (compiler-parse-place-shared-view spmd-callable)
      [(Callable _) true]
      [_ false]))
    (Err "parse: define :spmd-callable cannot be combined with :export-symbol")
    (if (ast-param-list-has-comptime? params)
      (match export
        [(Export _)
          (Err
            "parse: define :export-symbol cannot be used on functions with comptime parameters")]
        [(No)
          (match (compiler-parse-place-shared-view spmd-callable)
            [(No)
              (Ok
                (ast.ast-decl-def-fn-metadata-id
                  name
                  params
                  ret
                  body
                  (ast.ast-fn-metadata-full export spmd-callable)))]
            [(Callable _)
              (Err
                "parse: define :spmd-callable cannot be used on functions with comptime parameters")])])
      (Ok
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
  (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view rest))
    [(Cons first tail _)
      (if (sexpr-colon? (compiler-parse-place-shared-view first))
        (match (reader.spanned-sexpr-view tail)
          [(Cons ret body-tail _)
            (let
              [parsed-ret (try (parse-ast-type-spanned dispatch pools ret))]
              [parsed-body
                (try
                  (parse-ast-body-tail
                    dispatch
                    pools
                    body-tail
                    "parse: malformed function definition"))]
              (parse-ast-define-fn-finish
                name
                params
                parsed-ret
                parsed-body
                export
                spmd-callable))]
          [_ (Err "parse: malformed function definition")])
        (if (parse-ast-metadata-form?
          dispatch
          (compiler-parse-place-shared-view first))
          (match (reader.sexpr-view first)
            [(Cons key-node after-key)
              (match (reader.sexpr-view key-node)
                [(Sym key)
                  (cond
                    [(=
                        (ci.intern-syntax-id-value key)
                        (cbi.compiler-builtin-ctfe ":export-symbol"))
                      (if seen-export
                        (Err "parse: duplicate define :export-symbol metadata")
                        (let
                          [parsed-export
                            (try
                              (parse-ast-define-fn-export-tail
                                dispatch
                                after-key))]
                          (parse-ast-define-fn-rest
                            dispatch
                            pools
                            name
                            params
                            parsed-export
                            true
                            spmd-callable
                            seen-spmd-callable
                            tail)))]
                    [(=
                        (ci.intern-syntax-id-value key)
                        (cbi.compiler-builtin-ctfe ":spmd-callable"))
                      (if seen-spmd-callable
                        (Err "parse: duplicate define :spmd-callable metadata")
                        (let
                          [parsed-callable
                            (try
                              (parse-ast-define-fn-spmd-callable-tail
                                dispatch
                                after-key
                                (ast.ast-param-list-len (& params))))]
                          (parse-ast-define-fn-rest
                            dispatch
                            pools
                            name
                            params
                            export
                            seen-export
                            parsed-callable
                            true
                            tail)))]
                    [(compiler-parse-metadata-key? dispatch key)
                      (Err
                        (str_cat.str-cat
                          "parse: unknown define metadata "
                          (compiler-parse-dispatch-syntax-id-text dispatch key)))]
                    [else (Err "parse: malformed function metadata")])]
                [_ (Err "parse: malformed function definition")])]
            [_ (Err "parse: malformed function definition")])
          (let
            [parsed-body
              (try
                (parse-ast-body-tail
                  dispatch
                  pools
                  rest
                  "parse: malformed function definition"))]
            (parse-ast-define-fn-finish
              name
              params
              (Unit)
              parsed-body
              export
              spmd-callable))))]
    [_ (Err "parse: malformed function definition")]))

(define (parse-ast-define-fn
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [name : i64]
  [params : reader.SpannedSexpr]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (let
    [parsed-params
      (try
        (parse-ast-param-list
          dispatch
          pools
          (compiler-parse-place-shared-view params)))]
    (compiler-parse-semantic-param-list-origins! dispatch params)
    (parse-ast-define-fn-rest
      dispatch
      pools
      name
      parsed-params
      No
      false
      No
      false
      rest)))

(define (parse-ast-define
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(Cons head after-name _)
      (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view head))
        [(Sym name _)
          (compiler-parse-semantic-token-origin!
            dispatch
            (compiler-parse-place-shared-view head)
            CompilerParseSemanticOriginKind.ValueName)
          (parse-ast-define-value
            dispatch
            pools
            (ci.intern-syntax-id-value name)
            after-name)]
        [(Cons name-node params _)
          (match (reader.spanned-sexpr-view
            (compiler-parse-place-shared-view name-node))
            [(Sym name _)
              (compiler-parse-semantic-token-origin!
                dispatch
                (compiler-parse-place-shared-view name-node)
                CompilerParseSemanticOriginKind.ValueName)
              (parse-ast-define-fn
                dispatch
                pools
                (ci.intern-syntax-id-value name)
                params
                after-name)]
            [_ (Err "parse: malformed define")])]
        [_ (Err "parse: malformed define")])]
    [_ (Err "parse: malformed define")]))

(define (parse-ast-defmacro
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(Cons header after-header _)
      (match (reader.spanned-sexpr-view header)
        [(Cons name-node params _)
          (match (reader.spanned-sexpr-view name-node)
            [(Sym name _)
              (match (reader.spanned-sexpr-view after-header)
                [(Cons colon ret-tail _)
                  (match (reader.spanned-sexpr-view ret-tail)
                    [(Cons ret body-tail _)
                      (match (reader.spanned-sexpr-view body-tail)
                        [(Cons body end _)
                          (match (reader.spanned-sexpr-view end)
                            [(Nil _)
                              (if (sexpr-colon? colon)
                                (let
                                  [parsed-params
                                    (try
                                      (parse-ast-macro-param-list
                                        dispatch
                                        pools
                                        (compiler-parse-place-shared-view
                                          params)))]
                                  (compiler-parse-semantic-param-list-origins!
                                    dispatch
                                    params)
                                  (let
                                    [parsed-ret
                                      (try
                                        (parse-ast-type-spanned
                                          dispatch
                                          pools
                                          ret))]
                                    [parsed-body
                                      (try
                                        (parse-ast-expr-with-pools
                                          dispatch
                                          pools
                                          body))]
                                    (Ok
                                      (ast.ast-decl-def-macro-id
                                        (ci.intern-syntax-id-value name)
                                        parsed-params
                                        parsed-ret
                                        parsed-body))))
                                (Err "parse: expected ':' in macro definition"))]
                            [_ (Err "parse: malformed defmacro")])]
                        [_ (Err "parse: malformed defmacro")])]
                    [_ (Err "parse: malformed defmacro")])]
                [_ (Err "parse: malformed defmacro")])]
            [_ (Err "parse: malformed defmacro")])]
        [_ (Err "parse: malformed defmacro")])]
    [_ (Err "parse: malformed defmacro")]))

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
        (&mut intern-state)
        tail
        0
        (string.string-length tail)))))

(define (parse-ast-extern-varargs-open? [name-id : ci.InternSyntaxId]) : bool
  (= (ci.intern-syntax-id-value name-id) (cbi.compiler-builtin-ctfe "...")))

(define (parse-ast-extern-varargs-tail-type
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [name-id : ci.InternSyntaxId]) : ResultAstType
  (if (parse-ast-extern-varargs-typed-name? dispatch name-id)
    (parse-ast-type
      dispatch
      pools
      (Sym
        (ci.intern-syntax-id-from-raw
          (parse-ast-extern-varargs-tail-id dispatch name-id))
        (token.SourceSpan 0 0 0 0)))
    (Err "parse: expected typed extern varargs tail")))

(define (parse-ast-extern-head-fixed-param
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [item : reader.SpannedSexpr]) : ResultAstExternHeadItem
  (let
    [param
      (try
        (parse-ast-param dispatch pools (compiler-parse-place-shared-view item)))]
    (compiler-parse-semantic-param-origin! dispatch item)
    (match param
      [(Param _ ty comptime?)
        (if comptime?
          (Err "parse: extern parameters cannot be comptime")
          (Ok (Param ty)))])))

(define (parse-ast-extern-head-bracket-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [item : reader.SpannedSexpr]
  [items : reader.SpannedSexpr]) : ResultAstExternHeadItem
  (match (reader.spanned-sexpr-view items)
    [(Cons _ after-name _)
      (match (reader.spanned-sexpr-view after-name)
        [(Cons colon after-colon _)
          (match (reader.spanned-sexpr-view after-colon)
            [(Cons ty-node end _)
              (match (reader.spanned-sexpr-view end)
                [(Nil _)
                  (if (sexpr-colon? colon)
                    (match (reader.spanned-sexpr-view ty-node)
                      [(Sym ty-name ty-span)
                        (if (parse-ast-extern-varargs-open? ty-name)
                          (Err "parse: extern typed varargs tail needs a type")
                          (if (parse-ast-extern-varargs-typed-name?
                            dispatch
                            ty-name)
                            (let
                              [tail-ty
                                (try
                                  (parse-ast-extern-varargs-tail-type
                                    dispatch
                                    pools
                                    ty-name))]
                              (compiler-parse-semantic-type-origins!
                                dispatch
                                (Sym
                                  (ci.intern-syntax-id-from-raw
                                    (parse-ast-extern-varargs-tail-id
                                      dispatch
                                      ty-name))
                                  (token.SourceSpan
                                    (token.span-start-line ty-span)
                                    (+ (token.span-start-col ty-span) 3)
                                    (token.span-end-line ty-span)
                                    (token.span-end-col ty-span))))
                              (Ok (VarargsTyped tail-ty)))
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
  (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view item))
    [(Sym name _)
      (if (parse-ast-extern-varargs-open? name)
        (Ok (VarargsOpen))
        (if (parse-ast-extern-varargs-typed-name? dispatch name)
          (Err "parse: typed extern varargs tail must use bracket syntax")
          (Err "parse: malformed extern function head")))]
    [(BracketList items _)
      (parse-ast-extern-head-bracket-item dispatch pools item items)]
    [_ (Err "parse: malformed extern function head")]))

(define (parse-ast-extern-head-items
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [items : reader.SpannedSexpr]) : ResultAstExternHeader
  (match (reader.spanned-sexpr-view items)
    [(Nil _) (Ok -1 (ast.ast-type-list-new) (C))]
    [(Cons item tail _)
      (let
        [item : reader.SpannedSexpr item]
        [tail : reader.SpannedSexpr tail]
        [parsed-item (try (parse-ast-extern-head-item dispatch pools item))]
        (match parsed-item
          [(Param ty)
            (match (parse-ast-extern-head-items dispatch pools tail)
              [(Ok _ parsed-tail parsed-abi)
                (Ok
                  -1
                  (ast.ast-type-cons-with-pools pools ty parsed-tail)
                  parsed-abi)]
              [(Err message) (Err message)])]
          [(VarargsOpen)
            (match (reader.spanned-sexpr-view tail)
              [(Nil _) (Ok -1 (ast.ast-type-list-new) (CVarargsOpen))]
              [_ (Err "parse: extern varargs tail must be final")])]
          [(VarargsTyped tail-ty)
            (match (reader.spanned-sexpr-view tail)
              [(Nil _) (Ok -1 (ast.ast-type-list-new) (CVarargsTyped tail-ty))]
              [_ (Err "parse: extern varargs tail must be final")])]))]
    [_ (Err "parse: malformed extern function head")]))

(define (parse-ast-extern-header
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [head : reader.SpannedSexpr]) : ResultAstExternHeader
  (match (reader.spanned-sexpr-view head)
    [(Cons name-node params _)
      (match (reader.spanned-sexpr-view name-node)
        [(Sym name _)
          (match (parse-ast-extern-head-items dispatch pools params)
            [(Ok _ param-types abi)
              (Ok (ci.intern-syntax-id-value name) param-types abi)]
            [(Err message) (Err message)])]
        [_ (Err "parse: malformed extern function head")])]
    [_ (Err "parse: malformed extern function head")]))

(define (parse-ast-extern-c-varargs-legacy-message) : String
  "parse: legacy :abi c-varargs metadata is retired; use function-head ... or ...T varargs")

(define (parse-ast-extern-abi-tail
  [dispatch : sym_i64_env.SymI64Env]
  [tail : reader.SpannedSexpr]) : ResultAstExternAbi
  (match (reader.sexpr-view tail)
    [(Cons name-node rest)
      (match (reader.sexpr-view name-node)
        [(Sym name)
          (match (reader.sexpr-view rest)
            [(Nil)
              (if (=
                (ci.intern-syntax-id-value name)
                cbi.compiler-builtin-id-fix-c)
                (Ok (C))
                (if (=
                  (ci.intern-syntax-id-value name)
                  (cbi.compiler-builtin-ctfe "c-varargs"))
                  (Err (parse-ast-extern-c-varargs-legacy-message))
                  (Err
                    (str_cat.str-cat
                      "parse: unknown extern ABI "
                      (compiler-parse-dispatch-syntax-id-text dispatch name)))))]
            [(Cons fixed-node end)
              (match (reader.sexpr-view end)
                [(Nil)
                  (match (reader.sexpr-view fixed-node)
                    [(Int _ _)
                      (if (=
                        (ci.intern-syntax-id-value name)
                        (cbi.compiler-builtin-ctfe "c-varargs"))
                        (Err (parse-ast-extern-c-varargs-legacy-message))
                        (Err
                          (str_cat.str-cat
                            "parse: unknown extern ABI "
                            (compiler-parse-dispatch-syntax-id-text
                              dispatch
                              name))))]
                    [_ (Err "parse: malformed extern :abi metadata")])]
                [_ (Err "parse: malformed extern :abi metadata")])]
            [_ (Err "parse: malformed extern :abi metadata")])]
        [_ (Err "parse: malformed extern :abi metadata")])]
    [_ (Err "parse: malformed extern :abi metadata")]))

(define (parse-ast-extern-string-tail
  [dispatch : sym_i64_env.SymI64Env]
  [key : String]
  [tail : reader.SpannedSexpr]) : ResultAstExternSymbol
  (match (reader.sexpr-view tail)
    [(Cons value-node end)
      (match (reader.sexpr-view end)
        [(Nil)
          (match (reader.sexpr-view value-node)
            [(Str value-id)
              (let
                [value : String
                  (compiler-parse-dispatch-id-str dispatch value-id)]
                (if (> (string.string-length value) 0)
                  (Ok value value-id)
                  (Err
                    (str_cat.str-cat "parse: extern " key " must not be empty"))))]
            [_
              (Err (str_cat.str-cat "parse: malformed extern " key " metadata"))])]
        [_ (Err (str_cat.str-cat "parse: malformed extern " key " metadata"))])]
    [_ (Err (str_cat.str-cat "parse: malformed extern " key " metadata"))]))

(define (parse-ast-extern-symbol-tail
  [dispatch : sym_i64_env.SymI64Env]
  [tail : reader.SpannedSexpr]) : ResultAstExternSymbol
  (parse-ast-extern-string-tail dispatch ":symbol" tail))

(define (parse-ast-extern-abi-combine
  [base : ast.AstExternAbi]
  [parsed : ast.AstExternAbi]) : ResultAstExternAbi
  (if (ast.ast-extern-abi-c-varargs? (compiler-parse-place-shared-view base))
    (match parsed
      [(C) (Ok base)]
      [_ (Err "parse: extern varargs tail cannot be combined with another ABI")])
    (Ok parsed)))

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
    [(Cons head tail _)
      (if (sexpr-colon? (compiler-parse-place-shared-view head))
        (match (reader.spanned-sexpr-view tail)
          [(Cons ty end _)
            (match (reader.spanned-sexpr-view end)
              [(Nil _)
                (let
                  [parsed-ty (try (parse-ast-type-spanned dispatch pools ty))]
                  (Ok abi symbol-id seen-abi parsed-ty))]
              [_ (Err "parse: malformed extern")])]
          [_ (Err "parse: malformed extern")])
        (match (reader.sexpr-view head)
          [(Cons key-node after-key)
            (match (reader.sexpr-view key-node)
              [(Sym key)
                (cond
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe ":abi"))
                    (if seen-abi
                      (Err "parse: duplicate extern :abi metadata")
                      (let
                        [parsed-abi
                          (try (parse-ast-extern-abi-tail dispatch after-key))]
                        (parse-ast-extern-items
                          dispatch
                          pools
                          tail
                          parsed-abi
                          symbol-id
                          link-inputs
                          true
                          seen-symbol)))]
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe ":symbol"))
                    (if seen-symbol
                      (Err "parse: duplicate extern :symbol metadata")
                      (match (parse-ast-extern-symbol-tail dispatch after-key)
                        [(Ok _ parsed-symbol-id)
                          (parse-ast-extern-items
                            dispatch
                            pools
                            tail
                            abi
                            parsed-symbol-id
                            link-inputs
                            seen-abi
                            true)]
                        [(Err message) (Err message)]))]
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe ":link-lib"))
                    (match (parse-ast-extern-string-tail
                      dispatch
                      ":link-lib"
                      after-key)
                      [(Ok value _)
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
                          seen-symbol)]
                      [(Err message) (Err message)])]
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe ":link-search"))
                    (match (parse-ast-extern-string-tail
                      dispatch
                      ":link-search"
                      after-key)
                      [(Ok value _)
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
                          seen-symbol)]
                      [(Err message) (Err message)])]
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe ":link-arg"))
                    (match (parse-ast-extern-string-tail
                      dispatch
                      ":link-arg"
                      after-key)
                      [(Ok value _)
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
                          seen-symbol)]
                      [(Err message) (Err message)])]
                  [(compiler-parse-metadata-key? dispatch key)
                    (Err
                      (str_cat.str-cat
                        "parse: unknown extern metadata "
                        (compiler-parse-dispatch-syntax-id-text dispatch key)))]
                  [else (Err "parse: expected ':' in extern")])]
              [_ (Err "parse: expected ':' in extern")])]
          [_ (Err "parse: expected ':' in extern")]))]
    [_ (Err "parse: malformed extern")]))

(define (parse-ast-extern-head-finish
  [pools : ast.AstNodePoolContext]
  [abi : ast.AstExternAbi]
  [symbol-id : ci.InternId]
  [seen-abi : bool]
  [param-types : ast.AstTypeList]
  [ret : ast.AstType]) : ResultAstExternParts
  (Ok abi symbol-id seen-abi (ast.ast-ty-func-with-pools pools param-types ret)))

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
    [(Nil _)
      (parse-ast-extern-head-finish
        pools
        abi
        symbol-id
        seen-abi
        param-types
        ret)]
    [(Cons head tail _)
      (match (reader.sexpr-view head)
        [(Cons key-node after-key)
          (match (reader.sexpr-view key-node)
            [(Sym key)
              (cond
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe ":abi"))
                  (if seen-abi
                    (Err "parse: duplicate extern :abi metadata")
                    (let
                      [parsed-abi
                        (try (parse-ast-extern-abi-tail dispatch after-key))]
                      [combined-abi
                        (try (parse-ast-extern-abi-combine abi parsed-abi))]
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
                        ret)))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe ":symbol"))
                  (if seen-symbol
                    (Err "parse: duplicate extern :symbol metadata")
                    (match (parse-ast-extern-symbol-tail dispatch after-key)
                      [(Ok _ parsed-symbol-id)
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
                      [(Err message) (Err message)]))]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe ":link-lib"))
                  (match (parse-ast-extern-string-tail
                    dispatch
                    ":link-lib"
                    after-key)
                    [(Ok value _)
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
                        ret)]
                    [(Err message) (Err message)])]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe ":link-search"))
                  (match (parse-ast-extern-string-tail
                    dispatch
                    ":link-search"
                    after-key)
                    [(Ok value _)
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
                        ret)]
                    [(Err message) (Err message)])]
                [(=
                    (ci.intern-syntax-id-value key)
                    (cbi.compiler-builtin-ctfe ":link-arg"))
                  (match (parse-ast-extern-string-tail
                    dispatch
                    ":link-arg"
                    after-key)
                    [(Ok value _)
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
                        ret)]
                    [(Err message) (Err message)])]
                [(compiler-parse-metadata-key? dispatch key)
                  (Err
                    (str_cat.str-cat
                      "parse: unknown extern metadata "
                      (compiler-parse-dispatch-syntax-id-text dispatch key)))]
                [else (Err "parse: malformed extern")])]
            [_ (Err "parse: malformed extern")])]
        [_ (Err "parse: malformed extern")])]
    [_ (Err "parse: malformed extern")]))

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
    [(Cons head tail _)
      (if (sexpr-colon? (compiler-parse-place-shared-view head))
        (match (reader.spanned-sexpr-view tail)
          [(Cons ret end _)
            (match (reader.spanned-sexpr-view
              (compiler-parse-place-shared-view end))
              [(Nil _)
                (let
                  [parsed-ret (try (parse-ast-type-spanned dispatch pools ret))]
                  (parse-ast-extern-head-finish
                    pools
                    abi
                    symbol-id
                    seen-abi
                    param-types
                    parsed-ret))]
              [_
                (let
                  [parsed-ret (try (parse-ast-type-spanned dispatch pools ret))]
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
                    parsed-ret))])]
          [_ (Err "parse: malformed extern")])
        (match (reader.sexpr-view head)
          [(Cons key-node after-key)
            (match (reader.sexpr-view key-node)
              [(Sym key)
                (cond
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe ":abi"))
                    (if seen-abi
                      (Err "parse: duplicate extern :abi metadata")
                      (let
                        [parsed-abi
                          (try (parse-ast-extern-abi-tail dispatch after-key))]
                        [combined-abi
                          (try (parse-ast-extern-abi-combine abi parsed-abi))]
                        (parse-ast-extern-head-rest
                          dispatch
                          pools
                          tail
                          combined-abi
                          symbol-id
                          link-inputs
                          true
                          seen-symbol
                          param-types)))]
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe ":symbol"))
                    (if seen-symbol
                      (Err "parse: duplicate extern :symbol metadata")
                      (match (parse-ast-extern-symbol-tail dispatch after-key)
                        [(Ok _ parsed-symbol-id)
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
                        [(Err message) (Err message)]))]
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe ":link-lib"))
                    (match (parse-ast-extern-string-tail
                      dispatch
                      ":link-lib"
                      after-key)
                      [(Ok value _)
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
                          param-types)]
                      [(Err message) (Err message)])]
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe ":link-search"))
                    (match (parse-ast-extern-string-tail
                      dispatch
                      ":link-search"
                      after-key)
                      [(Ok value _)
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
                          param-types)]
                      [(Err message) (Err message)])]
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe ":link-arg"))
                    (match (parse-ast-extern-string-tail
                      dispatch
                      ":link-arg"
                      after-key)
                      [(Ok value _)
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
                          param-types)]
                      [(Err message) (Err message)])]
                  [(compiler-parse-metadata-key? dispatch key)
                    (Err
                      (str_cat.str-cat
                        "parse: unknown extern metadata "
                        (compiler-parse-dispatch-syntax-id-text dispatch key)))]
                  [else (Err "parse: expected ':' in extern")])]
              [_ (Err "parse: expected ':' in extern")])]
          [_ (Err "parse: expected ':' in extern")]))]
    [_ (Err "parse: malformed extern")]))

(define (parse-ast-extern-function-head
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [head : reader.SpannedSexpr]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (parse-ast-extern-header dispatch pools head)
    [(Ok name param-types abi)
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
          [(Ok parsed-abi parsed-symbol-id explicit-abi ty)
            (Ok
              (ast.ast-decl-extern-id
                name
                (Function)
                (Metadata
                  parsed-abi
                  parsed-symbol-id
                  link-inputs
                  (ast.ast-extern-metadata-flags
                    explicit-abi
                    (ci.intern-id-eq? parsed-symbol-id source-symbol))
                  No)
                ty))]
          [(Err message) (Err message)]))]
    [(Err message) (Err message)]))

(define (parse-ast-extern
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(Cons name-node after-name _)
      (match (reader.spanned-sexpr-view
        (compiler-parse-place-shared-view name-node))
        [(Sym name _)
          (let
            [name-id : i64 (ci.intern-syntax-id-value name)]
            [source-symbol : ci.InternId (ci.intern-syntax-id-renderable name)]
            [link-inputs : ast.AstExternLinkInputList
              (ast.ast-extern-link-input-list-new)]
            (match (parse-ast-extern-items
              dispatch
              pools
              after-name
              (C)
              source-symbol
              (&mut link-inputs)
              false
              false)
              [(Ok parsed-abi parsed-symbol-id explicit-abi parsed-ty)
                (Ok
                  (ast.ast-decl-extern-id
                    name-id
                    (Value)
                    (Metadata
                      parsed-abi
                      parsed-symbol-id
                      link-inputs
                      (ast.ast-extern-metadata-flags
                        explicit-abi
                        (ci.intern-id-eq? parsed-symbol-id source-symbol))
                      No)
                    parsed-ty))]
              [(Err message) (Err message)]))]
        [_ (parse-ast-extern-function-head dispatch pools name-node after-name)])]
    [_ (Err "parse: malformed extern")]))

(define (parse-ast-defenum
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(Cons name-node variants _)
      (match (reader.spanned-sexpr-view name-node)
        [(Sym name name-span)
          (let
            [name-id : i64 (ci.intern-syntax-id-value name)]
            [member-marker : i64
              (reader.sp-node-push
                (Int 0 (compiler-parse-marker "__tl_member_origin") name-span))]
            (compiler-parse-semantic-origin-push-components!
              name
              name-span
              (ModulePath)
              (TypeDefinition))
            (match (parse-ast-defenum-items
              dispatch
              pools
              variants
              (ast.ast-lifetime-list-new)
              (No)
              0
              false
              false
              false)
              [(Ok lifetimes cleanup markers parsed-variants)
                (reader.sp-node-pool-fill!
                  member-marker
                  (Int
                    (unsafe
                      (cast
                        (ptr->int
                          (ptr-cast
                            (__tl_array-data parsed-variants.slots)
                            : (Ptr u8)))
                        : i64))
                    (compiler-parse-marker "__tl_member_origin")
                    name-span))
                (if (ast.ast-variant-def-list-empty? (& parsed-variants))
                  (Err "parse: defenum needs at least one variant")
                  (if (ast.ast-lifetime-list-empty? (& lifetimes))
                    (Ok
                      (ast.ast-decl-with-aggregate-markers
                        (ast.ast-decl-def-enum-id
                          name-id
                          cleanup
                          parsed-variants)
                        markers))
                    (Ok
                      (ast.ast-decl-with-aggregate-markers
                        (ast.ast-decl-def-enum-lifetimes-id
                          name-id
                          lifetimes
                          cleanup
                          parsed-variants)
                        markers))))]
              [(Err message) (Err message)]))]
        [_ (Err "parse: malformed defenum")])]
    [_ (Err "parse: malformed defenum")]))

(define (parse-ast-defstruct
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(Cons name-node fields _)
      (match (reader.spanned-sexpr-view name-node)
        [(Sym name name-span)
          (let
            [name-id : i64 (ci.intern-syntax-id-value name)]
            [member-marker : i64
              (reader.sp-node-push
                (Int 0 (compiler-parse-marker "__tl_member_origin") name-span))]
            (compiler-parse-semantic-origin-push-components!
              name
              name-span
              (ModulePath)
              (TypeDefinition))
            (match (parse-ast-defstruct-items
              dispatch
              pools
              (compiler-parse-place-shared-view fields)
              (ast.ast-lifetime-list-new)
              (Default)
              (No)
              0
              0
              (ast.ast-field-def-list-new)
              false
              false
              false
              false)
              [(Ok lifetimes repr cleanup markers parsed-fields)
                (reader.sp-node-pool-fill!
                  member-marker
                  (Int
                    (unsafe
                      (cast
                        (ptr->int
                          (ptr-cast
                            (__tl_array-data parsed-fields.slots)
                            : (Ptr u8)))
                        : i64))
                    (compiler-parse-marker "__tl_member_origin")
                    name-span))
                (if (ast.ast-field-def-list-empty? (& parsed-fields))
                  (Err "parse: defstruct needs at least one field")
                  (if (ast.ast-lifetime-list-empty? (& lifetimes))
                    (Ok
                      (ast.ast-decl-with-aggregate-markers
                        (ast.ast-decl-def-struct-id
                          name-id
                          repr
                          cleanup
                          parsed-fields)
                        markers))
                    (Ok
                      (ast.ast-decl-with-aggregate-markers
                        (ast.ast-decl-def-struct-lifetimes-id
                          name-id
                          lifetimes
                          repr
                          cleanup
                          parsed-fields)
                        markers))))]
              [(Err message)
                ;; Only the walk's end knows a struct `(:align N)` lacks
                ;; `(:repr c)`; locate the error at that form.
                (when
                  (string.eq message (parse-ast-defstruct-align-needs-repr-c))
                  (parse-ast-defstruct-note-align-form! dispatch fields))
                (Err message)]))]
        [_ (Err "parse: malformed defstruct")])]
    [_ (Err "parse: malformed defstruct")]))

(define (parse-ast-defdispatch
  [dispatch : sym_i64_env.SymI64Env]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(Cons name-node variants _)
      (match (reader.spanned-sexpr-view name-node)
        [(Sym name _)
          (let
            [parsed-variants
              (try (parse-ast-dispatch-variant-list dispatch variants))]
            (if (ast.ast-dispatch-variant-list-empty? (& parsed-variants))
              (Err "parse: defdispatch needs at least one variant")
              (Ok
                (ast.ast-decl-def-dispatch-id
                  (ci.intern-syntax-id-value name)
                  parsed-variants))))]
        [_ (Err "parse: malformed defdispatch")])]
    [_ (Err "parse: malformed defdispatch")]))

(define (parse-ast-module-body-forms-into-vec
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [forms : reader.SpannedSexpr]
  [semantic-origins : (MutPtr ParseSemanticOriginVec)]
  [out : (&mut out ParseAstDeclVec)]) : ResultParseAstDeclVec
  (match (reader.spanned-sexpr-view forms)
    [(Nil _) (Ok)]
    [(Cons form rest _)
      (let
        [semantic-start : i64 out.semantic-origins.len]
        (compiler-parse-semantic-origin-capture-select!
          semantic-origins
          out.len)
        (match (parse-ast-decl-maybe-with-pools
          dispatch
          pools
          (compiler-parse-place-shared-view form))
          [(SomeDecl decl)
            (parse-ast-decl-vec-push-with-span
              out
              decl
              (compiler-parse-decl-origin-syntax-span dispatch form))
            (parse-ast-module-body-forms-into-vec
              dispatch
              pools
              rest
              semantic-origins
              out)]
          [(Decls decls)
            (set! out.semantic-origins.len semantic-start)
            (parse-ast-decl-vec-push-list! out decls)
            (parse-ast-module-body-forms-into-vec
              dispatch
              pools
              rest
              semantic-origins
              out)]
          [(NoDecl)
            (set! out.semantic-origins.len semantic-start)
            (parse-ast-module-body-forms-into-vec
              dispatch
              pools
              rest
              semantic-origins
              out)]
          [(Err message)
            (set! out.semantic-origins.len semantic-start)
            (Err message)]))]
    [_ (Err "parse: malformed module")]))

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
        [(Ok)
          (Ok
            (ast.ast-decl-module-body-id
              name
              (parse-ast-decl-vec-to-list (& out))))]
        [(Err message) (Err message)])]
    (compiler-parse-semantic-origin-capture-restore! previous-capture)
    result))

(define (parse-ast-module
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(Cons name-node end _)
      (match (reader.spanned-sexpr-view name-node)
        [(Sym name span)
          (compiler-parse-semantic-origin-push-components!
            name
            span
            (ModuleDefinition)
            (ModuleDefinition))
          (match (reader.spanned-sexpr-view
            (compiler-parse-place-shared-view end))
            [(Nil _)
              (Ok (ast.ast-decl-module-id (ci.intern-syntax-id-value name)))]
            [_
              (parse-ast-module-body
                dispatch
                pools
                (ci.intern-syntax-id-value name)
                end)])]
        [_ (Err "parse: malformed module")])]
    [_ (Err "parse: malformed module")]))

(define (parse-ast-import-spec
  [kind : ast.AstImportKind]
  [path : String]
  [module-name : ast.AstMaybeModuleName]
  [alias : ast.AstMaybeImportAlias]
  [span : ast.AstSourceSpan]) : ResultAstDecl
  (Ok
    (Import
      (ast.ast-decl-meta-runtime-shared-view)
      (Spec kind path module-name alias (box span)))))

(define (parse-ast-import-alias
  [kind : ast.AstImportKind]
  [path : String]
  [module-name : ast.AstMaybeModuleName]
  [tail : reader.SpannedSexpr]
  [span : ast.AstSourceSpan]) : ResultAstDecl
  (match (reader.spanned-sexpr-view tail)
    [(Cons as-node alias-tail _)
      (match (reader.spanned-sexpr-view as-node)
        [(Sym as-name _)
          (match (reader.spanned-sexpr-view alias-tail)
            [(Cons alias-node end _)
              (match (reader.spanned-sexpr-view end)
                [(Nil _)
                  (match (reader.spanned-sexpr-view alias-node)
                    [(Sym alias alias-span)
                      (if (=
                        (ci.intern-syntax-id-value as-name)
                        (cbi.compiler-builtin-ctfe "as"))
                        (begin
                          (compiler-parse-semantic-origin-push-components!
                            alias
                            alias-span
                            (ModulePath)
                            (ImportAlias))
                          (parse-ast-import-spec
                            kind
                            path
                            module-name
                            (Some (ci.intern-syntax-id-value alias))
                            span))
                        (Err "parse: malformed import"))]
                    [_ (Err "parse: malformed import")])]
                [_ (Err "parse: malformed import")])]
            [_ (Err "parse: malformed import")])]
        [_ (Err "parse: malformed import")])]
    [_ (Err "parse: malformed import")]))

(define (parse-ast-import-macro-tail
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [call-form : reader.SpannedSexpr]
  [tail : reader.SpannedSexpr]
  [span : ast.AstSourceSpan]) : ResultAstDecl
  (let
    [call-expr (try (parse-ast-expr-with-pools dispatch pools call-form))]
    (match (ast.ast-expr-unspan-with-pools
      pools
      (ast.ast-node-pool-context-expr-get pools call-expr))
      [(Call _ _)
        (match (reader.spanned-sexpr-view
          (compiler-parse-place-shared-view tail))
          [(Nil _) (parse-ast-import-spec (Macro call-expr No) "" No No span)]
          [(Cons head-node _ _)
            (match (reader.spanned-sexpr-view head-node)
              [(Sym head _)
                (if (=
                  (ci.intern-syntax-id-value head)
                  (cbi.compiler-builtin-ctfe "as"))
                  (parse-ast-import-alias (Macro call-expr No) "" No tail span)
                  (Err "parse: malformed import"))]
              [_ (Err "parse: malformed import")])]
          [_ (Err "parse: malformed import")])]
      [_ (Err "parse: import macro operand must be a call")])))

(define (parse-ast-dotted-import-default-alias-start [name : (& name str)]) : i64
  (let
    [n : i64 (string.string-length name)]
    [i : i64 0]
    [start : i64 0]
    (while (< i n)
      (if (string.char-eq (string.string-ref name i) '.')
        (set! start (+ i 1))
        unit)
      (set! i (+ i 1)))
    start))

(define (parse-ast-dotted-import-default-alias [name : String]) : String
  (let
    [start : i64 (parse-ast-dotted-import-default-alias-start name)]
    (string.substring name start (- (string.string-length name) start))))

(define (parse-ast-dotted-import-default-alias-id-with-state
  [intern-state : ci.InternCompatState]
  [name-id : i64]) : i64
  (ci.intern-compat-state-dotted-final-id intern-state name-id))

(define (parse-ast-dotted-import-wildcard? [name : (& name str)]) : bool
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
        (ModulePath)
        (ModulePath))
      (compiler-parse-semantic-origin-push-components!
        module-name
        span
        (ModulePath)
        (ModulePath)))
    unit))

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
          (ImportAlias)
          (ci.intern-id-value
            (ci.intern-compat-state-source-slice-id
              (&mut intern-state)
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
    (if (not (module_name.compiler-module-name-valid? module-name))
      (Err "parse: invalid dotted import module name")
      (if (parse-ast-dotted-import-wildcard? module-name)
        (match (reader.spanned-sexpr-view tail)
          [(Nil _)
            (let
              [target-id : i64
                (ci.intern-compat-state-dotted-prefix-id
                  intern-state
                  module-name-id)]
              (parse-ast-import-spec
                (ModuleAll)
                (ci.intern-compat-state-syntax-name-text-or
                  intern-state
                  target-id
                  "")
                (Some target-id)
                (Some cbi.compiler-builtin-id-fix-empty)
                span))]
          [_
            (Err
              "parse: wildcard import cannot use as; import a selected item instead")])
        (match (reader.spanned-sexpr-view
          (compiler-parse-place-shared-view tail))
          [(Nil _)
            (parse-ast-import-spec
              (Module)
              module-name
              (Some module-name-id)
              (Some
                (parse-ast-dotted-import-default-alias-id-with-state
                  intern-state
                  module-name-id))
              span)]
          [(Cons head-node _ _)
            (match (reader.spanned-sexpr-view head-node)
              [(Sym head _)
                (if (=
                  (ci.intern-syntax-id-value head)
                  (cbi.compiler-builtin-ctfe "as"))
                  (parse-ast-import-alias
                    (Module)
                    module-name
                    (Some module-name-id)
                    tail
                    span)
                  (Err "parse: malformed import"))]
              [_ (Err "parse: malformed import")])]
          [_ (Err "parse: malformed import")])))))

(define (parse-ast-import
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [span : ast.AstSourceSpan]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(Cons path-node tail _)
      (match (reader.spanned-sexpr-view
        (compiler-parse-place-shared-view path-node))
        [(Str _ _)
          (Err
            "parse: string-path imports are no longer supported; use a dotted module identity")]
        [(Sym module-name module-span)
          (let
            [module-start-line : i64 module-span.start-line]
            [module-start-col : i64 module-span.start-col]
            [module-end-line : i64 module-span.end-line]
            [module-end-col : i64 module-span.end-col]
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
                  (compiler-parse-place-shared-view tail)
                  span)]
              (match (& result)
                [(Ok _)
                  (match (reader.spanned-sexpr-view tail)
                    [(Nil _)
                      (compiler-parse-semantic-default-import-alias-origin!
                        dispatch
                        module-name
                        (token.SourceSpan
                          module-start-line
                          module-start-col
                          module-end-line
                          module-end-col))]
                    [_ unit])
                  result]
                [(Err _) result])))]
        [(Cons _ _ _)
          (parse-ast-import-macro-tail dispatch pools path-node tail span)]
        [_ (Err "parse: malformed import")])]
    [_ (Err "parse: malformed import")]))

(define (parse-ast-include-str
  [dispatch : sym_i64_env.SymI64Env]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(Nil _) (Err "parse: include-str expects name and string path")]
    [(Cons name-node tail _)
      (match (reader.spanned-sexpr-view name-node)
        [(Sym name _)
          (match (reader.spanned-sexpr-view tail)
            [(Cons path-node after-path _)
              (match (reader.spanned-sexpr-view path-node)
                [(Str path-id _)
                  (match (reader.spanned-sexpr-view after-path)
                    [(Nil _)
                      (Ok
                        (IncludeStr
                          (ci.intern-syntax-id-value name)
                          (compiler-parse-dispatch-id-str dispatch path-id)))]
                    [_ (Err "parse: include-str expects exactly two operands")])]
                [_ (Err "parse: include-str path must be a string")])]
            [(Nil _) (Err "parse: include-str expects name and string path")]
            [_ (Err "parse: include-str expects exactly two operands")])]
        [_ (Err "parse: include-str name must be a symbol")])]
    [_ (Err "parse: malformed include-str")]))

(define (parse-ast-include-str-comptime
  [dispatch : sym_i64_env.SymI64Env]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(Nil _) (Err "parse: include-str-comptime expects name and string path")]
    [(Cons name-node tail _)
      (match (reader.spanned-sexpr-view name-node)
        [(Sym name _)
          (match (reader.spanned-sexpr-view tail)
            [(Cons path-node after-path _)
              (match (reader.spanned-sexpr-view path-node)
                [(Str path-id _)
                  (match (reader.spanned-sexpr-view after-path)
                    [(Nil _)
                      (Ok
                        (IncludeStrComptime
                          (ci.intern-syntax-id-value name)
                          (compiler-parse-dispatch-id-str dispatch path-id)))]
                    [_
                      (Err
                        "parse: include-str-comptime expects exactly two operands")])]
                [_ (Err "parse: include-str-comptime path must be a string")])]
            [(Nil _)
              (Err "parse: include-str-comptime expects name and string path")]
            [_ (Err "parse: include-str-comptime expects exactly two operands")])]
        [_ (Err "parse: include-str-comptime name must be a symbol")])]
    [_ (Err "parse: malformed include-str-comptime")]))

(define (parse-ast-include-str-lzss
  [dispatch : sym_i64_env.SymI64Env]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(Nil _) (Err "parse: include-str-lzss expects name and string path")]
    [(Cons name-node tail _)
      (match (reader.spanned-sexpr-view name-node)
        [(Sym name _)
          (match (reader.spanned-sexpr-view tail)
            [(Cons path-node end _)
              (match (reader.spanned-sexpr-view path-node)
                [(Str path _)
                  (match (reader.spanned-sexpr-view end)
                    [(Nil _)
                      (Ok
                        (IncludeStrLzss
                          (ci.intern-syntax-id-value name)
                          (compiler-parse-dispatch-id-str dispatch path)))]
                    [_
                      (Err
                        "parse: include-str-lzss expects exactly two operands")])]
                [_ (Err "parse: include-str-lzss path must be a string")])]
            [(Nil _)
              (Err "parse: include-str-lzss expects name and string path")]
            [_ (Err "parse: include-str-lzss expects exactly two operands")])]
        [_ (Err "parse: include-str-lzss name must be a symbol")])]
    [_ (Err "parse: malformed include-str-lzss")]))

(define (parse-ast-include-bin
  [dispatch : sym_i64_env.SymI64Env]
  [rest : reader.SpannedSexpr]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(Nil _) (Err "parse: include-bin expects name and string path")]
    [(Cons name-node tail _)
      (match (reader.spanned-sexpr-view name-node)
        [(Sym name _)
          (match (reader.spanned-sexpr-view tail)
            [(Cons path-node after-path _)
              (match (reader.spanned-sexpr-view path-node)
                [(Str path-id _)
                  (match (reader.spanned-sexpr-view after-path)
                    [(Nil _)
                      (Ok
                        (IncludeBin
                          (ci.intern-syntax-id-value name)
                          (compiler-parse-dispatch-id-str dispatch path-id)))]
                    [_ (Err "parse: include-bin expects exactly two operands")])]
                [_ (Err "parse: include-bin path must be a string")])]
            [(Nil _) (Err "parse: include-bin expects name and string path")]
            [_ (Err "parse: include-bin expects exactly two operands")])]
        [_ (Err "parse: include-bin name must be a symbol")])]
    [_ (Err "parse: malformed include-bin")]))

(define (parse-ast-test-body
  [pools : ast.AstNodePoolContext]
  [exprs : ast.AstExprList]) : i64
  (if (= exprs.len 1)
    (ast.ast-expr-list-get (& exprs) 0 0)
    (ast.ast-node-pool-context-expr-push pools (Begin exprs))))

(define (parse-ast-test-body-metadata-free?
  [dispatch : sym_i64_env.SymI64Env]
  [forms : reader.SpannedSexpr]) : bool
  (match (reader.spanned-sexpr-view forms)
    [(Nil _) true]
    [(Cons item tail _)
      (and
        (not (parse-ast-metadata-form? dispatch item))
        (parse-ast-test-body-metadata-free? dispatch tail))]
    [_ false]))

(define (parse-ast-test-metadata-forms
  [dispatch : sym_i64_env.SymI64Env]
  [forms : reader.SpannedSexpr]
  [ignore-reason : ast.AstTestIgnoreReason]
  [seen-ignore : bool]
  [slow : bool]
  [seen-slow : bool]) : ResultAstTestMetadataForms
  (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view forms))
    [(Nil _) (Ok (ast.ast-test-metadata-new ignore-reason slow) forms)]
    [(Cons item tail _)
      (if (parse-ast-metadata-form?
        dispatch
        (compiler-parse-place-shared-view item))
        (match (reader.sexpr-view item)
          [(Cons key-node after-key)
            (match (reader.sexpr-view key-node)
              [(Sym key)
                (cond
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe ":ignore"))
                    (if seen-ignore
                      (Err "parse: duplicate test :ignore metadata")
                      (match (reader.sexpr-view after-key)
                        [(Cons reason-node end)
                          (match (reader.sexpr-view end)
                            [(Nil)
                              (match (reader.sexpr-view reason-node)
                                [(Str reason-id)
                                  (let
                                    [reason : String
                                      (compiler-parse-dispatch-id-str
                                        dispatch
                                        reason-id)]
                                    (if (= (string.string-length reason) 0)
                                      (Err
                                        "parse: test :ignore reason must not be empty")
                                      (parse-ast-test-metadata-forms
                                        dispatch
                                        tail
                                        (Some reason)
                                        true
                                        slow
                                        seen-slow)))]
                                [_
                                  (Err
                                    "parse: test :ignore metadata expects one string reason")])]
                            [_
                              (Err
                                "parse: test :ignore metadata expects one string reason")])]
                        [_
                          (Err
                            "parse: test :ignore metadata expects one string reason")]))]
                  [(=
                      (ci.intern-syntax-id-value key)
                      (cbi.compiler-builtin-ctfe ":slow"))
                    (if seen-slow
                      (Err "parse: duplicate test :slow metadata")
                      (match (reader.sexpr-view after-key)
                        [(Nil)
                          (parse-ast-test-metadata-forms
                            dispatch
                            tail
                            ignore-reason
                            seen-ignore
                            true
                            true)]
                        [_ (Err "parse: test :slow metadata takes no values")]))]
                  [else
                    (Err
                      (str_cat.str-cat
                        "parse: unknown test metadata "
                        (compiler-parse-dispatch-syntax-id-text dispatch key)))])]
              [_ (Err "parse: malformed test metadata")])]
          [_ (Err "parse: malformed test metadata")])
        (if (parse-ast-test-body-metadata-free?
          dispatch
          (compiler-parse-place-shared-view forms))
          (Ok (ast.ast-test-metadata-new ignore-reason slow) forms)
          (Err "parse: test metadata must appear before body expressions")))]
    [_ (Err "parse: malformed test metadata or body")]))

(define (parse-ast-test
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [rest : reader.SpannedSexpr]
  [form-span : ast.AstSourceSpan]) : ResultAstDecl
  (match (reader.spanned-sexpr-view rest)
    [(Cons name-node body-forms _)
      (match (reader.spanned-sexpr-view name-node)
        [(Sym name _)
          (match (parse-ast-test-metadata-forms
            dispatch
            body-forms
            No
            false
            false
            false)
            [(Err message) (Err message)]
            [(Ok metadata parsed-body-forms)
              (match (reader.spanned-sexpr-view
                (compiler-parse-place-shared-view parsed-body-forms))
                [(Nil _) (Err "parse: test needs at least one expression")]
                [_
                  (let
                    [exprs
                      (try
                        (parse-ast-expr-list dispatch pools parsed-body-forms))]
                    (Ok
                      (ast.ast-decl-test-metadata-id
                        (ci.intern-syntax-id-value name)
                        (parse-ast-test-body pools exprs)
                        metadata
                        form-span)))])])]
        [_ (Err "parse: malformed test")])]
    [_ (Err "parse: malformed test")]))

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
    [(Cons inner end _)
      (match (reader.spanned-sexpr-view end)
        [(Nil _)
          (let
            [decl (try (parse-ast-decl dispatch pools inner))]
            (match (compiler-parse-place-shared-view decl)
              [(DefFn decl-meta _ _ _ _ _) (Ok (ast.ast-decl-unsafe decl))]
              [(Extern decl-meta _ _ _ _) (Ok (ast.ast-decl-unsafe decl))]
              [_
                (Err
                  "parse: unsafe declaration accepts only function define or extern")]))]
        [_ (Err "parse: unsafe declaration expects exactly one declaration")])]
    [_ (Err "parse: unsafe declaration expects exactly one declaration")]))

(define (parse-ast-module-macro-call
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [form : reader.SpannedSexpr]) : ResultAstDecl
  (let
    [call-expr
      (try
        (parse-ast-expr-with-pools
          dispatch
          pools
          (compiler-parse-place-shared-view form)))]
    (match (ast.ast-expr-unspan-with-pools
      pools
      (ast.ast-node-pool-context-expr-get pools call-expr))
      [(Call _ _)
        (parse-ast-import-spec
          (MacroDecls call-expr No)
          ""
          No
          No
          (ast-source-span-from-source-span (reader.spanned-sexpr-span form)))]
      [_ (Err "parse: expected declaration")])))

(define (parse-ast-decl
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstDecl
  (let
    [result : ResultAstDecl
      (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view s))
        [(Cons head-node rest _)
          (match (reader.spanned-sexpr-view head-node)
            [(Sym head _)
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
                        (reader.spanned-sexpr-span
                          (compiler-parse-place-shared-view s))))]
                  [(= tag (compiler-parse-tag-decl-include-str))
                    (parse-ast-include-str dispatch rest)]
                  [(= tag (compiler-parse-tag-decl-include-str-comptime))
                    (parse-ast-include-str-comptime dispatch rest)]
                  [(= tag (compiler-parse-tag-decl-include-str-lzss))
                    (parse-ast-include-str-lzss dispatch rest)]
                  [(= tag (compiler-parse-tag-decl-removed-compressed-include))
                    (Err (compiler-parse-removed-compressed-include-message))]
                  [(= tag (compiler-parse-tag-decl-include-bin))
                    (parse-ast-include-bin dispatch rest)]
                  [(= tag (compiler-parse-tag-decl-module))
                    (parse-ast-module dispatch pools rest)]
                  [(parse-ast-removed-declaration-name?
                      dispatch
                      (ci.intern-syntax-id-value head))
                    (Err (parse-ast-removed-declaration-message))]
                  [(= tag (compiler-parse-tag-expr-unsafe))
                    (parse-ast-unsafe-decl dispatch pools rest)]
                  [(= tag (compiler-parse-tag-decl-test))
                    (parse-ast-test
                      dispatch
                      pools
                      rest
                      (ast-source-span-from-source-span
                        (reader.spanned-sexpr-span
                          (compiler-parse-place-shared-view s))))]
                  [(compiler-parse-policy-form?
                      (ci.intern-syntax-id-value head))
                    (Err (compiler-parse-abstraction-policy-message))]
                  [else
                    (parse-ast-module-macro-call
                      dispatch
                      pools
                      (compiler-parse-place-shared-view s))]))]
            [_ (Err "parse: malformed declaration")])]
        [_ (Err "parse: malformed declaration")])]
    (parse-ast-error-span-note-decl dispatch s result)))

(define (parse-ast-decl-maybe-with-pools
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [s : reader.SpannedSexpr]) : ResultAstMaybeDecl
  (let
    [result : ResultAstMaybeDecl
      (match (reader.spanned-sexpr-view (compiler-parse-place-shared-view s))
        [(Cons head-node rest _)
          (match (reader.spanned-sexpr-view head-node)
            [(Sym head _)
              (if (=
                (ci.intern-syntax-id-value head)
                (cbi.compiler-builtin-ctfe "cfg"))
                (match (reader.spanned-sexpr-view rest)
                  [(Cons pred decl-tail _)
                    (match (reader.spanned-sexpr-view decl-tail)
                      [(Cons decl-form end _)
                        (match (reader.spanned-sexpr-view end)
                          [(Nil _)
                            (match (compiler-cfg-eval dispatch pred)
                              [(Ok enabled)
                                (if enabled
                                  (parse-ast-decl-maybe-with-pools
                                    dispatch
                                    pools
                                    decl-form)
                                  (NoDecl))]
                              [(Err message) (Err message)])]
                          [_
                            (Err
                              "parse: cfg declaration expects predicate and declaration")])]
                      [_
                        (Err
                          "parse: cfg declaration expects predicate and declaration")])]
                  [_
                    (Err
                      "parse: cfg declaration expects predicate and declaration")])
                (match (parse-ast-decl
                  dispatch
                  pools
                  (compiler-parse-place-shared-view s))
                  [(Ok decl) (SomeDecl decl)]
                  [(Err message) (Err message)]))]
            [_
              (match (parse-ast-decl
                dispatch
                pools
                (compiler-parse-place-shared-view s))
                [(Ok decl) (SomeDecl decl)]
                [(Err message) (Err message)])])]
        [_ (Err "parse: malformed declaration")])]
    (parse-ast-error-span-note-maybe-decl dispatch s result)))

(define (parse-ast-decl-maybe
  [dispatch : sym_i64_env.SymI64Env]
  [s : reader.SpannedSexpr]) : ResultAstMaybeDecl
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultAstMaybeDecl
      (parse-ast-decl-maybe-with-pools dispatch pools s)]
    (ast.ast-node-pool-context-install! pools)
    result))

(defstruct ParseAstDeclVec
  (slots (__tl_dyn-array ast.AstDecl))
  (spans (__tl_dyn-array ast.AstSourceSpan))
  (semantic-origins ParseSemanticOriginVec)
  (len i64))

(define (parse-ast-decl-vec-fallback) : ast.AstDecl
  (Module cbi.compiler-builtin-id-fix-lt_parse_ast_decl_vec_fallback_gt))

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
  (unless
    (>= index count)
    (set! (array-ref dst index) (array-ref src index))
    (parse-ast-decl-vec-copy-range dst src (+ index 1) count)))

(define (parse-ast-decl-vec-span-copy-range
  [dst : (&mut dst (__tl_dyn-array ast.AstSourceSpan))]
  [src : (& src (__tl_dyn-array ast.AstSourceSpan))]
  [index : i64]
  [count : i64]) : unit
  (unless
    (>= index count)
    (set! (array-ref dst index) (array-ref src index))
    (parse-ast-decl-vec-span-copy-range dst src (+ index 1) count)))

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
    (parse-ast-decl-vec-copy-range (&mut bigger) (& v.slots) 0 n)
    (parse-ast-decl-vec-span-copy-range (&mut bigger-spans) (& v.spans) 0 n)
    (set! v.slots bigger)
    (set! v.spans bigger-spans)))

(define (parse-ast-decl-vec-push-with-span
  [v : (&mut v ParseAstDeclVec)]
  [value : ast.AstDecl]
  [span : ast.AstSourceSpan]) : unit
  (if (< v.len (array-length v.slots))
    unit
    (parse-ast-decl-vec-grow v))
  (let
    [index : i64 v.len]
    (set! (array-ref v.slots index) value)
    (set! (array-ref v.spans index) span)
    (set! v.len (+ index 1))))

(define (parse-ast-decl-vec-push
  [v : (&mut v ParseAstDeclVec)]
  [value : ast.AstDecl]) : unit
  (parse-ast-decl-vec-push-with-span v value (ast.ast-decl-span-fallback)))

(define (parse-ast-decl-vec-push-list!
  [out : (&mut out ParseAstDeclVec)]
  [decls : ast.AstDeclList]) : unit
  (match (ast.ast-decl-list-step decls)
    [(Nil) unit]
    [(Cons head rest)
      (parse-ast-decl-vec-push out head)
      (parse-ast-decl-vec-push-list! out rest)]))

(define (parse-ast-decl-vec-copy-to-list
  [items : (& items ParseAstDeclVec)]
  [index : i64]
  [out : (&mut out ast.AstDeclList)]) : unit
  (unless
    (>= index (parse-ast-decl-vec-len items))
    (ast.ast-decl-list-push
      out
      (parse-ast-decl-vec-get items index (parse-ast-decl-vec-fallback)))
    (parse-ast-decl-vec-copy-to-list items (+ index 1) out)))

(define (compiler-parse-decl-origin-needs-record? [decl : ast.AstDecl]) : bool
  (match decl
    [(Def decl-meta _ _ _) false]
    [(DefFn decl-meta _ _ _ _ _) false]
    [(DefMacro decl-meta _ _ _ _) false]
    [(Test _ _ _ _) false]
    [(Unsafe inner-box)
      (compiler-parse-decl-origin-needs-record? (deref inner-box))]
    [_ true]))

(define (compiler-parse-decl-origin-register-selected!
  [items : (& items ParseAstDeclVec)]
  [out : (& out ast.AstDeclList)]) : unit
  (let
    [index : i64 0]
    (while (< index (parse-ast-decl-vec-len items))
      (if (compiler-parse-decl-origin-needs-record?
        (parse-ast-decl-vec-get items index (parse-ast-decl-vec-fallback)))
        (let
          [span : ast.AstSourceSpan (array-ref items.spans index)]
          (compiler-parse-decl-origin-register-maybe!
            out
            index
            (Some
              (ast.AstSourceSpan
                span.start-line
                span.start-col
                span.end-line
                span.end-col))))
        unit)
      (set! index (+ index 1)))))

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
      (reader.sp-node-pool-fill!
        run-start
        (Int
          (compiler-parse-decl-list-storage-key decls)
          (compiler-parse-marker "__tl_semantic_origin")
          marker-span))
      (reader.sp-node-pool-fill!
        (+ run-start 1)
        (Int
          (+ decls.offset slot)
          (compiler-parse-marker "__tl_semantic_origin_start")
          (token.SourceSpan count 0 0 0)))
      (while (< index count)
        (let
          [origin : ParseSemanticOriginRecord
            (array-ref origins.items (+ start index))]
          (reader.sp-node-pool-fill!
            (+ (+ run-start 2) index)
            (Int
              origin.written-name
              (compiler-parse-semantic-origin-kind-marker
                (compiler-parse-semantic-origin-kind-from-tag origin.kind-tag))
              (token.SourceSpan
                origin.start-line
                origin.start-col
                origin.end-line
                origin.end-col)))
          (set! index (+ index 1)))))))

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
        (set! start (+ start count))))))

(define (parse-ast-decl-vec-to-list [items : (& items ParseAstDeclVec)]) : ast.AstDeclList
  (let
    [out : ast.AstDeclList
      (ast.ast-decl-list-with-capacity (parse-ast-decl-vec-len items))]
    (parse-ast-decl-vec-copy-to-list items 0 (&mut out))
    (compiler-parse-decl-origin-register-selected! items (& out))
    (compiler-parse-semantic-origin-register-selected! items (& out))
    out))

;; Wrappers are declarations semantically, but declaration-shape errors belong
;; to the declaration inside them. Keep the innermost source form's bounds.
(define (compiler-parse-decl-origin-syntax-span
  [dispatch : sym_i64_env.SymI64Env]
  [form : reader.SpannedSexpr]) : ast.AstSourceSpan
  (let
    [fallback : ast.AstSourceSpan
      (ast-source-span-from-source-span
        (reader.spanned-sexpr-span (compiler-parse-place-shared-view form)))]
    (match (reader.spanned-sexpr-view form)
      [(Cons head-node rest _)
        (match (reader.spanned-sexpr-view head-node)
          [(Sym head _)
            (let
              [tag : i64
                (compiler-parse-dispatch-tag
                  dispatch
                  (ci.intern-syntax-id-value head))]
              (cond
                [(=
                    (ci.intern-syntax-id-value head)
                    (cbi.compiler-builtin-ctfe "cfg"))
                  (match (reader.spanned-sexpr-view rest)
                    [(Cons _ decl-tail _)
                      (match (reader.spanned-sexpr-view decl-tail)
                        [(Cons decl-form _ _)
                          (compiler-parse-decl-origin-syntax-span
                            dispatch
                            decl-form)]
                        [_ fallback])]
                    [_ fallback])]
                [(= tag (compiler-parse-tag-expr-unsafe))
                  (match (reader.spanned-sexpr-view rest)
                    [(Cons inner _ _)
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
    (Ok)
    (let
      ;; The spanned tree for one top-level form is dead once its AstDecl is
      ;; built (the decl carries AST-pool ids + spans by value, no sp ids), so
      ;; truncate the spanned pool back to here before reading the next form.
      ;; Bounds the spanned pool to a single form so it never has to grow.
      [mark : i64 (reader.sp-node-pool-len)]
      (match (reader.form-spanned-result (& toks) (&mut cur))
        [(Ok form)
          (let
            [records-start : i64 (reader.sp-node-pool-len)]
            [semantic-start : i64 out.semantic-origins.len]
            (compiler-parse-semantic-origin-capture-begin!
              (ci.intern-compat-state-semantic-name-view
                (compiler-parse-dispatch-intern-state dispatch))
              semantic-origins
              out.len
              (compiler-parse-binding-origins-enabled dispatch))
            (match (parse-ast-decl-maybe-with-pools
              dispatch
              pools
              (compiler-parse-place-shared-view form))
              [(SomeDecl decl)
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
                  out)]
              [(Decls decls)
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
                  out)]
              [(NoDecl)
                (set! out.semantic-origins.len semantic-start)
                (compiler-parse-semantic-origin-capture-end!)
                (compiler-parse-member-records-compact! mark records-start)
                (parse-ast-program-forms-into-vec
                  dispatch
                  pools
                  toks
                  cur
                  semantic-origins
                  out)]
              [(Err message)
                (set! out.semantic-origins.len semantic-start)
                (compiler-parse-semantic-origin-capture-end!)
                (reader.sp-node-pool-truncate! mark)
                (Err message)]))]
        [(Err err)
          (reader.sp-node-pool-truncate! mark)
          (Err (token.source-error-message err))]))))

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
    [_ (try result)]
    (Ok (parse-ast-decl-vec-to-list (& out)))))

(define (parse-ast-program-dispatch) : sym_i64_env.SymI64Env
  (compiler-parse-dispatch-env))

(define (parse-ast-program-dispatch-with-cfg [cfgs : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (compiler-parse-dispatch-env-from-cfg cfgs))

(define (parse-ast-program-with-cfg-and-pools
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultAstProgram
  (compiler-parse-semantic-origin-capture-end!)
  (let
    [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [base-dispatch : sym_i64_env.SymI64Env
      (parse-ast-program-dispatch-with-cfg cfgs)]
    [base-control : i64
      (compiler-parse-env-marker-value
        base-dispatch
        compiler-parse-state-marker-id)]
    [invocation : CompilerParseInvocationFrame
      (CompilerParseInvocationFrame 0 0 0 0 0 0)]
    [invocation-address : i64
      (cast
        (unsafe
          (ptr->int (ptr-cast (ptr-addr-of invocation) : (Ptr u8))))
        : i64)]
    [dispatch-with-invocation : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        base-dispatch
        compiler-parse-invocation-marker-id
        invocation-address)]
    [dispatch : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        dispatch-with-invocation
        compiler-parse-invocation-control-marker-id
        base-control)]
    (set! (array-ref cur 0) 0)
    (compiler-parse-raw-i64-set!
      invocation-address
      compiler-parse-invocation-control-slot
      base-control)
    (let
      [decls (try (parse-ast-program-forms dispatch pools toks cur))]
      (Ok (ast.ast-program decls)))))

(define (parse-ast-source [src : String]) : ResultAstProgram
  (parse-ast-source-with-cfg src (compiler-cfg-empty)))

(define (parse-ast-source-with-cfg-and-pools
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultAstProgram
  (compiler-parse-source-builtins-prepare!)
  (match (compiler-parse-spanned-result-with-cfg src cfgs)
    [(Ok toks) (parse-ast-program-with-cfg-and-pools toks cfgs pools)]
    [(Err err) (Err (token.source-error-message err))]))

(define (parse-ast-source-with-cfg
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgram
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultAstProgram
      (parse-ast-source-with-cfg-and-pools src cfgs pools)]
    (ast.ast-node-pool-context-install! pools)
    result))

(define (parse-ast-repl-module-macro-call-decl? [decl : ast.AstDecl]) : bool
  (match decl
    [(Import decl-meta (Spec (MacroDecls _ _) path (No) (No) _))
      (string.eq path "")]
    [_ false]))

(define (parse-ast-repl-error [span : token.SourceSpan] [message : String]) : ResultAstReplItem
  (Err
    (box
      (parse-ast-canonical-diagnostic
        (cdiag.compiler-diagnostic-from-span "" span message)))))

(define (parse-ast-repl-source-error [err : token.SourceError]) : ResultAstReplItem
  (parse-ast-repl-error
    (token.source-error-span (compiler-parse-place-shared-view err))
    (token.source-error-message err)))

;; The REPL dispatch carries no invocation frame to record the failing subform,
;; so an expression error is located at the input form.
(define (parse-ast-repl-expr-item
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [form : reader.SpannedSexpr]) : ResultAstReplItem
  (match (parse-ast-expr-with-pools
    dispatch
    pools
    (compiler-parse-place-shared-view form))
    [(Ok expr) (Ok (AstReplExpr expr))]
    [(Err message)
      (parse-ast-repl-error (reader.spanned-sexpr-span form) message)]))

(define (parse-ast-repl-source-with-pools
  [src : String]
  [pools : ast.AstNodePoolContext]) : ResultAstReplItem
  (cbi.compiler-builtin-initialize-for-parse!)
  (let
    [mark : i64 (reader.sp-node-pool-len)]
    (match (lexer.spanned-result src)
      [(Ok toks)
        (let
          [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
          [dispatch : sym_i64_env.SymI64Env (parse-ast-program-dispatch)]
          (set! (array-ref cur 0) 0)
          (if (= (reader.peek-spanned-tag (& toks) (& cur)) (token.tag-end))
            (begin
              (reader.sp-node-pool-truncate! mark)
              (parse-ast-repl-error
                (token.SourceSpan 1 1 1 1)
                "parse: expected REPL input"))
            (match (reader.form-spanned-result (& toks) (&mut cur))
              [(Ok form)
                (let
                  [records-start : i64 (reader.sp-node-pool-len)]
                  (if (= (reader.peek-spanned-tag toks cur) (token.tag-end))
                    (match (parse-ast-decl
                      dispatch
                      pools
                      (compiler-parse-place-shared-view form))
                      [(Ok decl)
                        (let
                          [result : ResultAstReplItem
                            (if (parse-ast-repl-module-macro-call-decl?
                              (compiler-parse-place-shared-view decl))
                              (parse-ast-repl-expr-item dispatch pools form)
                              (Ok (AstReplDecl decl)))]
                          (compiler-parse-member-records-compact!
                            mark
                            records-start)
                          result)]
                      [(Err _)
                        (reader.sp-node-pool-truncate! records-start)
                        (let
                          [result : ResultAstReplItem
                            (parse-ast-repl-expr-item dispatch pools form)]
                          (reader.sp-node-pool-truncate! mark)
                          result)])
                    (begin
                      (reader.sp-node-pool-truncate! mark)
                      (parse-ast-repl-error
                        (token.spanned-token-span
                          (& (array-ref toks (array-ref cur 0))))
                        "parse: trailing tokens after REPL input"))))]
              [(Err err)
                (reader.sp-node-pool-truncate! mark)
                (parse-ast-repl-source-error err)])))]
      [(Err err)
        (reader.sp-node-pool-truncate! mark)
        (parse-ast-repl-source-error err)])))

(define (parse-ast-repl-source [src : String]) : ResultAstReplItem
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultAstReplItem (parse-ast-repl-source-with-pools src pools)]
    (ast.ast-node-pool-context-install! pools)
    result))

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
  [toks : (& toks (__tl_dyn-array token.SpannedToken))]
  [cur : (&mut cur (__tl_dyn-array i64))]
  [form-start : i64]) : unit
  (let
    [scan : i64 form-start]
    [depth : i64 0]
    [done : bool false]
    (while (not done)
      (let
        [tag : i64
          (token.tag-ref
            (token.spanned-token-token-ref (& (array-ref toks scan))))]
        (cond
          [(= tag (token.tag-end))
            (set! (array-ref cur 0) scan)
            (set! done true)]
          [(or (= tag (token.tag-lparen)) (= tag (token.tag-lbracket)))
            (set! depth (+ depth 1))
            (set! scan (+ scan 1))]
          [(or (= tag (token.tag-rparen)) (= tag (token.tag-rbracket)))
            (set! scan (+ scan 1))
            (if (> depth 0)
              (set! depth (- depth 1))
              unit)
            (when (= depth 0) (set! (array-ref cur 0) scan) (set! done true))]
          [(and (= depth 0) (parse-ast-recovery-prefix-tag? tag))
            (set! scan (+ scan 1))]
          [else
            (set! scan (+ scan 1))
            (when (= depth 0) (set! (array-ref cur 0) scan) (set! done true))])))))

(define (parse-ast-program-forms-recovery-into-vec
  [path : String]
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cur : (__tl_dyn-array i64)]
  [semantic-origins : (MutPtr ParseSemanticOriginVec)]
  [out : (&mut out ParseAstDeclVec)]
  [diagnostics : (&mut diagnostics cdiag.CompilerDiagnosticList)]) : unit
  (if (= (reader.peek-spanned-tag (& toks) (& cur)) (token.tag-end))
    unit
    (let
      [mark : i64 (reader.sp-node-pool-len)]
      [form-start : i64 (reader.cur-pos (& cur))]
      (match (reader.form-spanned-result (& toks) (&mut cur))
        [(Ok spanned-form)
          (let
            [records-start : i64 (reader.sp-node-pool-len)]
            [semantic-start : i64 out.semantic-origins.len]
            (parse-ast-error-span-clear! dispatch)
            (compiler-parse-semantic-origin-capture-begin!
              (ci.intern-compat-state-semantic-name-view
                (compiler-parse-dispatch-intern-state dispatch))
              semantic-origins
              out.len
              (compiler-parse-binding-origins-enabled dispatch))
            (match (parse-ast-decl-maybe-with-pools
              dispatch
              pools
              (compiler-parse-place-shared-view spanned-form))
              [(SomeDecl decl)
                (parse-ast-decl-vec-push-with-span
                  out
                  decl
                  (compiler-parse-decl-origin-syntax-span dispatch spanned-form))
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
                  diagnostics)]
              [(Decls decls)
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
                  diagnostics)]
              [(NoDecl)
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
                  diagnostics)]
              [(Err message)
                (let
                  [diag : cdiag.CompilerDiagnostic
                    (parse-ast-canonical-diagnostic
                      (cdiag.compiler-diagnostic-from-span
                        (compiler-parse-place-shared-view path)
                        (parse-ast-error-span-current
                          dispatch
                          (reader.spanned-sexpr-span spanned-form))
                        message))]
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
                    diagnostics))]))]
        [(Err err)
          (let
            [diag : cdiag.CompilerDiagnostic
              (parse-ast-canonical-diagnostic
                (cdiag.compiler-diagnostic-from-source-error
                  (compiler-parse-place-shared-view path)
                  err))]
            (reader.sp-node-pool-truncate! mark)
            (parse-ast-recover-top-level-cursor! (& toks) (&mut cur) form-start)
            (cdiag.compiler-diagnostic-list-push! diagnostics diag)
            (parse-ast-program-forms-recovery-into-vec
              path
              dispatch
              pools
              toks
              cur
              semantic-origins
              out
              diagnostics))]))))

(define (parse-ast-program-recovery-diagnostic-with-cfg-and-pools
  [path : String]
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultAstProgramRecovery
  (let
    [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [base-dispatch : sym_i64_env.SymI64Env
      (parse-ast-program-dispatch-with-cfg cfgs)]
    [base-control : i64
      (compiler-parse-env-marker-value
        base-dispatch
        compiler-parse-state-marker-id)]
    [invocation : CompilerParseInvocationFrame
      (CompilerParseInvocationFrame 0 0 0 0 0 0)]
    [invocation-address : i64
      (cast
        (unsafe
          (ptr->int (ptr-cast (ptr-addr-of invocation) : (Ptr u8))))
        : i64)]
    [dispatch-with-invocation : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        base-dispatch
        compiler-parse-invocation-marker-id
        invocation-address)]
    [dispatch : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        dispatch-with-invocation
        compiler-parse-invocation-control-marker-id
        base-control)]
    [out : ParseAstDeclVec (parse-ast-decl-vec-new)]
    (set! (array-ref cur 0) 0)
    (compiler-parse-raw-i64-set!
      invocation-address
      compiler-parse-invocation-control-slot
      base-control)
    (let
      [diagnostics : cdiag.CompilerDiagnosticList
        (cdiag.compiler-diagnostic-list-empty)]
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
      (Parsed
        (ast.ast-program (parse-ast-decl-vec-to-list (& out)))
        (box diagnostics)))))

(define (parse-ast-source-recovery-diagnostic-with-cfg-and-pools
  [path : String]
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultAstProgramRecovery
  (compiler-parse-source-builtins-prepare!)
  (match (compiler-parse-spanned-result-with-cfg src cfgs)
    [(Ok toks)
      (parse-ast-program-recovery-diagnostic-with-cfg-and-pools
        path
        toks
        cfgs
        pools)]
    [(Err err)
      (Fatal
        (box
          (cdiag.compiler-diagnostic-list-single
            (parse-ast-canonical-diagnostic
              (cdiag.compiler-diagnostic-from-source-error path err)))))]))

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
    (ast.ast-node-pool-context-install! pools)
    result))

(define (parse-ast-program-forms-diagnostic-into-vec
  [path : String]
  [dispatch : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cur : (__tl_dyn-array i64)]
  [semantic-origins : (MutPtr ParseSemanticOriginVec)]
  [out : (&mut out ParseAstDeclVec)]) : ResultParseAstDeclVecDiagnostic
  (if (= (reader.peek-spanned-tag (& toks) (& cur)) (token.tag-end))
    (Ok)
    (let
      ;; Bound the spanned pool to a single top-level form (see
      ;; parse-ast-program-forms): the decl carries no sp ids, so truncate back
      ;; before reading the next form.
      [mark : i64 (reader.sp-node-pool-len)]
      (match (reader.form-spanned-result (& toks) (&mut cur))
        [(Ok spanned-form)
          (let
            [records-start : i64 (reader.sp-node-pool-len)]
            [semantic-start : i64 out.semantic-origins.len]
            (parse-ast-error-span-clear! dispatch)
            (compiler-parse-semantic-origin-capture-begin!
              (ci.intern-compat-state-semantic-name-view
                (compiler-parse-dispatch-intern-state dispatch))
              semantic-origins
              out.len
              (compiler-parse-binding-origins-enabled dispatch))
            (match (parse-ast-decl-maybe-with-pools
              dispatch
              pools
              (compiler-parse-place-shared-view spanned-form))
              [(SomeDecl decl)
                (parse-ast-decl-vec-push-with-span
                  out
                  decl
                  (compiler-parse-decl-origin-syntax-span dispatch spanned-form))
                (compiler-parse-semantic-origin-capture-end!)
                (compiler-parse-member-records-compact! mark records-start)
                (parse-ast-program-forms-diagnostic-into-vec
                  path
                  dispatch
                  pools
                  toks
                  cur
                  semantic-origins
                  out)]
              [(Decls decls)
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
                  out)]
              [(NoDecl)
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
                  out)]
              [(Err message)
                (set! out.semantic-origins.len semantic-start)
                (compiler-parse-semantic-origin-capture-end!)
                (reader.sp-node-pool-truncate! mark)
                (Err
                  (box
                    (parse-ast-canonical-diagnostic
                      (cdiag.compiler-diagnostic-from-span
                        path
                        (parse-ast-error-span-current
                          dispatch
                          (reader.spanned-sexpr-span spanned-form))
                        message))))]))]
        [(Err err)
          (reader.sp-node-pool-truncate! mark)
          (Err
            (box
              (parse-ast-canonical-diagnostic
                (cdiag.compiler-diagnostic-from-source-error path err))))]))))

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
    [_ (try result)]
    (Ok (parse-ast-decl-vec-to-list (& out)))))

(define (parse-ast-program-diagnostic-with-cfg-and-pools
  [path : String]
  [toks : (__tl_dyn-array token.SpannedToken)]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultAstProgramDiagnostic
  (let
    [cur : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [base-dispatch : sym_i64_env.SymI64Env
      (parse-ast-program-dispatch-with-cfg cfgs)]
    [base-control : i64
      (compiler-parse-env-marker-value
        base-dispatch
        compiler-parse-state-marker-id)]
    [invocation : CompilerParseInvocationFrame
      (CompilerParseInvocationFrame 0 0 0 0 0 0)]
    [invocation-address : i64
      (cast
        (unsafe
          (ptr->int (ptr-cast (ptr-addr-of invocation) : (Ptr u8))))
        : i64)]
    [dispatch-with-invocation : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        base-dispatch
        compiler-parse-invocation-marker-id
        invocation-address)]
    [dispatch : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        dispatch-with-invocation
        compiler-parse-invocation-control-marker-id
        base-control)]
    (set! (array-ref cur 0) 0)
    (compiler-parse-raw-i64-set!
      invocation-address
      compiler-parse-invocation-control-slot
      base-control)
    (let
      [decls
        (try (parse-ast-program-forms-diagnostic path dispatch pools toks cur))]
      (Ok (ast.ast-program decls)))))

(define (parse-ast-source-diagnostic [path : String] [src : String]) : ResultAstProgramDiagnostic
  (parse-ast-source-diagnostic-with-cfg path src (compiler-cfg-empty)))

(define (parse-ast-source-diagnostic-with-cfg-and-pools
  [path : String]
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]
  [pools : ast.AstNodePoolContext]) : ResultAstProgramDiagnostic
  (compiler-parse-source-builtins-prepare!)
  (match (compiler-parse-spanned-result-with-cfg src cfgs)
    [(Ok toks)
      (parse-ast-program-diagnostic-with-cfg-and-pools path toks cfgs pools)]
    [(Err err)
      (Err
        (box
          (parse-ast-canonical-diagnostic
            (cdiag.compiler-diagnostic-from-source-error path err))))]))

(define (parse-ast-source-diagnostic-with-cfg
  [path : String]
  [src : String]
  [cfgs : sym_i64_env.SymI64Env]) : ResultAstProgramDiagnostic
  (let
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    [result : ResultAstProgramDiagnostic
      (parse-ast-source-diagnostic-with-cfg-and-pools path src cfgs pools)]
    (ast.ast-node-pool-context-install! pools)
    result))

(define (ast-decl-list-count [decls : ast.AstDeclList]) : i64
  (ast.ast-decl-list-len (& decls)))

;; Serial tool compatibility adapter. Production parsing above uses the
;; explicit-state twin; lint ownership is tracked separately by #4699.
(define (parse-ast-dotted-import-default-alias-id [name-id : i64]) : i64
  (ci.intern-dotted-final-id name-id))