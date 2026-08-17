;; compiler_symbols.tl - Top-level compiler symbol table over AstProgram.
;;
;; Handles are packed as kind * stride + declaration index, where index is the
;; source-order position among supported declarations. Import declarations have
;; no top-level symbol name here and do not consume an index.
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.io)
(import stdlib.arena)
(import compiler_builtin_ids as cbi)
(import compiler_parse_core as parser)
(import compiler_ast_types as ast)
(import compiler_diagnostic as cdiag)
(import compiler_intern as ci)
(import sym_i64_env)
(import stdlib.string)
(import stdlib.option)
(import (option.option i64) as option_i64)

;; Top-level and registry symbol keys are non-negative intern/composite ids.
;; Store key+1 so a zero-filled scalar key array is immediately a valid empty
;; table; -1 is the deletion tombstone. Parallel i64 arrays avoid the general
;; hashmap's enum-slot initialization pass and keep the lookup hot path to two
;; scalar loads per occupied probe.
(defstruct CompilerSymbolMap
  (keys (__tl_dyn-array i64))
  (values (__tl_dyn-array i64))
  (len i64)
  (deleted i64))

(defenum CompilerSymbols
  (CompilerSymbols
    CompilerSymbolMap
    CompilerSymbolMap
    CompilerSymbolMap
    (__tl_dyn-array ast.AstDecl)
    ;; One allocation with two capacity-sized lanes: effective module owners,
    ;; then physical provenance. Keeping the sidecar in the existing field
    ;; preserves TcContext's hot pass-by-value width.
    (__tl_dyn-array i64)
    i64))

(defenum ResultCompilerSymbols
  (Ok CompilerSymbols)
  (Err String))

;; Keep the compact String result for symbol-table helpers, but offer a
;; source-facing adapter for callers that have declaration paths. Symbol
;; construction itself is deliberately used by small internal probes too.
(defenum ResultCompilerSymbolsDiagnostic
  (Ok CompilerSymbols)
  (Err (Box cdiag.CompilerDiagnostic)))

(defenum CompilerSymbolsMaybeSpan
  (No)
  (Some ast.AstSourceSpan))

(defenum CompilerMaybeString
  (CompilerNoString)
  (CompilerSomeString String))

(defenum CompilerRegistries
  (CompilerRegistries CompilerSymbolMap CompilerSymbolMap i64))

(defenum ResultCompilerRegistries
  (Ok CompilerRegistries)
  (Err String))

(defenum ResultCompilerRegistriesDiagnostic
  (Ok CompilerRegistries)
  (Err (Box cdiag.CompilerDiagnostic)))

;; `build-compiler-symbols-with-paths` is single-threaded and reports its
;; failure immediately to a caller. Retain only the source coordinates for
;; that short handoff: a generated declaration can belong to a reclaimed macro
;; arena before a later diagnostic adapter runs.
(define compiler-symbols-last-error-path : String
  "")
(define compiler-symbols-last-error-span : ast.AstSourceSpan
  (ast.ast-decl-span-fallback))
(define compiler-symbols-last-error-has-span : bool
  false)

(define (compiler-symbols-clear-last-error!) : unit
  (begin
    (set! compiler-symbols-last-error-path "")
    (set! compiler-symbols-last-error-span (ast.ast-decl-span-fallback))
    (set! compiler-symbols-last-error-has-span false)))

(define (compiler-symbols-note-last-error-member-span!
  [span : ast.AstSourceSpan]) : unit
  (let
    [has-span : bool (> (ast.ast-source-span-start-line span) 0)]
    (begin
      (set! compiler-symbols-last-error-span span)
      (set! compiler-symbols-last-error-has-span has-span))))

(define (compiler-symbols-expr-maybe-span [expr : ast.AstExpr]) : CompilerSymbolsMaybeSpan
  (match expr
    [(ast.AstExpr.Spanned _ span) (CompilerSymbolsMaybeSpan.Some span)]
    [(ast.AstExpr.Unary _ inner)
      (compiler-symbols-expr-maybe-span (ast.ast-node-get inner))]
    [(ast.AstExpr.Ann inner _)
      (compiler-symbols-expr-maybe-span (ast.ast-node-get inner))]
    [(ast.AstExpr.Cast inner _)
      (compiler-symbols-expr-maybe-span (ast.ast-node-get inner))]
    [(ast.AstExpr.Borrow _ _ inner)
      (compiler-symbols-expr-maybe-span (ast.ast-node-get inner))]
    [_ CompilerSymbolsMaybeSpan.No]))

(define (compiler-symbols-decl-maybe-span [decl : ast.AstDecl]) : CompilerSymbolsMaybeSpan
  (match decl
    [(ast.AstDecl.Def decl-meta _ _ body)
      (compiler-symbols-expr-maybe-span (ast.ast-node-get body))]
    [(ast.AstDecl.DefFn decl-meta _ _ _ body _)
      (compiler-symbols-expr-maybe-span (ast.ast-node-get body))]
    [(ast.AstDecl.DefMacro decl-meta _ _ _ body)
      (compiler-symbols-expr-maybe-span (ast.ast-node-get body))]
    [(ast.AstDecl.Test _ _ span) (CompilerSymbolsMaybeSpan.Some span)]
    [(ast.AstDecl.Unsafe inner-box)
      (compiler-symbols-decl-maybe-span (__tl-box-place inner-box))]
    [_ CompilerSymbolsMaybeSpan.No]))

(define (compiler-symbols-note-last-error-fallback!
  [decl : ast.AstDecl]
  [path : (& path str)]) : unit
  (begin
    (set! compiler-symbols-last-error-path (string.copy path))
    (match (compiler-symbols-decl-maybe-span decl)
      [(CompilerSymbolsMaybeSpan.Some span)
        (begin
          (set! compiler-symbols-last-error-span span)
          (set! compiler-symbols-last-error-has-span true))]
      [(CompilerSymbolsMaybeSpan.No)
        (begin
          (set! compiler-symbols-last-error-span (ast.ast-decl-span-fallback))
          (set! compiler-symbols-last-error-has-span false))])))

(define (compiler-symbols-note-last-error!
  [origin-key : i64]
  [origin-slot : i64]
  [decl : ast.AstDecl]
  [path : String]) : unit
  (begin
    (set! compiler-symbols-last-error-path path)
    (match (parser.compiler-parse-decl-origin-span-key-slot
      origin-key
      origin-slot)
      [(parser.CompilerParseMaybeDeclSpan.Some span)
        (begin
          (set! compiler-symbols-last-error-span span)
          (set! compiler-symbols-last-error-has-span true))]
      [(parser.CompilerParseMaybeDeclSpan.None)
        (match (compiler-symbols-decl-maybe-span decl)
          [(CompilerSymbolsMaybeSpan.Some span)
            (begin
              (set! compiler-symbols-last-error-span span)
              (set! compiler-symbols-last-error-has-span true))]
          [(CompilerSymbolsMaybeSpan.No)
            (begin
              (set!
                compiler-symbols-last-error-span
                (ast.ast-decl-span-fallback))
              (set! compiler-symbols-last-error-has-span false))])])))

(define (compiler-symbols-last-error-diagnostic [message : String]) : cdiag.CompilerDiagnostic
  (if compiler-symbols-last-error-has-span
    (cdiag.compiler-diagnostic-from-ast-span
      (string.copy (& compiler-symbols-last-error-path))
      compiler-symbols-last-error-span
      message)
    (cdiag.compiler-diagnostic-at-start
      (string.copy (& compiler-symbols-last-error-path))
      message)))

(define (compiler-symbol-kind-value-define) : i64
  1)

(define (compiler-symbol-kind-function-define) : i64
  2)

(define (compiler-symbol-kind-extern) : i64
  3)

(define (compiler-symbol-kind-defenum) : i64
  4)

(define (compiler-symbol-kind-defstruct) : i64
  5)

(define (compiler-symbol-kind-enum-variant) : i64
  6)

(define (compiler-symbol-kind-struct-field) : i64
  7)

(define (compiler-symbol-kind-defmacro) : i64
  8)

(define (compiler-symbol-kind-defdispatch) : i64
  9)

(define (compiler-symbol-kind-struct-cleanup) : i64
  10)

(define (compiler-symbol-kind-enum-cleanup) : i64
  11)

(define (compiler-symbol-handle-stride) : i64
  1000000000)

(define (compiler-registry-child-stride) : i64
  1000)

(define (compiler-symbol-make-handle [kind : i64] [index : i64]) : i64
  (+ (* kind (compiler-symbol-handle-stride)) index))

(define (compiler-symbol-handle-kind [handle : i64]) : i64
  (/ handle (compiler-symbol-handle-stride)))

(define (compiler-symbol-handle-index [handle : i64]) : i64
  (% handle (compiler-symbol-handle-stride)))

(define (compiler-registry-make-handle
  [kind : i64]
  [owner-index : i64]
  [child-index : i64]) : i64
  (+
    (* kind (compiler-symbol-handle-stride))
    (+ (* owner-index (compiler-registry-child-stride)) child-index)))

(define (compiler-registry-handle-kind [handle : i64]) : i64
  (compiler-symbol-handle-kind handle))

(define (compiler-registry-handle-owner-index [handle : i64]) : i64
  (/ (compiler-symbol-handle-index handle) (compiler-registry-child-stride)))

(define (compiler-registry-handle-child-index [handle : i64]) : i64
  (% (compiler-symbol-handle-index handle) (compiler-registry-child-stride)))

(define (compiler-registry-variant-owner-handle [handle : i64]) : i64
  (compiler-symbol-make-handle
    (compiler-symbol-kind-defenum)
    (compiler-registry-handle-owner-index handle)))

(define (compiler-symbol-map-round-capacity [requested : i64]) : i64
  (let
    [capacity : i64 4]
    (begin
      (while (< capacity requested)
        (set! capacity (* capacity 2)))
      capacity)))

(define (compiler-symbol-map-with-capacity [requested : i64]) : CompilerSymbolMap
  (let
    [capacity : i64 (compiler-symbol-map-round-capacity requested)]
    (CompilerSymbolMap
      (__tl_make-array i64 capacity)
      (__tl_make-array i64 capacity)
      0
      0)))

(define (compiler-symbol-map-empty) : CompilerSymbolMap
  (compiler-symbol-map-with-capacity 256))

(define (compiler-symbol-map-missing-handle) : i64
  -1)

(define (compiler-symbol-map-first-slot [key : i64] [capacity : i64]) : i64
  (let
    ;; Opaque structural handles and direct name IDs are both session-stable
    ;; integers. Fold high owner bits before the power-of-two mask so adjacent
    ;; record slots do not form one long linear-probe cluster.
    [folded : i64 (bit-xor key (bit-xor (shr key 17) (shr key 34)))]
    (bit-and (* folded 6364136223846793005) (- capacity 1))))

(define (compiler-symbol-map-lookup-handle-id
  [map : (& map CompilerSymbolMap)]
  [key : i64]) : i64
  (let
    [keys : (__tl_dyn-array i64) map.keys]
    [values : (__tl_dyn-array i64) map.values]
    [capacity : i64 (array-length keys)]
    (if (<= capacity 0)
      (compiler-symbol-map-missing-handle)
      (let
        ;; The masked slot is always in bounds, so the probe reads raw slot
        ;; data like the put path instead of paying a bounds check per probe.
        [key-data : (Ptr i64)
          (unsafe
            (ptr-cast (array-data keys) : (Ptr i64)))]
        [value-data : (Ptr i64)
          (unsafe
            (ptr-cast (array-data values) : (Ptr i64)))]
        [encoded : i64 (+ key 1)]
        [slot : i64 (compiler-symbol-map-first-slot key capacity)]
        [mask : i64 (- capacity 1)]
        (begin
          ;; Put grows before occupied+tombstone slots reach 75%, so every
          ;; table always contains an empty slot. Probing therefore terminates
          ;; on zero without a redundant full-capacity counter in this hot loop.
          (while true
            (let
              [present : i64
                (unsafe
                  (ptr-read (ptr-offset key-data slot)))]
              (cond
                [(= present 0) (return (compiler-symbol-map-missing-handle))]
                [(= present encoded)
                  (return
                    (unsafe
                      (ptr-read (ptr-offset value-data slot))))]
                [else (set! slot (bit-and (+ slot 1) mask))])))
          (compiler-symbol-map-missing-handle))))))

(define (compiler-symbol-map-put-no-grow!
  [map : (&mut map CompilerSymbolMap)]
  [key : i64]
  [handle : i64]) : unit
  (let
    [keys : (__tl_dyn-array i64) map.keys]
    [values : (__tl_dyn-array i64) map.values]
    [key-data : (MutPtr i64)
      (unsafe
        (ptr-cast (array-data keys) : (MutPtr i64)))]
    [value-data : (MutPtr i64)
      (unsafe
        (ptr-cast (array-data values) : (MutPtr i64)))]
    [capacity : i64 (array-length keys)]
    [mask : i64 (- capacity 1)]
    [encoded : i64 (+ key 1)]
    [slot : i64 (compiler-symbol-map-first-slot key capacity)]
    [first-deleted : i64 -1]
    (begin
      ;; Growth keeps one empty slot in every probe sequence.
      (while true
        (let
          [present : i64
            (unsafe
              (ptr-read (ptr-offset key-data slot)))]
          (cond
            [(= present 0)
              (let
                [target : i64
                  (if (>= first-deleted 0)
                    first-deleted
                    slot)]
                (begin
                  (unsafe
                    (ptr-write! (ptr-offset key-data target) encoded)
                    (ptr-write! (ptr-offset value-data target) handle))
                  (set! map.len (+ map.len 1))
                  (if (>= first-deleted 0)
                    (set! map.deleted (- map.deleted 1))
                    unit)
                  (return unit)))]
            [(= present -1)
              (begin
                (if (< first-deleted 0)
                  (set! first-deleted slot)
                  unit)
                (set! slot (bit-and (+ slot 1) mask)))]
            [(= present encoded)
              (begin
                (unsafe
                  (ptr-write! (ptr-offset value-data slot) handle))
                (return unit))]
            [else (set! slot (bit-and (+ slot 1) mask))])))
      unit)))

(define (compiler-symbol-map-grow! [map : (&mut map CompilerSymbolMap)]) : unit
  (let
    [old-keys : (__tl_dyn-array i64) map.keys]
    [old-values : (__tl_dyn-array i64) map.values]
    [old-capacity : i64 (array-length old-keys)]
    [new-capacity : i64
      (if (> old-capacity 0)
        (* old-capacity 2)
        4)]
    [i : i64 0]
    (begin
      (set! map.keys (__tl_make-array i64 new-capacity))
      (set! map.values (__tl_make-array i64 new-capacity))
      (set! map.len 0)
      (set! map.deleted 0)
      (while (< i old-capacity)
        (let
          [encoded : i64 (array-ref old-keys i)]
          (begin
            (if (> encoded 0)
              (compiler-symbol-map-put-no-grow!
                map
                (- encoded 1)
                (array-ref old-values i))
              unit)
            (set! i (+ i 1))))))))

(define (compiler-symbol-map-put!
  [map : (&mut map CompilerSymbolMap)]
  [key : i64]
  [handle : i64]) : unit
  (let
    [capacity : i64 (array-length map.keys)]
    [used : i64 (+ map.len map.deleted)]
    (begin
      (if (or (<= capacity 0) (>= (* used 4) (* capacity 3)))
        (compiler-symbol-map-grow! map)
        unit)
      (compiler-symbol-map-put-no-grow! map key handle))))

(define (compiler-symbol-map-remove-id!
  [map : (&mut map CompilerSymbolMap)]
  [key : i64]) : bool
  (let
    [capacity : i64 (array-length map.keys)]
    (if (<= capacity 0)
      false
      (let
        [encoded : i64 (+ key 1)]
        [slot : i64 (compiler-symbol-map-first-slot key capacity)]
        [walked : i64 0]
        (begin
          (while (< walked capacity)
            (let
              [present : i64 (array-ref map.keys slot)]
              (cond
                [(= present 0) (return false)]
                [(= present encoded)
                  (begin
                    (set! (array-ref map.keys slot) -1)
                    (set! map.len (- map.len 1))
                    (set! map.deleted (+ map.deleted 1))
                    (return true))]
                [else
                  (begin
                    (set! slot (bit-and (+ slot 1) (- capacity 1)))
                    (set! walked (+ walked 1)))])))
          false)))))

(define (compiler-symbol-map-lookup-id
  [map : (& map CompilerSymbolMap)]
  [name-id : i64]) : option_i64.Option
  (let
    [handle : i64 (compiler-symbol-map-lookup-handle-id map name-id)]
    (if (>= handle 0)
      (option_i64.Some handle)
      option_i64.None)))

(define (compiler-symbol-map-contains-id?
  [map : (& map CompilerSymbolMap)]
  [name-id : i64]) : bool
  (>= (compiler-symbol-map-lookup-handle-id map name-id) 0))

(define (compiler-symbol-map-bind-id!
  [map : (&mut map CompilerSymbolMap)]
  [name-id : i64]
  [handle : i64]) : unit
  (compiler-symbol-map-put! map name-id handle))

(define (compiler-decl-list-index-count [decls : ast.AstDeclList]) : i64
  (let
    [count : i64 0]
    [index : i64 0]
    [decl-count : i64 (ast.ast-decl-list-len (& decls))]
    [decl-offset : i64 decls.offset]
    (begin
      (while (< index decl-count)
        (let
          [decl : ast.AstDecl (array-ref decls.slots (+ decl-offset index))]
          (begin
            (match decl
              [(ast.AstDecl.Import decl-meta _) unit]
              [(ast.AstDecl.Module _) unit]
              [(ast.AstDecl.ModuleBody _ body-box)
                (set!
                  count
                  (+
                    count
                    (compiler-decl-list-index-count (__tl-box-place body-box))))]
              [(ast.AstDecl.Test _ _ _) unit]
              [_ (set! count (+ count 1))])
            (set! index (+ index 1)))))
      count)))

(define (compiler-symbols-empty-with-decls-and-capacity
  [decl-count : i64]
  [capacity : i64]) : CompilerSymbols
  (CompilerSymbols
    (compiler-symbol-map-empty)
    (compiler-symbol-map-empty)
    (compiler-symbol-map-empty)
    (__tl_make-array ast.AstDecl capacity)
    (__tl_make-array i64 (* capacity 2))
    decl-count))

(define (compiler-symbols-empty-with-decls [decl-count : i64]) : CompilerSymbols
  (compiler-symbols-empty-with-decls-and-capacity decl-count decl-count))

(define (compiler-symbols-empty) : CompilerSymbols
  (compiler-symbols-empty-with-decls 0))

(define compiler-registries-next-identity : i64
  0)

(define (compiler-registries-fresh-identity!) : i64
  (begin
    (set!
      compiler-registries-next-identity
      (+ compiler-registries-next-identity 1))
    compiler-registries-next-identity))

(define (compiler-registries-empty) : CompilerRegistries
  (CompilerRegistries
    (compiler-symbol-map-empty)
    (compiler-symbol-map-empty)
    (compiler-registries-fresh-identity!)))

(define (compiler-registries-identity [registries : CompilerRegistries]) : i64
  (match registries
    [(CompilerRegistries _ _ identity) identity]))

(define (compiler-symbols-lookup-value-id
  [symbols : CompilerSymbols]
  [name-id : i64]) : option_i64.Option
  (match symbols
    [(CompilerSymbols values _ _ _ _ _)
      (match (compiler-symbol-map-lookup-id
        (& values)
        (compiler-symbol-name-id-key name-id))
        [(option_i64.Some handle) (option_i64.Some handle)]
        [(option_i64.None)
          (match (compiler-symbol-dotted-variant-key-id name-id)
            [(option_i64.Some key-id)
              (compiler-symbol-map-lookup-id (& values) key-id)]
            [(option_i64.None) option_i64.None])])]))

(define (compiler-symbols-lookup-type-id
  [symbols : CompilerSymbols]
  [name-id : i64]) : option_i64.Option
  (match symbols
    [(CompilerSymbols _ types _ _ _ _)
      (compiler-symbol-map-lookup-id
        (& types)
        (compiler-symbol-name-id-key name-id))]))

(define (compiler-symbols-lookup-macro-id
  [symbols : CompilerSymbols]
  [name-id : i64]) : option_i64.Option
  (match symbols
    [(CompilerSymbols _ _ macros _ _ _)
      (compiler-symbol-map-lookup-id
        (& macros)
        (compiler-symbol-name-id-key name-id))]))

(define (compiler-symbols-missing-handle) : i64
  (compiler-symbol-map-missing-handle))

(define (compiler-symbols-handle-found? [handle : i64]) : bool
  (>= handle 0))

(define (compiler-symbols-option-or
  [found : option_i64.Option]
  [fallback : i64]) : i64
  (match found
    [(option_i64.Some handle) handle]
    [option_i64.None fallback]))

(define (compiler-symbols-lookup-value-id-or
  [symbols : CompilerSymbols]
  [name-id : i64]
  [fallback : i64]) : i64
  (match symbols
    [(CompilerSymbols values _ _ _ _ _)
      (let
        [handle : i64
          (compiler-symbol-map-lookup-handle-id
            (& values)
            (compiler-symbol-name-id-key name-id))]
        (if (>= handle 0)
          handle
          (match (compiler-symbol-dotted-variant-key-id name-id)
            [(option_i64.Some key-id)
              (let
                [variant-handle : i64
                  (compiler-symbol-map-lookup-handle-id (& values) key-id)]
                (if (>= variant-handle 0)
                  variant-handle
                  fallback))]
            [(option_i64.None) fallback])))]))

(define (compiler-symbols-lookup-type-id-or
  [symbols : CompilerSymbols]
  [name-id : i64]
  [fallback : i64]) : i64
  (match symbols
    [(CompilerSymbols _ types _ _ _ _)
      (let
        [handle : i64
          (compiler-symbol-map-lookup-handle-id
            (& types)
            (compiler-symbol-name-id-key name-id))]
        (if (>= handle 0)
          handle
          fallback))]))

(define (compiler-symbols-decls [symbols : CompilerSymbols]) : (__tl_dyn-array
    ast.AstDecl)
  (match symbols
    [(CompilerSymbols _ _ _ decls _ _) decls]))

(define (compiler-symbols-owner-module-ids [symbols : CompilerSymbols]) : (__tl_dyn-array
    i64)
  (match symbols
    [(CompilerSymbols _ _ _ _ owner-module-ids _) owner-module-ids]))

(define (compiler-symbols-decl-count [symbols : CompilerSymbols]) : i64
  (match symbols
    [(CompilerSymbols _ _ _ _ _ decl-count) decl-count]))

(define (compiler-symbols-growth-capacity [capacity : i64] [required : i64]) : i64
  (if (>= capacity required)
    capacity
    (compiler-symbols-growth-capacity
      (if (< capacity 8)
        8
        (* capacity 2))
      required)))

;; Symbol handles index the owned declaration arrays, not the flattened program
;; view. That lets additive macro splices append fresh handles without shifting
;; every existing map entry. Capacity grows geometrically, so the only
;; whole-table copy is amortized across all splices in a compilation.
(define (compiler-symbols-ensure-decl-capacity
  [symbols : CompilerSymbols]
  [required : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-module-ids decl-count)
      (let
        [capacity : i64 (array-length decls)]
        (if (>= capacity required)
          symbols
          (let
            [next-capacity : i64
              (compiler-symbols-growth-capacity capacity required)]
            [next-decls : (__tl_dyn-array ast.AstDecl)
              (__tl_make-array ast.AstDecl next-capacity)]
            [next-owner-module-ids : (__tl_dyn-array i64)
              (__tl_make-array i64 (* next-capacity 2))]
            [index : i64 0]
            (begin
              (while (< index decl-count)
                (begin
                  (set! (array-ref next-decls index) (array-ref decls index))
                  (set!
                    (array-ref next-owner-module-ids index)
                    (array-ref owner-module-ids index))
                  (set!
                    (array-ref next-owner-module-ids (+ next-capacity index))
                    (array-ref owner-module-ids (+ capacity index)))
                  (set! index (+ index 1))))
              (CompilerSymbols
                values
                types
                macros
                next-decls
                next-owner-module-ids
                decl-count)))))]))

(define (compiler-symbols-with-decl-count
  [symbols : CompilerSymbols]
  [decl-count : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-module-ids _)
      (CompilerSymbols values types macros decls owner-module-ids decl-count)]))

(define (compiler-symbols-duplicate-value-message [name : String]) : String
  (str_cat.str-cat "symbols: duplicate value declaration " name))

(define (compiler-symbols-duplicate-type-message [name : String]) : String
  (str_cat.str-cat "symbols: duplicate type declaration " name))

(define (compiler-symbols-duplicate-macro-message [name : String]) : String
  (str_cat.str-cat "symbols: duplicate macro declaration " name))

(define (compiler-symbols-duplicate-macro-value-message [name : String]) : String
  (str_cat.str-cat "symbols: duplicate macro/value declaration " name))

(define (compiler-registries-duplicate-variant-message [name : String]) : String
  (str_cat.str-cat "symbols: duplicate enum variant " name))

(define (compiler-struct-field-key [struct-name : String] [field-name : String]) : String
  ;; Flat field registry key. Field names may repeat across structs because the
  ;; struct name is part of the key.
  (str_cat.str-cat struct-name "." field-name))

(define (compiler-composite-pair-key-id [left-id : i64] [right-id : i64]) : i64
  (ci.intern-composite-pair-id left-id right-id))

(define (compiler-composite-pair-key-id? [key-id : i64]) : bool
  (ci.intern-composite-pair-id? key-id))

(define (compiler-composite-pair-left-id [key-id : i64]) : i64
  (ci.intern-composite-left-id-unchecked key-id))

(define (compiler-composite-pair-right-id [key-id : i64]) : i64
  (ci.intern-composite-right-id-unchecked key-id))

(define (compiler-composite-triple-key-id
  [left-id : i64]
  [middle-id : i64]
  [right-id : i64]) : i64
  (ci.intern-composite-triple-id left-id middle-id right-id))

(define (compiler-composite-triple-key-id? [key-id : i64]) : bool
  (ci.intern-composite-triple-id? key-id))

(define (compiler-composite-triple-left-id [key-id : i64]) : i64
  (ci.intern-composite-left-id-unchecked key-id))

(define (compiler-composite-triple-middle-id [key-id : i64]) : i64
  (ci.intern-composite-middle-id-unchecked key-id))

(define (compiler-composite-triple-right-id [key-id : i64]) : i64
  (ci.intern-composite-right-id-unchecked key-id))

