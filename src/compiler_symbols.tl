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
(import compiler_owned_view as owned_view)
(import sym_i64_env)
(import stdlib.string)
(import stdlib.option)
(import (option.option i64) as option_i64)

(defstruct CompilerSymbolsProgramRef
  (:lifetimes program)
  (value (& program ast.AstProgram)))

(defmacro (compiler-symbols-decl-shared-view [decl : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,decl))))

(define (compiler-symbols-program-shared-view
  [program : (& program ast.AstProgram)]) : ast.AstProgram
  (let
    [cell : (CompilerSymbolsProgramRef program)
      (CompilerSymbolsProgramRef program)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr address : (Ptr ast.AstProgram))))))

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

(defstruct CompilerSymbolsRef
  (:lifetimes symbols)
  (value (& symbols CompilerSymbols)))

;; A type map is append-only after construction. Its backing allocation
;; identifies one table incarnation, while `generation` observes additions
;; that fit without reallocating. Job-owned lookup caches use both fields so a
;; negative result cannot survive symbol growth or a rebuilt macro view.
(defstruct CompilerSymbolsTypeMapStamp
  (owner i64)
  (generation i64))

(define (compiler-symbols-shared-view [symbols : (& symbols CompilerSymbols)]) : CompilerSymbols
  (let
    [cell : (CompilerSymbolsRef symbols) (CompilerSymbolsRef symbols)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr address : (Ptr CompilerSymbols))))))

(defmacro (compiler-symbols-reference-shared-view [symbols : Expr]) : Expr
  `(owned_view.compiler-owned-reference-shared-view ,symbols))

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

(defstruct CompilerRegistriesRef
  (:lifetimes registries)
  (value (& registries CompilerRegistries)))

(define (compiler-registries-shared-view
  [registries : (& registries CompilerRegistries)]) : CompilerRegistries
  (let
    [cell : (CompilerRegistriesRef registries)
      (CompilerRegistriesRef registries)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr address : (Ptr CompilerRegistries))))))

(defmacro (compiler-registries-reference-shared-view [registries : Expr]) : Expr
  `(owned_view.compiler-owned-reference-shared-view ,registries))

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

;; A macro symbol generation can build this short-lived side channel in a
;; scratch arena, while its caller converts the returned String error into a
;; rich diagnostic only after retiring that arena. Copy the sole allocated
;; field into the caller's active arena before that retirement; the span and
;; flag are scalar values.
(define (compiler-symbols-stabilize-last-error!) : unit
  (set!
    compiler-symbols-last-error-path
    (string.copy (& compiler-symbols-last-error-path))))

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
    [(ast.AstDecl.Test _ _ _ span) (CompilerSymbolsMaybeSpan.Some span)]
    [(ast.AstDecl.Unsafe inner-box)
      (compiler-symbols-decl-maybe-span (deref inner-box))]
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

;; A symbol handle is `kind * handle-stride + index`. A registry (member)
;; handle splits the index into `owner-index * child-stride + child-index`.
;; Both ranges are bounded so that no two (kind, owner, child) triples share a
;; handle: child indexes stay below the child stride and owner indexes below
;; handle-stride / child-stride; otherwise a child index past the stride decodes
;; as a child of the next declaration and types a field through the wrong
;; struct. Both strides are powers of two (2^50 and 2^20), so
;; typecheck's frequent handle decoding is shifts and masks rather than
;; multiplications by 64-bit constants.
(define (compiler-symbol-handle-stride) : i64
  1125899906842624)

(define (compiler-registry-child-stride) : i64
  1048576)

;; Owner (declaration) indexes a registry handle can encode.
(define (compiler-registry-owner-limit) : i64
  (/ (compiler-symbol-handle-stride) (compiler-registry-child-stride)))

;; True when a registry handle can encode this owner and child without
;; aliasing another member.
(define (compiler-registry-indexes-encodable?
  [owner-index : i64]
  [child-index : i64]) : bool
  (and
    (>= owner-index 0)
    (< owner-index (compiler-registry-owner-limit))
    (>= child-index 0)
    (< child-index (compiler-registry-child-stride))))

;; Diagnostic for a declaration whose members exceed what a registry handle
;; can encode. Registration reports it before any handle is built.
(define (compiler-registry-limit-message
  [declaration-kind : String]
  [owner-name : String]
  [member-kind : String]
  [owner-index : i64]) : String
  (if (and (>= owner-index 0) (< owner-index (compiler-registry-owner-limit)))
    (str_cat.str-cat
      "symbols: "
      declaration-kind
      " "
      owner-name
      " has more than "
      (string.int->string (compiler-registry-child-stride))
      " "
      member-kind
      "; a struct or enum declares at most "
      (string.int->string (compiler-registry-child-stride))
      " members")
    (str_cat.str-cat
      "symbols: "
      declaration-kind
      " "
      owner-name
      " is beyond the "
      (string.int->string (compiler-registry-owner-limit))
      "-declaration limit for structs and enums")))

(define (compiler-symbol-make-handle [kind : i64] [index : i64]) : i64
  (+ (* kind (compiler-symbol-handle-stride)) index))

(define (compiler-symbol-handle-kind [handle : i64]) : i64
  (/ handle (compiler-symbol-handle-stride)))

(define (compiler-symbol-handle-index [handle : i64]) : i64
  (% handle (compiler-symbol-handle-stride)))

;; Registration rejects unencodable indexes with a located diagnostic first;
;; reaching the panic is a compiler bug, never an aliasing handle.
(define (compiler-registry-make-handle
  [kind : i64]
  [owner-index : i64]
  [child-index : i64]) : i64
  (if (compiler-registry-indexes-encodable? owner-index child-index)
    (+
      (* kind (compiler-symbol-handle-stride))
      (+ (* owner-index (compiler-registry-child-stride)) child-index))
    (io.panic "symbols: registry handle indexes are out of range")))

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
            (ptr-cast (__tl_array-data keys) : (Ptr i64)))]
        [value-data : (Ptr i64)
          (unsafe
            (ptr-cast (__tl_array-data values) : (Ptr i64)))]
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
        (ptr-cast (__tl_array-data keys) : (MutPtr i64)))]
    [value-data : (MutPtr i64)
      (unsafe
        (ptr-cast (__tl_array-data values) : (MutPtr i64)))]
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