(define (compiler-struct-field-key-id-by-id
  [struct-name-id : i64]
  [field-name-id : i64]) : i64
  (cond
    [(compiler-composite-pair-key-id? struct-name-id)
      (compiler-composite-triple-key-id
        (compiler-composite-pair-left-id struct-name-id)
        (compiler-composite-pair-right-id struct-name-id)
        field-name-id)]
    [(not (ci.intern-renderable-id? struct-name-id))
      (compiler-composite-pair-key-id struct-name-id field-name-id)]
    [(ci.intern-qualified? struct-name-id)
      (compiler-composite-triple-key-id
        (ci.intern-qualified-module-id struct-name-id)
        (ci.intern-qualified-base-id struct-name-id)
        field-name-id)]
    [else (compiler-composite-pair-key-id struct-name-id field-name-id)]))

(define (compiler-struct-field-key-id-in-module-by-id
  [module-id : i64]
  [struct-name-id : i64]
  [field-name-id : i64]) : i64
  (if (or (< module-id 0) (= module-id cbi.compiler-builtin-id-fix-empty))
    (compiler-composite-pair-key-id struct-name-id field-name-id)
    (compiler-composite-triple-key-id module-id struct-name-id field-name-id)))

(define (compiler-registries-duplicate-field-message
  [struct-name : String]
  [field-name : String]) : String
  (str_cat.str-cat
    "symbols: duplicate field "
    (compiler-struct-field-key struct-name field-name)))

(define (compiler-symbol-module-key [module : String] [name : String]) : String
  (if (= (string.string-length module) 0)
    name
    (str_cat.str-cat module "/" name)))

(define (compiler-symbol-root-module-id) : i64
  -1)

(define (compiler-symbol-root-module-id? [module-id : i64]) : bool
  (or (< module-id 0) (= module-id cbi.compiler-builtin-id-fix-empty)))

(define (compiler-symbol-module-key-by-id [module-id : i64] [name-id : i64]) : String
  (let
    [name : String
      (cond
        [(compiler-composite-triple-key-id? name-id)
          (compiler-symbol-module-key
            (ci.intern-syntax-name-text-or
              (compiler-composite-triple-left-id name-id)
              "<structural-module>")
            (compiler-enum-qualified-variant-name
              (ci.intern-syntax-name-text-or
                (compiler-composite-triple-middle-id name-id)
                "<structural-name>")
              (ci.intern-syntax-name-text-or
                (compiler-composite-triple-right-id name-id)
                "<structural-name>")))]
        [(compiler-composite-pair-key-id? name-id)
          (compiler-enum-qualified-variant-name
            (ci.intern-syntax-name-text-or
              (compiler-composite-pair-left-id name-id)
              "<structural-name>")
            (ci.intern-syntax-name-text-or
              (compiler-composite-pair-right-id name-id)
              "<structural-name>"))]
        [(ci.intern-renderable-id? name-id) (ci.intern-str name-id)]
        [else "<structural-symbol>"])]
    (if (or
      (compiler-composite-triple-key-id? name-id)
      (compiler-symbol-root-module-id? module-id))
      name
      (compiler-symbol-module-key
        (ci.intern-syntax-name-text-or module-id "<structural-module>")
        name))))

(define (compiler-enum-qualified-variant-name
  [enum-name : String]
  [variant-name : String]) : String
  (str_cat.str-cat enum-name "." variant-name))

(define (compiler-enum-qualified-variant-name-id
  [enum-name-id : i64]
  [variant-name-id : i64]) : i64
  (compiler-composite-pair-key-id enum-name-id variant-name-id))

(define (compiler-symbol-module-key-id-by-id [module-id : i64] [name-id : i64]) : i64
  (cond
    [(compiler-symbol-root-module-id? module-id) name-id]
    [(and
        (ci.intern-renderable-id? name-id)
        (ci.intern-qualified? name-id)
        (= (ci.intern-qualified-module-id name-id) module-id))
      (compiler-symbol-name-id-key name-id)]
    [(compiler-composite-pair-key-id? name-id)
      (compiler-composite-triple-key-id
        module-id
        (compiler-composite-pair-left-id name-id)
        (compiler-composite-pair-right-id name-id))]
    [else (compiler-composite-pair-key-id module-id name-id)]))

(define (compiler-symbol-name-id-key [name-id : i64]) : i64
  (ast.ast-nominal-name-id-key name-id))

(define (compiler-symbol-dotted-variant-key-id-in-module
  [name-id : i64]
  [default-module-id : i64]) : option_i64.Option
  (if (not (ci.intern-renderable-id? name-id))
    option_i64.None
    (let
      [base-id : i64
        (if (ci.intern-qualified? name-id)
          (ci.intern-qualified-base-id name-id)
          name-id)]
      [enum-prefix-id : i64 (ci.intern-dotted-prefix-id base-id)]
      [variant-id : i64 (ci.intern-dotted-final-id base-id)]
      (if (or (< enum-prefix-id 0) (< variant-id 0))
        option_i64.None
        (let
          [qualified : bool (ci.intern-qualified? name-id)]
          [module-prefix-id : i64 (ci.intern-dotted-prefix-id enum-prefix-id)]
          [module-id : i64
            (if qualified
              (ci.intern-qualified-module-id name-id)
              (if (>= module-prefix-id 0)
                module-prefix-id
                default-module-id))]
          [enum-id : i64
            (if qualified
              enum-prefix-id
              (ci.intern-dotted-final-id enum-prefix-id))]
          (option_i64.Some
            (compiler-symbol-module-key-id-by-id
              module-id
              (compiler-enum-qualified-variant-name-id enum-id variant-id))))))))

(define (compiler-symbol-dotted-variant-key-id [name-id : i64]) : option_i64.Option
  (compiler-symbol-dotted-variant-key-id-in-module
    name-id
    (compiler-symbol-root-module-id)))

(define (compiler-symbol-dotted-variant-key-id-in-module-or
  [name-id : i64]
  [default-module-id : i64]
  [fallback : i64]) : i64
  (match (compiler-symbol-dotted-variant-key-id-in-module
    name-id
    default-module-id)
    [(option_i64.Some key-id) key-id]
    [(option_i64.None) fallback]))

(define (compiler-symbols-add-value-alias-key-id
  [symbols : CompilerSymbols (:consume)]
  [key-id : i64]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (if (compiler-symbol-map-contains-id? (& values) key-id)
        symbols
        (begin
          (compiler-symbol-map-bind-id! (&mut values) key-id handle)
          (CompilerSymbols values types macros decls owner-names decl-count)))]))

(define (compiler-symbols-add-type-alias-key-id
  [symbols : CompilerSymbols (:consume)]
  [key-id : i64]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (if (compiler-symbol-map-contains-id? (& types) key-id)
        symbols
        (begin
          (compiler-symbol-map-bind-id! (&mut types) key-id handle)
          (CompilerSymbols values types macros decls owner-names decl-count)))]))

(define (compiler-symbols-add-macro-alias-key-id
  [symbols : CompilerSymbols (:consume)]
  [key-id : i64]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (if (compiler-symbol-map-contains-id? (& macros) key-id)
        symbols
        (begin
          (compiler-symbol-map-bind-id! (&mut macros) key-id handle)
          (CompilerSymbols values types macros decls owner-names decl-count)))]))

(define (compiler-symbols-remove-macro-alias-if-handle
  [symbols : CompilerSymbols (:consume)]
  [name-id : i64]
  [handle : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (match (compiler-symbol-map-lookup-id
        (& macros)
        (compiler-symbol-name-id-key name-id))
        [(option_i64.Some existing)
          (if (= existing handle)
            (if (compiler-symbol-map-remove-id!
              (&mut macros)
              (compiler-symbol-name-id-key name-id))
              (CompilerSymbols values types macros decls owner-names decl-count)
              symbols)
            symbols)]
        [(option_i64.None) symbols])]))

(define (compiler-registries-add-variant-alias-key-id
  [registries : CompilerRegistries (:consume)]
  [key-id : i64]
  [handle : i64]) : CompilerRegistries
  (match registries
    [(CompilerRegistries variants fields identity)
      (if (compiler-symbol-map-contains-id? (& variants) key-id)
        registries
        (begin
          (compiler-symbol-map-bind-id! (&mut variants) key-id handle)
          (CompilerRegistries variants fields identity)))]))

(define (compiler-symbols-add-value-id
  [symbols : CompilerSymbols (:consume)]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (if (compiler-symbol-map-contains-id? (& values) name-id)
        (ResultCompilerSymbols.Err
          (compiler-symbols-duplicate-value-message display-name))
        (if (compiler-symbol-map-contains-id? (& macros) name-id)
          (ResultCompilerSymbols.Err
            (compiler-symbols-duplicate-macro-value-message display-name))
          (begin
            (compiler-symbol-map-bind-id! (&mut values) name-id handle)
            (ResultCompilerSymbols.Ok
              (CompilerSymbols values types macros decls owner-names decl-count)))))]))

(define (compiler-symbols-add-type-id
  [symbols : CompilerSymbols (:consume)]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (if (compiler-symbol-map-contains-id? (& types) name-id)
        (ResultCompilerSymbols.Err
          (compiler-symbols-duplicate-type-message display-name))
        (begin
          (compiler-symbol-map-bind-id! (&mut types) name-id handle)
          (ResultCompilerSymbols.Ok
            (CompilerSymbols values types macros decls owner-names decl-count))))]))

(define (compiler-symbols-add-macro-id
  [symbols : CompilerSymbols (:consume)]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (if (compiler-symbol-map-contains-id? (& macros) name-id)
        (ResultCompilerSymbols.Err
          (compiler-symbols-duplicate-macro-message display-name))
        (if (compiler-symbol-map-contains-id? (& values) name-id)
          (ResultCompilerSymbols.Err
            (compiler-symbols-duplicate-macro-value-message display-name))
          (begin
            (compiler-symbol-map-bind-id! (&mut macros) name-id handle)
            (ResultCompilerSymbols.Ok
              (CompilerSymbols values types macros decls owner-names decl-count)))))]))

(define (compiler-symbols-handle-from-nonroot-owner?
  [symbols : CompilerSymbols]
  [handle : i64]) : bool
  (not
    (compiler-symbol-root-module-id?
      (compiler-symbols-owner-module-id-at-index-or
        symbols
        (compiler-symbol-handle-index handle)
        (compiler-symbol-root-module-id)))))

(define (compiler-symbols-add-root-macro-id
  [symbols : CompilerSymbols (:consume)]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (match (compiler-symbol-map-lookup-id (& macros) name-id)
        [(option_i64.Some existing)
          (if (compiler-symbols-handle-from-nonroot-owner? symbols existing)
            (if (compiler-symbol-map-contains-id? (& values) name-id)
              (ResultCompilerSymbols.Err
                (compiler-symbols-duplicate-macro-value-message display-name))
              (begin
                (compiler-symbol-map-bind-id! (&mut macros) name-id handle)
                (ResultCompilerSymbols.Ok
                  (CompilerSymbols
                    values
                    types
                    macros
                    decls
                    owner-names
                    decl-count))))
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-macro-message display-name)))]
        [(option_i64.None)
          (if (compiler-symbol-map-contains-id? (& values) name-id)
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-macro-value-message display-name))
            (begin
              (compiler-symbol-map-bind-id! (&mut macros) name-id handle)
              (ResultCompilerSymbols.Ok
                (CompilerSymbols
                  values
                  types
                  macros
                  decls
                  owner-names
                  decl-count))))])]))

(define (compiler-symbols-add-root-value-id
  [symbols : CompilerSymbols (:consume)]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (match (compiler-symbol-map-lookup-id (& values) name-id)
        [(option_i64.Some existing)
          (if (compiler-symbols-handle-from-nonroot-owner? symbols existing)
            (if (compiler-symbol-map-contains-id? (& macros) name-id)
              (ResultCompilerSymbols.Err
                (compiler-symbols-duplicate-macro-value-message display-name))
              (begin
                (compiler-symbol-map-bind-id! (&mut values) name-id handle)
                (ResultCompilerSymbols.Ok
                  (CompilerSymbols
                    values
                    types
                    macros
                    decls
                    owner-names
                    decl-count))))
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-value-message display-name)))]
        [(option_i64.None)
          (if (compiler-symbol-map-contains-id? (& macros) name-id)
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-macro-value-message display-name))
            (begin
              (compiler-symbol-map-bind-id! (&mut values) name-id handle)
              (ResultCompilerSymbols.Ok
                (CompilerSymbols
                  values
                  types
                  macros
                  decls
                  owner-names
                  decl-count))))])]))

(define (compiler-symbols-add-value-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]
  [handle : i64]) : ResultCompilerSymbols
  (let
    [key-id : i64 (compiler-symbol-module-key-id-by-id module-id name-id)]
    [display-name : String (compiler-symbol-module-key-by-id module-id name-id)]
    (match (if (compiler-symbol-root-module-id? module-id)
      (compiler-symbols-add-root-value-id symbols key-id display-name handle)
      (compiler-symbols-add-value-id symbols key-id display-name handle))
      [(ResultCompilerSymbols.Ok next)
        (if (compiler-symbols-comptime-module-id? module-id)
          (ResultCompilerSymbols.Ok next)
          (ResultCompilerSymbols.Ok
            (compiler-symbols-add-value-alias-key-id
              next
              (compiler-symbol-name-id-key name-id)
              handle)))]
      [(ResultCompilerSymbols.Err message) (ResultCompilerSymbols.Err message)])))

(define (compiler-symbols-comptime-module-id? [module-id : i64]) : bool
  (and
    (>= module-id 0)
    (= module-id cbi.compiler-builtin-id-fix-stdlib_dot_comptime)))

(define (compiler-symbols-add-type-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]
  [handle : i64]) : ResultCompilerSymbols
  (let
    [key-id : i64 (compiler-symbol-module-key-id-by-id module-id name-id)]
    [display-name : String (compiler-symbol-module-key-by-id module-id name-id)]
    (match (compiler-symbols-add-type-id symbols key-id display-name handle)
      [(ResultCompilerSymbols.Ok next)
        (if (compiler-symbols-comptime-module-id? module-id)
          (ResultCompilerSymbols.Ok next)
          (ResultCompilerSymbols.Ok
            (compiler-symbols-add-type-alias-key-id
              next
              (compiler-symbol-name-id-key name-id)
              handle)))]
      [(ResultCompilerSymbols.Err message) (ResultCompilerSymbols.Err message)])))

(define (compiler-symbols-add-variant-value-key-in-module-id
  [symbols : CompilerSymbols (:consume)]
  [key-id : i64]
  [module-id : i64]
  [display-name-id : i64]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (match (compiler-symbol-map-lookup-id (& values) key-id)
        [(option_i64.Some existing)
          (if (=
            (compiler-symbol-handle-kind existing)
            (compiler-symbol-kind-enum-variant))
            (ResultCompilerSymbols.Err
              (compiler-registries-duplicate-variant-message
                (compiler-symbol-module-key-by-id module-id display-name-id)))
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-value-message
                (compiler-symbol-module-key-by-id module-id display-name-id))))]
        [(option_i64.None)
          (if (compiler-symbol-map-contains-id? (& macros) key-id)
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-macro-value-message
                (compiler-symbol-module-key-by-id module-id display-name-id)))
            (begin
              (compiler-symbol-map-bind-id! (&mut values) key-id handle)
              (ResultCompilerSymbols.Ok
                (CompilerSymbols
                  values
                  types
                  macros
                  decls
                  owner-names
                  decl-count))))])]))

(define (compiler-symbols-add-variant-flat-value-alias-key-in-module-id
  [symbols : CompilerSymbols (:consume)]
  [key-id : i64]
  [module-id : i64]
  [display-name-id : i64]
  [handle : i64]) : ResultCompilerSymbols
  (match symbols
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (match (compiler-symbol-map-lookup-id (& values) key-id)
        [(option_i64.Some existing)
          (if (=
            (compiler-symbol-handle-kind existing)
            (compiler-symbol-kind-enum-variant))
            (ResultCompilerSymbols.Ok symbols)
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-value-message
                (compiler-symbol-module-key-by-id module-id display-name-id))))]
        [(option_i64.None)
          (if (compiler-symbol-map-contains-id? (& macros) key-id)
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-macro-value-message
                (compiler-symbol-module-key-by-id module-id display-name-id)))
            (begin
              (compiler-symbol-map-bind-id! (&mut values) key-id handle)
              (ResultCompilerSymbols.Ok
                (CompilerSymbols
                  values
                  types
                  macros
                  decls
                  owner-names
                  decl-count))))])]))

(define (compiler-symbols-add-variant-value-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [enum-name-id : i64]
  [name-id : i64]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerSymbols
  (let
    [qualified-name-id : i64
      (compiler-enum-qualified-variant-name-id enum-name-id name-id)]
    [qualified-key-id : i64
      (compiler-symbol-module-key-id-by-id module-id qualified-name-id)]
    [flat-key-id : i64 (compiler-symbol-module-key-id-by-id module-id name-id)]
    [handle : i64
      (compiler-registry-make-handle
        (compiler-symbol-kind-enum-variant)
        enum-index
        variant-index)]
    (match (compiler-symbols-add-variant-value-key-in-module-id
      symbols
      qualified-key-id
      module-id
      qualified-name-id
      handle)
      [(ResultCompilerSymbols.Ok next)
        (match (compiler-symbols-add-variant-flat-value-alias-key-in-module-id
          next
          flat-key-id
          module-id
          name-id
          handle)
          [(ResultCompilerSymbols.Ok with-flat)
            (if (compiler-symbols-comptime-module-id? module-id)
              (ResultCompilerSymbols.Ok with-flat)
              (ResultCompilerSymbols.Ok
                (compiler-symbols-add-value-alias-key-id
                  with-flat
                  (compiler-symbol-name-id-key name-id)
                  handle)))]
          [(ResultCompilerSymbols.Err message)
            (ResultCompilerSymbols.Err message)])]
      [(ResultCompilerSymbols.Err message) (ResultCompilerSymbols.Err message)])))

(define (compiler-symbols-add-variant-values-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [enum-name-id : i64]
  [variants : ast.AstVariantDefList]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerSymbols
  (if (>= variant-index (ast.ast-variant-def-list-len (& variants)))
    (ResultCompilerSymbols.Ok symbols)
    (match (ast.ast-variant-def-list-get
      (& variants)
      variant-index
      (ast.ast-variant-def-fallback))
      [(ast.AstVariantDef.Def name _ _)
        (match (compiler-symbols-add-variant-value-in-module-id
          symbols
          module-id
          enum-name-id
          name
          enum-index
          variant-index)
          [(ResultCompilerSymbols.Ok next)
            (compiler-symbols-add-variant-values-in-module-id
              next
              module-id
              enum-name-id
              variants
              enum-index
              (+ variant-index 1))]
          [(ResultCompilerSymbols.Err message)
            (begin
              (compiler-symbols-note-last-error-member-span!
                (parser.compiler-parse-variant-def-list-span-get
                  (& variants)
                  variant-index
                  (ast.ast-decl-span-fallback)))
              (ResultCompilerSymbols.Err message))])])))

(define (compiler-symbols-add-macro-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]
  [handle : i64]) : ResultCompilerSymbols
  (let
    [key-id : i64 (compiler-symbol-module-key-id-by-id module-id name-id)]
    [display-name : String (compiler-symbol-module-key-by-id module-id name-id)]
    (match (if (compiler-symbol-root-module-id? module-id)
      (compiler-symbols-add-root-macro-id symbols key-id display-name handle)
      (compiler-symbols-add-macro-id symbols key-id display-name handle))
      [(ResultCompilerSymbols.Ok next)
        (ResultCompilerSymbols.Ok
          (compiler-symbols-add-macro-alias-key-id
            next
            (compiler-symbol-name-id-key name-id)
            handle))]
      [(ResultCompilerSymbols.Err message) (ResultCompilerSymbols.Err message)])))

(define (compiler-symbols-lookup-value-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]) : option_i64.Option
  (match symbols
    [(CompilerSymbols values _ _ _ _ _)
      (compiler-symbol-map-lookup-id
        (& values)
        (compiler-symbol-module-key-id-by-id module-id name-id))]))

(define (compiler-symbols-lookup-type-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]) : option_i64.Option
  (match symbols
    [(CompilerSymbols _ types _ _ _ _)
      (compiler-symbol-map-lookup-id
        (& types)
        (compiler-symbol-module-key-id-by-id module-id name-id))]))

(define (compiler-symbols-lookup-macro-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]) : option_i64.Option
  (match symbols
    [(CompilerSymbols _ _ macros _ _ _)
      (compiler-symbol-map-lookup-id
        (& macros)
        (compiler-symbol-module-key-id-by-id module-id name-id))]))

(define (compiler-symbols-lookup-value-in-module-id-or
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]
  [fallback : i64]) : i64
  (match symbols
    [(CompilerSymbols values _ _ _ _ _)
      (let
        [handle : i64
          (compiler-symbol-map-lookup-handle-id
            (& values)
            (compiler-symbol-module-key-id-by-id module-id name-id))]
        (if (>= handle 0)
          handle
          fallback))]))

(define (compiler-symbols-lookup-type-in-module-id-or
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]
  [fallback : i64]) : i64
  (match symbols
    [(CompilerSymbols _ types _ _ _ _)
      (let
        [handle : i64
          (compiler-symbol-map-lookup-handle-id
            (& types)
            (compiler-symbol-module-key-id-by-id module-id name-id))]
        (if (>= handle 0)
          handle
          fallback))]))

(define (compiler-symbols-lookup-macro-in-module-id-or
  [symbols : CompilerSymbols]
  [module-id : i64]
  [name-id : i64]
  [fallback : i64]) : i64
  (match symbols
    [(CompilerSymbols _ _ macros _ _ _)
      (let
        [handle : i64
          (compiler-symbol-map-lookup-handle-id
            (& macros)
            (compiler-symbol-module-key-id-by-id module-id name-id))]
        (if (>= handle 0)
          handle
          fallback))]))

(define (compiler-registries-lookup-field-in-module-id
  [registries : CompilerRegistries]
  [module-id : i64]
  [type-name-id : i64]
  [field-name-id : i64]) : option_i64.Option
  (match registries
    [(CompilerRegistries _ fields _)
      (compiler-symbol-map-lookup-id
        (& fields)
        (compiler-struct-field-key-id-in-module-by-id
          module-id
          type-name-id
          field-name-id))]))

(define (compiler-symbols-generated-meta-suffix
  [meta : ast.AstGeneratedDeclMeta]) : String
  (match meta
    [(ast.AstGeneratedDeclMeta.Some generator item _ key)
      (if (> (string.string-length key) 0)
        (str_cat.str-cat " (generated identity: " key ")")
        (str_cat.str-cat
          " (generated declaration: "
          item
          " from "
          generator
          ")"))]
    [(ast.AstGeneratedDeclMeta.No) ""]))

(define (compiler-symbols-with-generated-context
  [message : String]
  [meta : ast.AstGeneratedDeclMeta]) : String
  (str_cat.str-cat message (compiler-symbols-generated-meta-suffix meta)))

(define (compiler-symbols-add-struct-cleanup-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [cleanup : ast.AstStructCleanup]
  [index : i64]) : ResultCompilerSymbols
  (match cleanup
    [(ast.AstStructCleanup.No) (ResultCompilerSymbols.Ok symbols)]
    [(ast.AstStructCleanup.Fn cleanup-name)
      (compiler-symbols-add-value-in-module-id
        symbols
        module-id
        cleanup-name
        (compiler-symbol-make-handle
          (compiler-symbol-kind-struct-cleanup)
          index))]))

(define (compiler-symbols-add-enum-cleanup-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [cleanup : ast.AstEnumCleanup]
  [index : i64]) : ResultCompilerSymbols
  (match cleanup
    [(ast.AstEnumCleanup.No) (ResultCompilerSymbols.Ok symbols)]
    [(ast.AstEnumCleanup.Fn cleanup-name)
      (compiler-symbols-add-value-in-module-id
        symbols
        module-id
        cleanup-name
        (compiler-symbol-make-handle (compiler-symbol-kind-enum-cleanup) index))]))

(define (compiler-symbols-add-decl-in-module-inner
  [symbols : CompilerSymbols]
  [module-id : i64]
  [decl : ast.AstDecl]
  [index : i64]) : ResultCompilerSymbols
  (match decl
    [(ast.AstDecl.Def decl-meta name _ _)
      (compiler-symbols-add-value-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-value-define) index))]
    [(ast.AstDecl.DefFn decl-meta name _ _ _ _)
      (compiler-symbols-add-value-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle
          (compiler-symbol-kind-function-define)
          index))]
    [(ast.AstDecl.DefMacro decl-meta name _ _ _)
      (compiler-symbols-add-macro-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defmacro) index))]
    [(ast.AstDecl.Extern decl-meta name _ _ _)
      (compiler-symbols-add-value-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-extern) index))]
    [(ast.AstDecl.DefDispatch decl-meta name _)
      (compiler-symbols-add-value-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defdispatch) index))]
    [(ast.AstDecl.DefEnum decl-meta name cleanup variants)
      (match (compiler-symbols-add-type-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
        [(ResultCompilerSymbols.Ok next)
          (match (compiler-symbols-add-variant-values-in-module-id
            next
            module-id
            name
            variants
            index
            0)
            [(ResultCompilerSymbols.Ok with-variants)
              (compiler-symbols-add-enum-cleanup-in-module-id
                with-variants
                module-id
                cleanup
                index)]
            [(ResultCompilerSymbols.Err message)
              (ResultCompilerSymbols.Err message)])]
        [(ResultCompilerSymbols.Err message)
          (ResultCompilerSymbols.Err message)])]
    [(ast.AstDecl.DefEnumLifetimes decl-meta name _ cleanup variants)
      (match (compiler-symbols-add-type-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
        [(ResultCompilerSymbols.Ok next)
          (match (compiler-symbols-add-variant-values-in-module-id
            next
            module-id
            name
            variants
            index
            0)
            [(ResultCompilerSymbols.Ok with-variants)
              (compiler-symbols-add-enum-cleanup-in-module-id
                with-variants
                module-id
                cleanup
                index)]
            [(ResultCompilerSymbols.Err message)
              (ResultCompilerSymbols.Err message)])]
        [(ResultCompilerSymbols.Err message)
          (ResultCompilerSymbols.Err message)])]
    [(ast.AstDecl.DefStruct decl-meta name _ cleanup _)
      (match (compiler-symbols-add-type-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        [(ResultCompilerSymbols.Ok next)
          (match (compiler-symbols-add-value-in-module-id
            next
            module-id
            name
            (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
            [(ResultCompilerSymbols.Ok with-constructor)
              (compiler-symbols-add-struct-cleanup-in-module-id
                with-constructor
                module-id
                cleanup
                index)]
            [(ResultCompilerSymbols.Err message)
              (ResultCompilerSymbols.Err message)])]
        [(ResultCompilerSymbols.Err message)
          (ResultCompilerSymbols.Err message)])]
    [(ast.AstDecl.DefStructLifetimes decl-meta name _ _ cleanup _)
      (match (compiler-symbols-add-type-in-module-id
        symbols
        module-id
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        [(ResultCompilerSymbols.Ok next)
          (match (compiler-symbols-add-value-in-module-id
            next
            module-id
            name
            (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
            [(ResultCompilerSymbols.Ok with-constructor)
              (compiler-symbols-add-struct-cleanup-in-module-id
                with-constructor
                module-id
                cleanup
                index)]
            [(ResultCompilerSymbols.Err message)
              (ResultCompilerSymbols.Err message)])]
        [(ResultCompilerSymbols.Err message)
          (ResultCompilerSymbols.Err message)])]
    [(ast.AstDecl.IncludeStr _ _) (ResultCompilerSymbols.Ok symbols)]
    [(ast.AstDecl.IncludeStrComptime _ _) (ResultCompilerSymbols.Ok symbols)]
    [(ast.AstDecl.IncludeStrLzss _ _) (ResultCompilerSymbols.Ok symbols)]
    [(ast.AstDecl.IncludeBin _ _) (ResultCompilerSymbols.Ok symbols)]
    [(ast.AstDecl.Import decl-meta _) (ResultCompilerSymbols.Ok symbols)]
    [(ast.AstDecl.Module _) (ResultCompilerSymbols.Ok symbols)]
    [(ast.AstDecl.ModuleBody name body-box)
      (build-compiler-symbol-list-in-module
        (__tl-box-place body-box)
        (__tl-box-place body-box)
        symbols
        index
        name)]
    [(ast.AstDecl.Test _ _ _) (ResultCompilerSymbols.Ok symbols)]
    [(ast.AstDecl.Unsafe inner-box)
      (let
        [inner : ast.AstDecl (__tl-box-place inner-box)]
        (compiler-symbols-add-decl-in-module symbols module-id inner index))]))

(define (compiler-symbols-add-decl-in-module
  [symbols : CompilerSymbols]
  [module-id : i64]
  [decl : ast.AstDecl]
  [index : i64]) : ResultCompilerSymbols
  (match (compiler-symbols-add-decl-in-module-inner
    symbols
    module-id
    decl
    index)
    [(ResultCompilerSymbols.Ok next) (ResultCompilerSymbols.Ok next)]
    [(ResultCompilerSymbols.Err message)
      (ResultCompilerSymbols.Err
        (compiler-symbols-with-generated-context
          message
          (ast.ast-decl-generated-meta decl)))]))

(define (compiler-symbols-add-variant-value-aliases
  [symbols : CompilerSymbols]
  [alias-id : i64]
  [enum-name-id : i64]
  [variants : ast.AstVariantDefList]
  [enum-index : i64]
  [variant-index : i64]) : CompilerSymbols
  (if (>= variant-index (ast.ast-variant-def-list-len (& variants)))
    symbols
    (match (ast.ast-variant-def-list-get
      (& variants)
      variant-index
      (ast.ast-variant-def-fallback))
      [(ast.AstVariantDef.Def name _ _)
        (let
          [qualified-name-id : i64
            (compiler-enum-qualified-variant-name-id enum-name-id name)]
          [handle : i64
            (compiler-registry-make-handle
              (compiler-symbol-kind-enum-variant)
              enum-index
              variant-index)]
          (compiler-symbols-add-variant-value-aliases
            (compiler-symbols-add-value-alias-key-id
              (compiler-symbols-add-value-alias-key-id
                symbols
                (compiler-symbol-module-key-id-by-id alias-id name)
                handle)
              (compiler-symbol-module-key-id-by-id alias-id qualified-name-id)
              handle)
            alias-id
            enum-name-id
            variants
            enum-index
            (+ variant-index 1)))])))

(define (compiler-symbols-add-struct-cleanup-alias
  [symbols : CompilerSymbols]
  [alias-id : i64]
  [cleanup : ast.AstStructCleanup]
  [index : i64]) : CompilerSymbols
  (match cleanup
    [(ast.AstStructCleanup.No) symbols]
    [(ast.AstStructCleanup.Fn cleanup-name)
      (compiler-symbols-add-value-alias-key-id
        symbols
        (compiler-symbol-module-key-id-by-id alias-id cleanup-name)
        (compiler-symbol-make-handle
          (compiler-symbol-kind-struct-cleanup)
          index))]))

(define (compiler-symbols-add-enum-cleanup-alias
  [symbols : CompilerSymbols]
  [alias-id : i64]
  [cleanup : ast.AstEnumCleanup]
  [index : i64]) : CompilerSymbols
  (match cleanup
    [(ast.AstEnumCleanup.No) symbols]
    [(ast.AstEnumCleanup.Fn cleanup-name)
      (compiler-symbols-add-value-alias-key-id
        symbols
        (compiler-symbol-module-key-id-by-id alias-id cleanup-name)
        (compiler-symbol-make-handle (compiler-symbol-kind-enum-cleanup) index))]))

(define (compiler-symbols-add-decl-alias-in-module
  [symbols : CompilerSymbols]
  [alias-id : i64]
  [decl : ast.AstDecl]
  [index : i64]) : CompilerSymbols
  (match decl
    [(ast.AstDecl.Def decl-meta name _ _)
      (compiler-symbols-add-value-alias-key-id
        symbols
        (compiler-symbol-module-key-id-by-id alias-id name)
        (compiler-symbol-make-handle (compiler-symbol-kind-value-define) index))]
    [(ast.AstDecl.DefFn decl-meta name _ _ _ _)
      (compiler-symbols-add-value-alias-key-id
        symbols
        (compiler-symbol-module-key-id-by-id alias-id name)
        (compiler-symbol-make-handle
          (compiler-symbol-kind-function-define)
          index))]
    [(ast.AstDecl.DefMacro decl-meta name _ _ _)
      (compiler-symbols-add-macro-alias-key-id
        symbols
        (compiler-symbol-module-key-id-by-id alias-id name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defmacro) index))]
    [(ast.AstDecl.Extern decl-meta name _ _ _)
      (compiler-symbols-add-value-alias-key-id
        symbols
        (compiler-symbol-module-key-id-by-id alias-id name)
        (compiler-symbol-make-handle (compiler-symbol-kind-extern) index))]
    [(ast.AstDecl.DefDispatch decl-meta name _)
      (compiler-symbols-add-value-alias-key-id
        symbols
        (compiler-symbol-module-key-id-by-id alias-id name)
        (compiler-symbol-make-handle (compiler-symbol-kind-defdispatch) index))]
    [(ast.AstDecl.DefEnum decl-meta name cleanup variants)
      (compiler-symbols-add-enum-cleanup-alias
        (compiler-symbols-add-variant-value-aliases
          (compiler-symbols-add-type-alias-key-id
            symbols
            (compiler-symbol-module-key-id-by-id alias-id name)
            (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
          alias-id
          name
          variants
          index
          0)
        alias-id
        cleanup
        index)]
    [(ast.AstDecl.DefEnumLifetimes decl-meta name _ cleanup variants)
      (compiler-symbols-add-enum-cleanup-alias
        (compiler-symbols-add-variant-value-aliases
          (compiler-symbols-add-type-alias-key-id
            symbols
            (compiler-symbol-module-key-id-by-id alias-id name)
            (compiler-symbol-make-handle (compiler-symbol-kind-defenum) index))
          alias-id
          name
          variants
          index
          0)
        alias-id
        cleanup
        index)]
    [(ast.AstDecl.DefStruct decl-meta name _ cleanup _)
      (compiler-symbols-add-struct-cleanup-alias
        (compiler-symbols-add-value-alias-key-id
          (compiler-symbols-add-type-alias-key-id
            symbols
            (compiler-symbol-module-key-id-by-id alias-id name)
            (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
          (compiler-symbol-module-key-id-by-id alias-id name)
          (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        alias-id
        cleanup
        index)]
    [(ast.AstDecl.DefStructLifetimes decl-meta name _ _ cleanup _)
      (compiler-symbols-add-struct-cleanup-alias
        (compiler-symbols-add-value-alias-key-id
          (compiler-symbols-add-type-alias-key-id
            symbols
            (compiler-symbol-module-key-id-by-id alias-id name)
            (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
          (compiler-symbol-module-key-id-by-id alias-id name)
          (compiler-symbol-make-handle (compiler-symbol-kind-defstruct) index))
        alias-id
        cleanup
        index)]
    [(ast.AstDecl.Unsafe inner-box)
      (let
        [inner : ast.AstDecl (__tl-box-place inner-box)]
        (compiler-symbols-add-decl-alias-in-module symbols alias-id inner index))]
    [(ast.AstDecl.ModuleBody _ _) symbols]
    [_ symbols]))

(define (compiler-symbols-remove-decl-macro-alias
  [symbols : CompilerSymbols]
  [decl : ast.AstDecl]
  [index : i64]) : CompilerSymbols
  (match decl
    [(ast.AstDecl.DefMacro decl-meta name _ _ _)
      (compiler-symbols-remove-macro-alias-if-handle
        symbols
        name
        (compiler-symbol-make-handle (compiler-symbol-kind-defmacro) index))]
    [(ast.AstDecl.Unsafe inner-box)
      (let
        [inner : ast.AstDecl (__tl-box-place inner-box)]
        (compiler-symbols-remove-decl-macro-alias symbols inner index))]
    [_ symbols]))

(define (compiler-symbols-macro-module-set-add-decl
  [modules : sym_i64_env.SymI64Env]
  [module-id : i64]
  [decl : ast.AstDecl]) : sym_i64_env.SymI64Env
  (match decl
    [(ast.AstDecl.DefMacro decl-meta _ _ _ _)
      (if (sym_i64_env.sym-i64-contains-id modules module-id)
        modules
        (sym_i64_env.sym-i64-bind-id modules module-id 1))]
    [(ast.AstDecl.Unsafe inner-box)
      (let
        [inner : ast.AstDecl (__tl-box-place inner-box)]
        (compiler-symbols-macro-module-set-add-decl modules module-id inner))]
    [(ast.AstDecl.ModuleBody name body-box)
      (compiler-symbols-macro-module-set-list
        (__tl-box-place body-box)
        name
        modules)]
    [_ modules]))

(define (compiler-symbols-macro-module-set-list
  [decls : ast.AstDeclList]
  [module-id : i64]
  [modules : sym_i64_env.SymI64Env]) : sym_i64_env.SymI64Env
  (let
    [cur-modules : sym_i64_env.SymI64Env modules]
    [cur-module : i64 module-id]
    [index : i64 0]
    [decl-count : i64 (ast.ast-decl-list-len (& decls))]
    [decl-offset : i64 decls.offset]
    (begin
      (while (< index decl-count)
        (let
          [decl : ast.AstDecl (array-ref decls.slots (+ decl-offset index))]
          (begin
            (match decl
              [(ast.AstDecl.Module next-module) (set! cur-module next-module)]
              [(ast.AstDecl.Import decl-meta _) unit]
              [(ast.AstDecl.IncludeStr _ _) unit]
              [(ast.AstDecl.IncludeStrComptime _ _) unit]
              [(ast.AstDecl.IncludeStrLzss _ _) unit]
              [(ast.AstDecl.IncludeBin _ _) unit]
              [(ast.AstDecl.Test _ _ _) unit]
              [_
                (set!
                  cur-modules
                  (compiler-symbols-macro-module-set-add-decl
                    cur-modules
                    cur-module
                    decl))])
            (set! index (+ index 1)))))
      cur-modules)))

(define (compiler-symbols-macro-module-set [decls : ast.AstDeclList]) : sym_i64_env.SymI64Env
  (compiler-symbols-macro-module-set-list
    decls
    (compiler-symbol-root-module-id)
    (sym_i64_env.sym-i64-empty)))

(define (compiler-symbols-module-owner-map-add
  [modules : sym_i64_env.SymI64Env]
  [module-id : i64]
  [owner-id : i64]) : sym_i64_env.SymI64Env
  (if (or (< module-id 0) (sym_i64_env.sym-i64-contains-id modules module-id))
    modules
    (sym_i64_env.sym-i64-bind-id modules module-id owner-id)))

(define (compiler-symbols-dotted-import-module-set-add-target
  [modules : sym_i64_env.SymI64Env]
  [target-module : i64]) : sym_i64_env.SymI64Env
  (if (sym_i64_env.sym-i64-contains-id modules target-module)
    modules
    (let
      [with-target : sym_i64_env.SymI64Env
        (sym_i64_env.sym-i64-bind-id modules target-module target-module)]
      [target-name : String
        (ci.intern-syntax-name-text-or target-module "<structural-module>")]
      [with-generated : sym_i64_env.SymI64Env
        (match (ci.intern-generated-canonical-lookup target-name)
          [(InternLookupFound generated-id)
            (compiler-symbols-module-owner-map-add
              with-target
              generated-id
              target-module)]
          [(InternLookupMissing) with-target])]
      with-generated)))

(define (compiler-symbols-dotted-suffix-owner-module-id
  [modules : sym_i64_env.SymI64Env]
  [path-owner-id : i64]) : i64
  (if (< path-owner-id 0)
    -1
    (let
      [suffix-id : i64 (ci.intern-dotted-tail-id path-owner-id)]
      (begin
        (while (>= suffix-id 0)
          (let
            [suffix-owner : i64
              (sym_i64_env.sym-i64-lookup-id-or modules suffix-id -1)]
            (if (>= suffix-owner 0)
              (return suffix-owner)
              (set! suffix-id (ci.intern-dotted-tail-id suffix-id)))))
        -1))))

(define (compiler-symbols-dotted-path-owner-module-id
  [modules : sym_i64_env.SymI64Env]
  [path-owner-id : i64]) : i64
  (let
    [exact-owner : i64
      (sym_i64_env.sym-i64-lookup-id-or modules path-owner-id -1)]
    [suffix-owner : i64
      (compiler-symbols-dotted-suffix-owner-module-id modules path-owner-id)]
    (cond [(>= exact-owner 0) exact-owner] [else suffix-owner])))

(defstruct CompilerSymbolsModuleSets
  (macro-modules sym_i64_env.SymI64Env)
  (dotted-modules sym_i64_env.SymI64Env))

(define (compiler-symbols-module-sets-list
  [decls : ast.AstDeclList]
  [module-id : i64]
  [sets : CompilerSymbolsModuleSets]) : CompilerSymbolsModuleSets
  (let
    [macro-modules : sym_i64_env.SymI64Env sets.macro-modules]
    [dotted-modules : sym_i64_env.SymI64Env sets.dotted-modules]
    [cur-module : i64 module-id]
    [index : i64 0]
    [decl-count : i64 (ast.ast-decl-list-len (& decls))]
    [decl-offset : i64 decls.offset]
    (begin
      (while (< index decl-count)
        (let
          [decl : ast.AstDecl (array-ref decls.slots (+ decl-offset index))]
          (begin
            (match decl
              [(ast.AstDecl.Module next-module) (set! cur-module next-module)]
              [(ast.AstDecl.Import
                  decl-meta
                  (ast.AstImportSpec.Spec
                    _
                    _
                    (ast.AstMaybeModuleName.Some target-module)
                    _
                    _))
                (set!
                  dotted-modules
                  (compiler-symbols-dotted-import-module-set-add-target
                    dotted-modules
                    target-module))]
              [(ast.AstDecl.Import decl-meta _) unit]
              [(ast.AstDecl.ModuleBody name body-box)
                (let
                  [nested : CompilerSymbolsModuleSets
                    (compiler-symbols-module-sets-list
                      (__tl-box-place body-box)
                      name
                      (CompilerSymbolsModuleSets macro-modules dotted-modules))]
                  (begin
                    (set! macro-modules nested.macro-modules)
                    (set! dotted-modules nested.dotted-modules)))]
              [(ast.AstDecl.IncludeStr _ _) unit]
              [(ast.AstDecl.IncludeStrComptime _ _) unit]
              [(ast.AstDecl.IncludeStrLzss _ _) unit]
              [(ast.AstDecl.IncludeBin _ _) unit]
              [(ast.AstDecl.Test _ _ _) unit]
              [_
                (set!
                  macro-modules
                  (compiler-symbols-macro-module-set-add-decl
                    macro-modules
                    cur-module
                    decl))])
            (set! index (+ index 1)))))
      (CompilerSymbolsModuleSets macro-modules dotted-modules))))

(define (compiler-symbols-module-sets [decls : ast.AstDeclList]) : CompilerSymbolsModuleSets
  (compiler-symbols-module-sets-list
    decls
    (compiler-symbol-root-module-id)
    (CompilerSymbolsModuleSets
      (sym_i64_env.sym-i64-empty)
      (sym_i64_env.sym-i64-empty))))

;; An explicit `module ... as alias` import resolves dotted uses through the
;; import target directly. It should not leave the module's legacy bare macro
;; alias in the importer.
;; Real (non-Import/Module/Test) decls grouped by their enclosing module, built
;; once so alias installation touches only a module's own decls instead of
;; rescanning every decl in the program per import. Installing aliases for M
;; imported modules over a program of N decls was O(M*N) per symbol-table build
;; (and the table is rebuilt many times across a self-compile); the index makes
;; it O(N) to build plus O(decls-in-target-module) per import.
;;
;; Fields: mod-ids[slot] and mod-head[slot] are a small module-id -> head-entry
;; association (module counts are tiny, so a linear probe beats a hashmap here);
;; num-modules is its length. Per-module entries chain forward in decl order via
;; ent-next (-1 terminates); ent-pos[k] is the decl's index in `decls` and
;; ent-ridx[k] is the global real-decl ordinal the alias handles are keyed by --
;; both identical to the ordinals the previous whole-program scans produced.
(defenum ModuleDeclIndex
  (ModuleDeclIndex
    (__tl_dyn-array i64)
    (__tl_dyn-array i64)
    i64
    (__tl_dyn-array i64)
    (__tl_dyn-array i64)
    (__tl_dyn-array i64)))

;; Linear probe for `module-id` in the first `num-modules` slots of `mod-ids`;
;; returns its slot or -1. Extracted from the index builder so that hot loop
;; keeps fewer values live at once.
(define (compiler-module-index-find-slot
  [mod-ids : (__tl_dyn-array i64)]
  [num-modules : i64]
  [module-id : i64]) : i64
  (let
    [i : i64 0]
    [slot : i64 -1]
    (begin
      (while (< i num-modules)
        (if (= (array-ref mod-ids i) module-id)
          (begin
            (set! slot i)
            (set! i num-modules))
          (set! i (+ i 1))))
      slot)))

(define (compiler-symbols-build-module-decl-index [decls : ast.AstDeclList]) : ModuleDeclIndex
  (let
    [decl-count : i64 (ast.ast-decl-list-len (& decls))]
    [cap : i64
      (if (> decl-count 0)
        decl-count
        1)]
    [decl-offset : i64 decls.offset]
    [slots : (__tl_dyn-array ast.AstDecl) decls.slots]
    [mod-ids : (__tl_dyn-array i64) (__tl_make-array i64 cap)]
    [mod-head : (__tl_dyn-array i64) (__tl_make-array i64 cap)]
    [mod-tail : (__tl_dyn-array i64) (__tl_make-array i64 cap)]
    [ent-pos : (__tl_dyn-array i64) (__tl_make-array i64 cap)]
    [ent-ridx : (__tl_dyn-array i64) (__tl_make-array i64 cap)]
    [ent-next : (__tl_dyn-array i64) (__tl_make-array i64 cap)]
    [num-modules : i64 0]
    [num-entries : i64 0]
    [real-index : i64 0]
    [cur-module : i64 (compiler-symbol-root-module-id)]
    ;; Decls arrive grouped by module, so the linear find-slot probe only
    ;; needs to run when a Module decl switches cur-module; -1 marks the
    ;; memo stale. Slot assignment order (first appearance) is unchanged.
    [cur-slot : i64 -1]
    [position : i64 0]
    (begin
      (while (< position decl-count)
        (begin
          (match (array-ref slots (+ decl-offset position))
            [(ast.AstDecl.Import decl-meta _) unit]
            [(ast.AstDecl.IncludeStr _ _) unit]
            [(ast.AstDecl.IncludeStrComptime _ _) unit]
            [(ast.AstDecl.IncludeStrLzss _ _) unit]
            [(ast.AstDecl.IncludeBin _ _) unit]
            [(ast.AstDecl.Module next-module)
              (begin
                (set! cur-module next-module)
                (set! cur-slot -1))]
            [(ast.AstDecl.Test _ _ _) unit]
            [_
              (let
                [slot : i64
                  (if (>= cur-slot 0)
                    cur-slot
                    (compiler-module-index-find-slot
                      mod-ids
                      num-modules
                      cur-module))]
                (begin
                  (if (< slot 0)
                    (begin
                      (set! slot num-modules)
                      (set! (array-ref mod-ids num-modules) cur-module)
                      (set! (array-ref mod-head num-modules) -1)
                      (set! (array-ref mod-tail num-modules) -1)
                      (set! num-modules (+ num-modules 1)))
                    unit)
                  (set! cur-slot slot)
                  (set! (array-ref ent-pos num-entries) position)
                  (set! (array-ref ent-ridx num-entries) real-index)
                  (set! (array-ref ent-next num-entries) -1)
                  (if (< (array-ref mod-head slot) 0)
                    (begin
                      (set! (array-ref mod-head slot) num-entries)
                      (set! (array-ref mod-tail slot) num-entries))
                    (begin
                      (set!
                        (array-ref ent-next (array-ref mod-tail slot))
                        num-entries)
                      (set! (array-ref mod-tail slot) num-entries)))
                  (set! num-entries (+ num-entries 1))
                  (set! real-index (+ real-index 1))))])
          (set! position (+ position 1))))
      (ModuleDeclIndex mod-ids mod-head num-modules ent-pos ent-ridx ent-next))))

(define (compiler-module-decl-index-head
  [index : ModuleDeclIndex]
  [module-id : i64]) : i64
  (match index
    [(ModuleDeclIndex mod-ids mod-head num-modules _ _ _)
      (let
        [i : i64 0]
        [head : i64 -1]
        (begin
          (while (< i num-modules)
            (if (= (array-ref mod-ids i) module-id)
              (begin
                (set! head (array-ref mod-head i))
                (set! i num-modules))
              (set! i (+ i 1))))
          head))]))

(define (compiler-symbols-module-has-macro-map?
  [symbols : CompilerSymbols]
  [target-module-id : i64]) : bool
  (match symbols
    [(CompilerSymbols _ _ macros _ _ _)
      (let
        [capacity : i64 (array-length macros.keys)]
        [index : i64 0]
        (begin
          (while (< index capacity)
            (if (> (array-ref macros.keys index) 0)
              (let
                [handle : i64 (array-ref macros.values index)]
                (when
                  (and
                    (=
                      (compiler-symbol-handle-kind handle)
                      (compiler-symbol-kind-defmacro))
                    (=
                      (compiler-symbols-owner-module-id-at-index-or
                        symbols
                        (compiler-symbol-handle-index handle)
                        (compiler-symbol-root-module-id))
                      target-module-id))
                  (return true)))
              unit)
            (set! index (+ index 1)))
          false))]))

(define (compiler-symbols-remove-module-macro-aliases-from-map
  [symbols : CompilerSymbols]
  [target-module-id : i64]) : CompilerSymbols
  (match symbols
    [(CompilerSymbols _ _ macros decls _ _)
      (let
        [capacity : i64 (array-length macros.keys)]
        [cur-symbols : CompilerSymbols symbols]
        [index : i64 0]
        (begin
          (while (< index capacity)
            (if (> (array-ref macros.keys index) 0)
              (let
                [handle : i64 (array-ref macros.values index)]
                [decl-index : i64 (compiler-symbol-handle-index handle)]
                (if (and
                  (>= decl-index 0)
                  (< decl-index (compiler-symbols-decl-count cur-symbols))
                  (=
                    (compiler-symbol-handle-kind handle)
                    (compiler-symbol-kind-defmacro))
                  (=
                    (compiler-symbols-owner-module-id-at-index-or
                      cur-symbols
                      decl-index
                      (compiler-symbol-root-module-id))
                    target-module-id))
                  (set!
                    cur-symbols
                    (compiler-symbols-remove-decl-macro-alias
                      cur-symbols
                      (array-ref decls decl-index)
                      decl-index))
                  unit))
              unit)
            (set! index (+ index 1)))
          cur-symbols))]))

(define (compiler-symbols-remove-module-macro-aliases-indexed
  [symbols : CompilerSymbols]
  [decls : ast.AstDeclList]
  [index : ModuleDeclIndex]
  [target-module-id : i64]
  [handle-index-offset : i64]) : CompilerSymbols
  (match index
    [(ModuleDeclIndex _ _ _ ent-pos ent-ridx ent-next)
      (let
        [decl-offset : i64 decls.offset]
        [slots : (__tl_dyn-array ast.AstDecl) decls.slots]
        [cur-symbols : CompilerSymbols symbols]
        [k : i64 (compiler-module-decl-index-head index target-module-id)]
        (begin
          (if (< k 0)
            (set!
              cur-symbols
              (compiler-symbols-remove-module-macro-aliases-from-map
                cur-symbols
                target-module-id))
            unit)
          (while (>= k 0)
            (begin
              (set!
                cur-symbols
                (compiler-symbols-remove-decl-macro-alias
                  cur-symbols
                  (array-ref slots (+ decl-offset (array-ref ent-pos k)))
                  (+ handle-index-offset (array-ref ent-ridx k))))
              (set! k (array-ref ent-next k))))
          cur-symbols))]))

(define (compiler-symbols-add-module-aliases-indexed
  [symbols : CompilerSymbols]
  [decls : ast.AstDeclList]
  [index : ModuleDeclIndex]
  [target-module-id : i64]
  [alias-id : i64]
  [handle-index-offset : i64]) : CompilerSymbols
  (match index
    [(ModuleDeclIndex _ _ _ ent-pos ent-ridx ent-next)
      (let
        [decl-offset : i64 decls.offset]
        [slots : (__tl_dyn-array ast.AstDecl) decls.slots]
        [cur-symbols : CompilerSymbols symbols]
        [k : i64 (compiler-module-decl-index-head index target-module-id)]
        (begin
          (while (>= k 0)
            (begin
              (set!
                cur-symbols
                (compiler-symbols-add-decl-alias-in-module
                  cur-symbols
                  alias-id
                  (array-ref slots (+ decl-offset (array-ref ent-pos k)))
                  (+ handle-index-offset (array-ref ent-ridx k))))
              (set! k (array-ref ent-next k))))
          cur-symbols))]))

(define (compiler-symbols-import-alias-key-id
  [importer-module : i64]
  [alias : i64]) : i64
  (if (= alias cbi.compiler-builtin-id-fix-empty)
    importer-module
    alias))

(define (compiler-symbols-add-selected-item-alias
  [symbols : CompilerSymbols]
  [target-module-id : i64]
  [item-id : i64]
  [importer-module-id : i64]
  [alias-id : i64]) : CompilerSymbols
  (let
    [alias-key : i64
      (compiler-symbol-module-key-id-by-id importer-module-id alias-id)]
    [value-handle : option_i64.Option
      (compiler-symbols-lookup-value-in-module-id
        symbols
        target-module-id
        item-id)]
    [type-handle : option_i64.Option
      (compiler-symbols-lookup-type-in-module-id
        symbols
        target-module-id
        item-id)]
    [macro-handle : option_i64.Option
      (compiler-symbols-lookup-macro-in-module-id
        symbols
        target-module-id
        item-id)]
    [with-value : CompilerSymbols
      (match value-handle
        [(option_i64.Some handle)
          (compiler-symbols-add-value-alias-key-id symbols alias-key handle)]
        [(option_i64.None) symbols])]
    [with-type : CompilerSymbols
      (match type-handle
        [(option_i64.Some handle)
          (compiler-symbols-add-type-alias-key-id with-value alias-key handle)]
        [(option_i64.None) with-value])]
    (match macro-handle
      [(option_i64.Some handle)
        (compiler-symbols-add-macro-alias-key-id with-type alias-key handle)]
      [(option_i64.None) with-type])))

(define (build-compiler-symbol-aliases-list-with-index-offset
  [all-decls : ast.AstDeclList]
  [decls : ast.AstDeclList]
  [symbols : CompilerSymbols]
  [module-id : i64]
  [macro-modules : sym_i64_env.SymI64Env]
  [handle-index-offset : i64]) : CompilerSymbols
  (let
    [cur-symbols : CompilerSymbols symbols]
    [cur-module-id : i64 module-id]
    [index : i64 0]
    [decl-count : i64 (ast.ast-decl-list-len (& decls))]
    [decl-offset : i64 decls.offset]
    [decl-index : ModuleDeclIndex
      (compiler-symbols-build-module-decl-index all-decls)]
    (begin
      (while (< index decl-count)
        (let
          [decl : ast.AstDecl (array-ref decls.slots (+ decl-offset index))]
          [next-symbols : CompilerSymbols
            (match decl
              [(ast.AstDecl.Import
                  decl-meta
                  (ast.AstImportSpec.Spec
                    (ast.AstImportKind.ModuleItem item)
                    _
                    (ast.AstMaybeModuleName.Some target-module)
                    (ast.AstMaybeImportAlias.Some alias)
                    _))
                (compiler-symbols-add-selected-item-alias
                  cur-symbols
                  target-module
                  item
                  cur-module-id
                  alias)]
              [(ast.AstDecl.Import
                  decl-meta
                  (ast.AstImportSpec.Spec
                    _
                    _
                    (ast.AstMaybeModuleName.Some target-module)
                    (ast.AstMaybeImportAlias.Some alias)
                    _))
                (let
                  [target-module-id : i64 target-module]
                  [target-has-macros : bool
                    (or
                      (sym_i64_env.sym-i64-contains-id
                        macro-modules
                        target-module-id)
                      (compiler-symbols-module-has-macro-map?
                        cur-symbols
                        target-module-id))]
                  [without-bare-macros : CompilerSymbols
                    (if target-has-macros
                      (compiler-symbols-remove-module-macro-aliases-indexed
                        cur-symbols
                        all-decls
                        decl-index
                        target-module-id
                        handle-index-offset)
                      cur-symbols)]
                  (if (= alias cbi.compiler-builtin-id-fix-empty)
                    (compiler-symbols-add-module-aliases-indexed
                      without-bare-macros
                      all-decls
                      decl-index
                      target-module-id
                      cur-module-id
                      handle-index-offset)
                    without-bare-macros))]
              [_ cur-symbols])]
          (begin
            (set! cur-symbols next-symbols)
            (match decl
              [(ast.AstDecl.Module next-module)
                (set! cur-module-id next-module)]
              [_ unit])
            (set! index (+ index 1)))))
      cur-symbols)))

(define (build-compiler-symbol-aliases-list
  [all-decls : ast.AstDeclList]
  [decls : ast.AstDeclList]
  [symbols : CompilerSymbols]
  [module-id : i64]
  [macro-modules : sym_i64_env.SymI64Env]) : CompilerSymbols
  (build-compiler-symbol-aliases-list-with-index-offset
    all-decls
    decls
    symbols
    module-id
    macro-modules
    0))

(define (build-compiler-symbol-list
  [decls : ast.AstDeclList]
  [symbols : CompilerSymbols]
  [index : i64]) : ResultCompilerSymbols
  (build-compiler-symbol-list-in-module
    decls
    decls
    symbols
    index
    (compiler-symbol-root-module-id)))

(define (compiler-symbol-decl-counts-for-index? [decl : ast.AstDecl]) : bool
  (match decl
    [(ast.AstDecl.Import decl-meta _) false]
    [(ast.AstDecl.IncludeStr _ _) false]
    [(ast.AstDecl.IncludeStrComptime _ _) false]
    [(ast.AstDecl.IncludeStrLzss _ _) false]
    [(ast.AstDecl.IncludeBin _ _) false]
    [(ast.AstDecl.Module _) false]
    [(ast.AstDecl.ModuleBody _ _) false]
    [(ast.AstDecl.Test _ _ _) false]
    [_ true]))

(define (compiler-symbol-path-list-repeat
  [decls : ast.AstDeclList]
  [path : String]
  [owner-id : i64]) : ast.AstDeclPathList
  (compiler-symbol-path-list-repeat-with-provenance
    decls
    path
    owner-id
    owner-id))

(define (compiler-symbol-path-list-repeat-with-provenance
  [decls : ast.AstDeclList]
  [path : String]
  [owner-id : i64]
  [provenance-id : i64]) : ast.AstDeclPathList
  (let
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [out : ast.AstDeclPathList (ast.ast-decl-path-list-with-capacity count)]
    [index : i64 0]
    (begin
      (while (< index count)
        (begin
          (ast.ast-decl-path-list-push-with-owner-and-provenance-id
            (&mut out)
            path
            owner-id
            provenance-id)
          (set! index (+ index 1))))
      out)))

(define (compiler-symbol-path-at-index
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [target : i64]
  [index : i64]) : String
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) ""]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        [decl-path : String
          (match (ast.ast-decl-path-list-step paths)
            [(ast.AstDeclPathListStep.Cons path _) path]
            [(ast.AstDeclPathListStep.Nil) ""])]
        [rest-paths : ast.AstDeclPathList
          (match (ast.ast-decl-path-list-step paths)
            [(ast.AstDeclPathListStep.Cons _ path-rest)
              (let
                [path-rest : ast.AstDeclPathList path-rest]
                path-rest)]
            [(ast.AstDeclPathListStep.Nil) (ast.ast-decl-path-list-new)])]
        (match decl
          [(ast.AstDecl.ModuleBody _ body-box)
            (let
              [body : ast.AstDeclList (__tl-box-place body-box)]
              [body-count : i64 (compiler-decl-list-index-count body)]
              (if (< target (+ index body-count))
                (compiler-symbol-path-at-index
                  body
                  (compiler-symbol-path-list-repeat
                    body
                    decl-path
                    (ast.ast-decl-path-list-owner-id
                      (& paths)
                      0
                      cbi.compiler-builtin-id-fix-empty))
                  target
                  index)
                (compiler-symbol-path-at-index
                  rest
                  rest-paths
                  target
                  (+ index body-count))))]
          [_
            (if (compiler-symbol-decl-counts-for-index? decl)
              (if (= target index)
                decl-path
                (compiler-symbol-path-at-index
                  rest
                  rest-paths
                  target
                  (+ index 1)))
              (compiler-symbol-path-at-index rest rest-paths target index))]))]))

(define (compiler-symbols-duplicate-location-suffix
  [first-path : String]
  [duplicate-path : String]) : String
  (if (> (string.string-length first-path) 0)
    (if (> (string.string-length duplicate-path) 0)
      (str_cat.str-cat
        " (first declared in "
        first-path
        "; duplicate in "
        duplicate-path
        ")")
      (str_cat.str-cat " (first declared in " first-path ")"))
    (if (> (string.string-length duplicate-path) 0)
      (str_cat.str-cat " (duplicate in " duplicate-path ")")
      "")))

(define (compiler-symbols-duplicate-value-message-with-paths
  [symbols : CompilerSymbols]
  [all-decls : ast.AstDeclList]
  [all-paths : ast.AstDeclPathList]
  [module-id : i64]
  [name-id : i64]
  [_index : i64]
  [decl-path : String]) : CompilerMaybeString
  (match (compiler-symbols-lookup-value-in-module-id symbols module-id name-id)
    [(option_i64.Some existing)
      (if (and
        (compiler-symbol-root-module-id? module-id)
        (compiler-symbols-handle-from-nonroot-owner? symbols existing))
        CompilerNoString
        (let
          [first-path : String
            (compiler-symbol-path-at-index
              all-decls
              all-paths
              (compiler-symbol-handle-index existing)
              0)]
          [display-name : String
            (compiler-symbol-module-key-by-id module-id name-id)]
          (CompilerSomeString
            (str_cat.str-cat
              (compiler-symbols-duplicate-value-message display-name)
              (compiler-symbols-duplicate-location-suffix first-path decl-path)))))]
    [(option_i64.None) CompilerNoString]))

(define (compiler-symbols-duplicate-value-message-for-decl-with-paths-id
  [symbols : CompilerSymbols]
  [all-decls : ast.AstDeclList]
  [all-paths : ast.AstDeclPathList]
  [module-id : i64]
  [decl : ast.AstDecl]
  [index : i64]
  [decl-path : String]) : CompilerMaybeString
  (match decl
    [(ast.AstDecl.Def decl-meta name _ _)
      (compiler-symbols-duplicate-value-message-with-paths
        symbols
        all-decls
        all-paths
        module-id
        name
        index
        decl-path)]
    [(ast.AstDecl.DefFn decl-meta name _ _ _ _)
      (compiler-symbols-duplicate-value-message-with-paths
        symbols
        all-decls
        all-paths
        module-id
        name
        index
        decl-path)]
    [(ast.AstDecl.Extern decl-meta name _ _ _)
      (compiler-symbols-duplicate-value-message-with-paths
        symbols
        all-decls
        all-paths
        module-id
        name
        index
        decl-path)]
    [(ast.AstDecl.DefDispatch decl-meta name _)
      (compiler-symbols-duplicate-value-message-with-paths
        symbols
        all-decls
        all-paths
        module-id
        name
        index
        decl-path)]
    [(ast.AstDecl.Unsafe inner-box)
      (let
        [inner : ast.AstDecl (__tl-box-place inner-box)]
        (compiler-symbols-duplicate-value-message-for-decl-with-paths-id
          symbols
          all-decls
          all-paths
          module-id
          inner
          index
          decl-path))]
    [_ CompilerNoString]))

(define (compiler-symbol-indexed-decl [decl : ast.AstDecl]) : ast.AstDecl
  (match decl
    [(ast.AstDecl.Unsafe inner-box)
      (let
        [inner : ast.AstDecl (__tl-box-place inner-box)]
        inner)]
    [_ decl]))

(define (compiler-symbol-owner-name-for-decl
  [decl : ast.AstDecl]
  [module-id : i64]) : String
  (match decl
    [(ast.AstDecl.Def decl-meta name _ _)
      (compiler-symbol-module-key-by-id module-id name)]
    [(ast.AstDecl.DefFn decl-meta name _ _ _ _)
      (compiler-symbol-module-key-by-id module-id name)]
    [(ast.AstDecl.Extern decl-meta name _ _ _)
      (compiler-symbol-module-key-by-id module-id name)]
    [(ast.AstDecl.DefMacro decl-meta name _ _ _)
      (compiler-symbol-module-key-by-id module-id name)]
    [(ast.AstDecl.DefDispatch decl-meta name _)
      (compiler-symbol-module-key-by-id module-id name)]
    [(ast.AstDecl.DefEnum decl-meta name _ _)
      (compiler-symbol-module-key-by-id module-id name)]
    [(ast.AstDecl.DefEnumLifetimes decl-meta name _ _ _)
      (compiler-symbol-module-key-by-id module-id name)]
    [(ast.AstDecl.DefStruct decl-meta name _ _ _)
      (compiler-symbol-module-key-by-id module-id name)]
    [(ast.AstDecl.DefStructLifetimes decl-meta name _ _ _ _)
      (compiler-symbol-module-key-by-id module-id name)]
    [_ ""]))

(define (compiler-symbol-owner-id-for-decl
  [decl : ast.AstDecl]
  [module-id : i64]) : i64
  (match decl
    [(ast.AstDecl.Def decl-meta name _ _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [(ast.AstDecl.DefFn decl-meta name _ _ _ _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [(ast.AstDecl.Extern decl-meta name _ _ _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [(ast.AstDecl.DefMacro decl-meta name _ _ _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [(ast.AstDecl.DefDispatch decl-meta name _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [(ast.AstDecl.DefEnum decl-meta name _ _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [(ast.AstDecl.DefEnumLifetimes decl-meta name _ _ _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [(ast.AstDecl.DefStruct decl-meta name _ _ _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [(ast.AstDecl.DefStructLifetimes decl-meta name _ _ _ _)
      (compiler-symbol-module-key-id-by-id module-id name)]
    [_ -1]))

(define (compiler-symbols-index-decl!
  [symbols : CompilerSymbols]
  [decl : ast.AstDecl]
  [index : i64]
  [module-id : i64]
  [provenance-id : i64]) : unit
  (let
    [indexed : ast.AstDecl (compiler-symbol-indexed-decl decl)]
    (begin
      (set! (array-ref (compiler-symbols-decls symbols) index) indexed)
      (set!
        (array-ref (compiler-symbols-owner-module-ids symbols) index)
        module-id)
      (set!
        (array-ref
          (compiler-symbols-owner-module-ids symbols)
          (+ (array-length (compiler-symbols-decls symbols)) index))
        provenance-id))))

(define (compiler-symbols-owner-module-id-at-index-or
  [symbols : CompilerSymbols]
  [target : i64]
  [fallback : i64]) : i64
  (let
    [owner-module-ids : (__tl_dyn-array i64)
      (compiler-symbols-owner-module-ids symbols)]
    (if (or (< target 0) (>= target (compiler-symbols-decl-count symbols)))
      fallback
      (array-ref owner-module-ids target))))

(define (compiler-symbols-provenance-id-at-index-or
  [symbols : CompilerSymbols]
  [target : i64]
  [fallback : i64]) : i64
  (let
    [owner-module-ids : (__tl_dyn-array i64)
      (compiler-symbols-owner-module-ids symbols)]
    (if (or (< target 0) (>= target (compiler-symbols-decl-count symbols)))
      fallback
      (array-ref
        owner-module-ids
        (+ (array-length (compiler-symbols-decls symbols)) target)))))

(define (compiler-symbols-owner-id-at-index-or
  [symbols : CompilerSymbols]
  [target : i64]
  [fallback : i64]) : i64
  (let
    [decls : (__tl_dyn-array ast.AstDecl) (compiler-symbols-decls symbols)]
    [owner-module-ids : (__tl_dyn-array i64)
      (compiler-symbols-owner-module-ids symbols)]
    (if (or (< target 0) (>= target (compiler-symbols-decl-count symbols)))
      fallback
      (let
        [owner-id : i64
          (compiler-symbol-owner-id-for-decl
            (array-ref decls target)
            (array-ref owner-module-ids target))]
        (if (< owner-id 0)
          fallback
          owner-id)))))

(define (compiler-symbols-owner-name-at-index
  [symbols : CompilerSymbols]
  [target : i64]) : CompilerMaybeString
  (let
    [decls : (__tl_dyn-array ast.AstDecl) (compiler-symbols-decls symbols)]
    [owner-module-ids : (__tl_dyn-array i64)
      (compiler-symbols-owner-module-ids symbols)]
    (if (or (< target 0) (>= target (compiler-symbols-decl-count symbols)))
      (CompilerNoString)
      (let
        [owner-name : String
          (compiler-symbol-owner-name-for-decl
            (array-ref decls target)
            (array-ref owner-module-ids target))]
        (if (> (string.string-length owner-name) 0)
          (CompilerSomeString owner-name)
          (CompilerNoString))))))

(define (build-compiler-symbol-list-in-module
  [all-decls : ast.AstDeclList]
  [decls : ast.AstDeclList]
  [symbols : CompilerSymbols]
  [index : i64]
  [module-id : i64]) : ResultCompilerSymbols
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) (ResultCompilerSymbols.Ok symbols)]
    [(ast.AstDeclListStep.Cons decl rest)
      (let
        [rest : ast.AstDeclList rest]
        (match decl
          [(ast.AstDecl.Import decl-meta _)
            (build-compiler-symbol-list-in-module
              all-decls
              rest
              symbols
              index
              module-id)]
          [(ast.AstDecl.IncludeStr _ _)
            (build-compiler-symbol-list-in-module
              all-decls
              rest
              symbols
              index
              module-id)]
          [(ast.AstDecl.IncludeStrComptime _ _)
            (build-compiler-symbol-list-in-module
              all-decls
              rest
              symbols
              index
              module-id)]
          [(ast.AstDecl.IncludeStrLzss _ _)
            (build-compiler-symbol-list-in-module
              all-decls
              rest
              symbols
              index
              module-id)]
          [(ast.AstDecl.IncludeBin _ _)
            (build-compiler-symbol-list-in-module
              all-decls
              rest
              symbols
              index
              module-id)]
          [(ast.AstDecl.Module next-module)
            (build-compiler-symbol-list-in-module
              all-decls
              rest
              symbols
              index
              next-module)]
          [(ast.AstDecl.ModuleBody name body-box)
            (let
              [body : ast.AstDeclList (__tl-box-place body-box)]
              [body-count : i64 (compiler-decl-list-index-count body)]
              (match (build-compiler-symbol-list-in-module
                all-decls
                body
                symbols
                index
                name)
                [(ResultCompilerSymbols.Ok body-symbols)
                  (build-compiler-symbol-list-in-module
                    all-decls
                    rest
                    body-symbols
                    (+ index body-count)
                    module-id)]
                [(ResultCompilerSymbols.Err message)
                  (ResultCompilerSymbols.Err message)]))]
          [(ast.AstDecl.Test _ _ _)
            (build-compiler-symbol-list-in-module
              all-decls
              rest
              symbols
              index
              module-id)]
          [_
            (begin
              (compiler-symbols-index-decl!
                symbols
                decl
                index
                module-id
                cbi.compiler-builtin-id-fix-empty)
              (match (compiler-symbols-add-decl-in-module
                symbols
                module-id
                decl
                index)
                [(ResultCompilerSymbols.Ok next-symbols)
                  (build-compiler-symbol-list-in-module
                    all-decls
                    rest
                    next-symbols
                    (+ index 1)
                    module-id)]
                [(ResultCompilerSymbols.Err message)
                  (ResultCompilerSymbols.Err message)]))]))]))

(define (build-compiler-symbol-list-with-paths-in-module
  [all-decls : ast.AstDeclList]
  [all-paths : ast.AstDeclPathList]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [symbols : CompilerSymbols]
  [dotted-modules : sym_i64_env.SymI64Env]
  [index : i64]
  [module-id : i64]) : ResultCompilerSymbols
  (let
    ;; The list-step match moves the cursor before its arm runs. Preserve the
    ;; original storage identity and track the source slot independently so a
    ;; declaration failure can still recover that declaration's cold origin.
    [decl-origin-key : i64
      (parser.compiler-parse-decl-list-storage-key (& decls))]
    [decl-origin-offset : i64 decls.offset]
    [cur-decls : ast.AstDeclList decls]
    [cur-paths : ast.AstDeclPathList paths]
    [cur-symbols : CompilerSymbols symbols]
    [cur-dotted-modules : sym_i64_env.SymI64Env dotted-modules]
    [cur-index : i64 index]
    [cur-position : i64 0]
    [cur-module-id : i64 module-id]
    [result : ResultCompilerSymbols
      (ResultCompilerSymbols.Err "symbols: internal decls walk")]
    [done : bool false]
    (begin
      (while (not done)
        (match (ast.ast-decl-list-step cur-decls)
          [(ast.AstDeclListStep.Nil)
            (begin
              (set! result (ResultCompilerSymbols.Ok cur-symbols))
              (set! done true))]
          [(ast.AstDeclListStep.Cons decl rest)
            (let
              [rest : ast.AstDeclList rest]
              [decl-path : String
                (match (ast.ast-decl-path-list-step cur-paths)
                  [(ast.AstDeclPathListStep.Cons path _) path]
                  [(ast.AstDeclPathListStep.Nil) ""])]
              [path-owner-id : i64
                (ast.ast-decl-path-list-owner-id
                  (& cur-paths)
                  0
                  cbi.compiler-builtin-id-fix-empty)]
              [path-provenance-id : i64
                (ast.ast-decl-path-list-provenance-id
                  (& cur-paths)
                  0
                  cbi.compiler-builtin-id-fix-empty)]
              [rest-paths : ast.AstDeclPathList
                (match (ast.ast-decl-path-list-step cur-paths)
                  [(ast.AstDeclPathListStep.Cons _ path-rest)
                    (let
                      [path-rest : ast.AstDeclPathList path-rest]
                      path-rest)]
                  [(ast.AstDeclPathListStep.Nil) (ast.ast-decl-path-list-new)])]
              (match decl
                [(ast.AstDecl.Import decl-meta _)
                  (begin
                    (set! cur-decls rest)
                    (set! cur-paths rest-paths)
                    (set! cur-position (+ cur-position 1)))]
                [(ast.AstDecl.IncludeStr _ _)
                  (begin
                    (set! cur-decls rest)
                    (set! cur-paths rest-paths)
                    (set! cur-position (+ cur-position 1)))]
                [(ast.AstDecl.IncludeStrComptime _ _)
                  (begin
                    (set! cur-decls rest)
                    (set! cur-paths rest-paths)
                    (set! cur-position (+ cur-position 1)))]
                [(ast.AstDecl.IncludeStrLzss _ _)
                  (begin
                    (set! cur-decls rest)
                    (set! cur-paths rest-paths)
                    (set! cur-position (+ cur-position 1)))]
                [(ast.AstDecl.IncludeBin _ _)
                  (begin
                    (set! cur-decls rest)
                    (set! cur-paths rest-paths)
                    (set! cur-position (+ cur-position 1)))]
                [(ast.AstDecl.Module next-module)
                  (begin
                    (set! cur-decls rest)
                    (set! cur-paths rest-paths)
                    (set! cur-position (+ cur-position 1))
                    (set! cur-module-id next-module))]
                [(ast.AstDecl.ModuleBody name body-box)
                  (let
                    [body : ast.AstDeclList (__tl-box-place body-box)]
                    [body-count : i64 (compiler-decl-list-index-count body)]
                    [body-paths : ast.AstDeclPathList
                      (compiler-symbol-path-list-repeat-with-provenance
                        body
                        decl-path
                        (ast.ast-decl-path-list-owner-id
                          (& cur-paths)
                          0
                          cbi.compiler-builtin-id-fix-empty)
                        path-provenance-id)]
                    (match (build-compiler-symbol-list-with-paths-in-module
                      all-decls
                      all-paths
                      body
                      body-paths
                      cur-symbols
                      cur-dotted-modules
                      cur-index
                      name)
                      [(ResultCompilerSymbols.Ok next-symbols)
                        (begin
                          (set! cur-decls rest)
                          (set! cur-paths rest-paths)
                          (set! cur-position (+ cur-position 1))
                          (set! cur-symbols next-symbols)
                          (set! cur-index (+ cur-index body-count)))]
                      [(ResultCompilerSymbols.Err message)
                        (begin
                          (set! result (ResultCompilerSymbols.Err message))
                          (set! done true))]))]
                [(ast.AstDecl.Test _ _ _)
                  (begin
                    (set! cur-decls rest)
                    (set! cur-paths rest-paths)
                    (set! cur-position (+ cur-position 1)))]
                [_
                  (match (compiler-symbols-duplicate-value-message-for-decl-with-paths-id
                    cur-symbols
                    all-decls
                    all-paths
                    cur-module-id
                    decl
                    cur-index
                    decl-path)
                    [(CompilerSomeString message)
                      (begin
                        (compiler-symbols-note-last-error!
                          decl-origin-key
                          (+ decl-origin-offset cur-position)
                          decl
                          decl-path)
                        (set! result (ResultCompilerSymbols.Err message))
                        (set! done true))]
                    [CompilerNoString
                      (begin
                        ;; Keep the cheap expression/member fallback current for
                        ;; later registry diagnostics. Cold declaration-origin
                        ;; lookup is deferred until this add actually fails.
                        (compiler-symbols-note-last-error-fallback!
                          decl
                          (& decl-path))
                        (compiler-symbols-index-decl!
                          cur-symbols
                          decl
                          cur-index
                          (if (and
                            ;; Source nominal declarations loaded through a
                            ;; legacy path retain their flat lookup aliases but
                            ;; share the dotted import's canonical owner.
                            (not (ast.ast-decl-comptime-only? decl))
                            (match decl
                              [(ast.AstDecl.DefEnum decl-meta _ _ _) true]
                              [(ast.AstDecl.DefEnumLifetimes decl-meta _ _ _ _)
                                true]
                              [_ false]))
                            (let
                              [resolved-owner : i64
                                (compiler-symbols-dotted-path-owner-module-id
                                  cur-dotted-modules
                                  path-owner-id)]
                              (if (>= resolved-owner 0)
                                (begin
                                  (set!
                                    cur-dotted-modules
                                    (sym_i64_env.sym-i64-bind-id
                                      cur-dotted-modules
                                      path-owner-id
                                      resolved-owner))
                                  resolved-owner)
                                cur-module-id))
                            cur-module-id)
                          path-provenance-id)
                        (match (compiler-symbols-add-decl-in-module
                          cur-symbols
                          cur-module-id
                          decl
                          cur-index)
                          [(ResultCompilerSymbols.Ok next-symbols)
                            (begin
                              (set! cur-decls rest)
                              (set! cur-paths rest-paths)
                              (set! cur-position (+ cur-position 1))
                              (set! cur-symbols next-symbols)
                              (set! cur-index (+ cur-index 1)))]
                          [(ResultCompilerSymbols.Err message)
                            (begin
                              (if compiler-symbols-last-error-has-span
                                unit
                                (compiler-symbols-note-last-error!
                                  decl-origin-key
                                  (+ decl-origin-offset cur-position)
                                  decl
                                  decl-path))
                              (set! result (ResultCompilerSymbols.Err message))
                              (set! done true))]))])]))]))
      result)))

(define (build-compiler-symbols [program : ast.AstProgram]) : ResultCompilerSymbols
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        (match (build-compiler-symbol-list
          decls
          (compiler-symbols-empty-with-decls
            (compiler-decl-list-index-count decls))
          0)
          [(ResultCompilerSymbols.Ok symbols)
            (let
              [macro-modules : sym_i64_env.SymI64Env
                (compiler-symbols-macro-module-set decls)]
              [aliased : CompilerSymbols
                (build-compiler-symbol-aliases-list
                  decls
                  decls
                  symbols
                  (compiler-symbol-root-module-id)
                  macro-modules)]
              (ResultCompilerSymbols.Ok aliased))]
          [(ResultCompilerSymbols.Err message)
            (ResultCompilerSymbols.Err message)]))]))

(define (build-compiler-symbols-with-paths-and-capacity
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [requested-capacity : i64]) : ResultCompilerSymbols
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        [module-sets : CompilerSymbolsModuleSets
          (compiler-symbols-module-sets decls)]
        [decl-count : i64 (compiler-decl-list-index-count decls)]
        (match (build-compiler-symbol-list-with-paths-in-module
          decls
          paths
          decls
          paths
          (compiler-symbols-empty-with-decls-and-capacity
            decl-count
            (if (> requested-capacity decl-count)
              requested-capacity
              decl-count))
          module-sets.dotted-modules
          0
          (compiler-symbol-root-module-id))
          [(ResultCompilerSymbols.Ok symbols)
            (let
              [aliased : CompilerSymbols
                (build-compiler-symbol-aliases-list
                  decls
                  decls
                  symbols
                  (compiler-symbol-root-module-id)
                  module-sets.macro-modules)]
              (ResultCompilerSymbols.Ok aliased))]
          [(ResultCompilerSymbols.Err message)
            (ResultCompilerSymbols.Err message)]))]))

(define (build-compiler-symbols-with-paths
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]) : ResultCompilerSymbols
  (build-compiler-symbols-with-paths-and-capacity program paths 0))

(define (build-compiler-symbols-diagnostic-with-paths
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]) : ResultCompilerSymbolsDiagnostic
  (begin
    (compiler-symbols-clear-last-error!)
    (match (build-compiler-symbols-with-paths program paths)
      [(ResultCompilerSymbols.Ok symbols)
        (ResultCompilerSymbolsDiagnostic.Ok symbols)]
      [(ResultCompilerSymbols.Err message)
        (ResultCompilerSymbolsDiagnostic.Err
          (box (compiler-symbols-last-error-diagnostic message)))])))

(define (build-compiler-symbols-diagnostic-with-paths-and-capacity
  [program : ast.AstProgram]
  [paths : ast.AstDeclPathList]
  [capacity : i64]) : ResultCompilerSymbolsDiagnostic
  (begin
    (compiler-symbols-clear-last-error!)
    (match (build-compiler-symbols-with-paths-and-capacity
      program
      paths
      capacity)
      [(ResultCompilerSymbols.Ok symbols)
        (ResultCompilerSymbolsDiagnostic.Ok symbols)]
      [(ResultCompilerSymbols.Err message)
        (ResultCompilerSymbolsDiagnostic.Err
          (box (compiler-symbols-last-error-diagnostic message)))])))

;; Extend the owned symbol storage with one additive splice. Existing handles
;; remain stable; new declarations receive handles at the old logical end. The
;; splice-local alias pass uses the same offset, so an unqualified marker that
;; imports the freshly generated module points at the appended declarations.
;; Callers keep the whole-program rebuild as the diagnostic fallback on error.
(define (compiler-symbols-decls-declare-module-id?
  [decls : ast.AstDeclList]
  [target-module-id : i64]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) false]
    [(ast.AstDeclListStep.Cons decl rest)
      (or
        (match decl
          [(ast.AstDecl.Module module-id) (= module-id target-module-id)]
          [(ast.AstDecl.ModuleBody module-id body-box)
            (or
              (= module-id target-module-id)
              (compiler-symbols-decls-declare-module-id?
                (__tl-box-place body-box)
                target-module-id))]
          [(ast.AstDecl.Unsafe inner-box)
            (match (__tl-box-place inner-box)
              [(ast.AstDecl.ModuleBody module-id body-box)
                (or
                  (= module-id target-module-id)
                  (compiler-symbols-decls-declare-module-id?
                    (__tl-box-place body-box)
                    target-module-id))]
              [_ false])]
          [_ false])
        (compiler-symbols-decls-declare-module-id? rest target-module-id))]))

(define (compiler-symbols-insert-import-safe?
  [all-decls : ast.AstDeclList]
  [target-module : i64]
  [alias : i64]) : bool
  (or
    (compiler-symbols-decls-declare-module-id? all-decls target-module)
    (not (= alias cbi.compiler-builtin-id-fix-empty))))

(define (compiler-symbols-insert-aliases-self-contained?
  [all-decls : ast.AstDeclList]
  [decls : ast.AstDeclList]) : bool
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) true]
    [(ast.AstDeclListStep.Cons decl rest)
      (and
        (match decl
          [(ast.AstDecl.Import
              decl-meta
              (ast.AstImportSpec.Spec
                _
                _
                (ast.AstMaybeModuleName.Some target-module)
                (ast.AstMaybeImportAlias.Some alias)
                _))
            (compiler-symbols-insert-import-safe? all-decls target-module alias)]
          [(ast.AstDecl.Import
              decl-meta
              (ast.AstImportSpec.Spec
                _
                _
                (ast.AstMaybeModuleName.Some _)
                (ast.AstMaybeImportAlias.No)
                _))
            true]
          ;; File-backed imports do not install symbol/registry aliases. The
          ;; macro walk materializes them immediately afterward; that path
          ;; intentionally performs the conservative whole-program rebuild.
          [(ast.AstDecl.Import decl-meta _) true]
          [(ast.AstDecl.ModuleBody _ body-box)
            (compiler-symbols-insert-aliases-self-contained?
              all-decls
              (__tl-box-place body-box))]
          [(ast.AstDecl.Unsafe inner-box)
            (match (__tl-box-place inner-box)
              [(ast.AstDecl.Import
                  decl-meta
                  (ast.AstImportSpec.Spec
                    _
                    _
                    (ast.AstMaybeModuleName.Some target-module)
                    (ast.AstMaybeImportAlias.Some alias)
                    _))
                (compiler-symbols-insert-import-safe?
                  all-decls
                  target-module
                  alias)]
              [(ast.AstDecl.Import
                  decl-meta
                  (ast.AstImportSpec.Spec
                    _
                    _
                    (ast.AstMaybeModuleName.Some _)
                    (ast.AstMaybeImportAlias.No)
                    _))
                true]
              [(ast.AstDecl.Import decl-meta _) true]
              [_ true])]
          [_ true])
        (compiler-symbols-insert-aliases-self-contained? all-decls rest))]))

(define (compiler-symbols-insert-decls
  [symbols : CompilerSymbols]
  [decls : ast.AstDeclList]
  [module-id : i64]) : ResultCompilerSymbols
  (let
    [old-count : i64 (compiler-symbols-decl-count symbols)]
    [added-count : i64 (compiler-decl-list-index-count decls)]
    [grown : CompilerSymbols
      (compiler-symbols-ensure-decl-capacity symbols (+ old-count added-count))]
    (match (build-compiler-symbol-list-in-module
      decls
      decls
      grown
      old-count
      module-id)
      [(ResultCompilerSymbols.Ok appended)
        (let
          [macro-modules : sym_i64_env.SymI64Env
            (compiler-symbols-macro-module-set decls)]
          [aliased : CompilerSymbols
            (build-compiler-symbol-aliases-list-with-index-offset
              decls
              decls
              appended
              module-id
              macro-modules
              old-count)]
          (ResultCompilerSymbols.Ok
            (compiler-symbols-with-decl-count aliased (+ old-count added-count))))]
      [(ResultCompilerSymbols.Err message) (ResultCompilerSymbols.Err message)])))

(define (build-compiler-symbols-from-source [src : String]) : ResultCompilerSymbols
  (match (parser.parse-ast-source src)
    [(parser.ResultAstProgram.Ok program) (build-compiler-symbols program)]
    [(parser.ResultAstProgram.Err message) (ResultCompilerSymbols.Err message)]))

(define (compiler-registries-lookup-variant-id
  [registries : CompilerRegistries]
  [name-id : i64]) : option_i64.Option
  (match registries
    [(CompilerRegistries variants _ _)
      (match (compiler-symbol-map-lookup-id
        (& variants)
        (compiler-symbol-name-id-key name-id))
        [(option_i64.Some handle) (option_i64.Some handle)]
        [(option_i64.None)
          (match (compiler-symbol-dotted-variant-key-id name-id)
            [(option_i64.Some key-id)
              (compiler-symbol-map-lookup-id (& variants) key-id)]
            [(option_i64.None) option_i64.None])])]))

(define (compiler-registries-lookup-variant-key-id
  [registries : CompilerRegistries]
  [key-id : i64]) : option_i64.Option
  (match registries
    [(CompilerRegistries variants _ _)
      (compiler-symbol-map-lookup-id (& variants) key-id)]))

(define (compiler-registries-lookup-struct-field-id
  [registries : CompilerRegistries]
  [struct-name-id : i64]
  [field-name-id : i64]) : option_i64.Option
  (match registries
    [(CompilerRegistries _ fields _)
      (compiler-symbol-map-lookup-id
        (& fields)
        (compiler-struct-field-key-id-by-id struct-name-id field-name-id))]))

(define (compiler-registries-lookup-variant-id-or
  [registries : CompilerRegistries]
  [name-id : i64]
  [fallback : i64]) : i64
  (match registries
    [(CompilerRegistries variants _ _)
      (let
        [handle : i64
          (compiler-symbol-map-lookup-handle-id
            (& variants)
            (compiler-symbol-name-id-key name-id))]
        (if (>= handle 0)
          handle
          (match (compiler-symbol-dotted-variant-key-id name-id)
            [(option_i64.Some key-id)
              (let
                [variant-handle : i64
                  (compiler-symbol-map-lookup-handle-id (& variants) key-id)]
                (if (>= variant-handle 0)
                  variant-handle
                  fallback))]
            [(option_i64.None) fallback])))]))

(define (compiler-registries-lookup-variant-key-id-or
  [registries : CompilerRegistries]
  [key-id : i64]
  [fallback : i64]) : i64
  (match registries
    [(CompilerRegistries variants _ _)
      (let
        [handle : i64
          (compiler-symbol-map-lookup-handle-id (& variants) key-id)]
        (if (>= handle 0)
          handle
          fallback))]))

(define (compiler-registries-lookup-struct-field-id-or
  [registries : CompilerRegistries]
  [struct-name-id : i64]
  [field-name-id : i64]
  [fallback : i64]) : i64
  (match registries
    [(CompilerRegistries _ fields _)
      (let
        [handle : i64
          (compiler-symbol-map-lookup-handle-id
            (& fields)
            (compiler-struct-field-key-id-by-id struct-name-id field-name-id))]
        (if (>= handle 0)
          handle
          fallback))]))

(define (compiler-registries-add-variant-in-module-id
  [registries : CompilerRegistries (:consume)]
  [module-id : i64]
  [enum-name-id : i64]
  [name-id : i64]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerRegistries
  (let
    [qualified-name-id : i64
      (compiler-enum-qualified-variant-name-id enum-name-id name-id)]
    [qualified-key-id : i64
      (compiler-symbol-module-key-id-by-id module-id qualified-name-id)]
    [qualified-display-name : String
      (compiler-symbol-module-key-by-id module-id qualified-name-id)]
    [module-name-key-id : i64
      (compiler-symbol-module-key-id-by-id module-id name-id)]
    [name-key-id : i64 (compiler-symbol-name-id-key name-id)]
    [handle : i64
      (compiler-registry-make-handle
        (compiler-symbol-kind-enum-variant)
        enum-index
        variant-index)]
    (match registries
      [(CompilerRegistries variants fields identity)
        (if (compiler-symbol-map-contains-id? (& variants) qualified-key-id)
          (ResultCompilerRegistries.Err
            (compiler-registries-duplicate-variant-message
              qualified-display-name))
          (begin
            (compiler-symbol-map-bind-id!
              (&mut variants)
              qualified-key-id
              handle)
            (let
              [aliases1 : CompilerRegistries
                (if (= module-name-key-id qualified-key-id)
                  (CompilerRegistries variants fields identity)
                  (compiler-registries-add-variant-alias-key-id
                    (CompilerRegistries variants fields identity)
                    module-name-key-id
                    handle))]
              [aliases2 : CompilerRegistries
                (if (or
                  (= name-key-id qualified-key-id)
                  (= name-key-id module-name-key-id))
                  aliases1
                  (compiler-registries-add-variant-alias-key-id
                    aliases1
                    name-key-id
                    handle))]
              (ResultCompilerRegistries.Ok aliases2))))])))

(define (compiler-registries-add-field-in-module-id
  [registries : CompilerRegistries (:consume)]
  [module-id : i64]
  [struct-name-id : i64]
  [field-name-id : i64]
  [struct-index : i64]
  [field-index : i64]) : ResultCompilerRegistries
  (match registries
    [(CompilerRegistries variants fields identity)
      (let
        [key-id : i64
          (compiler-struct-field-key-id-in-module-by-id
            module-id
            struct-name-id
            field-name-id)]
        (if (compiler-symbol-map-contains-id? (& fields) key-id)
          (ResultCompilerRegistries.Err
            (compiler-registries-duplicate-field-message
              (compiler-symbol-module-key-by-id module-id struct-name-id)
              (ci.intern-str field-name-id)))
          (begin
            (compiler-symbol-map-bind-id!
              (&mut fields)
              key-id
              (compiler-registry-make-handle
                (compiler-symbol-kind-struct-field)
                struct-index
                field-index))
            (ResultCompilerRegistries.Ok
              (CompilerRegistries variants fields identity)))))]))

(define (compiler-registries-add-field-alias
  [registries : CompilerRegistries (:consume)]
  [module-id : i64]
  [struct-name-id : i64]
  [field-name-id : i64]
  [handle : i64]) : CompilerRegistries
  (match registries
    [(CompilerRegistries variants fields identity)
      (let
        [key-id : i64
          (compiler-struct-field-key-id-in-module-by-id
            module-id
            struct-name-id
            field-name-id)]
        (if (compiler-symbol-map-contains-id? (& fields) key-id)
          registries
          (begin
            (compiler-symbol-map-bind-id! (&mut fields) key-id handle)
            (CompilerRegistries variants fields identity))))]))

(define (compiler-registries-add-variant-aliases-list
  [registries : CompilerRegistries]
  [alias-id : i64]
  [enum-name-id : i64]
  [variants : ast.AstVariantDefList]
  [enum-index : i64]
  [variant-index : i64]) : CompilerRegistries
  (if (>= variant-index (ast.ast-variant-def-list-len (& variants)))
    registries
    (match (ast.ast-variant-def-list-get
      (& variants)
      variant-index
      (ast.ast-variant-def-fallback))
      [(ast.AstVariantDef.Def name _ _)
        (let
          [qualified-name-id : i64
            (compiler-enum-qualified-variant-name-id enum-name-id name)]
          [handle : i64
            (compiler-registry-make-handle
              (compiler-symbol-kind-enum-variant)
              enum-index
              variant-index)]
          (compiler-registries-add-variant-aliases-list
            (compiler-registries-add-variant-alias-key-id
              (compiler-registries-add-variant-alias-key-id
                registries
                (compiler-symbol-module-key-id-by-id alias-id name)
                handle)
              (compiler-symbol-module-key-id-by-id alias-id qualified-name-id)
              handle)
            alias-id
            enum-name-id
            variants
            enum-index
            (+ variant-index 1)))])))

(define (compiler-registries-add-field-aliases-list
  [registries : CompilerRegistries]
  [module-id : i64]
  [struct-name-id : i64]
  [fields : ast.AstFieldDefList]
  [struct-index : i64]
  [field-index : i64]) : CompilerRegistries
  (if (>= field-index (ast.ast-field-def-list-len (& fields)))
    registries
    (match (ast.ast-field-def-list-get
      (& fields)
      field-index
      (ast.ast-field-def-fallback))
      [(ast.AstFieldDef.Def name _ _)
        (compiler-registries-add-field-aliases-list
          (compiler-registries-add-field-alias
            registries
            module-id
            struct-name-id
            name
            (compiler-registry-make-handle
              (compiler-symbol-kind-struct-field)
              struct-index
              field-index))
          module-id
          struct-name-id
          fields
          struct-index
          (+ field-index 1))])))

(define (compiler-registries-add-decl-alias-in-module
  [registries : CompilerRegistries]
  [alias-id : i64]
  [decl : ast.AstDecl]
  [index : i64]) : CompilerRegistries
  (match decl
    [(ast.AstDecl.DefEnum decl-meta name _ variants)
      (compiler-registries-add-variant-aliases-list
        registries
        alias-id
        name
        variants
        index
        0)]
    [(ast.AstDecl.DefEnumLifetimes decl-meta name _ _ variants)
      (compiler-registries-add-variant-aliases-list
        registries
        alias-id
        name
        variants
        index
        0)]
    [(ast.AstDecl.DefStruct decl-meta name _ _ fields)
      (compiler-registries-add-field-aliases-list
        registries
        alias-id
        name
        fields
        index
        0)]
    [(ast.AstDecl.DefStructLifetimes decl-meta name _ _ _ fields)
      (compiler-registries-add-field-aliases-list
        registries
        alias-id
        name
        fields
        index
        0)]
    [_ registries]))

(define (compiler-registries-add-module-aliases-indexed
  [registries : CompilerRegistries]
  [decls : ast.AstDeclList]
  [index : ModuleDeclIndex]
  [target-module-id : i64]
  [alias-id : i64]
  [handle-index-offset : i64]) : CompilerRegistries
  (match index
    [(ModuleDeclIndex _ _ _ ent-pos ent-ridx ent-next)
      (let
        [decl-offset : i64 decls.offset]
        [slots : (__tl_dyn-array ast.AstDecl) decls.slots]
        [cur-registries : CompilerRegistries registries]
        [k : i64 (compiler-module-decl-index-head index target-module-id)]
        (begin
          (while (>= k 0)
            (begin
              (set!
                cur-registries
                (compiler-registries-add-decl-alias-in-module
                  cur-registries
                  alias-id
                  (array-ref slots (+ decl-offset (array-ref ent-pos k)))
                  (+ handle-index-offset (array-ref ent-ridx k))))
              (set! k (array-ref ent-next k))))
          cur-registries))]))

(define (build-compiler-registry-aliases-list-with-index-offset
  [all-decls : ast.AstDeclList]
  [decls : ast.AstDeclList]
  [registries : CompilerRegistries]
  [module-id : i64]
  [handle-index-offset : i64]) : CompilerRegistries
  (let
    [enclosing-arena : i64 (arena.tl_arena_current)]
    [index-arena : i64 (arena.tl_arena_make)]
    [_switch-to-index : unit
      (unsafe
        (arena.tl_arena_set index-arena))]
    [decl-index : ModuleDeclIndex
      (compiler-symbols-build-module-decl-index all-decls)]
    [_restore-enclosing : unit
      (unsafe
        (arena.tl_arena_set enclosing-arena))]
    [result : CompilerRegistries
      (let
        [cur-registries : CompilerRegistries registries]
        [cur-module-id : i64 module-id]
        [index : i64 0]
        [decl-count : i64 (ast.ast-decl-list-len (& decls))]
        [decl-offset : i64 decls.offset]
        (begin
          (while (< index decl-count)
            (let
              [decl : ast.AstDecl (array-ref decls.slots (+ decl-offset index))]
              [next-registries : CompilerRegistries
                (match decl
                  [(ast.AstDecl.Import
                      decl-meta
                      (ast.AstImportSpec.Spec
                        _
                        _
                        (ast.AstMaybeModuleName.Some target-module)
                        (ast.AstMaybeImportAlias.Some alias)
                        _))
                    (if (= alias cbi.compiler-builtin-id-fix-empty)
                      (compiler-registries-add-module-aliases-indexed
                        cur-registries
                        all-decls
                        decl-index
                        target-module
                        (compiler-symbols-import-alias-key-id
                          cur-module-id
                          alias)
                        handle-index-offset)
                      cur-registries)]
                  [_ cur-registries])]
              (begin
                (set! cur-registries next-registries)
                (match decl
                  [(ast.AstDecl.Module next-module)
                    (set! cur-module-id next-module)]
                  [_ unit])
                (set! index (+ index 1)))))
          cur-registries))]
    (begin
      (unsafe
        (arena.tl_arena_destroy index-arena))
      result)))

(define (build-compiler-registry-aliases-list
  [all-decls : ast.AstDeclList]
  [decls : ast.AstDeclList]
  [registries : CompilerRegistries]
  [module-id : i64]) : CompilerRegistries
  (build-compiler-registry-aliases-list-with-index-offset
    all-decls
    decls
    registries
    module-id
    0))

(define (build-compiler-variant-registry-list-in-module
  [variants : ast.AstVariantDefList]
  [registries : CompilerRegistries]
  [module-id : i64]
  [path : String]
  [enum-name-id : i64]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerRegistries
  (if (>= variant-index (ast.ast-variant-def-list-len (& variants)))
    (ResultCompilerRegistries.Ok registries)
    (match (ast.ast-variant-def-list-get
      (& variants)
      variant-index
      (ast.ast-variant-def-fallback))
      [(ast.AstVariantDef.Def name _ _)
        (match (compiler-registries-add-variant-in-module-id
          registries
          module-id
          enum-name-id
          name
          enum-index
          variant-index)
          [(ResultCompilerRegistries.Ok next-registries)
            (build-compiler-variant-registry-list-in-module
              variants
              next-registries
              module-id
              path
              enum-name-id
              enum-index
              (+ variant-index 1))]
          [(ResultCompilerRegistries.Err message)
            (begin
              (set! compiler-symbols-last-error-path path)
              (compiler-symbols-note-last-error-member-span!
                (parser.compiler-parse-variant-def-list-span-get
                  (& variants)
                  variant-index
                  (ast.ast-decl-span-fallback)))
              (ResultCompilerRegistries.Err message))])])))

(define (build-compiler-field-registry-list
  [fields : ast.AstFieldDefList]
  [registries : CompilerRegistries]
  [seen : sym_i64_env.SymI64Env]
  [module-id : i64]
  [path : String]
  [struct-name-id : i64]
  [struct-index : i64]
  [field-index : i64]) : ResultCompilerRegistries
  (if (>= field-index (ast.ast-field-def-list-len (& fields)))
    (ResultCompilerRegistries.Ok registries)
    (match (ast.ast-field-def-list-get
      (& fields)
      field-index
      (ast.ast-field-def-fallback))
      [(ast.AstFieldDef.Def name _ _)
        (if (sym_i64_env.sym-i64-contains-id seen name)
          (begin
            (set! compiler-symbols-last-error-path path)
            (compiler-symbols-note-last-error-member-span!
              (parser.compiler-parse-field-def-list-span-get
                (& fields)
                field-index
                (ast.ast-decl-span-fallback)))
            (ResultCompilerRegistries.Err
              (compiler-registries-duplicate-field-message
                (compiler-symbol-module-key-by-id module-id struct-name-id)
                (ci.intern-str name))))
          (match (compiler-registries-add-field-in-module-id
            registries
            module-id
            struct-name-id
            name
            struct-index
            field-index)
            [(ResultCompilerRegistries.Ok next-registries)
              (build-compiler-field-registry-list
                fields
                next-registries
                (sym_i64_env.sym-i64-bind-id seen name field-index)
                module-id
                path
                struct-name-id
                struct-index
                (+ field-index 1))]
            [(ResultCompilerRegistries.Err message)
              (begin
                (set! compiler-symbols-last-error-path path)
                (compiler-symbols-note-last-error-member-span!
                  (parser.compiler-parse-field-def-list-span-get
                    (& fields)
                    field-index
                    (ast.ast-decl-span-fallback)))
                (ResultCompilerRegistries.Err message))]))])))

(define (build-compiler-registry-list-in-module
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [registries : CompilerRegistries]
  [index : i64]
  [module-id : i64]) : ResultCompilerRegistries
  (let
    [cur-registries : CompilerRegistries registries]
    [cur-index : i64 index]
    [cur-module-id : i64 module-id]
    [position : i64 0]
    [decl-count : i64 (ast.ast-decl-list-len (& decls))]
    [decl-offset : i64 decls.offset]
    [result : ResultCompilerRegistries
      (ResultCompilerRegistries.Err "symbols: internal registry walk")]
    [done : bool false]
    (begin
      (while (not done)
        (if (>= position decl-count)
          (begin
            (set! result (ResultCompilerRegistries.Ok cur-registries))
            (set! done true))
          (let
            [decl : ast.AstDecl
              (array-ref decls.slots (+ decl-offset position))]
            [decl-path : String
              (ast.ast-decl-path-list-get (& paths) position "")]
            (match decl
              [(ast.AstDecl.Import decl-meta _) (set! position (+ position 1))]
              [(ast.AstDecl.IncludeStr _ _) (set! position (+ position 1))]
              [(ast.AstDecl.IncludeStrComptime _ _)
                (set! position (+ position 1))]
              [(ast.AstDecl.IncludeStrLzss _ _) (set! position (+ position 1))]
              [(ast.AstDecl.IncludeBin _ _) (set! position (+ position 1))]
              [(ast.AstDecl.Module next-module)
                (begin
                  (set! position (+ position 1))
                  (set! cur-module-id next-module))]
              [(ast.AstDecl.ModuleBody name body-box)
                (let
                  [body : ast.AstDeclList (__tl-box-place body-box)]
                  [body-count : i64 (compiler-decl-list-index-count body)]
                  [body-paths : ast.AstDeclPathList
                    (compiler-symbol-path-list-repeat
                      body
                      decl-path
                      (ast.ast-decl-path-list-owner-id
                        (& paths)
                        position
                        cbi.compiler-builtin-id-fix-empty))]
                  (match (build-compiler-registry-list-in-module
                    body
                    body-paths
                    cur-registries
                    cur-index
                    name)
                    [(ResultCompilerRegistries.Ok next-registries)
                      (begin
                        (set! position (+ position 1))
                        (set! cur-registries next-registries)
                        (set! cur-index (+ cur-index body-count)))]
                    [(ResultCompilerRegistries.Err message)
                      (begin
                        (set! result (ResultCompilerRegistries.Err message))
                        (set! done true))]))]
              [(ast.AstDecl.Test _ _ _) (set! position (+ position 1))]
              [(ast.AstDecl.DefEnum decl-meta name _ variants)
                (match (build-compiler-variant-registry-list-in-module
                  variants
                  cur-registries
                  cur-module-id
                  decl-path
                  name
                  cur-index
                  0)
                  [(ResultCompilerRegistries.Ok next-registries)
                    (begin
                      (set! position (+ position 1))
                      (set! cur-registries next-registries)
                      (set! cur-index (+ cur-index 1)))]
                  [(ResultCompilerRegistries.Err message)
                    (begin
                      (set! result (ResultCompilerRegistries.Err message))
                      (set! done true))])]
              [(ast.AstDecl.DefEnumLifetimes decl-meta name _ _ variants)
                (match (build-compiler-variant-registry-list-in-module
                  variants
                  cur-registries
                  cur-module-id
                  decl-path
                  name
                  cur-index
                  0)
                  [(ResultCompilerRegistries.Ok next-registries)
                    (begin
                      (set! position (+ position 1))
                      (set! cur-registries next-registries)
                      (set! cur-index (+ cur-index 1)))]
                  [(ResultCompilerRegistries.Err message)
                    (begin
                      (set! result (ResultCompilerRegistries.Err message))
                      (set! done true))])]
              [(ast.AstDecl.DefStruct decl-meta name _ _ fields)
                (match (build-compiler-field-registry-list
                  fields
                  cur-registries
                  (sym_i64_env.sym-i64-empty)
                  cur-module-id
                  decl-path
                  name
                  cur-index
                  0)
                  [(ResultCompilerRegistries.Ok next-registries)
                    (begin
                      (set! position (+ position 1))
                      (set! cur-registries next-registries)
                      (set! cur-index (+ cur-index 1)))]
                  [(ResultCompilerRegistries.Err message)
                    (begin
                      (set! result (ResultCompilerRegistries.Err message))
                      (set! done true))])]
              [(ast.AstDecl.DefStructLifetimes decl-meta name _ _ _ fields)
                (match (build-compiler-field-registry-list
                  fields
                  cur-registries
                  (sym_i64_env.sym-i64-empty)
                  cur-module-id
                  decl-path
                  name
                  cur-index
                  0)
                  [(ResultCompilerRegistries.Ok next-registries)
                    (begin
                      (set! position (+ position 1))
                      (set! cur-registries next-registries)
                      (set! cur-index (+ cur-index 1)))]
                  [(ResultCompilerRegistries.Err message)
                    (begin
                      (set! result (ResultCompilerRegistries.Err message))
                      (set! done true))])]
              [_
                (begin
                  (set! position (+ position 1))
                  (set! cur-index (+ cur-index 1)))]))))
      result)))

(define (build-compiler-registries-for-decls-with-paths
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]) : ResultCompilerRegistries
  (match (build-compiler-registry-list-in-module
    decls
    paths
    (compiler-registries-empty)
    0
    (compiler-symbol-root-module-id))
    [(ResultCompilerRegistries.Ok registries)
      (let
        [aliased : CompilerRegistries
          (build-compiler-registry-aliases-list
            decls
            decls
            registries
            (compiler-symbol-root-module-id))]
        (ResultCompilerRegistries.Ok aliased))]
    [(ResultCompilerRegistries.Err message)
      (ResultCompilerRegistries.Err message)]))

(define (build-compiler-registries-with-symbols
  [program : ast.AstProgram]
  [_symbols : CompilerSymbols]) : ResultCompilerRegistries
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        (build-compiler-registries-for-decls-with-paths
          decls
          (compiler-symbol-path-list-repeat
            decls
            ""
            cbi.compiler-builtin-id-fix-empty)))]))

;; Registry handles encode the flattened declaration owner index. A generated
;; declaration splice before an existing owner therefore needs to move the
;; cached handle forward by the number of index-bearing declarations inserted.
;; Updating the maps in place is proportional to the registry, rather than to
;; the whole program, and preserves the ordinary positional-handle ABI used by
;; typechecking and lowering.
(define (compiler-registry-handle-shift-owner-index
  [handle : i64]
  [insertion-index : i64]
  [delta : i64]) : i64
  (let
    [owner-index : i64 (compiler-registry-handle-owner-index handle)]
    (if (>= owner-index insertion-index)
      (compiler-registry-make-handle
        (compiler-registry-handle-kind handle)
        (+ owner-index delta)
        (compiler-registry-handle-child-index handle))
      handle)))

(define (compiler-registry-shift-map-owner-indices!
  [map : (&mut map CompilerSymbolMap)]
  [insertion-index : i64]
  [delta : i64]) : unit
  (if (<= delta 0)
    unit
    (let
      [capacity : i64 (array-length map.keys)]
      [index : i64 0]
      (while (< index capacity)
        (begin
          (if (> (array-ref map.keys index) 0)
            (let
              [handle : i64 (array-ref map.values index)]
              (set!
                (array-ref map.values index)
                (compiler-registry-handle-shift-owner-index
                  handle
                  insertion-index
                  delta)))
            unit)
          (set! index (+ index 1)))))))

(define (compiler-registries-shift-owner-indices
  [registries : CompilerRegistries (:consume)]
  [insertion-index : i64]
  [delta : i64]) : CompilerRegistries
  (match registries
    [(CompilerRegistries variants fields identity)
      (begin
        (compiler-registry-shift-map-owner-indices!
          (&mut variants)
          insertion-index
          delta)
        (compiler-registry-shift-map-owner-indices!
          (&mut fields)
          insertion-index
          delta)
        (CompilerRegistries variants fields identity))]))

;; Extend an existing registry across an additive declaration splice. Callers
;; must conservatively reject imports and other surfaces that can alter alias
;; resolution; this helper only repairs positional owner handles and registers
;; the declarations newly inserted at `insertion-index`.
(define (compiler-registries-insert-decls
  [registries : CompilerRegistries]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [insertion-index : i64]
  [module-id : i64]) : ResultCompilerRegistries
  (let
    [added-count : i64 (compiler-decl-list-index-count decls)]
    [shifted : CompilerRegistries
      (compiler-registries-shift-owner-indices
        registries
        insertion-index
        added-count)]
    (build-compiler-registry-list-in-module
      decls
      paths
      shifted
      insertion-index
      module-id)))

;; Companion to compiler-symbols-insert-decls: when symbol handles append, new
;; registry owners use the same append index and no existing owner shifts.
(define (compiler-registries-append-decls
  [registries : CompilerRegistries]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [append-index : i64]
  [module-id : i64]) : ResultCompilerRegistries
  (match (build-compiler-registry-list-in-module
    decls
    paths
    registries
    append-index
    module-id)
    [(ResultCompilerRegistries.Ok appended)
      (ResultCompilerRegistries.Ok
        (build-compiler-registry-aliases-list-with-index-offset
          decls
          decls
          appended
          module-id
          append-index))]
    [(ResultCompilerRegistries.Err message)
      (ResultCompilerRegistries.Err message)]))

(define (build-compiler-registries-diagnostic-with-symbols-and-paths
  [program : ast.AstProgram]
  [_symbols : CompilerSymbols]
  [paths : ast.AstDeclPathList]) : ResultCompilerRegistriesDiagnostic
  (begin
    (compiler-symbols-clear-last-error!)
    (match program
      [(ast.AstProgram.Program decls-box)
        (let
          [decls : ast.AstDeclList (__tl-box-place decls-box)]
          (match (build-compiler-registries-for-decls-with-paths decls paths)
            [(ResultCompilerRegistries.Ok registries)
              (ResultCompilerRegistriesDiagnostic.Ok registries)]
            [(ResultCompilerRegistries.Err message)
              (ResultCompilerRegistriesDiagnostic.Err
                (box (compiler-symbols-last-error-diagnostic message)))]))])))

(define (build-compiler-registries [program : ast.AstProgram]) : ResultCompilerRegistries
  (match (build-compiler-symbols program)
    [(ResultCompilerSymbols.Ok symbols)
      (build-compiler-registries-with-symbols program symbols)]
    [(ResultCompilerSymbols.Err message) (ResultCompilerRegistries.Err message)]))

(define (build-compiler-registries-from-source [src : String]) : ResultCompilerRegistries
  (match (parser.parse-ast-source src)
    [(parser.ResultAstProgram.Ok program) (build-compiler-registries program)]
    [(parser.ResultAstProgram.Err message)
      (ResultCompilerRegistries.Err message)]))

(define (compiler-decl-list-at-index
  [decls : ast.AstDeclList]
  [target : i64]
  [index : i64]) : parser.ResultAstDecl
  (let
    [slot : i64 0]
    [logical-index : i64 index]
    [decl-count : i64 (ast.ast-decl-list-len (& decls))]
    [decl-offset : i64 decls.offset]
    (begin
      (while (< slot decl-count)
        (let
          [decl : ast.AstDecl (array-ref decls.slots (+ decl-offset slot))]
          (begin
            (match decl
              [(ast.AstDecl.Import decl-meta _) unit]
              [(ast.AstDecl.IncludeStr _ _) unit]
              [(ast.AstDecl.IncludeStrComptime _ _) unit]
              [(ast.AstDecl.IncludeStrLzss _ _) unit]
              [(ast.AstDecl.IncludeBin _ _) unit]
              [(ast.AstDecl.Module _) unit]
              [(ast.AstDecl.Test _ _ _) unit]
              [_
                (if (= target logical-index)
                  (return
                    (match decl
                      [(ast.AstDecl.Unsafe inner-box)
                        (let
                          [inner : ast.AstDecl (__tl-box-place inner-box)]
                          (parser.ResultAstDecl.Ok inner))]
                      [_ (parser.ResultAstDecl.Ok decl)]))
                  (set! logical-index (+ logical-index 1)))])
            (set! slot (+ slot 1)))))
      (parser.ResultAstDecl.Err "symbols: declaration index not found"))))

(define (compiler-program-decl-at-index
  [program : ast.AstProgram]
  [target : i64]) : parser.ResultAstDecl
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        (compiler-decl-list-at-index decls target 0))]))

(define (compiler-symbols-decl-at-index
  [symbols : CompilerSymbols]
  [target : i64]) : parser.ResultAstDecl
  (let
    [decls : (__tl_dyn-array ast.AstDecl) (compiler-symbols-decls symbols)]
    (if (or (< target 0) (>= target (compiler-symbols-decl-count symbols)))
      (parser.ResultAstDecl.Err "symbols: declaration index not found")
      (parser.ResultAstDecl.Ok (array-ref decls target)))))

(define (compiler-variant-types-at-index
  [variants : ast.AstVariantDefList]
  [target : i64]
  [index : i64]) : parser.ResultAstTypeList
  (if (or
    (< target index)
    (>= target (ast.ast-variant-def-list-len (& variants))))
    (parser.ResultAstTypeList.Err "symbols: variant index not found")
    (match (ast.ast-variant-def-list-get
      (& variants)
      target
      (ast.ast-variant-def-fallback))
      [(ast.AstVariantDef.Def _ fields _) (parser.ResultAstTypeList.Ok fields)])))

(define (compiler-variant-name-id-at-index
  [variants : ast.AstVariantDefList]
  [target : i64]
  [index : i64]) : option_i64.Option
  (if (>= index (ast.ast-variant-def-list-len (& variants)))
    option_i64.None
    (match (ast.ast-variant-def-list-get
      (& variants)
      index
      (ast.ast-variant-def-fallback))
      [(ast.AstVariantDef.Def name-id _ _)
        (if (= target index)
          (option_i64.Some name-id)
          (compiler-variant-name-id-at-index variants target (+ index 1)))])))

(define (compiler-field-type-at-index
  [fields : ast.AstFieldDefList]
  [target : i64]
  [index : i64]) : parser.ResultAstType
  (if (>= index (ast.ast-field-def-list-len (& fields)))
    (parser.ResultAstType.Err "symbols: field index not found")
    (match (ast.ast-field-def-list-get
      (& fields)
      index
      (ast.ast-field-def-fallback))
      [(ast.AstFieldDef.Def _ ty _)
        (if (= target index)
          (parser.ResultAstType.Ok ty)
          (compiler-field-type-at-index fields target (+ index 1)))])))

(define (compiler-registries-variant-fields
  [program : ast.AstProgram]
  [handle : i64]) : parser.ResultAstTypeList
  (match (compiler-program-decl-at-index
    program
    (compiler-registry-handle-owner-index handle))
    [(parser.ResultAstDecl.Ok decl)
      (match decl
        [(ast.AstDecl.DefEnum decl-meta _ _ variants)
          (compiler-variant-types-at-index
            variants
            (compiler-registry-handle-child-index handle)
            0)]
        [(ast.AstDecl.DefEnumLifetimes decl-meta _ _ _ variants)
          (compiler-variant-types-at-index
            variants
            (compiler-registry-handle-child-index handle)
            0)]
        [_ (parser.ResultAstTypeList.Err "symbols: variant owner is not enum")])]
    [(parser.ResultAstDecl.Err message) (parser.ResultAstTypeList.Err message)]))

(define (compiler-registries-variant-fields-indexed
  [symbols : CompilerSymbols]
  [handle : i64]) : parser.ResultAstTypeList
  (match (compiler-symbols-decl-at-index
    symbols
    (compiler-registry-handle-owner-index handle))
    [(parser.ResultAstDecl.Ok decl)
      (match decl
        [(ast.AstDecl.DefEnum decl-meta _ _ variants)
          (compiler-variant-types-at-index
            variants
            (compiler-registry-handle-child-index handle)
            0)]
        [(ast.AstDecl.DefEnumLifetimes decl-meta _ _ _ variants)
          (compiler-variant-types-at-index
            variants
            (compiler-registry-handle-child-index handle)
            0)]
        [_ (parser.ResultAstTypeList.Err "symbols: variant owner is not enum")])]
    [(parser.ResultAstDecl.Err message) (parser.ResultAstTypeList.Err message)]))

(define (compiler-registries-variant-name-id-indexed
  [symbols : CompilerSymbols]
  [handle : i64]) : option_i64.Option
  (match (compiler-symbols-decl-at-index
    symbols
    (compiler-registry-handle-owner-index handle))
    [(parser.ResultAstDecl.Ok decl)
      (match decl
        [(ast.AstDecl.DefEnum decl-meta _ _ variants)
          (compiler-variant-name-id-at-index
            variants
            (compiler-registry-handle-child-index handle)
            0)]
        [(ast.AstDecl.DefEnumLifetimes decl-meta _ _ _ variants)
          (compiler-variant-name-id-at-index
            variants
            (compiler-registry-handle-child-index handle)
            0)]
        [_ option_i64.None])]
    [(parser.ResultAstDecl.Err _) option_i64.None]))

(define (compiler-registries-struct-field-type
  [program : ast.AstProgram]
  [handle : i64]) : parser.ResultAstType
  (match (compiler-program-decl-at-index
    program
    (compiler-registry-handle-owner-index handle))
    [(parser.ResultAstDecl.Ok decl)
      (match decl
        [(ast.AstDecl.DefStruct decl-meta _ _ _ fields)
          (compiler-field-type-at-index
            fields
            (compiler-registry-handle-child-index handle)
            0)]
        [(ast.AstDecl.DefStructLifetimes decl-meta _ _ _ _ fields)
          (compiler-field-type-at-index
            fields
            (compiler-registry-handle-child-index handle)
            0)]
        [_ (parser.ResultAstType.Err "symbols: field owner is not struct")])]
    [(parser.ResultAstDecl.Err message) (parser.ResultAstType.Err message)]))

(define (compiler-registries-struct-field-type-indexed
  [symbols : CompilerSymbols]
  [handle : i64]) : parser.ResultAstType
  (let
    [decls : (__tl_dyn-array ast.AstDecl) (compiler-symbols-decls symbols)]
    [owner-index : i64 (compiler-registry-handle-owner-index handle)]
    [child-index : i64 (compiler-registry-handle-child-index handle)]
    (if (or
      (< owner-index 0)
      (>= owner-index (compiler-symbols-decl-count symbols)))
      (parser.ResultAstType.Err "symbols: declaration index not found")
      (match (array-ref decls owner-index)
        [(ast.AstDecl.DefStruct decl-meta _ _ _ fields)
          (compiler-field-type-at-index fields child-index 0)]
        [(ast.AstDecl.DefStructLifetimes decl-meta _ _ _ _ fields)
          (compiler-field-type-at-index fields child-index 0)]
        [_ (parser.ResultAstType.Err "symbols: field owner is not struct")]))))

(define (compiler-symbols-decl-name-id-at-index
  [symbols : CompilerSymbols]
  [target : i64]) : i64
  (match (compiler-symbols-decl-at-index symbols target)
    [(parser.ResultAstDecl.Ok decl)
      (match decl
        [(ast.AstDecl.Def decl-meta name _ _) name]
        [(ast.AstDecl.DefFn decl-meta name _ _ _ _) name]
        [(ast.AstDecl.DefMacro decl-meta name _ _ _) name]
        [(ast.AstDecl.Extern decl-meta name _ _ _) name]
        [(ast.AstDecl.DefDispatch decl-meta name _) name]
        [(ast.AstDecl.DefEnum decl-meta name _ _) name]
        [(ast.AstDecl.DefEnumLifetimes decl-meta name _ _ _) name]
        [(ast.AstDecl.DefStruct decl-meta name _ _ _) name]
        [(ast.AstDecl.DefStructLifetimes decl-meta name _ _ _ _) name]
        [_ -1])]
    [(parser.ResultAstDecl.Err _) -1]))

(define (compiler-symbols-owner-module-id-at-index
  [symbols : CompilerSymbols]
  [target : i64]) : i64
  (let
    [owners : (__tl_dyn-array i64) (compiler-symbols-owner-module-ids symbols)]
    (if (or (< target 0) (>= target (compiler-symbols-decl-count symbols)))
      -1
      (array-ref owners target))))

(define (compiler-symbols-variant-name-id-at-index
  [symbols : CompilerSymbols]
  [owner-index : i64]
  [variant-index : i64]) : i64
  (match (compiler-symbols-decl-at-index symbols owner-index)
    [(parser.ResultAstDecl.Ok decl)
      (match decl
        [(ast.AstDecl.DefEnum decl-meta _ _ variants)
          (compiler-symbols-option-or
            (compiler-variant-name-id-at-index variants variant-index 0)
            -1)]
        [(ast.AstDecl.DefEnumLifetimes decl-meta _ _ _ variants)
          (compiler-symbols-option-or
            (compiler-variant-name-id-at-index variants variant-index 0)
            -1)]
        [_ -1])]
    [(parser.ResultAstDecl.Err _) -1]))

(define (compiler-field-name-id-at-index
  [fields : ast.AstFieldDefList]
  [target : i64]) : i64
  (if (or (< target 0) (>= target (ast.ast-field-def-list-len (& fields))))
    -1
    (match (ast.ast-field-def-list-get
      (& fields)
      target
      (ast.ast-field-def-fallback))
      [(ast.AstFieldDef.Def name-id _ _) name-id])))

(define (compiler-symbols-field-name-id-at-index
  [symbols : CompilerSymbols]
  [owner-index : i64]
  [field-index : i64]) : i64
  (match (compiler-symbols-decl-at-index symbols owner-index)
    [(parser.ResultAstDecl.Ok decl)
      (match decl
        [(ast.AstDecl.DefStruct decl-meta _ _ _ fields)
          (compiler-field-name-id-at-index fields field-index)]
        [(ast.AstDecl.DefStructLifetimes decl-meta _ _ _ _ fields)
          (compiler-field-name-id-at-index fields field-index)]
        [_ -1])]
    [(parser.ResultAstDecl.Err _) -1]))

(define (compiler-symbols-expr-source-id [expr : ast.AstExpr]) : i64
  (match expr
    [(ast.AstExpr.Spanned inner _)
      (compiler-symbols-expr-source-id (ast.ast-node-get inner))]
    [(ast.AstExpr.Var name-id) name-id]
    [_ -1]))

(define (compiler-symbols-decl-value-source-id-at-index
  [symbols : CompilerSymbols]
  [target : i64]) : i64
  (match (compiler-symbols-decl-at-index symbols target)
    [(parser.ResultAstDecl.Ok (ast.AstDecl.Def decl-meta _ _ value))
      (compiler-symbols-expr-source-id (ast.ast-node-get value))]
    [(parser.ResultAstDecl.Ok _) -1]
    [(parser.ResultAstDecl.Err _) -1]))

(define (compiler-symbol-lookup-score
  [found : option_i64.Option]
  [want-kind : i64]
  [want-index : i64]) : i64
  (match found
    [(option_i64.Some handle)
      (if (and
        (= (compiler-symbol-handle-kind handle) want-kind)
        (= (compiler-symbol-handle-index handle) want-index))
        1
        0)]
    [(option_i64.None) 0]))

(define (compiler-symbols-miss-score [found : option_i64.Option]) : i64
  (match found
    [(option_i64.None) 1]
    [(option_i64.Some _) 0]))

(define (compiler-registry-miss-score [found : option_i64.Option]) : i64
  (match found
    [(option_i64.None) 1]
    [(option_i64.Some _) 0]))

(define (compiler-registry-lookup-score
  [found : option_i64.Option]
  [want-kind : i64]
  [want-owner : i64]
  [want-child : i64]) : i64
  (match found
    [(option_i64.Some handle)
      (if (and
        (= (compiler-registry-handle-kind handle) want-kind)
        (= (compiler-registry-handle-owner-index handle) want-owner)
        (= (compiler-registry-handle-child-index handle) want-child))
        1
        0)]
    [(option_i64.None) 0]))

(define (compiler-type-result-tag-score
  [found : parser.ResultAstType]
  [want-tag : i64]) : i64
  (match found
    [(parser.ResultAstType.Ok ty)
      (if (= (ast.ast-type-tag ty) want-tag)
        1
        0)]
    [(parser.ResultAstType.Err _) 0]))

(define (compiler-type-list-single-tag-score
  [found : parser.ResultAstTypeList]
  [want-tag : i64]) : i64
  (match found
    [(parser.ResultAstTypeList.Ok types)
      (if (= (ast.ast-type-list-len (& types)) 1)
        (if (=
          (ast.ast-type-tag
            (ast.ty-node-get
              (ast.ast-type-list-get (& types) 0 (ast.ast-type-id-fallback))))
          want-tag)
          1
          0)
        0)]
    [(parser.ResultAstTypeList.Err _) 0]))

(define (compiler-symbols-smoke-source) : String
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
      (if (and (= x 42) true)
          (match (Some x) [(Some v) v] [_ 0])
          0))))")

(define (compiler-symbols-smoke-score [symbols : CompilerSymbols]) : i64
  (let
    [point-id : i64 (compiler-symbols-decl-name-id-at-index symbols 0)]
    [maybe-id : i64 (compiler-symbols-decl-name-id-at-index symbols 1)]
    [none-id : i64 (compiler-symbols-variant-name-id-at-index symbols 1 0)]
    [some-id : i64 (compiler-symbols-variant-name-id-at-index symbols 1 1)]
    [extern-id : i64 (compiler-symbols-decl-name-id-at-index symbols 2)]
    [answer-id : i64 (compiler-symbols-decl-name-id-at-index symbols 3)]
    [main-id : i64 (compiler-symbols-decl-name-id-at-index symbols 4)]
    (+
      (compiler-symbol-lookup-score
        (compiler-symbols-lookup-type-id symbols point-id)
        (compiler-symbol-kind-defstruct)
        0)
      (+
        (compiler-symbol-lookup-score
          (compiler-symbols-lookup-value-id symbols point-id)
          (compiler-symbol-kind-defstruct)
          0)
        (+
          (compiler-symbol-lookup-score
            (compiler-symbols-lookup-type-id symbols maybe-id)
            (compiler-symbol-kind-defenum)
            1)
          (+
            (compiler-registry-lookup-score
              (compiler-symbols-lookup-value-id symbols none-id)
              (compiler-symbol-kind-enum-variant)
              1
              0)
            (+
              (compiler-registry-lookup-score
                (compiler-symbols-lookup-value-id symbols some-id)
                (compiler-symbol-kind-enum-variant)
                1
                1)
              (+
                (compiler-symbol-lookup-score
                  (compiler-symbols-lookup-value-id symbols extern-id)
                  (compiler-symbol-kind-extern)
                  2)
                (+
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-value-id symbols answer-id)
                    (compiler-symbol-kind-value-define)
                    3)
                  (+
                    (compiler-symbol-lookup-score
                      (compiler-symbols-lookup-value-id symbols main-id)
                      (compiler-symbol-kind-function-define)
                      4)
                    (+
                      (compiler-symbols-miss-score
                        (compiler-symbols-lookup-value-id symbols -1))
                      (compiler-symbols-miss-score
                        (compiler-symbols-lookup-type-id symbols -1)))))))))))))