(define (compiler-decl-list-index-count [decls : (& decls ast.AstDeclList)]) : i64
  (let
    [count : i64 0]
    [index : i64 0]
    [decl-count : i64 (ast.ast-decl-list-len (& decls))]
    [decl-offset : i64 decls.offset]
    (begin
      (while (< index decl-count)
        (let
          [decl : ast.AstDecl
            (ast.ast-array-shared-view decls.slots (+ decl-offset index))]
          (begin
            (match decl
              [(ast.AstDecl.Import decl-meta _) unit]
              [(ast.AstDecl.Module _) unit]
              [(ast.AstDecl.ModuleBody _ body-box)
                (set!
                  count
                  (+ count (compiler-decl-list-index-count (deref body-box))))]
              [(ast.AstDecl.Test _ _ _ _) unit]
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

(define (compiler-registries-identity
  [registries : (& registries CompilerRegistries)]) : i64
  (match (compiler-registries-reference-shared-view registries)
    [(CompilerRegistries _ _ identity) identity]))

(define (compiler-symbols-lookup-value-id
  [symbols : (& symbols CompilerSymbols)]
  [name-id : i64]) : option_i64.Option
  (match (compiler-symbols-reference-shared-view symbols)
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
  [symbols : (& symbols CompilerSymbols)]
  [name-id : i64]) : option_i64.Option
  (match (compiler-symbols-reference-shared-view symbols)
    [(CompilerSymbols _ types _ _ _ _)
      (compiler-symbol-map-lookup-id
        (& types)
        (compiler-symbol-name-id-key name-id))]))

(defmacro (compiler-symbols-type-map-stamp [symbols : Expr]) : Expr
  `(match (compiler-symbols-reference-shared-view ,symbols)
    [(CompilerSymbols _ types _ _ _ _)
      (CompilerSymbolsTypeMapStamp
        (cast
          (unsafe
            (ptr->int (ptr-cast (__tl_array-data types.keys) : (Ptr i64))))
          : i64)
        types.len)]))

(define (compiler-symbols-lookup-macro-id
  [symbols : (& symbols CompilerSymbols)]
  [name-id : i64]) : option_i64.Option
  (match (compiler-symbols-reference-shared-view symbols)
    [(CompilerSymbols _ _ macros _ _ _)
      (compiler-symbol-map-lookup-id
        (& macros)
        (compiler-symbol-name-id-key name-id))]))

(define (compiler-symbols-missing-handle) : i64
  (compiler-symbol-map-missing-handle))

(define (compiler-symbols-handle-found? [handle : i64]) : bool
  (>= handle 0))

(define (compiler-symbols-lookup-value-id-or
  [symbols : (& symbols CompilerSymbols)]
  [name-id : i64]
  [fallback : i64]) : i64
  (match (compiler-symbols-reference-shared-view symbols)
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
  [symbols : (& symbols CompilerSymbols)]
  [name-id : i64]
  [fallback : i64]) : i64
  (match (compiler-symbols-reference-shared-view symbols)
    [(CompilerSymbols _ types _ _ _ _)
      (let
        [handle : i64
          (compiler-symbol-map-lookup-handle-id
            (& types)
            (compiler-symbol-name-id-key name-id))]
        (if (>= handle 0)
          handle
          fallback))]))

(define (compiler-symbols-decls [symbols : (& symbols CompilerSymbols)]) : (__tl_dyn-array
    ast.AstDecl)
  (match (compiler-symbols-reference-shared-view symbols)
    [(CompilerSymbols _ _ _ decls _ _) decls]))

(define (compiler-symbols-owner-module-ids
  [symbols : (& symbols CompilerSymbols)]) : (__tl_dyn-array i64)
  (match (compiler-symbols-reference-shared-view symbols)
    [(CompilerSymbols _ _ _ _ owner-module-ids _) owner-module-ids]))

(define (compiler-symbols-decl-count [symbols : (& symbols CompilerSymbols)]) : i64
  (match (compiler-symbols-reference-shared-view symbols)
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
  (match (compiler-symbols-shared-view symbols)
    [(CompilerSymbols values types macros decls owner-module-ids decl-count)
      (let
        [capacity : i64 (array-length decls)]
        (if (>= capacity required)
          (CompilerSymbols
            values
            types
            macros
            decls
            owner-module-ids
            decl-count)
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
  (match (compiler-symbols-shared-view symbols)
    [(CompilerSymbols values types macros decls owner-module-ids _)
      (CompilerSymbols values types macros decls owner-module-ids decl-count)]))

(define (compiler-symbols-duplicate-value-message [name : String]) : String
  (str_cat.str-cat "symbols: duplicate value declaration " name))

(define (compiler-symbols-duplicate-type-message [name : String]) : String
  (str_cat.str-cat "symbols: duplicate type declaration " name))

(define (compiler-symbols-duplicate-macro-message [name : String]) : String
  (str_cat.str-cat "symbols: duplicate macro declaration " name))

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
  [symbols : CompilerSymbols]
  [key-id : i64]
  [handle : i64]) : CompilerSymbols
  (match (compiler-symbols-shared-view symbols)
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (if (compiler-symbol-map-contains-id? (& values) key-id)
        (CompilerSymbols values types macros decls owner-names decl-count)
        (begin
          (compiler-symbol-map-bind-id! (&mut values) key-id handle)
          (CompilerSymbols values types macros decls owner-names decl-count)))]))

(define (compiler-symbols-add-type-alias-key-id
  [symbols : CompilerSymbols]
  [key-id : i64]
  [handle : i64]) : CompilerSymbols
  (match (compiler-symbols-shared-view symbols)
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (if (compiler-symbol-map-contains-id? (& types) key-id)
        (CompilerSymbols values types macros decls owner-names decl-count)
        (begin
          (compiler-symbol-map-bind-id! (&mut types) key-id handle)
          (CompilerSymbols values types macros decls owner-names decl-count)))]))

(define (compiler-symbols-add-macro-alias-key-id
  [symbols : CompilerSymbols]
  [key-id : i64]
  [handle : i64]) : CompilerSymbols
  (match (compiler-symbols-shared-view symbols)
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (if (compiler-symbol-map-contains-id? (& macros) key-id)
        (CompilerSymbols values types macros decls owner-names decl-count)
        (begin
          (compiler-symbol-map-bind-id! (&mut macros) key-id handle)
          (CompilerSymbols values types macros decls owner-names decl-count)))]))

(define (compiler-symbols-remove-macro-alias-if-handle
  [symbols : CompilerSymbols]
  [name-id : i64]
  [handle : i64]) : CompilerSymbols
  (match (compiler-symbols-shared-view symbols)
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
              (CompilerSymbols values types macros decls owner-names decl-count))
            (CompilerSymbols values types macros decls owner-names decl-count))]
        [(option_i64.None)
          (CompilerSymbols values types macros decls owner-names decl-count)])]))

(define (compiler-registries-add-variant-alias-key-id
  [registries : CompilerRegistries]
  [key-id : i64]
  [handle : i64]) : CompilerRegistries
  (match (compiler-registries-shared-view registries)
    [(CompilerRegistries variants fields identity)
      (if (compiler-symbol-map-contains-id? (& variants) key-id)
        (CompilerRegistries variants fields identity)
        (begin
          (compiler-symbol-map-bind-id! (&mut variants) key-id handle)
          (CompilerRegistries variants fields identity)))]))

;; SPEC 4.4.2 requires value and macro declarations to remain independent even
;; when their spelling is identical. Duplicate checks therefore consult only
;; the map for the namespace being populated.
(define (compiler-symbols-add-value-id
  [symbols : CompilerSymbols]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match (compiler-symbols-shared-view symbols)
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (if (compiler-symbol-map-contains-id? (& values) name-id)
        (ResultCompilerSymbols.Err
          (compiler-symbols-duplicate-value-message display-name))
        (begin
          (compiler-symbol-map-bind-id! (&mut values) name-id handle)
          (ResultCompilerSymbols.Ok
            (CompilerSymbols values types macros decls owner-names decl-count))))]))

(define (compiler-symbols-add-type-id
  [symbols : CompilerSymbols]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match (compiler-symbols-shared-view symbols)
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (if (compiler-symbol-map-contains-id? (& types) name-id)
        (ResultCompilerSymbols.Err
          (compiler-symbols-duplicate-type-message display-name))
        (begin
          (compiler-symbol-map-bind-id! (&mut types) name-id handle)
          (ResultCompilerSymbols.Ok
            (CompilerSymbols values types macros decls owner-names decl-count))))]))

(define (compiler-symbols-add-macro-id
  [symbols : CompilerSymbols]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match (compiler-symbols-shared-view symbols)
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (if (compiler-symbol-map-contains-id? (& macros) name-id)
        (ResultCompilerSymbols.Err
          (compiler-symbols-duplicate-macro-message display-name))
        (begin
          (compiler-symbol-map-bind-id! (&mut macros) name-id handle)
          (ResultCompilerSymbols.Ok
            (CompilerSymbols values types macros decls owner-names decl-count))))]))

(define (compiler-symbols-handle-from-nonroot-owner?
  [symbols : (& symbols CompilerSymbols)]
  [handle : i64]) : bool
  (not
    (compiler-symbol-root-module-id?
      (compiler-symbols-owner-module-id-at-index-or
        symbols
        (compiler-symbol-handle-index handle)
        (compiler-symbol-root-module-id)))))

(define (compiler-symbols-add-root-macro-id
  [symbols : CompilerSymbols]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match (compiler-symbols-shared-view symbols)
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (match (compiler-symbol-map-lookup-id (& macros) name-id)
        [(option_i64.Some existing)
          (if (compiler-symbols-handle-from-nonroot-owner? symbols existing)
            (begin
              (compiler-symbol-map-bind-id! (&mut macros) name-id handle)
              (ResultCompilerSymbols.Ok
                (CompilerSymbols
                  values
                  types
                  macros
                  decls
                  owner-names
                  decl-count)))
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-macro-message display-name)))]
        [(option_i64.None)
          (begin
            (compiler-symbol-map-bind-id! (&mut macros) name-id handle)
            (ResultCompilerSymbols.Ok
              (CompilerSymbols values types macros decls owner-names decl-count)))])]))

(define (compiler-symbols-add-root-value-id
  [symbols : CompilerSymbols]
  [name-id : i64]
  [display-name : String]
  [handle : i64]) : ResultCompilerSymbols
  (match (compiler-symbols-shared-view symbols)
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (match (compiler-symbol-map-lookup-id (& values) name-id)
        [(option_i64.Some existing)
          (if (compiler-symbols-handle-from-nonroot-owner? symbols existing)
            (begin
              (compiler-symbol-map-bind-id! (&mut values) name-id handle)
              (ResultCompilerSymbols.Ok
                (CompilerSymbols
                  values
                  types
                  macros
                  decls
                  owner-names
                  decl-count)))
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-value-message display-name)))]
        [(option_i64.None)
          (begin
            (compiler-symbol-map-bind-id! (&mut values) name-id handle)
            (ResultCompilerSymbols.Ok
              (CompilerSymbols values types macros decls owner-names decl-count)))])]))

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
  [symbols : CompilerSymbols]
  [key-id : i64]
  [module-id : i64]
  [display-name-id : i64]
  [handle : i64]) : ResultCompilerSymbols
  (match (compiler-symbols-shared-view symbols)
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
          (begin
            (compiler-symbol-map-bind-id! (&mut values) key-id handle)
            (ResultCompilerSymbols.Ok
              (CompilerSymbols values types macros decls owner-names decl-count)))])]))

(define (compiler-symbols-add-variant-flat-value-alias-key-in-module-id
  [symbols : CompilerSymbols]
  [key-id : i64]
  [module-id : i64]
  [display-name-id : i64]
  [handle : i64]) : ResultCompilerSymbols
  (match (compiler-symbols-shared-view symbols)
    [(CompilerSymbols values types macros decls owner-names decl-count)
      (match (compiler-symbol-map-lookup-id (& values) key-id)
        [(option_i64.Some existing)
          (if (=
            (compiler-symbol-handle-kind existing)
            (compiler-symbol-kind-enum-variant))
            (ResultCompilerSymbols.Ok
              (CompilerSymbols values types macros decls owner-names decl-count))
            (ResultCompilerSymbols.Err
              (compiler-symbols-duplicate-value-message
                (compiler-symbol-module-key-by-id module-id display-name-id))))]
        [(option_i64.None)
          (begin
            (compiler-symbol-map-bind-id! (&mut values) key-id handle)
            (ResultCompilerSymbols.Ok
              (CompilerSymbols values types macros decls owner-names decl-count)))])]))

(define (compiler-symbols-add-variant-value-in-module-id
  [symbols : CompilerSymbols]
  [module-id : i64]
  [enum-name-id : i64]
  [name-id : i64]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerSymbols
  (if (not (compiler-registry-indexes-encodable? enum-index variant-index))
    (ResultCompilerSymbols.Err
      (compiler-registry-limit-message
        "enum"
        (compiler-symbol-module-key-by-id module-id enum-name-id)
        "variants"
        enum-index))
    (let
      [qualified-name-id : i64
        (compiler-enum-qualified-variant-name-id enum-name-id name-id)]
      [qualified-key-id : i64
        (compiler-symbol-module-key-id-by-id module-id qualified-name-id)]
      [flat-key-id : i64
        (compiler-symbol-module-key-id-by-id module-id name-id)]
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
        [(ResultCompilerSymbols.Err message)
          (ResultCompilerSymbols.Err message)]))))

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
  [symbols : (& symbols CompilerSymbols)]
  [module-id : i64]
  [name-id : i64]) : option_i64.Option
  (match (compiler-symbols-reference-shared-view symbols)
    [(CompilerSymbols values _ _ _ _ _)
      (compiler-symbol-map-lookup-id
        (& values)
        (compiler-symbol-module-key-id-by-id module-id name-id))]))

(define (compiler-symbols-lookup-type-in-module-id
  [symbols : (& symbols CompilerSymbols)]
  [module-id : i64]
  [name-id : i64]) : option_i64.Option
  (match (compiler-symbols-reference-shared-view symbols)
    [(CompilerSymbols _ types _ _ _ _)
      (compiler-symbol-map-lookup-id
        (& types)
        (compiler-symbol-module-key-id-by-id module-id name-id))]))

(define (compiler-symbols-lookup-macro-in-module-id
  [symbols : (& symbols CompilerSymbols)]
  [module-id : i64]
  [name-id : i64]) : option_i64.Option
  (match (compiler-symbols-reference-shared-view symbols)
    [(CompilerSymbols _ _ macros _ _ _)
      (compiler-symbol-map-lookup-id
        (& macros)
        (compiler-symbol-module-key-id-by-id module-id name-id))]))

(define (compiler-symbols-lookup-value-in-module-id-or
  [symbols : (& symbols CompilerSymbols)]
  [module-id : i64]
  [name-id : i64]
  [fallback : i64]) : i64
  (match (compiler-symbols-reference-shared-view symbols)
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
  [symbols : (& symbols CompilerSymbols)]
  [module-id : i64]
  [name-id : i64]
  [fallback : i64]) : i64
  (match (compiler-symbols-reference-shared-view symbols)
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
  [symbols : (& symbols CompilerSymbols)]
  [module-id : i64]
  [name-id : i64]
  [fallback : i64]) : i64
  (match (compiler-symbols-reference-shared-view symbols)
    [(CompilerSymbols _ _ macros _ _ _)
      (let
        [handle : i64
          (compiler-symbol-map-lookup-handle-id
            (& macros)
            (compiler-symbol-module-key-id-by-id module-id name-id))]
        (if (>= handle 0)
          handle
          fallback))]))

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
        (ci.intern-syntax-id-value cleanup-name)
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
        (ci.intern-syntax-id-value cleanup-name)
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
      (let
        [body : ast.AstDeclList (deref body-box)]
        (build-compiler-symbol-list-in-module
          (ast.ast-place-shared-view body)
          body
          symbols
          index
          name))]
    [(ast.AstDecl.Test _ _ _ _) (ResultCompilerSymbols.Ok symbols)]
    [(ast.AstDecl.Unsafe inner-box)
      (let
        [inner : ast.AstDecl (deref inner-box)]
        (compiler-symbols-add-decl-in-module symbols module-id inner index))]))

(define (compiler-symbols-add-decl-in-module
  [symbols : CompilerSymbols]
  [module-id : i64]
  [decl : ast.AstDecl]
  [index : i64]) : ResultCompilerSymbols
  (let
    [generated-meta : ast.AstGeneratedDeclMeta
      (ast.ast-decl-generated-meta decl)]
    (match (compiler-symbols-add-decl-in-module-inner
      symbols
      module-id
      decl
      index)
      [(ResultCompilerSymbols.Ok next) (ResultCompilerSymbols.Ok next)]
      [(ResultCompilerSymbols.Err message)
        (ResultCompilerSymbols.Err
          (compiler-symbols-with-generated-context message generated-meta))])))

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
        (compiler-symbol-module-key-id-by-id
          alias-id
          (ci.intern-syntax-id-value cleanup-name))
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
        (compiler-symbol-module-key-id-by-id
          alias-id
          (ci.intern-syntax-id-value cleanup-name))
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
        [inner : ast.AstDecl (deref inner-box)]
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
        [inner : ast.AstDecl (deref inner-box)]
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
        [inner : ast.AstDecl (deref inner-box)]
        (compiler-symbols-macro-module-set-add-decl modules module-id inner))]
    [(ast.AstDecl.ModuleBody name body-box)
      (compiler-symbols-macro-module-set-list (deref body-box) name modules)]
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
          [decl : ast.AstDecl
            (ast.ast-array-shared-view decls.slots (+ decl-offset index))]
          [decl-for-add : ast.AstDecl (compiler-symbols-decl-shared-view decl)]
          (begin
            (match decl
              [(ast.AstDecl.Module next-module) (set! cur-module next-module)]
              [(ast.AstDecl.Import decl-meta _) unit]
              [(ast.AstDecl.IncludeStr _ _) unit]
              [(ast.AstDecl.IncludeStrComptime _ _) unit]
              [(ast.AstDecl.IncludeStrLzss _ _) unit]
              [(ast.AstDecl.IncludeBin _ _) unit]
              [(ast.AstDecl.Test _ _ _ _) unit]
              [_
                (set!
                  cur-modules
                  (compiler-symbols-macro-module-set-add-decl
                    cur-modules
                    cur-module
                    decl-for-add))])
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
  [modules : (& modules sym_i64_env.SymI64Env)]
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
  [modules : (& modules sym_i64_env.SymI64Env)]
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
          [decl : ast.AstDecl
            (ast.ast-array-shared-view decls.slots (+ decl-offset index))]
          [decl-for-add : ast.AstDecl (compiler-symbols-decl-shared-view decl)]
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
                      (deref body-box)
                      name
                      (CompilerSymbolsModuleSets macro-modules dotted-modules))]
                  (begin
                    (set! macro-modules nested.macro-modules)
                    (set! dotted-modules nested.dotted-modules)))]
              [(ast.AstDecl.IncludeStr _ _) unit]
              [(ast.AstDecl.IncludeStrComptime _ _) unit]
              [(ast.AstDecl.IncludeStrLzss _ _) unit]
              [(ast.AstDecl.IncludeBin _ _) unit]
              [(ast.AstDecl.Test _ _ _ _) unit]
              [_
                (set!
                  macro-modules
                  (compiler-symbols-macro-module-set-add-decl
                    macro-modules
                    cur-module
                    decl-for-add))])
            (set! index (+ index 1)))))
      (CompilerSymbolsModuleSets macro-modules dotted-modules))))

(define (compiler-symbols-module-sets [decls : ast.AstDeclList]) : CompilerSymbolsModuleSets
  (compiler-symbols-module-sets-list
    decls
    (compiler-symbol-root-module-id)
    (CompilerSymbolsModuleSets
      (sym_i64_env.sym-i64-empty)
      (sym_i64_env.sym-i64-empty))))

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
;; ent-ridx[k] is the global real-decl ordinal the alias handles are keyed by.
(defenum ModuleDeclIndex
  (ModuleDeclIndex
    (__tl_dyn-array i64)
    (__tl_dyn-array i64)
    i64
    (__tl_dyn-array i64)
    (__tl_dyn-array i64)
    (__tl_dyn-array i64)))

(defstruct ModuleDeclIndexRef
  (:lifetimes index)
  (value (& index ModuleDeclIndex)))

(define (compiler-module-decl-index-shared-view
  [index : (& index ModuleDeclIndex)]) : ModuleDeclIndex
  (let
    [cell : (ModuleDeclIndexRef index) (ModuleDeclIndexRef index)]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr address : (Ptr ModuleDeclIndex))))))

;; Linear probe for `module-id` in the first `num-modules` slots of `mod-ids`;
;; returns its slot or -1. Extracted from the index builder so that hot loop
;; keeps fewer values live at once.
(define (compiler-module-index-find-slot
  [mod-ids : (& mod-ids (__tl_dyn-array i64))]
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

(define (compiler-symbols-build-module-decl-index
  [decls : (& decls ast.AstDeclList)]) : ModuleDeclIndex
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
            [(ast.AstDecl.Test _ _ _ _) unit]
            [_
              (let
                [slot : i64
                  (if (>= cur-slot 0)
                    cur-slot
                    (compiler-module-index-find-slot
                      (& mod-ids)
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
  [index : (& index ModuleDeclIndex)]
  [module-id : i64]) : i64
  (match (compiler-module-decl-index-shared-view index)
    [(ModuleDeclIndex mod-ids mod-head num-modules _ _ _)
      (let
        [module-count : i64 num-modules]
        [i : i64 0]
        [head : i64 -1]
        (begin
          (while (< i module-count)
            (if (= (array-ref mod-ids i) module-id)
              (begin
                (set! head (array-ref mod-head i))
                (set! i module-count))
              (set! i (+ i 1))))
          head))]))

(define (compiler-symbols-module-has-macro-map?
  [symbols : (& symbols CompilerSymbols)]
  [target-module-id : i64]) : bool
  (match (compiler-symbols-reference-shared-view symbols)
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
  (let
    [cur-symbols : CompilerSymbols (compiler-symbols-shared-view symbols)]
    (match (compiler-symbols-shared-view cur-symbols)
      [(CompilerSymbols _ _ macros decls _ _)
        (let
          [capacity : i64 (array-length macros.keys)]
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
                        (ast.ast-array-shared-view decls decl-index)
                        decl-index))
                    unit))
                unit)
              (set! index (+ index 1)))
            cur-symbols))])))

;; An explicit `module ... as alias` import resolves dotted uses through the
;; import target directly. It should not leave the module's legacy bare macro
;; alias in the importer.
(define (compiler-symbols-remove-module-macro-aliases-indexed
  [symbols : CompilerSymbols]
  [decls : (& decls ast.AstDeclList)]
  [index : ModuleDeclIndex]
  [target-module-id : i64]
  [handle-index-offset : i64]) : CompilerSymbols
  (let
    [head : i64 (compiler-module-decl-index-head (& index) target-module-id)]
    (match index
      [(ModuleDeclIndex _ _ _ ent-pos ent-ridx ent-next)
        (let
          [decl-offset : i64 decls.offset]
          [slots : (__tl_dyn-array ast.AstDecl) decls.slots]
          [cur-symbols : CompilerSymbols symbols]
          [k : i64 head]
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
                    (ast.ast-array-shared-view
                      slots
                      (+ decl-offset (array-ref ent-pos k)))
                    (+ handle-index-offset (array-ref ent-ridx k))))
                (set! k (array-ref ent-next k))))
            cur-symbols))])))

(define (compiler-symbols-add-module-aliases-indexed
  [symbols : CompilerSymbols]
  [decls : (& decls ast.AstDeclList)]
  [index : ModuleDeclIndex]
  [target-module-id : i64]
  [alias-id : i64]
  [handle-index-offset : i64]) : CompilerSymbols
  (let
    [head : i64 (compiler-module-decl-index-head (& index) target-module-id)]
    (match index
      [(ModuleDeclIndex _ _ _ ent-pos ent-ridx ent-next)
        (let
          [decl-offset : i64 decls.offset]
          [slots : (__tl_dyn-array ast.AstDecl) decls.slots]
          [cur-symbols : CompilerSymbols symbols]
          [k : i64 head]
          (begin
            (while (>= k 0)
              (begin
                (set!
                  cur-symbols
                  (compiler-symbols-add-decl-alias-in-module
                    cur-symbols
                    alias-id
                    (ast.ast-array-shared-view
                      slots
                      (+ decl-offset (array-ref ent-pos k)))
                    (+ handle-index-offset (array-ref ent-ridx k))))
                (set! k (array-ref ent-next k))))
            cur-symbols))])))

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
          [decl : ast.AstDecl
            (ast.ast-array-shared-view decls.slots (+ decl-offset index))]
          [decl-for-module : ast.AstDecl
            (compiler-symbols-decl-shared-view decl)]
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
                  (compiler-symbols-shared-view cur-symbols)
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
                        (compiler-symbols-shared-view cur-symbols)
                        all-decls
                        (ast.ast-place-shared-view decl-index)
                        target-module-id
                        handle-index-offset)
                      (compiler-symbols-shared-view cur-symbols))]
                  (if (= alias cbi.compiler-builtin-id-fix-empty)
                    (compiler-symbols-add-module-aliases-indexed
                      without-bare-macros
                      all-decls
                      (ast.ast-place-shared-view decl-index)
                      target-module-id
                      cur-module-id
                      handle-index-offset)
                    without-bare-macros))]
              [_ (compiler-symbols-shared-view cur-symbols)])]
          (begin
            (set! cur-symbols next-symbols)
            (match decl-for-module
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
    (ast.ast-place-shared-view decls)
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
    [(ast.AstDecl.Test _ _ _ _) false]
    [_ true]))

(define (compiler-symbol-path-list-repeat
  [decls : (& decls ast.AstDeclList)]
  [path : String]
  [owner-id : i64]) : ast.AstDeclPathList
  (compiler-symbol-path-list-repeat-with-provenance
    decls
    path
    owner-id
    owner-id))

(define (compiler-symbol-path-list-repeat-with-provenance
  [decls : (& decls ast.AstDeclList)]
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
            (string.copy (& path))
            owner-id
            provenance-id)
          (set! index (+ index 1))))
      out)))

(define (compiler-symbol-path-at-index-head
  [decl : ast.AstDecl]
  [rest : ast.AstDeclList]
  [decl-path : String]
  [rest-paths : ast.AstDeclPathList]
  [owner-id : i64]
  [target : i64]
  [index : i64]) : String
  (let
    [decl-for-count : ast.AstDecl (compiler-symbols-decl-shared-view decl)]
    (match decl
      [(ast.AstDecl.ModuleBody _ body-box)
        (let
          [body : ast.AstDeclList (deref body-box)]
          [body-count : i64 (compiler-decl-list-index-count body)]
          (if (< target (+ index body-count))
            (compiler-symbol-path-at-index
              (ast.ast-place-shared-view body)
              (compiler-symbol-path-list-repeat body decl-path owner-id)
              target
              index)
            (compiler-symbol-path-at-index
              rest
              rest-paths
              target
              (+ index body-count))))]
      [_
        (if (compiler-symbol-decl-counts-for-index? decl-for-count)
          (if (= target index)
            decl-path
            (compiler-symbol-path-at-index rest rest-paths target (+ index 1)))
          (compiler-symbol-path-at-index rest rest-paths target index))])))

(define (compiler-symbol-path-at-index
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [target : i64]
  [index : i64]) : String
  (let
    [owner-id : i64
      (ast.ast-decl-path-list-owner-id
        (& paths)
        0
        cbi.compiler-builtin-id-fix-empty)]
    (match (ast.ast-decl-list-step decls)
      [(ast.AstDeclListStep.Nil) ""]
      [(ast.AstDeclListStep.Cons decl rest)
        (match (ast.ast-decl-path-list-step paths)
          [(ast.AstDeclPathListStep.Cons path path-rest)
            (compiler-symbol-path-at-index-head
              decl
              rest
              path
              path-rest
              owner-id
              target
              index)]
          [(ast.AstDeclPathListStep.Nil)
            (compiler-symbol-path-at-index-head
              decl
              rest
              ""
              (ast.ast-decl-path-list-new)
              owner-id
              target
              index)])])))

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
  [symbols : (& symbols CompilerSymbols)]
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
  [symbols : (& symbols CompilerSymbols)]
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
        [inner : ast.AstDecl (deref inner-box)]
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
  (let
    [fallback : ast.AstDecl (compiler-symbols-decl-shared-view decl)]
    (match decl
      [(ast.AstDecl.Unsafe inner-box)
        (let
          [inner : ast.AstDecl (deref inner-box)]
          inner)]
      [_ fallback])))

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

(define (compiler-symbols-index-decl
  [symbols : CompilerSymbols]
  [decl : ast.AstDecl]
  [index : i64]
  [module-id : i64]
  [provenance-id : i64]) : CompilerSymbols
  (match (compiler-symbols-shared-view symbols)
    [(CompilerSymbols values types macros decls owner-module-ids decl-count)
      (let
        [indexed : ast.AstDecl (compiler-symbol-indexed-decl decl)]
        (begin
          (set! (array-ref decls index) indexed)
          (set! (array-ref owner-module-ids index) module-id)
          (set!
            (array-ref owner-module-ids (+ (array-length decls) index))
            provenance-id)
          (CompilerSymbols
            values
            types
            macros
            decls
            owner-module-ids
            decl-count)))]))

(define (compiler-symbols-owner-module-id-at-index-or
  [symbols : (& symbols CompilerSymbols)]
  [target : i64]
  [fallback : i64]) : i64
  (let
    [owner-module-ids : (__tl_dyn-array i64)
      (compiler-symbols-owner-module-ids symbols)]
    (if (or (< target 0) (>= target (compiler-symbols-decl-count symbols)))
      fallback
      (array-ref owner-module-ids target))))

(define (compiler-symbols-provenance-id-at-index-or
  [symbols : (& symbols CompilerSymbols)]
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
  [symbols : (& symbols CompilerSymbols)]
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
            (ast.ast-array-shared-view decls target)
            (array-ref owner-module-ids target))]
        (if (< owner-id 0)
          fallback
          owner-id)))))

(define (compiler-symbols-owner-name-at-index
  [symbols : (& symbols CompilerSymbols)]
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
            (ast.ast-array-shared-view decls target)
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
        [decl-for-index : ast.AstDecl (compiler-symbols-decl-shared-view decl)]
        [decl-for-add : ast.AstDecl (compiler-symbols-decl-shared-view decl)]
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
              [body : ast.AstDeclList (deref body-box)]
              [body-count : i64 (compiler-decl-list-index-count body)]
              (match (build-compiler-symbol-list-in-module
                (ast.ast-place-shared-view all-decls)
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
          [(ast.AstDecl.Test _ _ _ _)
            (build-compiler-symbol-list-in-module
              all-decls
              rest
              symbols
              index
              module-id)]
          [_
            (begin
              (set!
                symbols
                (compiler-symbols-index-decl
                  symbols
                  decl-for-index
                  index
                  module-id
                  cbi.compiler-builtin-id-fix-empty))
              (match (compiler-symbols-add-decl-in-module
                symbols
                module-id
                decl-for-add
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
            (return (ResultCompilerSymbols.Ok cur-symbols))]
          [(ast.AstDeclListStep.Cons decl rest)
            (let
              [rest : ast.AstDeclList rest]
              [decl-master : ast.AstDecl
                (compiler-symbols-decl-shared-view decl)]
              [decl-path : String
                (ast.ast-decl-path-list-get (& cur-paths) 0 "")]
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
                (ast.ast-decl-path-list-tail
                  (ast.ast-place-shared-view cur-paths))]
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
                    [body : ast.AstDeclList (deref body-box)]
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
                      (ast.ast-place-shared-view all-decls)
                      (ast.ast-place-shared-view all-paths)
                      body
                      body-paths
                      (compiler-symbols-shared-view cur-symbols)
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
                [(ast.AstDecl.Test _ _ _ _)
                  (begin
                    (set! cur-decls rest)
                    (set! cur-paths rest-paths)
                    (set! cur-position (+ cur-position 1)))]
                [_
                  (match (compiler-symbols-duplicate-value-message-for-decl-with-paths-id
                    (& cur-symbols)
                    (ast.ast-place-shared-view all-decls)
                    (ast.ast-place-shared-view all-paths)
                    cur-module-id
                    (compiler-symbols-decl-shared-view decl-master)
                    cur-index
                    (string.copy (& decl-path)))
                    [(CompilerSomeString message)
                      (begin
                        (compiler-symbols-note-last-error!
                          decl-origin-key
                          (+ decl-origin-offset cur-position)
                          decl-master
                          (string.copy (& decl-path)))
                        (set! result (ResultCompilerSymbols.Err message))
                        (set! done true))]
                    [CompilerNoString
                      (begin
                        ;; Keep the cheap expression/member fallback current for
                        ;; later registry diagnostics. Cold declaration-origin
                        ;; lookup is deferred until this add actually fails.
                        (compiler-symbols-note-last-error-fallback!
                          (compiler-symbols-decl-shared-view decl-master)
                          (& decl-path))
                        (set!
                          cur-symbols
                          (compiler-symbols-index-decl
                            cur-symbols
                            (compiler-symbols-decl-shared-view decl-master)
                            cur-index
                            (if (and
                              ;; Source nominal declarations loaded through a
                              ;; legacy path retain their flat lookup aliases but
                              ;; share the dotted import's canonical owner.
                              (not (ast.ast-decl-comptime-only? decl-master))
                              (match (compiler-symbols-decl-shared-view
                                decl-master)
                                [(ast.AstDecl.DefEnum decl-meta _ _ _) true]
                                [(ast.AstDecl.DefEnumLifetimes
                                    decl-meta
                                    _
                                    _
                                    _
                                    _)
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
                            path-provenance-id))
                        (match (compiler-symbols-add-decl-in-module
                          cur-symbols
                          cur-module-id
                          (compiler-symbols-decl-shared-view decl-master)
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
                                  decl-master
                                  (string.copy (& decl-path))))
                              (set! result (ResultCompilerSymbols.Err message))
                              (set! done true))]))])]))]))
      result)))

(define (build-compiler-symbols [program : (& program ast.AstProgram)]) : ResultCompilerSymbols
  (match (compiler-symbols-program-shared-view program)
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (match (build-compiler-symbol-list
          (ast.ast-place-shared-view decls)
          (compiler-symbols-empty-with-decls
            (compiler-decl-list-index-count decls))
          0)
          [(ResultCompilerSymbols.Ok symbols)
            (let
              [macro-modules : sym_i64_env.SymI64Env
                (compiler-symbols-macro-module-set
                  (ast.ast-place-shared-view decls))]
              [aliased : CompilerSymbols
                (build-compiler-symbol-aliases-list
                  (ast.ast-place-shared-view decls)
                  decls
                  symbols
                  (compiler-symbol-root-module-id)
                  macro-modules)]
              (ResultCompilerSymbols.Ok aliased))]
          [(ResultCompilerSymbols.Err message)
            (ResultCompilerSymbols.Err message)]))]))

(define (build-compiler-symbols-with-paths-and-capacity
  [program : (& program ast.AstProgram)]
  [paths : ast.AstDeclPathList]
  [requested-capacity : i64]) : ResultCompilerSymbols
  (match (compiler-symbols-program-shared-view program)
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        [module-sets : CompilerSymbolsModuleSets
          (compiler-symbols-module-sets (ast.ast-place-shared-view decls))]
        [decl-count : i64 (compiler-decl-list-index-count decls)]
        (match (build-compiler-symbol-list-with-paths-in-module
          (ast.ast-place-shared-view decls)
          (ast.ast-place-shared-view paths)
          (ast.ast-place-shared-view decls)
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
                  (ast.ast-place-shared-view decls)
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
                (deref body-box)
                target-module-id))]
          [(ast.AstDecl.Unsafe inner-box)
            (match (deref inner-box)
              [(ast.AstDecl.ModuleBody module-id body-box)
                (or
                  (= module-id target-module-id)
                  (compiler-symbols-decls-declare-module-id?
                    (deref body-box)
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
            (compiler-symbols-insert-import-safe?
              (ast.ast-place-shared-view all-decls)
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
          ;; File-backed imports do not install symbol/registry aliases. The
          ;; macro walk materializes them immediately afterward; that path
          ;; intentionally performs the conservative whole-program rebuild.
          [(ast.AstDecl.Import decl-meta _) true]
          [(ast.AstDecl.ModuleBody _ body-box)
            (compiler-symbols-insert-aliases-self-contained?
              (ast.ast-place-shared-view all-decls)
              (deref body-box))]
          [(ast.AstDecl.Unsafe inner-box)
            (match (deref inner-box)
              [(ast.AstDecl.Import
                  decl-meta
                  (ast.AstImportSpec.Spec
                    _
                    _
                    (ast.AstMaybeModuleName.Some target-module)
                    (ast.AstMaybeImportAlias.Some alias)
                    _))
                (compiler-symbols-insert-import-safe?
                  (ast.ast-place-shared-view all-decls)
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
      (ast.ast-place-shared-view decls)
      (ast.ast-place-shared-view decls)
      grown
      old-count
      module-id)
      [(ResultCompilerSymbols.Ok appended)
        (let
          [macro-modules : sym_i64_env.SymI64Env
            (compiler-symbols-macro-module-set
              (ast.ast-place-shared-view decls))]
          [aliased : CompilerSymbols
            (build-compiler-symbol-aliases-list-with-index-offset
              (ast.ast-place-shared-view decls)
              decls
              appended
              module-id
              macro-modules
              old-count)]
          (ResultCompilerSymbols.Ok
            (compiler-symbols-with-decl-count aliased (+ old-count added-count))))]
      [(ResultCompilerSymbols.Err message) (ResultCompilerSymbols.Err message)])))

(define (compiler-registries-lookup-variant-id
  [registries : (& registries CompilerRegistries)]
  [name-id : i64]) : option_i64.Option
  (match (compiler-registries-reference-shared-view registries)
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
  [registries : (& registries CompilerRegistries)]
  [key-id : i64]) : option_i64.Option
  (match (compiler-registries-reference-shared-view registries)
    [(CompilerRegistries variants _ _)
      (compiler-symbol-map-lookup-id (& variants) key-id)]))

(define (compiler-registries-lookup-struct-field-id
  [registries : (& registries CompilerRegistries)]
  [struct-name-id : i64]
  [field-name-id : i64]) : option_i64.Option
  (match (compiler-registries-reference-shared-view registries)
    [(CompilerRegistries _ fields _)
      (compiler-symbol-map-lookup-id
        (& fields)
        (compiler-struct-field-key-id-by-id struct-name-id field-name-id))]))

(define (compiler-registries-lookup-variant-id-or
  [registries : (& registries CompilerRegistries)]
  [name-id : i64]
  [fallback : i64]) : i64
  (match (compiler-registries-reference-shared-view registries)
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
  [registries : (& registries CompilerRegistries)]
  [key-id : i64]
  [fallback : i64]) : i64
  (match (compiler-registries-reference-shared-view registries)
    [(CompilerRegistries variants _ _)
      (let
        [handle : i64
          (compiler-symbol-map-lookup-handle-id (& variants) key-id)]
        (if (>= handle 0)
          handle
          fallback))]))

(define (compiler-registries-lookup-struct-field-id-or
  [registries : (& registries CompilerRegistries)]
  [struct-name-id : i64]
  [field-name-id : i64]
  [fallback : i64]) : i64
  (match (compiler-registries-reference-shared-view registries)
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
  [registries : CompilerRegistries]
  [module-id : i64]
  [enum-name-id : i64]
  [name-id : i64]
  [enum-index : i64]
  [variant-index : i64]) : ResultCompilerRegistries
  (if (not (compiler-registry-indexes-encodable? enum-index variant-index))
    (ResultCompilerRegistries.Err
      (compiler-registry-limit-message
        "enum"
        (compiler-symbol-module-key-by-id module-id enum-name-id)
        "variants"
        enum-index))
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
      (match (compiler-registries-shared-view registries)
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
                (ResultCompilerRegistries.Ok aliases2))))]))))

(define (compiler-registries-add-field-in-module-id
  [registries : CompilerRegistries]
  [module-id : i64]
  [struct-name-id : i64]
  [field-name-id : i64]
  [struct-index : i64]
  [field-index : i64]) : ResultCompilerRegistries
  (if (not (compiler-registry-indexes-encodable? struct-index field-index))
    (ResultCompilerRegistries.Err
      (compiler-registry-limit-message
        "struct"
        (compiler-symbol-module-key-by-id module-id struct-name-id)
        "fields"
        struct-index))
    (match (compiler-registries-shared-view registries)
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
                (CompilerRegistries variants fields identity)))))])))

(define (compiler-registries-add-field-alias
  [registries : CompilerRegistries]
  [module-id : i64]
  [struct-name-id : i64]
  [field-name-id : i64]
  [handle : i64]) : CompilerRegistries
  (match (compiler-registries-shared-view registries)
    [(CompilerRegistries variants fields identity)
      (let
        [key-id : i64
          (compiler-struct-field-key-id-in-module-by-id
            module-id
            struct-name-id
            field-name-id)]
        (if (compiler-symbol-map-contains-id? (& fields) key-id)
          (CompilerRegistries variants fields identity)
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
            (ci.intern-syntax-id-value name)
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
  [decls : (& decls ast.AstDeclList)]
  [index : ModuleDeclIndex]
  [target-module-id : i64]
  [alias-id : i64]
  [handle-index-offset : i64]) : CompilerRegistries
  (let
    [head : i64 (compiler-module-decl-index-head (& index) target-module-id)]
    (match index
      [(ModuleDeclIndex _ _ _ ent-pos ent-ridx ent-next)
        (let
          [decl-offset : i64 decls.offset]
          [slots : (__tl_dyn-array ast.AstDecl) decls.slots]
          [cur-registries : CompilerRegistries registries]
          [k : i64 head]
          (begin
            (while (>= k 0)
              (begin
                (set!
                  cur-registries
                  (compiler-registries-add-decl-alias-in-module
                    cur-registries
                    alias-id
                    (ast.ast-array-shared-view
                      slots
                      (+ decl-offset (array-ref ent-pos k)))
                    (+ handle-index-offset (array-ref ent-ridx k))))
                (set! k (array-ref ent-next k))))
            cur-registries))])))

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
              [decl : ast.AstDecl
                (ast.ast-array-shared-view decls.slots (+ decl-offset index))]
              [decl-for-module : ast.AstDecl
                (compiler-symbols-decl-shared-view decl)]
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
                        (compiler-registries-shared-view cur-registries)
                        all-decls
                        (ast.ast-place-shared-view decl-index)
                        target-module
                        (compiler-symbols-import-alias-key-id
                          cur-module-id
                          alias)
                        handle-index-offset)
                      (compiler-registries-shared-view cur-registries))]
                  [_ (compiler-registries-shared-view cur-registries)])]
              (begin
                (set! cur-registries next-registries)
                (match decl-for-module
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
        (let
          [name-id : i64 (ci.intern-syntax-id-value name)]
          (if (sym_i64_env.sym-i64-contains-id seen name-id)
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
                  (ci.intern-str name-id))))
            (match (compiler-registries-add-field-in-module-id
              registries
              module-id
              struct-name-id
              name-id
              struct-index
              field-index)
              [(ResultCompilerRegistries.Ok next-registries)
                (build-compiler-field-registry-list
                  fields
                  next-registries
                  (sym_i64_env.sym-i64-bind-id seen name-id field-index)
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
                  (ResultCompilerRegistries.Err message))])))])))

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
          (return (ResultCompilerRegistries.Ok cur-registries))
          (let
            [decl : ast.AstDecl
              (ast.ast-array-shared-view decls.slots (+ decl-offset position))]
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
                  [body : ast.AstDeclList (deref body-box)]
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
                    (compiler-registries-shared-view cur-registries)
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
              [(ast.AstDecl.Test _ _ _ _) (set! position (+ position 1))]
              [(ast.AstDecl.DefEnum decl-meta name _ variants)
                (match (build-compiler-variant-registry-list-in-module
                  variants
                  (compiler-registries-shared-view cur-registries)
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
                  (compiler-registries-shared-view cur-registries)
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
                  (compiler-registries-shared-view cur-registries)
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
                  (compiler-registries-shared-view cur-registries)
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
    (ast.ast-place-shared-view decls)
    paths
    (compiler-registries-empty)
    0
    (compiler-symbol-root-module-id))
    [(ResultCompilerRegistries.Ok registries)
      (let
        [aliased : CompilerRegistries
          (build-compiler-registry-aliases-list
            (ast.ast-place-shared-view decls)
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
        [decls : ast.AstDeclList (deref decls-box)]
        (build-compiler-registries-for-decls-with-paths
          (ast.ast-place-shared-view decls)
          (compiler-symbol-path-list-repeat
            decls
            ""
            cbi.compiler-builtin-id-fix-empty)))]))

;; Companion to compiler-symbols-insert-decls: when symbol handles append, new
;; registry owners use the same append index and no existing owner shifts.
(define (compiler-registries-append-decls
  [registries : CompilerRegistries]
  [decls : ast.AstDeclList]
  [paths : ast.AstDeclPathList]
  [append-index : i64]
  [module-id : i64]) : ResultCompilerRegistries
  (match (build-compiler-registry-list-in-module
    (ast.ast-place-shared-view decls)
    paths
    registries
    append-index
    module-id)
    [(ResultCompilerRegistries.Ok appended)
      (ResultCompilerRegistries.Ok
        (build-compiler-registry-aliases-list-with-index-offset
          (ast.ast-place-shared-view decls)
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
          [decls : ast.AstDeclList (deref decls-box)]
          (match (build-compiler-registries-for-decls-with-paths decls paths)
            [(ResultCompilerRegistries.Ok registries)
              (ResultCompilerRegistriesDiagnostic.Ok registries)]
            [(ResultCompilerRegistries.Err message)
              (ResultCompilerRegistriesDiagnostic.Err
                (box (compiler-symbols-last-error-diagnostic message)))]))])))

(define (build-compiler-registries [program : (& program ast.AstProgram)]) : ResultCompilerRegistries
  (match (build-compiler-symbols program)
    [(ResultCompilerSymbols.Ok symbols)
      (build-compiler-registries-with-symbols
        (compiler-symbols-program-shared-view program)
        symbols)]
    [(ResultCompilerSymbols.Err message) (ResultCompilerRegistries.Err message)]))

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
          [decl : ast.AstDecl
            (ast.ast-array-shared-view decls.slots (+ decl-offset slot))]
          [decl-view : ast.AstDecl (compiler-symbols-decl-shared-view decl)]
          [return-view : ast.AstDecl
            (compiler-symbols-decl-shared-view decl-view)]
          (begin
            (match decl
              [(ast.AstDecl.Import decl-meta _) unit]
              [(ast.AstDecl.IncludeStr _ _) unit]
              [(ast.AstDecl.IncludeStrComptime _ _) unit]
              [(ast.AstDecl.IncludeStrLzss _ _) unit]
              [(ast.AstDecl.IncludeBin _ _) unit]
              [(ast.AstDecl.Module _) unit]
              [(ast.AstDecl.Test _ _ _ _) unit]
              [_
                (if (= target logical-index)
                  (return
                    (match decl-view
                      [(ast.AstDecl.Unsafe inner-box)
                        (let
                          [inner : ast.AstDecl (deref inner-box)]
                          (parser.ResultAstDecl.Ok inner))]
                      [_ (parser.ResultAstDecl.Ok return-view)]))
                  (set! logical-index (+ logical-index 1)))])
            (set! slot (+ slot 1)))))
      (parser.ResultAstDecl.Err "symbols: declaration index not found"))))

(define (compiler-program-decl-at-index
  [program : ast.AstProgram]
  [target : i64]) : parser.ResultAstDecl
  (match program
    [(ast.AstProgram.Program decls-box)
      (let
        [decls : ast.AstDeclList (deref decls-box)]
        (compiler-decl-list-at-index decls target 0))]))

(define (compiler-symbols-decl-at-index
  [symbols : (& symbols CompilerSymbols)]
  [target : i64]) : parser.ResultAstDecl
  (let
    [decls : (__tl_dyn-array ast.AstDecl) (compiler-symbols-decls symbols)]
    (if (or (< target 0) (>= target (compiler-symbols-decl-count symbols)))
      (parser.ResultAstDecl.Err "symbols: declaration index not found")
      (parser.ResultAstDecl.Ok (ast.ast-array-shared-view decls target)))))

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

(define (compiler-registries-variant-fields-indexed
  [symbols : (& symbols CompilerSymbols)]
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
  [symbols : (& symbols CompilerSymbols)]
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
  [symbols : (& symbols CompilerSymbols)]
  [handle : i64]) : parser.ResultAstType
  (let
    [decls : (__tl_dyn-array ast.AstDecl) (compiler-symbols-decls symbols)]
    [owner-index : i64 (compiler-registry-handle-owner-index handle)]
    [child-index : i64 (compiler-registry-handle-child-index handle)]
    (if (or
      (< owner-index 0)
      (>= owner-index (compiler-symbols-decl-count symbols)))
      (parser.ResultAstType.Err "symbols: declaration index not found")
      (match (ast.ast-array-shared-view decls owner-index)
        [(ast.AstDecl.DefStruct decl-meta _ _ _ fields)
          (compiler-field-type-at-index fields child-index 0)]
        [(ast.AstDecl.DefStructLifetimes decl-meta _ _ _ _ fields)
          (compiler-field-type-at-index fields child-index 0)]
        [_ (parser.ResultAstType.Err "symbols: field owner is not struct")]))))

(define (compiler-symbols-decl-name-id-at-index
  [symbols : (& symbols CompilerSymbols)]
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