(define (compiler-registries-smoke-score
  [program : ast.AstProgram]
  [symbols : CompilerSymbols]
  [registries : CompilerRegistries]) : i64
  (let
    [point-id : i64 (compiler-symbols-decl-name-id-at-index symbols 0)]
    [some-id : i64 (compiler-symbols-variant-name-id-at-index symbols 1 1)]
    [none-id : i64 (compiler-symbols-variant-name-id-at-index symbols 1 0)]
    [x-id : i64 (compiler-symbols-field-name-id-at-index symbols 0 0)]
    [y-id : i64 (compiler-symbols-field-name-id-at-index symbols 0 1)]
    [some : option_i64.Option
      (compiler-registries-lookup-variant-id registries some-id)]
    [none : option_i64.Option
      (compiler-registries-lookup-variant-id registries none-id)]
    [x-field : option_i64.Option
      (compiler-registries-lookup-struct-field-id registries point-id x-id)]
    [y-field : option_i64.Option
      (compiler-registries-lookup-struct-field-id registries point-id y-id)]
    (+
      (compiler-registry-lookup-score
        some
        (compiler-symbol-kind-enum-variant)
        1
        1)
      (+
        (compiler-registry-lookup-score
          none
          (compiler-symbol-kind-enum-variant)
          1
          0)
        (+
          (compiler-registry-lookup-score
            x-field
            (compiler-symbol-kind-struct-field)
            0
            0)
          (+
            (compiler-registry-lookup-score
              y-field
              (compiler-symbol-kind-struct-field)
              0
              1)
            (+
              (match x-field
                [(option_i64.Some handle)
                  (compiler-type-result-tag-score
                    (compiler-registries-struct-field-type program handle)
                    (ast.ast-type-tag (ast.AstType.I64)))]
                [(option_i64.None) 0])
              (+
                (match some
                  [(option_i64.Some handle)
                    (compiler-type-list-single-tag-score
                      (compiler-registries-variant-fields program handle)
                      (ast.ast-type-tag (ast.AstType.I64)))]
                  [(option_i64.None) 0])
                (+
                  (compiler-symbols-miss-score
                    (compiler-registries-lookup-variant-id registries -1))
                  (compiler-symbols-miss-score
                    (compiler-registries-lookup-struct-field-id
                      registries
                      point-id
                      -1)))))))))))

(define (compiler-symbols-duplicate-value-source) : String
  "(define answer : i64 1)
(define (answer) : i64 2)")

(define (compiler-symbols-duplicate-type-source) : String
  "(defstruct Point (x i64))
(defenum Point (PointVariant))")

(define (compiler-registries-duplicate-variant-source) : String
  "(defenum Left (Same) (Same))")

(define (compiler-registries-cross-enum-variant-source) : String
  "(defenum Left (Same))
(defenum Right (Same))")

(define (compiler-registries-duplicate-field-source) : String
  "(defstruct Pair (x i64) (x i64))")

(define (compiler-symbols-macro-source) : String
  "(defmacro (all [first : bool] [rest : bool ...]) : bool first)
(define (main) : i64 0)")

(define (compiler-symbols-duplicate-macro-value-source) : String
  "(defmacro (same) : bool (expr-bool true))
(define same : i64 1)")

(define (compiler-symbols-module-duplicate-value-source) : String
  "(module left)
(define same : i64 1)
(define same : i64 2)")

(define (compiler-symbols-module-duplicate-type-source) : String
  "(module left)
(defstruct Point (x i64))
(defenum Point (PointVariant))")

(define (compiler-symbols-module-duplicate-macro-value-source) : String
  "(module left)
(defmacro (same) : bool (expr-bool true))
(define same : i64 1)")

(define (compiler-symbols-module-duplicate-variant-source) : String
  "(module left)
(defenum Choice (Same) (Same))")

(define (compiler-symbols-variant-function-collision-source) : String
  "(defenum A (Foo))
(define (Foo [x : i64]) : i64 x)")

(define (compiler-symbols-variant-define-collision-source) : String
  "(defenum A (Foo))
(define Foo : i64 42)")

(define (compiler-symbols-variant-extern-collision-source) : String
  "(defenum A (Foo))
(extern (Foo [arg0 : i64]) : i64)")

(define (compiler-symbols-variant-struct-collision-source) : String
  "(defenum A (Foo))
(defstruct Foo (x i64))")

(define (compiler-symbols-struct-function-collision-source) : String
  "(defstruct Point (x i64))
(define (Point [x : i64]) : i64 x)")

(define (compiler-symbols-struct-define-collision-source) : String
  "(defstruct Point (x i64))
(define Point : i64 42)")

(define (compiler-symbols-struct-extern-collision-source) : String
  "(defstruct Point (x i64))
(extern (Point [arg0 : i64]) : i64)")

(define (compiler-symbols-duplicate-value-ok?) : bool
  (match (build-compiler-symbols-from-source
    (compiler-symbols-duplicate-value-source))
    [(ResultCompilerSymbols.Err message)
      (string.eq message (compiler-symbols-duplicate-value-message "answer"))]
    [(ResultCompilerSymbols.Ok _) false]))

(define (compiler-symbols-duplicate-type-ok?) : bool
  (match (build-compiler-symbols-from-source
    (compiler-symbols-duplicate-type-source))
    [(ResultCompilerSymbols.Err message)
      (string.eq message (compiler-symbols-duplicate-type-message "Point"))]
    [(ResultCompilerSymbols.Ok _) false]))

(define (compiler-symbols-duplicate-value-error-ok?
  [src : String]
  [name : String]) : bool
  (match (build-compiler-symbols-from-source src)
    [(ResultCompilerSymbols.Err message)
      (string.eq message (compiler-symbols-duplicate-value-message name))]
    [(ResultCompilerSymbols.Ok _) false]))

(define (compiler-symbols-module-duplicate-diagnostics-ok?) : bool
  (and
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-module-duplicate-value-source)
      "left/same")
    (match (build-compiler-symbols-from-source
      (compiler-symbols-module-duplicate-type-source))
      [(ResultCompilerSymbols.Err message)
        (string.eq
          message
          (compiler-symbols-duplicate-type-message "left/Point"))]
      [(ResultCompilerSymbols.Ok _) false])
    (match (build-compiler-symbols-from-source
      (compiler-symbols-module-duplicate-macro-value-source))
      [(ResultCompilerSymbols.Err message)
        (string.eq
          message
          (compiler-symbols-duplicate-macro-value-message "left/same"))]
      [(ResultCompilerSymbols.Ok _) false])
    (match (build-compiler-symbols-from-source
      (compiler-symbols-module-duplicate-variant-source))
      [(ResultCompilerSymbols.Err message)
        (string.eq
          message
          (compiler-registries-duplicate-variant-message "left/Choice.Same"))]
      [(ResultCompilerSymbols.Ok _) false])))

(define (compiler-symbols-module-duplicate-with-paths-ok?) : bool
  (match (parser.parse-ast-source
    (compiler-symbols-module-duplicate-value-source))
    [(parser.ResultAstProgram.Ok program)
      (let
        [paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
        (begin
          (ast.ast-decl-path-list-push-with-owner-id
            (&mut paths)
            "module.tl"
            cbi.compiler-builtin-id-fix-empty)
          (ast.ast-decl-path-list-push-with-owner-id
            (&mut paths)
            "first.tl"
            cbi.compiler-builtin-id-fix-empty)
          (ast.ast-decl-path-list-push-with-owner-id
            (&mut paths)
            "duplicate.tl"
            cbi.compiler-builtin-id-fix-empty)
          (match (build-compiler-symbols-with-paths program paths)
            [(ResultCompilerSymbols.Err message)
              (string.eq
                message
                "symbols: duplicate value declaration left/same (first declared in first.tl; duplicate in duplicate.tl)")]
            [(ResultCompilerSymbols.Ok _) false])))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-symbols-variant-value-collisions-ok?) : bool
  (and
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-variant-function-collision-source)
      "Foo")
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-variant-define-collision-source)
      "Foo")
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-variant-extern-collision-source)
      "Foo")
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-variant-struct-collision-source)
      "Foo")))

(define (compiler-symbols-struct-value-collisions-ok?) : bool
  (and
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-struct-function-collision-source)
      "Point")
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-struct-define-collision-source)
      "Point")
    (compiler-symbols-duplicate-value-error-ok?
      (compiler-symbols-struct-extern-collision-source)
      "Point")))

(define (compiler-registries-duplicate-variant-ok?) : bool
  (match (build-compiler-registries-from-source
    (compiler-registries-duplicate-variant-source))
    [(ResultCompilerRegistries.Err message)
      (string.eq
        message
        (compiler-registries-duplicate-variant-message "Left.Same"))]
    [(ResultCompilerRegistries.Ok _) false]))

(define (compiler-registries-cross-enum-variant-ok?) : bool
  (match (parser.parse-ast-source
    (compiler-registries-cross-enum-variant-source))
    [(parser.ResultAstProgram.Ok program)
      (match (build-compiler-symbols program)
        [(ResultCompilerSymbols.Ok symbols)
          (match (build-compiler-registries program)
            [(ResultCompilerRegistries.Ok registries)
              (let
                [left-id : i64
                  (compiler-symbols-decl-name-id-at-index symbols 0)]
                [left-same-id : i64
                  (compiler-symbols-variant-name-id-at-index symbols 0 0)]
                [right-id : i64
                  (compiler-symbols-decl-name-id-at-index symbols 1)]
                [right-same-id : i64
                  (compiler-symbols-variant-name-id-at-index symbols 1 0)]
                (and
                  (=
                    (compiler-registry-lookup-score
                      (compiler-registries-lookup-variant-id
                        registries
                        (compiler-enum-qualified-variant-name-id
                          left-id
                          left-same-id))
                      (compiler-symbol-kind-enum-variant)
                      0
                      0)
                    1)
                  (=
                    (compiler-registry-lookup-score
                      (compiler-registries-lookup-variant-id
                        registries
                        (compiler-enum-qualified-variant-name-id
                          right-id
                          right-same-id))
                      (compiler-symbol-kind-enum-variant)
                      1
                      0)
                    1)))]
            [(ResultCompilerRegistries.Err _) false])]
        [(ResultCompilerSymbols.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-registries-duplicate-field-ok?) : bool
  (match (build-compiler-registries-from-source
    (compiler-registries-duplicate-field-source))
    [(ResultCompilerRegistries.Err message)
      (string.eq
        message
        (compiler-registries-duplicate-field-message "Pair" "x"))]
    [(ResultCompilerRegistries.Ok _) false]))

(define (compiler-symbols-macro-namespace-ok?) : bool
  (match (parser.parse-ast-source (compiler-symbols-macro-source))
    [(parser.ResultAstProgram.Ok program)
      (match (build-compiler-symbols program)
        [(ResultCompilerSymbols.Ok symbols)
          (let
            [all-id : i64 (compiler-symbols-decl-name-id-at-index symbols 0)]
            [main-id : i64 (compiler-symbols-decl-name-id-at-index symbols 1)]
            (and
              (=
                (compiler-symbol-lookup-score
                  (compiler-symbols-lookup-macro-id symbols all-id)
                  (compiler-symbol-kind-defmacro)
                  0)
                1)
              (=
                (compiler-symbols-miss-score
                  (compiler-symbols-lookup-value-id symbols all-id))
                1)
              (=
                (compiler-symbol-lookup-score
                  (compiler-symbols-lookup-value-id symbols main-id)
                  (compiler-symbol-kind-function-define)
                  1)
                1)))]
        [(ResultCompilerSymbols.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-symbols-duplicate-macro-value-ok?) : bool
  (match (build-compiler-symbols-from-source
    (compiler-symbols-duplicate-macro-value-source))
    [(ResultCompilerSymbols.Err message)
      (string.eq
        message
        (compiler-symbols-duplicate-macro-value-message "same"))]
    [(ResultCompilerSymbols.Ok _) false]))

(define (compiler-registry-large-owner-handle-ok?) : bool
  (let
    [handle : i64
      (compiler-registry-make-handle (compiler-symbol-kind-enum-variant) 1234 5)]
    (and
      (=
        (compiler-registry-handle-kind handle)
        (compiler-symbol-kind-enum-variant))
      (= (compiler-registry-handle-owner-index handle) 1234)
      (= (compiler-registry-handle-child-index handle) 5))))

;; A threshold-sized registry map must shift every owner handle without moving
;; its scalar key/value storage.
(define (compiler-registry-shift-map-full-ok?) : bool
  (let
    [map : CompilerSymbolMap (compiler-symbol-map-empty)]
    [entry-count : i64 192]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (< index entry-count)
        (begin
          (compiler-symbol-map-put!
            (&mut map)
            index
            (compiler-registry-make-handle
              (compiler-symbol-kind-enum-variant)
              index
              0))
          (set! index (+ index 1))))
      (compiler-registry-shift-map-owner-indices! (&mut map) 0 1)
      (set! index 0)
      (while (< index entry-count)
        (begin
          (if (=
            (compiler-registry-lookup-score
              (compiler-symbol-map-lookup-id (& map) index)
              (compiler-symbol-kind-enum-variant)
              (+ index 1)
              0)
            1)
            unit
            (set! ok false))
          (set! index (+ index 1))))
      ok)))

(define (compiler-registries-incremental-base-source) : String
  "(module nested
  (defenum Later (Empty) (Value i64))
  (defstruct Record (value i64)))")

(define (compiler-registries-incremental-splice-source) : String
  "(defstruct Inserted (id i64))")

(define (compiler-registries-incremental-combined-source) : String
  "(module nested
  (defstruct Inserted (id i64))
  (defenum Later (Empty) (Value i64))
  (defstruct Record (value i64)))")

(define (compiler-registries-incremental-later-variant-ok?
  [symbols : CompilerSymbols]
  [registries : CompilerRegistries]) : bool
  (let
    [module-id : i64 (compiler-symbols-owner-module-id-at-index symbols 1)]
    [enum-id : i64 (compiler-symbols-decl-name-id-at-index symbols 1)]
    [variant-id : i64 (compiler-symbols-variant-name-id-at-index symbols 1 1)]
    (match (compiler-registries-lookup-variant-key-id
      registries
      (compiler-symbol-module-key-id-by-id
        module-id
        (compiler-enum-qualified-variant-name-id enum-id variant-id)))
      [(option_i64.Some handle)
        (and
          (=
            (compiler-registry-lookup-score
              (option_i64.Some handle)
              (compiler-symbol-kind-enum-variant)
              1
              1)
            1)
          (match (compiler-registries-variant-fields-indexed symbols handle)
            [(parser.ResultAstTypeList.Ok types)
              (if (= (ast.ast-type-list-len (& types)) 1)
                (match (ast.ty-node-get
                  (ast.ast-type-list-get (& types) 0 (ast.ast-type-id-fallback)))
                  [(ast.AstType.I64) true]
                  [_ false])
                false)]
            [(parser.ResultAstTypeList.Err _) false]))]
      [(option_i64.None) false])))

(define (compiler-registries-incremental-later-field-ok?
  [symbols : CompilerSymbols]
  [registries : CompilerRegistries]) : bool
  (match (compiler-registries-lookup-field-in-module-id
    registries
    (compiler-symbols-owner-module-id-at-index symbols 2)
    (compiler-symbols-decl-name-id-at-index symbols 2)
    (compiler-symbols-field-name-id-at-index symbols 2 0))
    [(option_i64.Some handle)
      (and
        (=
          (compiler-registry-lookup-score
            (option_i64.Some handle)
            (compiler-symbol-kind-struct-field)
            2
            0)
          1)
        (match (compiler-registries-struct-field-type-indexed symbols handle)
          [(parser.ResultAstType.Ok (ast.AstType.I64)) true]
          [(parser.ResultAstType.Ok _) false]
          [(parser.ResultAstType.Err _) false]))]
    [(option_i64.None) false]))

(define (compiler-registries-lifetime-field-indexed-ok?) : bool
  (match (parser.parse-ast-source
    "(defenum NotStruct (None))
(defstruct Borrowed (:lifetimes owner) (value (& owner i64)))")
    [(parser.ResultAstProgram.Ok program)
      (match (build-compiler-symbols program)
        [(ResultCompilerSymbols.Ok symbols)
          (match (build-compiler-registries program)
            [(ResultCompilerRegistries.Ok registries)
              (let
                [struct-index : i64 1]
                [struct-name-id : i64
                  (compiler-symbols-decl-name-id-at-index symbols struct-index)]
                [field-name-id : i64
                  (compiler-symbols-field-name-id-at-index
                    symbols
                    struct-index
                    0)]
                [module-id : i64
                  (compiler-symbols-owner-module-id-at-index
                    symbols
                    struct-index)]
                (match (compiler-registries-lookup-field-in-module-id
                  registries
                  module-id
                  struct-name-id
                  field-name-id)
                  [(option_i64.Some handle)
                    (and
                      (=
                        (compiler-registry-handle-kind handle)
                        (compiler-symbol-kind-struct-field))
                      (=
                        (compiler-registry-handle-owner-index handle)
                        struct-index)
                      (= (compiler-registry-handle-child-index handle) 0)
                      (match (compiler-registries-struct-field-type-indexed
                        symbols
                        handle)
                        [(parser.ResultAstType.Ok
                            (ast.AstType.Ref lifetime inner))
                          (and
                            (= lifetime (ci.intern "owner"))
                            (match (ast.ty-node-get inner)
                              [(ast.AstType.I64) true]
                              [_ false]))]
                        [_ false])
                      (match (compiler-registries-struct-field-type-indexed
                        symbols
                        (compiler-registry-make-handle
                          (compiler-symbol-kind-struct-field)
                          -1
                          0))
                        [(parser.ResultAstType.Err message)
                          (string.eq
                            message
                            "symbols: declaration index not found")]
                        [_ false])
                      (match (compiler-registries-struct-field-type-indexed
                        symbols
                        (compiler-registry-make-handle
                          (compiler-symbol-kind-struct-field)
                          0
                          0))
                        [(parser.ResultAstType.Err message)
                          (string.eq
                            message
                            "symbols: field owner is not struct")]
                        [_ false]))]
                  [(option_i64.None) false]))]
            [(ResultCompilerRegistries.Err _) false])]
        [(ResultCompilerSymbols.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

;; A generated nominal splice at the start of a nested module must leave later
;; enum-variant and struct-field handles pointing at their shifted owners.
(define (compiler-registries-incremental-splice-ok?) : bool
  (match (parser.parse-ast-source (compiler-registries-incremental-base-source))
    [(parser.ResultAstProgram.Ok base-program)
      (match (build-compiler-symbols base-program)
        [(ResultCompilerSymbols.Ok base-symbols)
          (match (build-compiler-registries base-program)
            [(ResultCompilerRegistries.Ok base-registries)
              (match (parser.parse-ast-source
                (compiler-registries-incremental-splice-source))
                [(parser.ResultAstProgram.Ok splice-program)
                  (match splice-program
                    [(ast.AstProgram.Program splice-box)
                      (let
                        [splice-decls : ast.AstDeclList
                          (__tl-box-place splice-box)]
                        [splice-paths : ast.AstDeclPathList
                          (compiler-symbol-path-list-repeat
                            splice-decls
                            ""
                            cbi.compiler-builtin-id-fix-empty)]
                        (match (compiler-registries-insert-decls
                          base-registries
                          splice-decls
                          splice-paths
                          0
                          (compiler-symbols-owner-module-id-at-index
                            base-symbols
                            0))
                          [(ResultCompilerRegistries.Ok rebased-registries)
                            (match (parser.parse-ast-source
                              (compiler-registries-incremental-combined-source))
                              [(parser.ResultAstProgram.Ok combined-program)
                                (match (build-compiler-symbols combined-program)
                                  [(ResultCompilerSymbols.Ok combined-symbols)
                                    (and
                                      (compiler-registries-incremental-later-variant-ok?
                                        combined-symbols
                                        rebased-registries)
                                      (compiler-registries-incremental-later-field-ok?
                                        combined-symbols
                                        rebased-registries))]
                                  [(ResultCompilerSymbols.Err _) false])]
                              [(parser.ResultAstProgram.Err _) false])]
                          [(ResultCompilerRegistries.Err _) false]))])]
                [(parser.ResultAstProgram.Err _) false])]
            [(ResultCompilerRegistries.Err _) false])]
        [(ResultCompilerSymbols.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-symbols-append-splice-source) : String
  "(module fresh
  (defenum Added (None) (Some i64))
  (defstruct Boxed (value i64)))")

(define (compiler-symbols-append-macro-base-source) : String
  "(module data)
(defmacro (all [first : bool]) : bool first)")

(define (compiler-symbols-append-macro-import-source) : String
  "(module fresh)
(define answer : i64 42)
(module main)
(import data as d)")

(define (compiler-symbols-append-external-macro-alias-ok?) : bool
  (match (parser.parse-ast-source (compiler-symbols-append-macro-base-source))
    [(parser.ResultAstProgram.Ok base-program)
      (match (build-compiler-symbols base-program)
        [(ResultCompilerSymbols.Ok base-symbols)
          (match (parser.parse-ast-source
            (compiler-symbols-append-macro-import-source))
            [(parser.ResultAstProgram.Ok splice-program)
              (match splice-program
                [(ast.AstProgram.Program splice-box)
                  (match (compiler-symbols-insert-decls
                    base-symbols
                    (__tl-box-place splice-box)
                    (compiler-symbol-root-module-id))
                    [(ResultCompilerSymbols.Ok appended)
                      (let
                        [macro-id : i64
                          (compiler-symbols-decl-name-id-at-index appended 0)]
                        [module-id : i64
                          (compiler-symbols-owner-module-id-at-index appended 0)]
                        (and
                          (=
                            (compiler-symbol-lookup-score
                              (compiler-symbols-lookup-macro-in-module-id
                                appended
                                module-id
                                macro-id)
                              (compiler-symbol-kind-defmacro)
                              0)
                            1)
                          (=
                            (compiler-symbols-miss-score
                              (compiler-symbols-lookup-macro-id
                                appended
                                macro-id))
                            1)))]
                    [(ResultCompilerSymbols.Err _) false])])]
            [(parser.ResultAstProgram.Err _) false])]
        [(ResultCompilerSymbols.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

;; Append-only symbol and registry growth keeps old handles stable while the
;; new nominal owners share the symbol table's logical end.
(define (compiler-symbols-append-splice-ok?) : bool
  (match (parser.parse-ast-source (compiler-registries-incremental-base-source))
    [(parser.ResultAstProgram.Ok base-program)
      (match (build-compiler-symbols base-program)
        [(ResultCompilerSymbols.Ok base-symbols)
          (match (build-compiler-registries base-program)
            [(ResultCompilerRegistries.Ok base-registries)
              (match (parser.parse-ast-source
                (compiler-symbols-append-splice-source))
                [(parser.ResultAstProgram.Ok splice-program)
                  (match splice-program
                    [(ast.AstProgram.Program splice-box)
                      (let
                        [splice-decls : ast.AstDeclList
                          (__tl-box-place splice-box)]
                        [splice-paths : ast.AstDeclPathList
                          (compiler-symbol-path-list-repeat
                            splice-decls
                            "generated.tl"
                            cbi.compiler-builtin-id-fix-empty)]
                        [append-index : i64
                          (compiler-symbols-decl-count base-symbols)]
                        (match (compiler-symbols-insert-decls
                          base-symbols
                          splice-decls
                          (compiler-symbol-root-module-id))
                          [(ResultCompilerSymbols.Ok appended-symbols)
                            (match (compiler-registries-append-decls
                              base-registries
                              splice-decls
                              splice-paths
                              append-index
                              (compiler-symbol-root-module-id))
                              [(ResultCompilerRegistries.Ok appended-registries)
                                (let
                                  [old-module-id : i64
                                    (compiler-symbols-owner-module-id-at-index
                                      appended-symbols
                                      0)]
                                  [old-enum-id : i64
                                    (compiler-symbols-decl-name-id-at-index
                                      appended-symbols
                                      0)]
                                  [old-variant-id : i64
                                    (compiler-symbols-variant-name-id-at-index
                                      appended-symbols
                                      0
                                      1)]
                                  [new-module-id : i64
                                    (compiler-symbols-owner-module-id-at-index
                                      appended-symbols
                                      append-index)]
                                  [new-enum-id : i64
                                    (compiler-symbols-decl-name-id-at-index
                                      appended-symbols
                                      append-index)]
                                  [new-variant-id : i64
                                    (compiler-symbols-variant-name-id-at-index
                                      appended-symbols
                                      append-index
                                      1)]
                                  (and
                                    (=
                                      (compiler-symbols-decl-count
                                        appended-symbols)
                                      (+ append-index 2))
                                    (=
                                      (compiler-registry-lookup-score
                                        (compiler-registries-lookup-variant-key-id
                                          appended-registries
                                          (compiler-symbol-module-key-id-by-id
                                            old-module-id
                                            (compiler-enum-qualified-variant-name-id
                                              old-enum-id
                                              old-variant-id)))
                                        (compiler-symbol-kind-enum-variant)
                                        0
                                        1)
                                      1)
                                    (=
                                      (compiler-registry-lookup-score
                                        (compiler-registries-lookup-variant-key-id
                                          appended-registries
                                          (compiler-symbol-module-key-id-by-id
                                            new-module-id
                                            (compiler-enum-qualified-variant-name-id
                                              new-enum-id
                                              new-variant-id)))
                                        (compiler-symbol-kind-enum-variant)
                                        append-index
                                        1)
                                      1)))]
                              [(ResultCompilerRegistries.Err _) false])]
                          [(ResultCompilerSymbols.Err _) false]))])]
                [(parser.ResultAstProgram.Err _) false])]
            [(ResultCompilerRegistries.Err _) false])]
        [(ResultCompilerSymbols.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-symbols-nominal-decl-source) : String
  "(defstruct Point (x i64) (y i64))
(defenum Maybe (None) (Some i64))
(define (main) : i64 0)")

(define (compiler-symbols-nominal-decl-ok?) : bool
  (match (parser.parse-ast-source (compiler-symbols-nominal-decl-source))
    [(parser.ResultAstProgram.Ok program)
      (match (build-compiler-symbols program)
        [(ResultCompilerSymbols.Ok symbols)
          (match (build-compiler-registries program)
            [(ResultCompilerRegistries.Ok registries)
              (and
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-type-id
                      symbols
                      (compiler-symbols-decl-name-id-at-index symbols 0))
                    (compiler-symbol-kind-defstruct)
                    0)
                  1)
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-type-id
                      symbols
                      (compiler-symbols-decl-name-id-at-index symbols 1))
                    (compiler-symbol-kind-defenum)
                    1)
                  1)
                (=
                  (compiler-registries-smoke-score program symbols registries)
                  8))]
            [(ResultCompilerRegistries.Err _) false])]
        [(ResultCompilerSymbols.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-symbols-module-scope-source) : String
  "(module left)
(define same : i64 1)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(module right)
(define same : i64 2)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))")

(define (compiler-symbols-module-scope-ok?) : bool
  (match (parser.parse-ast-source (compiler-symbols-module-scope-source))
    [(parser.ResultAstProgram.Ok program)
      (match (build-compiler-symbols program)
        [(ResultCompilerSymbols.Ok symbols)
          (match (build-compiler-registries program)
            [(ResultCompilerRegistries.Ok registries)
              (let
                [left-module-id : i64
                  (compiler-symbols-owner-module-id-at-index symbols 0)]
                [right-module-id : i64
                  (compiler-symbols-owner-module-id-at-index symbols 3)]
                [left-same-id : i64
                  (compiler-symbols-decl-name-id-at-index symbols 0)]
                [right-same-id : i64
                  (compiler-symbols-decl-name-id-at-index symbols 3)]
                [left-maybe-id : i64
                  (compiler-symbols-decl-name-id-at-index symbols 1)]
                [left-none-id : i64
                  (compiler-symbols-variant-name-id-at-index symbols 1 0)]
                [right-some-id : i64
                  (compiler-symbols-variant-name-id-at-index symbols 4 1)]
                [left-point-id : i64
                  (compiler-symbols-decl-name-id-at-index symbols 2)]
                [right-point-id : i64
                  (compiler-symbols-decl-name-id-at-index symbols 5)]
                [left-x-id : i64
                  (compiler-symbols-field-name-id-at-index symbols 2 0)]
                [right-x-id : i64
                  (compiler-symbols-field-name-id-at-index symbols 5 0)]
                (and
                  (=
                    (compiler-symbol-lookup-score
                      (compiler-symbols-lookup-value-in-module-id
                        symbols
                        left-module-id
                        left-same-id)
                      (compiler-symbol-kind-value-define)
                      0)
                    1)
                  (=
                    (compiler-symbol-lookup-score
                      (compiler-symbols-lookup-value-in-module-id
                        symbols
                        right-module-id
                        right-same-id)
                      (compiler-symbol-kind-value-define)
                      3)
                    1)
                  (=
                    (compiler-symbol-lookup-score
                      (compiler-symbols-lookup-type-in-module-id
                        symbols
                        left-module-id
                        left-maybe-id)
                      (compiler-symbol-kind-defenum)
                      1)
                    1)
                  (=
                    (compiler-symbol-lookup-score
                      (compiler-symbols-lookup-type-in-module-id
                        symbols
                        right-module-id
                        right-point-id)
                      (compiler-symbol-kind-defstruct)
                      5)
                    1)
                  (=
                    (compiler-registry-lookup-score
                      (compiler-registries-lookup-variant-key-id
                        registries
                        (compiler-symbol-module-key-id-by-id
                          left-module-id
                          left-none-id))
                      (compiler-symbol-kind-enum-variant)
                      1
                      0)
                    1)
                  (=
                    (compiler-registry-lookup-score
                      (compiler-registries-lookup-variant-key-id
                        registries
                        (compiler-symbol-module-key-id-by-id
                          right-module-id
                          right-some-id))
                      (compiler-symbol-kind-enum-variant)
                      4
                      1)
                    1)
                  (=
                    (compiler-registry-lookup-score
                      (compiler-registries-lookup-field-in-module-id
                        registries
                        left-module-id
                        left-point-id
                        left-x-id)
                      (compiler-symbol-kind-struct-field)
                      2
                      0)
                    1)
                  (=
                    (compiler-registry-lookup-score
                      (compiler-registries-lookup-field-in-module-id
                        registries
                        right-module-id
                        right-point-id
                        right-x-id)
                      (compiler-symbol-kind-struct-field)
                      5
                      0)
                    1)))]
            [(ResultCompilerRegistries.Err _) false])]
        [(ResultCompilerSymbols.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-symbols-structural-id-api-ok?) : bool
  (match (parser.parse-ast-source (compiler-symbols-module-scope-source))
    [(parser.ResultAstProgram.Ok program)
      (match (build-compiler-symbols program)
        [(ResultCompilerSymbols.Ok symbols)
          (match (build-compiler-registries program)
            [(ResultCompilerRegistries.Ok registries)
              (and
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-value-id
                      symbols
                      cbi.compiler-builtin-id-fix-left_slash_same)
                    (compiler-symbol-kind-value-define)
                    0)
                  1)
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-value-in-module-id
                      symbols
                      cbi.compiler-builtin-id-fix-right
                      cbi.compiler-builtin-id-fix-same)
                    (compiler-symbol-kind-value-define)
                    3)
                  1)
                (=
                  (compiler-symbol-lookup-score
                    (compiler-symbols-lookup-type-in-module-id
                      symbols
                      cbi.compiler-builtin-id-fix-left
                      cbi.compiler-builtin-id-fix-Maybe)
                    (compiler-symbol-kind-defenum)
                    1)
                  1)
                (=
                  (compiler-registry-lookup-score
                    (compiler-registries-lookup-variant-id
                      registries
                      cbi.compiler-builtin-id-fix-right_slash_Some)
                    (compiler-symbol-kind-enum-variant)
                    4
                    1)
                  1)
                (=
                  (compiler-registry-lookup-score
                    (compiler-registries-lookup-field-in-module-id
                      registries
                      cbi.compiler-builtin-id-fix-left
                      cbi.compiler-builtin-id-fix-Point
                      cbi.compiler-builtin-id-fix-x)
                    (compiler-symbol-kind-struct-field)
                    2
                    0)
                  1))]
            [(ResultCompilerRegistries.Err _) false])]
        [(ResultCompilerSymbols.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-symbol-map-fast-path-ok?) : bool
  (let
    [map : CompilerSymbolMap (compiler-symbol-map-empty)]
    [direct-id : i64 7]
    [structural-a : i64 (compiler-composite-pair-key-id 131073 262147)]
    [structural-b : i64 (compiler-composite-pair-key-id 131074 262148)]
    (begin
      (compiler-symbol-map-bind-id! (&mut map) direct-id 101)
      (compiler-symbol-map-bind-id! (&mut map) structural-a 201)
      (compiler-symbol-map-bind-id! (&mut map) structural-b 202)
      (and
        (match (compiler-symbol-map-lookup-id (& map) direct-id)
          [(option_i64.Some handle) (= handle 101)]
          [(option_i64.None) false])
        (match (compiler-symbol-map-lookup-id (& map) structural-a)
          [(option_i64.Some handle) (= handle 201)]
          [(option_i64.None) false])
        (match (compiler-symbol-map-lookup-id (& map) structural-b)
          [(option_i64.Some handle) (= handle 202)]
          [(option_i64.None) false])
        (compiler-symbol-map-remove-id! (&mut map) structural-a)
        (match (compiler-symbol-map-lookup-id (& map) structural-a)
          [(option_i64.Some _) false]
          [(option_i64.None) true])
        (match (compiler-symbol-map-lookup-id (& map) structural-b)
          [(option_i64.Some handle) (= handle 202)]
          [(option_i64.None) false])
        (compiler-symbol-map-remove-id! (&mut map) direct-id)
        (match (compiler-symbol-map-lookup-id (& map) direct-id)
          [(option_i64.Some _) false]
          [(option_i64.None) true])))))

(define (compiler-symbols-direct-qualified-add-ok?) : bool
  (let
    [handle : i64
      (compiler-symbol-make-handle (compiler-symbol-kind-value-define) 17)]
    [key-id : i64
      (compiler-symbol-module-key-id-by-id
        cbi.compiler-builtin-id-fix-left
        cbi.compiler-builtin-id-fix-same)]
    (match (compiler-symbols-add-value-id
      (compiler-symbols-empty)
      key-id
      "left/same"
      handle)
      [(ResultCompilerSymbols.Ok symbols)
        (and
          (=
            (compiler-symbol-lookup-score
              (compiler-symbols-lookup-value-id symbols key-id)
              (compiler-symbol-kind-value-define)
              17)
            1)
          (=
            (compiler-symbol-lookup-score
              (compiler-symbols-lookup-value-in-module-id
                symbols
                cbi.compiler-builtin-id-fix-left
                cbi.compiler-builtin-id-fix-same)
              (compiler-symbol-kind-value-define)
              17)
            1))]
      [(ResultCompilerSymbols.Err _) false])))

(define (compiler-symbols-import-alias-source) : String
  "(module data)
(define answer : i64 7)
(define (get) : i64 answer)
(defmacro (all [args : bool ...]) : bool
  `(all-from (__all-args ,@args) 0))
(defmacro (all-from [carrier : Expr] [idx : Expr]) : bool
  (match idx
    [(Expr.Int i)
      (match carrier
        [(Expr.Call _ elems)
          (if (>= i (expr-list-length elems))
            (expr-bool true)
            `(if ,(expr-list-nth elems i)
               (all-from ,carrier ,(expr-int (+ i 1)))
               false))]
        [_ (expr-bool true)])]
    [_ (expr-bool true)]))
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(module main)
(import data as d)
(define (main) : i64 (d.get))")

(define (compiler-program-first-import-alias-id [program : ast.AstProgram]) : i64
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (__tl-box-place decls-box)]
        [index : i64 0]
        [count : i64 (ast.ast-decl-list-len (& decls))]
        (begin
          (while (< index count)
            (match (ast.ast-decl-list-get
              (& decls)
              index
              (ast.ast-decl-fallback))
              [(ast.AstDecl.Import
                  decl-meta
                  (ast.AstImportSpec.Spec
                    _
                    _
                    _
                    (ast.AstMaybeImportAlias.Some alias-id)
                    _))
                (return alias-id)]
              [_ (set! index (+ index 1))]))
          -1))]))

(define (compiler-symbols-import-alias-ok?) : bool
  (match (parser.parse-ast-source (compiler-symbols-import-alias-source))
    [(parser.ResultAstProgram.Ok program)
      (match (build-compiler-symbols program)
        [(ResultCompilerSymbols.Ok symbols)
          (match (build-compiler-registries program)
            [(ResultCompilerRegistries.Ok registries)
              (let
                [alias-id : i64
                  (compiler-program-first-import-alias-id program)]
                [get-id : i64
                  (compiler-symbols-decl-name-id-at-index symbols 1)]
                [all-id : i64
                  (compiler-symbols-decl-name-id-at-index symbols 2)]
                [point-id : i64
                  (compiler-symbols-decl-name-id-at-index symbols 5)]
                [some-id : i64
                  (compiler-symbols-variant-name-id-at-index symbols 4 1)]
                [x-id : i64
                  (compiler-symbols-field-name-id-at-index symbols 5 0)]
                (and
                  (=
                    (compiler-symbols-miss-score
                      (compiler-symbols-lookup-value-id
                        symbols
                        (compiler-symbol-module-key-id-by-id alias-id get-id)))
                    1)
                  (=
                    (compiler-symbol-lookup-score
                      (compiler-symbols-lookup-value-id symbols get-id)
                      (compiler-symbol-kind-function-define)
                      1)
                    1)
                  (=
                    (compiler-symbols-miss-score
                      (compiler-symbols-lookup-macro-id
                        symbols
                        (compiler-symbol-module-key-id-by-id alias-id all-id)))
                    1)
                  (=
                    (compiler-symbols-miss-score
                      (compiler-symbols-lookup-macro-id symbols all-id))
                    1)
                  (=
                    (compiler-symbols-miss-score
                      (compiler-symbols-lookup-type-id
                        symbols
                        (compiler-symbol-module-key-id-by-id alias-id point-id)))
                    1)
                  (=
                    (compiler-symbol-lookup-score
                      (compiler-symbols-lookup-type-id symbols point-id)
                      (compiler-symbol-kind-defstruct)
                      5)
                    1)
                  (=
                    (compiler-registry-miss-score
                      (compiler-registries-lookup-variant-key-id
                        registries
                        (compiler-symbol-module-key-id-by-id alias-id some-id)))
                    1)
                  (=
                    (compiler-registry-lookup-score
                      (compiler-registries-lookup-variant-id registries some-id)
                      (compiler-symbol-kind-enum-variant)
                      4
                      1)
                    1)
                  (=
                    (compiler-registry-miss-score
                      (compiler-registries-lookup-field-in-module-id
                        registries
                        alias-id
                        point-id
                        x-id))
                    1)))]
            [(ResultCompilerRegistries.Err _) false])]
        [(ResultCompilerSymbols.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-symbols-comptime-root-helper-alias-source) : String
  "(module stdlib.comptime)
(defenum Expr (Bool bool))
(define (string.int->string [value : i64]) : String \"\")
(define (string.append [left : String] [right : String]) : String left)
(define (string.concat [left : String] [right : String]) : String left)
(define (expr-bool [value : bool]) : Expr (Expr.Bool value))
(module main)
(defenum Expr (Bool i64))
(define (expr-bool [value : i64]) : i64 value)")

(define (compiler-symbols-comptime-root-helper-alias-ok?) : bool
  (match (parser.parse-ast-source
    (compiler-symbols-comptime-root-helper-alias-source))
    [(parser.ResultAstProgram.Ok program)
      (match (build-compiler-symbols program)
        [(ResultCompilerSymbols.Ok symbols)
          (let
            [comptime-module-id : i64
              (compiler-symbols-owner-module-id-at-index symbols 0)]
            [comptime-expr-id : i64
              (compiler-symbols-decl-name-id-at-index symbols 0)]
            [int-to-string-id : i64
              (compiler-symbols-decl-name-id-at-index symbols 1)]
            [append-id : i64 (compiler-symbols-decl-name-id-at-index symbols 2)]
            [concat-id : i64 (compiler-symbols-decl-name-id-at-index symbols 3)]
            [comptime-expr-bool-id : i64
              (compiler-symbols-decl-name-id-at-index symbols 4)]
            [main-expr-id : i64
              (compiler-symbols-decl-name-id-at-index symbols 5)]
            [main-expr-bool-id : i64
              (compiler-symbols-decl-name-id-at-index symbols 6)]
            [main-expr-bool-variant-id : i64
              (compiler-symbols-variant-name-id-at-index symbols 5 0)]
            (and
              (=
                (compiler-symbol-lookup-score
                  (compiler-symbols-lookup-value-in-module-id
                    symbols
                    comptime-module-id
                    int-to-string-id)
                  (compiler-symbol-kind-function-define)
                  1)
                1)
              (=
                (compiler-symbol-lookup-score
                  (compiler-symbols-lookup-value-in-module-id
                    symbols
                    comptime-module-id
                    append-id)
                  (compiler-symbol-kind-function-define)
                  2)
                1)
              (=
                (compiler-symbol-lookup-score
                  (compiler-symbols-lookup-value-in-module-id
                    symbols
                    comptime-module-id
                    concat-id)
                  (compiler-symbol-kind-function-define)
                  3)
                1)
              (=
                (compiler-symbol-lookup-score
                  (compiler-symbols-lookup-value-in-module-id
                    symbols
                    comptime-module-id
                    comptime-expr-bool-id)
                  (compiler-symbol-kind-function-define)
                  4)
                1)
              (=
                (compiler-symbol-lookup-score
                  (compiler-symbols-lookup-type-in-module-id
                    symbols
                    comptime-module-id
                    comptime-expr-id)
                  (compiler-symbol-kind-defenum)
                  0)
                1)
              (=
                (compiler-symbols-miss-score
                  (compiler-symbols-lookup-value-id
                    symbols
                    (cbi.compiler-builtin-ctfe-ref 16)))
                1)
              (=
                (compiler-symbols-miss-score
                  (compiler-symbols-lookup-value-id
                    symbols
                    (cbi.compiler-builtin-ctfe-ref 14)))
                1)
              (=
                (compiler-symbols-miss-score
                  (compiler-symbols-lookup-value-id
                    symbols
                    (cbi.compiler-builtin-ctfe-ref 15)))
                1)
              (=
                (compiler-symbol-lookup-score
                  (compiler-symbols-lookup-value-id symbols main-expr-bool-id)
                  (compiler-symbol-kind-function-define)
                  6)
                1)
              (=
                (compiler-symbol-lookup-score
                  (compiler-symbols-lookup-type-id symbols main-expr-id)
                  (compiler-symbol-kind-defenum)
                  5)
                1)
              (=
                (compiler-registry-lookup-score
                  (compiler-symbols-lookup-value-id
                    symbols
                    main-expr-bool-variant-id)
                  (compiler-symbol-kind-enum-variant)
                  5
                  0)
                1)))]
        [(ResultCompilerSymbols.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-symbol-map-structure-ok?) : bool
  (let
    [map : CompilerSymbolMap (compiler-symbol-map-with-capacity 4)]
    (begin
      ;; These keys share low hash bits, exercising probing, growth, deletion,
      ;; tombstone reuse, and update without relying on compiler declarations.
      (compiler-symbol-map-put! (&mut map) 0 10)
      (compiler-symbol-map-put! (&mut map) 4 20)
      (compiler-symbol-map-put! (&mut map) 8 30)
      (compiler-symbol-map-put! (&mut map) 12 40)
      (compiler-symbol-map-put! (&mut map) 4 21)
      (unless (compiler-symbol-map-remove-id! (&mut map) 8) (return false))
      (compiler-symbol-map-put! (&mut map) 16 50)
      (and
        (= (array-length map.keys) 8)
        (= map.len 4)
        (= map.deleted 0)
        (= (compiler-symbol-map-lookup-handle-id (& map) 0) 10)
        (= (compiler-symbol-map-lookup-handle-id (& map) 4) 21)
        (=
          (compiler-symbol-map-lookup-handle-id (& map) 8)
          (compiler-symbol-map-missing-handle))
        (= (compiler-symbol-map-lookup-handle-id (& map) 12) 40)
        (= (compiler-symbol-map-lookup-handle-id (& map) 16) 50)
        (not (compiler-symbol-map-remove-id! (&mut map) 24))))))

(define (compiler-symbols-dotted-variant-id-source) : String
  "(define deep : i64 a.b.Enum.Variant)
(define qualified : i64 q/a.b.Enum.Variant)")

(define (compiler-symbols-dotted-variant-id-paths-ok?) : bool
  (match (parser.parse-ast-source (compiler-symbols-dotted-variant-id-source))
    [(parser.ResultAstProgram.Ok program)
      (match (build-compiler-symbols program)
        [(ResultCompilerSymbols.Ok symbols)
          (let
            [deep-id : i64
              (compiler-symbols-decl-value-source-id-at-index symbols 0)]
            [qualified-id : i64
              (compiler-symbols-decl-value-source-id-at-index symbols 1)]
            [deep-enum-path-id : i64 (ci.intern-dotted-prefix-id deep-id)]
            [deep-variant-id : i64 (ci.intern-dotted-final-id deep-id)]
            [deep-expected : i64
              (compiler-symbol-module-key-id-by-id
                (ci.intern-dotted-prefix-id deep-enum-path-id)
                (compiler-enum-qualified-variant-name-id
                  (ci.intern-dotted-final-id deep-enum-path-id)
                  deep-variant-id))]
            [qualified-base-id : i64 (ci.intern-qualified-base-id qualified-id)]
            [qualified-variant-id : i64
              (ci.intern-dotted-final-id qualified-base-id)]
            [qualified-expected : i64
              (compiler-symbol-module-key-id-by-id
                (ci.intern-qualified-module-id qualified-id)
                (compiler-enum-qualified-variant-name-id
                  (ci.intern-dotted-prefix-id qualified-base-id)
                  qualified-variant-id))]
            (and
              (match (compiler-symbol-dotted-variant-key-id deep-id)
                [(option_i64.Some key-id) (= key-id deep-expected)]
                [(option_i64.None) false])
              (match (compiler-symbol-dotted-variant-key-id qualified-id)
                [(option_i64.Some key-id) (= key-id qualified-expected)]
                [(option_i64.None) false])))]
        [(ResultCompilerSymbols.Err _) false])]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-symbols-dotted-suffix-owner-module-id-ok?) : bool
  (let
    [source-full : i64 (ci.intern "root.branch.leaf")]
    [source-qualified-full : i64 (ci.intern "module/root.branch.leaf")]
    [source-branch-leaf : i64 (ci.intern "branch.leaf")]
    [source-leaf : i64 (ci.intern "leaf")]
    [source-modules : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        (sym_i64_env.sym-i64-bind-id (sym_i64_env.sym-i64-empty) source-leaf 12)
        source-branch-leaf
        11)]
    [source-leaf-only : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id (sym_i64_env.sym-i64-empty) source-leaf 12)]
    [source-full-only : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id (sym_i64_env.sym-i64-empty) source-full 10)]
    [generated-root : i64 (ci.intern-generated-name "root")]
    [generated-branch : i64 (ci.intern-generated-name "branch")]
    [generated-leaf : i64 (ci.intern-generated-name "leaf")]
    [generated-root-branch : i64
      (ci.intern-generated-dotted-name
        "root.branch"
        generated-root
        generated-root
        generated-branch)]
    [generated-branch-leaf : i64
      (ci.intern-generated-dotted-name
        "branch.leaf"
        generated-branch
        generated-branch
        generated-leaf)]
    [generated-full : i64
      (ci.intern-generated-dotted-name
        "root.branch.leaf"
        generated-root
        generated-root-branch
        generated-branch-leaf)]
    [generated-opaque-full : i64 (ci.intern-generated-name "root.branch.leaf")]
    [generated-modules : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id
        (sym_i64_env.sym-i64-bind-id
          (sym_i64_env.sym-i64-empty)
          generated-leaf
          22)
        generated-branch-leaf
        21)]
    [single : i64 (ci.intern "single")]
    [single-module : sym_i64_env.SymI64Env
      (sym_i64_env.sym-i64-bind-id (sym_i64_env.sym-i64-empty) single 31)]
    (and
      (not (= source-branch-leaf generated-branch-leaf))
      (not (= source-leaf generated-leaf))
      (=
        (compiler-symbols-dotted-suffix-owner-module-id
          source-modules
          source-full)
        11)
      (=
        (compiler-symbols-dotted-suffix-owner-module-id
          source-leaf-only
          source-full)
        12)
      (=
        (compiler-symbols-dotted-suffix-owner-module-id
          source-modules
          source-qualified-full)
        11)
      (=
        (compiler-symbols-dotted-suffix-owner-module-id
          generated-modules
          generated-full)
        21)
      (=
        (compiler-symbols-dotted-suffix-owner-module-id
          generated-modules
          generated-opaque-full)
        -1)
      (=
        (compiler-symbols-dotted-suffix-owner-module-id
          source-modules
          generated-full)
        -1)
      (=
        (compiler-symbols-dotted-suffix-owner-module-id
          generated-modules
          source-full)
        -1)
      (=
        (compiler-symbols-dotted-suffix-owner-module-id
          source-full-only
          source-full)
        -1)
      (=
        (compiler-symbols-dotted-suffix-owner-module-id single-module single)
        -1)
      (=
        (compiler-symbols-dotted-suffix-owner-module-id
          (sym_i64_env.sym-i64-empty)
          source-full)
        -1))))

(define (compiler-symbols-module-id-identity-ok?) : bool
  (let
    [generated-empty-id : i64 (ci.intern-generated-canonical-name "")]
    [generated-comptime-id : i64
      (ci.intern-generated-canonical-name "stdlib.comptime")]
    [struct-id : i64 cbi.compiler-builtin-id-fix-Point]
    [field-id : i64 cbi.compiler-builtin-id-fix-x]
    (and
      (compiler-symbol-root-module-id? (compiler-symbol-root-module-id))
      (compiler-symbol-root-module-id? cbi.compiler-builtin-id-fix-empty)
      (not (compiler-symbol-root-module-id? generated-empty-id))
      (compiler-symbols-comptime-module-id?
        cbi.compiler-builtin-id-fix-stdlib_dot_comptime)
      (not
        (compiler-symbols-comptime-module-id? (compiler-symbol-root-module-id)))
      (not (compiler-symbols-comptime-module-id? generated-comptime-id))
      (=
        (compiler-struct-field-key-id-in-module-by-id
          cbi.compiler-builtin-id-fix-empty
          struct-id
          field-id)
        (compiler-composite-pair-key-id struct-id field-id))
      (=
        (compiler-struct-field-key-id-in-module-by-id
          generated-empty-id
          struct-id
          field-id)
        (compiler-composite-triple-key-id generated-empty-id struct-id field-id)))))

(define (compiler-symbols-defining-provenance-survives-owner-rewrite-ok?) : bool
  (match (parser.parse-ast-source "(define chosen : i64 42)")
    [(parser.ResultAstProgram.Ok program)
      (let
        [paths : ast.AstDeclPathList (ast.ast-decl-path-list-new)]
        [modules : ast.AstDeclModuleList (ast.ast-decl-module-list-new)]
        [recorded-owner : i64 (ci.intern "dependency.source")]
        [rewritten-owner : i64 (ci.intern "consumer.visible")]
        [provenance : i64 (ci.intern "deps/example/src/lib.tl")]
        (begin
          (ast.ast-decl-path-list-push-with-owner-and-provenance-id
            (&mut paths)
            "deps/example/src/lib.tl"
            recorded-owner
            provenance)
          (ast.ast-decl-module-list-push-id (&mut modules) rewritten-owner)
          (let
            [rewritten : ast.AstDeclPathList
              (ast.ast-decl-path-list-with-modules paths modules)]
            (match (build-compiler-symbols-with-paths program rewritten)
              [(ResultCompilerSymbols.Ok symbols)
                (and
                  (=
                    (ast.ast-decl-path-list-owner-id (& rewritten) 0 -1)
                    rewritten-owner)
                  (=
                    (compiler-symbols-provenance-id-at-index-or symbols 0 -1)
                    provenance)
                  (=
                    (ast.ast-decl-path-list-provenance-id (& rewritten) 0 -1)
                    provenance))]
              [(ResultCompilerSymbols.Err _) false]))))]
    [(parser.ResultAstProgram.Err _) false]))

(define (compiler-symbols-self-test) : i64
  (begin
    (cbi.compiler-builtin-refresh!)
    (match (parser.parse-ast-source (compiler-symbols-smoke-source))
      [(parser.ResultAstProgram.Ok program)
        (match (build-compiler-symbols program)
          [(ResultCompilerSymbols.Ok symbols)
            (match (build-compiler-registries program)
              [(ResultCompilerRegistries.Ok registries)
                (let
                  [ok : bool true]
                  (begin
                    (if (= (compiler-symbols-smoke-score symbols) 10)
                      unit
                      (set! ok false))
                    (if (=
                      (compiler-registries-smoke-score
                        program
                        symbols
                        registries)
                      8)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-duplicate-value-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-duplicate-type-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-module-duplicate-diagnostics-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-module-duplicate-with-paths-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-variant-value-collisions-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-struct-value-collisions-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-registries-duplicate-variant-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-registries-cross-enum-variant-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-registries-duplicate-field-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-registry-large-owner-handle-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-registry-shift-map-full-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-registries-incremental-splice-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-registries-lifetime-field-indexed-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-append-splice-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-append-external-macro-alias-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-nominal-decl-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-module-scope-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-structural-id-api-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbol-map-fast-path-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-direct-qualified-add-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-import-alias-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-comptime-root-helper-alias-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-macro-namespace-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-duplicate-macro-value-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbol-map-structure-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-dotted-variant-id-paths-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-dotted-suffix-owner-module-id-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-module-id-identity-ok?)
                      unit
                      (set! ok false))
                    (if (compiler-symbols-defining-provenance-survives-owner-rewrite-ok?)
                      unit
                      (set! ok false))
                    (if ok
                      42
                      (io.panic "symbols: smoke score mismatch"))))]
              [(ResultCompilerRegistries.Err message) (io.panic message)])]
          [(ResultCompilerSymbols.Err message) (io.panic message)])]
      [(parser.ResultAstProgram.Err message) (io.panic message)])))